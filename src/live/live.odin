// The surface trek offers other programs, over a unix socket.
//
// This is a deliberately small subset of the Lua config API, not a mirror of it: most of a
// config API is meaningless remotely (registrars, settings applied at load) or dangerous
// (anything that runs a command). What a sibling genuinely wants from a *running* trek is
// where it is standing and what is under the cursor -- facts it cannot get any other way,
// because they exist only inside this process.
//
// trek is therefore socket-only and writes no spawn descriptor: its truth IS the process.
// A fresh `trek` knows nothing about this one's root, expansion or selection, so answering
// from a new process would succeed while being wrong, which is worse than refusing.
package live

import "base:runtime"
import c "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

// A control socket serves occasional questions, not traffic. Every bound has a number.
MAX_CONNECTIONS :: 4
MAX_REQUEST :: 64 * 1024
MAX_RESPONSE :: 1024 * 1024
FRAME_HEADER :: 4

// What the host tells the server about itself each poll. Passed in rather than reached for,
// so this package never depends on the ui.
Snapshot :: struct {
	root:      string,
	selection: string,
	is_dir:    bool,
	tab:       string,
	tabs:      []string,
}

Connection :: struct {
	fd:      posix.FD,
	pending: [dynamic]byte,
	open:    bool,
}

Server :: struct {
	fd:          posix.FD,
	path:        string,
	connections: [MAX_CONNECTIONS]Connection,
	allocator:   runtime.Allocator,
	listening:   bool,
}

// $XDG_RUNTIME_DIR/onix/trek/<pid>.sock -- the family directory oslo already uses, so a
// sibling looks in one place for every tool rather than learning a path per tool.
socket_path :: proc(allocator := context.allocator) -> string {
	runtime_dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	base := runtime_dir
	if base == "" {
		base = fmt.tprintf("/tmp/onix-%d", posix.getuid())
	} else {
		base = fmt.tprintf("%s/onix", runtime_dir)
	}
	dir, _ := filepath.join([]string{base, "trek"}, context.temp_allocator)
	name := fmt.tprintf("%d.sock", posix.getpid())
	path, _ := filepath.join([]string{dir, name}, allocator)
	return path
}

// SO_PEERCRED, declared here because Odin's core does not carry it. Peer identity has to
// come from the kernel: a pid or uid the peer wrote into a message is a claim, this is a
// fact, and the difference decides whether the gate below means anything.
SOL_SOCKET :: 1
SO_PEERCRED :: 17

Ucred :: struct {
	pid: i32,
	uid: u32,
	gid: u32,
}

foreign import libc "system:c"
foreign libc {
	getsockopt :: proc(fd: posix.FD, level, optname: i32, optval: rawptr, optlen: ^u32) -> i32 ---
}

peer_is_owner :: proc(fd: posix.FD) -> bool {
	credentials: Ucred
	length := u32(size_of(Ucred))
	if getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) != 0 do return false
	return credentials.uid == u32(posix.getuid())
}

set_nonblocking :: proc(fd: posix.FD) {
	flags := posix.fcntl(fd, .GETFL)
	posix.fcntl(fd, .SETFL, flags | i32(posix.O_NONBLOCK))
}

// Bind on demand. Most runs are never asked anything and should have no socket at all,
// which is what makes the feature safe to leave available by default.
serve :: proc(server: ^Server, allocator := context.allocator) -> (string, bool) {
	server.allocator = allocator
	path := socket_path(allocator)
	dir := filepath.dir(path, context.temp_allocator)
	if os.make_directory_all(dir) != nil && !os.exists(dir) {
		delete(path, allocator)
		return "", false
	}
	// 0700: on Linux the directory mode is what actually keeps another user out, and the
	// credential check above is the second lock rather than the only one.
	_ = os.chmod(dir, os.Permissions{.Read_User, .Write_User, .Execute_User})

	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		delete(path, allocator)
		return "", false
	}
	address: posix.sockaddr_un
	address.sun_family = .UNIX
	bytes := transmute([]byte)path
	if len(bytes) >= len(address.sun_path) {
		posix.close(fd)
		delete(path, allocator)
		return "", false
	}
	for b, index in bytes do address.sun_path[index] = c_char_of(b)
	// A stale socket is one nothing is listening on; unlink and rebind rather than refusing
	// to start, since the previous trek that owned this pid is long gone.
	os.remove(path)
	if posix.bind(fd, cast(^posix.sockaddr)&address, posix.socklen_t(size_of(posix.sockaddr_un))) != .OK {
		posix.close(fd)
		delete(path, allocator)
		return "", false
	}
	if posix.listen(fd, MAX_CONNECTIONS) != .OK {
		posix.close(fd)
		os.remove(path)
		delete(path, allocator)
		return "", false
	}
	set_nonblocking(fd)
	server.fd = fd
	server.path = path
	server.listening = true
	return path, true
}

c_char_of :: proc(value: byte) -> c.char {
	return c.char(value)
}

stop :: proc(server: ^Server) {
	if !server.listening do return
	for &connection in server.connections {
		if connection.open {
			posix.close(connection.fd)
			delete(connection.pending)
			connection.open = false
		}
	}
	posix.close(server.fd)
	os.remove(server.path)
	delete(server.path, server.allocator)
	server^ = {}
}

// Four bytes of big-endian length, then the body. A socket is a stream with no message
// boundaries; without a length prefix every reader invents its own delimiter.
frame_length :: proc(header: []byte) -> int {
	return int(header[0]) << 24 | int(header[1]) << 16 | int(header[2]) << 8 | int(header[3])
}

write_frame :: proc(fd: posix.FD, body: string) {
	header := [4]byte{
		byte(len(body) >> 24), byte(len(body) >> 16), byte(len(body) >> 8), byte(len(body)),
	}
	posix.send(fd, raw_data(header[:]), 4, {})
	if len(body) > 0 do posix.send(fd, raw_data(body), uint(len(body)), {})
}

Request :: struct {
	call: string,
	args: []json.Value,
}

// Poll once from the host's event loop. Accepts and reads are non-blocking and a request
// that has not finished arriving is left for the next iteration: a stalled reader must
// never suspend the thing the user is actually using.
poll :: proc(server: ^Server, snapshot: Snapshot) {
	if !server.listening do return
	for {
		fd := posix.accept(server.fd, nil, nil)
		if fd < 0 do break
		if !peer_is_owner(fd) {
			posix.close(fd)
			continue
		}
		set_nonblocking(fd)
		placed := false
		for &connection in server.connections {
			if connection.open do continue
			connection.fd = fd
			connection.pending = make([dynamic]byte, server.allocator)
			connection.open = true
			placed = true
			break
		}
		// Over the connection cap: refuse rather than queue, so a peer that opens
		// without ever asking cannot lock the others out indefinitely.
		if !placed do posix.close(fd)
	}
	for &connection in server.connections {
		if !connection.open do continue
		if !read_available(&connection) {
			close_connection(&connection)
			continue
		}
		// A connection serves more than one request: a client that holds one open is the
		// obvious way to write one, and closing after each reply kills it on its second call.
		for serve_one(&connection, snapshot) {}
	}
}

read_available :: proc(connection: ^Connection) -> bool {
	scratch: [4096]byte
	for {
		count := posix.recv(connection.fd, raw_data(scratch[:]), len(scratch), {})
		if count == 0 do return false
		if count < 0 do return true
		if len(connection.pending) + int(count) > MAX_REQUEST + FRAME_HEADER do return false
		append(&connection.pending, ..scratch[:count])
	}
}

close_connection :: proc(connection: ^Connection) {
	posix.close(connection.fd)
	delete(connection.pending)
	connection^ = {}
}

// One complete frame, if one has arrived. Returns whether it handled anything, so the
// caller can drain a peer that pipelined several.
serve_one :: proc(connection: ^Connection, snapshot: Snapshot) -> bool {
	if len(connection.pending) < FRAME_HEADER do return false
	length := frame_length(connection.pending[:FRAME_HEADER])
	if length < 0 || length > MAX_REQUEST {
		close_connection(connection)
		return false
	}
	if len(connection.pending) < FRAME_HEADER + length do return false
	body := string(connection.pending[FRAME_HEADER:][:length])
	reply := dispatch(body, snapshot, context.temp_allocator)
	write_frame(connection.fd, reply)
	remaining := len(connection.pending) - FRAME_HEADER - length
	copy(connection.pending[:], connection.pending[FRAME_HEADER + length:])
	resize(&connection.pending, remaining)
	return true
}

// The whole vocabulary, on one screen. Plural-for-all, singular-for-one, matching the rest
// of the family. `verbs` ships from the first version: a client written against a tool that
// has it gets "no such call: verbs" from one that does not, and the family stops being one.
VERBS := []string{"verbs", "session", "cwd", "selection", "tabs", "client"}

// The client stub trek ships, handed out over the API as well as on stdout: a sandboxed VM
// with no io.popen cannot run `trek --lua-api`, and this is the only way it can fetch the
// right vocabulary using the wrong one.
CLIENT_SOURCE :: #load("../../lua/trek/client.lua")

json_escape :: proc(value: string, builder: ^strings.Builder) {
	strings.write_byte(builder, '"')
	for index in 0 ..< len(value) {
		ch := value[index]
		switch ch {
		case '"':  strings.write_string(builder, "\\\"")
		case '\\': strings.write_string(builder, "\\\\")
		case '\n': strings.write_string(builder, "\\n")
		case '\r': strings.write_string(builder, "\\r")
		case '\t': strings.write_string(builder, "\\t")
		case:
			if ch < 0x20 {
				strings.write_string(builder, fmt.tprintf("\\u%04x", int(ch)))
			} else {
				strings.write_byte(builder, ch)
			}
		}
	}
	strings.write_byte(builder, '"')
}

// `result` is a LIST and `n` says how many, matching oslo exactly. A family where one tool
// answers {"result": value} and another {"result": [value], "n": 1} fails *silently*: a
// client that unpacks reads nothing at all from the first, and an empty answer looks like
// an empty session rather than a protocol mismatch.
ok_reply :: proc(values: []string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, "{\"ok\":true,\"n\":")
	strings.write_string(&builder, fmt.tprintf("%d", len(values)))
	strings.write_string(&builder, ",\"result\":[")
	for value, index in values {
		if index > 0 do strings.write_string(&builder, ",")
		strings.write_string(&builder, value)
	}
	strings.write_string(&builder, "]}")
	return strings.to_string(builder)
}

// A refused verb is a reply, not a failure: the caller sees the tool's own error rather
// than a transport one. "no such call: nope" says what to fix; a dropped connection does not.
error_reply :: proc(message: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, "{\"ok\":false,\"error\":")
	json_escape(message, &builder)
	strings.write_string(&builder, "}")
	return strings.to_string(builder)
}

quoted :: proc(value: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	json_escape(value, &builder)
	return strings.to_string(builder)
}

string_list :: proc(values: []string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, "[")
	for value, index in values {
		if index > 0 do strings.write_string(&builder, ",")
		json_escape(value, &builder)
	}
	strings.write_string(&builder, "]")
	return strings.to_string(builder)
}

dispatch :: proc(body: string, snapshot: Snapshot, allocator := context.allocator) -> string {
	parsed, err := json.parse_string(body, allocator = context.temp_allocator)
	if err != nil do return error_reply("malformed request", allocator)
	object, is_object := parsed.(json.Object)
	if !is_object do return error_reply("request must be an object", allocator)
	name_value, has_name := object["call"]
	if !has_name do return error_reply("request has no call", allocator)
	name, is_string := name_value.(json.String)
	if !is_string do return error_reply("call must be a string", allocator)

	switch string(name) {
	case "verbs":
		return ok_reply({string_list(VERBS, context.temp_allocator)}, allocator)
	case "cwd":
		return ok_reply({quoted(snapshot.root, context.temp_allocator)}, allocator)
	case "selection":
		// Nothing selected is a real answer, and null is how the wire says so.
		if snapshot.selection == "" do return ok_reply({"null"}, allocator)
		return ok_reply({quoted(snapshot.selection, context.temp_allocator)}, allocator)
	case "tabs":
		return ok_reply({string_list(snapshot.tabs, context.temp_allocator)}, allocator)
	case "session":
		builder := strings.builder_make(context.temp_allocator)
		strings.write_string(&builder, "{\"id\":")
		strings.write_string(&builder, fmt.tprintf("%d", posix.getpid()))
		strings.write_string(&builder, ",\"root\":")
		json_escape(snapshot.root, &builder)
		strings.write_string(&builder, ",\"tab\":")
		json_escape(snapshot.tab, &builder)
		strings.write_string(&builder, ",\"socket\":")
		// Its own socket path, so a caller that read a live name can round-trip back to it.
		json_escape(socket_path(context.temp_allocator), &builder)
		strings.write_string(&builder, "}")
		return ok_reply({strings.to_string(builder)}, allocator)
	case "client":
		return ok_reply({quoted(string(CLIENT_SOURCE), context.temp_allocator)}, allocator)
	}
	return error_reply(fmt.tprintf("no such call: %s", string(name)), allocator)
}

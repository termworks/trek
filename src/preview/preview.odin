package preview

// A preview trek does not draw.
//
// trek knows what is selected; hexe knows how to put a second float beside this one.
// So trek says the path and hexe renders it -- `bat` for a file, `eza` for a directory --
// and trek never learns what either of those is. Outside hexe nothing here runs and
// nothing else in trek has to check.
//
// The channel is a fifo trek holds open for writing. That choice does the cleanup: the
// reader sees EOF the moment trek's descriptor closes, so the preview float dies with
// trek whether trek exited or crashed, and there is no float to orphan and no pid to
// remember.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import c "core:c"
import "core:sys/posix"

// Where trek's own float goes while the preview is beside it, and where the preview
// goes. Percentages of the hexe window: `x` is the float's centre, which is what
// hexe's geometry reports and takes.
TREK_X :: 15
TREK_WIDTH :: 30
PREVIEW_WIDTH :: 50
PREVIEW_HEIGHT :: 70
// hexe's `--size` takes a shift from centre rather than a position, so the same place
// is said differently to the two APIs.
PREVIEW_SHIFT_X :: 10

Geometry :: struct {
	x, y, width, height: int,
	known:               bool,
}

Preview :: struct {
	// Inside hexe, with a pane socket to talk to. False everywhere else, and every
	// entry point returns immediately.
	available:   bool,
	active:      bool,
	socket_path: string,
	fifo_path:   string,
	script_path: string,
	// Held open for writing for as long as the preview is up: it is what keeps the
	// reader from seeing EOF, and closing it is how the float is dismissed.
	fifo:        posix.FD,
	saved:       Geometry,
	// The last path handed over, so a redraw that did not move the cursor costs nothing.
	shown:       string,
	allocator:   runtime.Allocator,
}

init :: proc(state: ^Preview, allocator := context.allocator) {
	state.allocator = allocator
	state.fifo = -1
	socket := os.get_env("HEXE_PANE_API_SOCKET", allocator)
	if socket == "" {
		delete(socket, allocator)
		return
	}
	state.socket_path = socket
	state.available = true
}

available :: proc(state: ^Preview) -> bool {
	return state != nil && state.available
}

active :: proc(state: ^Preview) -> bool {
	return state != nil && state.active
}

destroy :: proc(state: ^Preview) {
	close(state)
	delete(state.socket_path, state.allocator)
	delete(state.shown, state.allocator)
	state^ = {}
}

// ---------------------------------------------------------------- hexe, over the socket

// One request, one reply, one connection. A preview asks hexe about four things in a
// whole session, so holding a connection open would be book-keeping for nothing.
call :: proc(state: ^Preview, request: string, allocator := context.temp_allocator) -> (string, bool) {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return "", false
	defer posix.close(fd)

	address: posix.sockaddr_un
	address.sun_family = .UNIX
	bytes := transmute([]byte)state.socket_path
	if len(bytes) >= len(address.sun_path) do return "", false
	for b, index in bytes do address.sun_path[index] = c.char(b)
	if posix.connect(fd, cast(^posix.sockaddr)&address, posix.socklen_t(size_of(posix.sockaddr_un))) != .OK {
		return "", false
	}

	header := [4]byte{
		byte(len(request) >> 24),
		byte(len(request) >> 16),
		byte(len(request) >> 8),
		byte(len(request)),
	}
	if posix.send(fd, raw_data(header[:]), 4, {}) != 4 do return "", false
	if posix.send(fd, raw_data(request), uint(len(request)), {}) != int(len(request)) do return "", false

	reply_header: [4]byte
	if posix.recv(fd, raw_data(reply_header[:]), 4, {}) != 4 do return "", false
	length := int(reply_header[0]) << 24 | int(reply_header[1]) << 16 | int(reply_header[2]) << 8 | int(reply_header[3])
	if length <= 0 || length > 1024 * 1024 do return "", false

	body := make([]byte, length, allocator)
	read := 0
	for read < length {
		count := posix.recv(fd, raw_data(body[read:]), uint(length - read), {})
		if count <= 0 do return "", false
		read += count
	}
	return string(body), true
}

// hexe answers `{"ok":true,"n":1,"result":[{...}]}`. Anything else -- a refusal, a
// version that does not serve this verb on a pane's socket -- reads as "not known",
// and the caller carries on without moving anything.
geometry :: proc(state: ^Preview) -> Geometry {
	body, ok := call(state, `{"call":"geometry"}`)
	if !ok do return {}
	return parse_geometry(body)
}

parse_geometry :: proc(body: string) -> Geometry {
	parsed, err := json.parse_string(body, allocator = context.temp_allocator)
	if err != nil do return {}
	root, is_object := parsed.(json.Object)
	if !is_object do return {}
	if truth, found := root["ok"].(json.Boolean); !found || !truth do return {}
	results, has_result := root["result"].(json.Array)
	if !has_result || len(results) == 0 do return {}
	record, is_record := results[0].(json.Object)
	if !is_record do return {}

	field :: proc(record: json.Object, name: string) -> int {
		#partial switch value in record[name] {
		case json.Integer: return int(value)
		case json.Float: return int(value)
		}
		return 0
	}
	return Geometry {
		x = field(record, "x"),
		y = field(record, "y"),
		width = field(record, "width"),
		height = field(record, "height"),
		known = true,
	}
}

// Move this float. A hexe that does not serve `geometry` on a pane's socket refuses
// this by name, which is not an error worth reporting: the preview still opens, it
// simply opens beside a float that did not step aside.
move :: proc(state: ^Preview, spec: string) {
	request := fmt.aprintf(`{{"call":"geometry","arg":%s}}`, spec, allocator = context.temp_allocator)
	_, _ = call(state, request)
}

// ---------------------------------------------------------------- the float, over the CLI

// The reader is a file rather than a quoted argument: `--command` carries one string
// through hexe's own parsing, and a shell loop with quotes in it does not survive that
// intact.
READER :: `#!/bin/sh
# Written by trek. One line in, one screen out; EOF ends it and the float closes.
while IFS= read -r target; do
  printf '\033[H\033[2J'
  if [ -d "$target" ]; then
    eza -la --icons --color=always -- "$target" 2>/dev/null || ls -la -- "$target"
  elif [ -f "$target" ]; then
    bat --color=always --style=numbers --paging=never --line-range=:400 -- "$target" 2>/dev/null \
      || head -c 100000 -- "$target"
  fi
done < "%s"
`

runtime_dir :: proc(allocator := context.allocator) -> string {
	base := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	path, _ := filepath.join([]string{base, "trek"}, allocator)
	return path
}

open :: proc(state: ^Preview) -> bool {
	dir := runtime_dir(context.temp_allocator)
	if os.make_directory_all(dir) != nil && !os.exists(dir) do return false
	_ = os.chmod(dir, os.Permissions{.Read_User, .Write_User, .Execute_User})

	pid := os.get_pid()
	state.fifo_path = fmt.aprintf("%s/preview-%d.fifo", dir, pid, allocator = state.allocator)
	state.script_path = fmt.aprintf("%s/preview-%d.sh", dir, pid, allocator = state.allocator)

	os.remove(state.fifo_path)
	path := strings.clone_to_cstring(state.fifo_path, context.temp_allocator)
	if posix.mkfifo(path, {.IRUSR, .IWUSR}) != .OK do return false

	script := fmt.aprintf(READER, state.fifo_path, allocator = context.temp_allocator)
	if os.write_entire_file(state.script_path, transmute([]byte)script) != nil do return false

	// Read-write so the open does not block waiting for a reader, and so the reader
	// never sees EOF while trek is alive.
	//
	// CLOEXEC is the part that took a test to find: without it the float hexe spawns
	// below inherits this descriptor, so it is a writer too, and closing trek's copy
	// leaves the reader waiting on a pipe that can never end. The preview would then
	// outlive every way of dismissing it.
	state.fifo = posix.open(path, {.RDWR, .NONBLOCK, .CLOEXEC})
	if state.fifo < 0 do return false

	command := fmt.aprintf("sh %s", state.script_path, allocator = context.temp_allocator)
	size := fmt.aprintf("%d,%d,%d,0", PREVIEW_WIDTH, PREVIEW_HEIGHT, PREVIEW_SHIFT_X, allocator = context.temp_allocator)
	description := os.Process_Desc {
		command = []string {
			"hexe", "terminal", "float",
			"--title", "preview",
			"--size", size,
			"--command", command,
		},
	}
	// Never waited on: the CLI blocks for the float's whole life by design, and what
	// ends it is the fifo closing rather than anything trek does to this process.
	_, err := os.process_start(description)
	if err != nil do return false
	return true
}

// ---------------------------------------------------------------- what trek calls

// Returns what to say in the footer, which is nothing when there is nothing to say.
toggle :: proc(state: ^Preview) -> string {
	if !state.available do return "preview needs hexe"
	if state.active {
		close(state)
		return "preview off"
	}
	state.saved = geometry(state)
	if !open(state) {
		close(state)
		return "preview could not start"
	}
	move(state, fmt.aprintf(`{{"x":%d,"width":%d}}`, TREK_X, TREK_WIDTH, allocator = context.temp_allocator))
	state.active = true
	return "preview on"
}

// Hand over whatever is selected now. Called with every snapshot, so the guard against
// re-sending an unchanged path is what keeps a redraw from re-running `bat`.
follow :: proc(state: ^Preview, path: string) {
	if !state.active || state.fifo < 0 do return
	if path == state.shown do return
	delete(state.shown, state.allocator)
	state.shown = strings.clone(path, state.allocator)
	if path == "" do return

	line := fmt.aprintf("%s\n", path, allocator = context.temp_allocator)
	written := posix.write(state.fifo, raw_data(line), uint(len(line)))
	// A reader that went away leaves the pipe with nobody on the other end. That is
	// the preview being closed by hand, not an error.
	if written < 0 do close(state)
}

close :: proc(state: ^Preview) {
	if state.fifo >= 0 {
		posix.close(state.fifo)
		state.fifo = -1
	}
	if state.fifo_path != "" {
		os.remove(state.fifo_path)
		delete(state.fifo_path, state.allocator)
		state.fifo_path = ""
	}
	if state.script_path != "" {
		os.remove(state.script_path)
		delete(state.script_path, state.allocator)
		state.script_path = ""
	}
	if state.active && state.saved.known {
		move(state, fmt.aprintf(`{{"x":%d,"width":%d}}`, state.saved.x, state.saved.width, allocator = context.temp_allocator))
	}
	delete(state.shown, state.allocator)
	state.shown = ""
	state.active = false
}

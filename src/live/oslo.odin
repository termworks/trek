// Telling the shell that started us where we have walked to.
//
// A file browser that leaves the shell where it found it is half a tool: you come back, look at the
// directory you were just in, and type `cd` to get there. trek already answers that at the end,
// with `--cwd-file` — but only at the end, and only once.
//
// oslo has a control socket, and one of the things a peer may ask for is a move. So in explorer
// mode, where walking in and out IS the interaction, every re-root is sent as it happens: the shell
// follows along, and its prompt says where you are while you are still looking around.
//
// # Fire and forget, deliberately
//
// The reply is not read. oslo answers `cd` with "accepted" rather than "done" — it applies the move
// on its own thread at its own safe point — so there is nothing in the answer trek could act on,
// and waiting for it would put a socket round trip in the path of every keypress that moves the
// cursor. A shell that is busy, wedged, or gone is a move that does not happen, which is exactly
// what a browser navigating on its own should cost.
//
// # Nothing happens outside a shell that asked for it
//
// `$OSLO_SOCK` is exported by an oslo that is serving, and inherited by what it starts. No variable
// means no socket, means nothing sent — so trek run from bash, or from an oslo that never bound
// one, behaves exactly as it did before.

package live

import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"

// oslo's framing: four bytes of big-endian length, then the JSON body.
OSLO_HEADER :: 4

@(private)
OSLO_HEX := "0123456789abcdef"

// Where the shell that started us is listening, or "" when there is none.
oslo_socket :: proc(allocator := context.allocator) -> string {
	path, found := os.lookup_env("OSLO_SOCK", allocator)
	if !found do return ""
	if len(path) == 0 {
		delete(path, allocator)
		return ""
	}
	return path
}

// Ask the shell to move to `path`. Answers whether the request was written.
//
// Failure is silent on purpose: this runs from the navigation path, and a browser that stopped to
// complain about a shell would be worse than one that quietly did not move it.
oslo_cd :: proc(path: string) -> bool {
	socket := oslo_socket(context.temp_allocator)
	if socket == "" do return false

	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return false
	defer posix.close(fd)

	address: posix.sockaddr_un
	address.sun_family = .UNIX
	bytes := transmute([]byte)socket
	if len(bytes) >= len(address.sun_path) do return false
	for b, index in bytes do address.sun_path[index] = c.char(b)
	if posix.connect(fd, cast(^posix.sockaddr)&address, posix.socklen_t(size_of(posix.sockaddr_un))) != .OK {
		return false
	}

	body := oslo_cd_request(path, context.temp_allocator)
	frame := make([]byte, OSLO_HEADER + len(body), context.temp_allocator)
	length := u32(len(body))
	frame[0] = byte(length >> 24)
	frame[1] = byte(length >> 16)
	frame[2] = byte(length >> 8)
	frame[3] = byte(length)
	copy(frame[OSLO_HEADER:], body)

	written := posix.write(fd, raw_data(frame), len(frame))
	return written == len(frame)
}

// `{"call":"cd","args":["<path>"]}`, with the path escaped.
//
// Built by hand rather than through the JSON encoder: it is one shape with one variable in it, and
// a marshaller here would mean a map allocated per keypress for a string that is always this.
oslo_cd_request :: proc(path: string, allocator := context.allocator) -> string {
	out := strings.builder_make(allocator)
	strings.write_string(&out, `{"call":"cd","args":["`)
	oslo_write_escaped(&out, path)
	strings.write_string(&out, `"]}`)
	return strings.to_string(out)
}

// **A path is not a safe thing to paste into JSON.** A quote or a backslash in a directory name —
// both legal on Linux — would end the string early and hand the shell a frame it cannot parse, or
// worse, one it parses as something else.
oslo_write_escaped :: proc(out: ^strings.Builder, text: string) {
	for r in text {
		switch r {
		case '"':
			strings.write_string(out, `\"`)
		case '\\':
			strings.write_string(out, `\\`)
		case '\n':
			strings.write_string(out, `\n`)
		case '\r':
			strings.write_string(out, `\r`)
		case '\t':
			strings.write_string(out, `\t`)
		case:
			if r < 0x20 {
				// The rest of the control range, which JSON requires as `\u00XX`.
				strings.write_string(out, `\u00`)
				strings.write_byte(out, OSLO_HEX[(int(r) >> 4) & 0xF])
				strings.write_byte(out, OSLO_HEX[int(r) & 0xF])
			} else {
				strings.write_rune(out, r)
			}
		}
	}
}

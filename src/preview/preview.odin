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
import "core:time"
import c "core:c"
import "core:sys/posix"

// Everything here is a percentage of the hexe window, and `x` is an ANCHOR inside the
// space the float does not fill: 0 is flush left, 100 flush right, 50 centred. A float
// of width W therefore has its left edge at `(100 - W) * x / 100`, not at `x` and not
// at `x - W/2`.
//
// That is worth stating because both simpler readings look right in the numbers and
// are wrong on screen. Read as centres, trek at `x=15 w=30` and a preview at `x=65
// w=70` compute as adjacent; measured in cells on a 135-column window they are
// [16,52) and [28,118), which is twenty-four columns of one drawn over the other.

// Where trek asks to stand once a preview is beside it: the left band.
TREK_WIDTH :: 30
// Narrower than this and a preview is not worth the room it takes.
MIN_PREVIEW :: 20
// How often to ask hexe who holds the cursor, in milliseconds. Slower than the input
// loop: nothing can steal focus without the user acting first.
FOCUS_INTERVAL :: 250

// A float's place, in percent, with `x`/`y` the centre.
Rect :: struct {
	x, y, width, height: int,
	// hexe's name for this pane. Only the record read from `pane` carries one.
	uuid:                string,
	known:               bool,
}

left_edge :: proc(rect: Rect) -> int {
	if rect.width >= 100 do return 0
	return (100 - rect.width) * rect.x / 100
}

right_edge :: proc(rect: Rect) -> int {
	return left_edge(rect) + rect.width
}

// Do these two boxes share any column?
overlaps :: proc(a, b: Rect) -> bool {
	return left_edge(a) < right_edge(b) && right_edge(a) > left_edge(b)
}

// The whole width, cut in two: the explorer on the left, the preview on the right.
//
// Adjacent by construction rather than by arithmetic done twice -- the preview starts
// exactly where the explorer ends, so there is no rounding gap to land in and no
// overlap to check for afterwards.
//
// The explorer keeps its own width when that leaves room, and is narrowed when it does
// not. A window with no room for both gets no preview at all: a preview squeezed into
// a few columns shows nothing and costs the explorer the space it had.
split :: proc(trek: Rect, shrink := 0) -> (explorer, preview: Rect, ok: bool) {
	if !trek.known do return {}, {}, false
	width := trek.width
	if width <= 0 do width = TREK_WIDTH
	// The explorer gives up a share of itself to the preview. A list of names needs
	// far less width than the file beside it, and the room has to come from somewhere.
	if shrink > 0 && shrink < 100 do width = max(width * (100 - shrink) / 100, 1)
	if 100 - width < MIN_PREVIEW do width = TREK_WIDTH
	if 100 - width < MIN_PREVIEW do return {}, {}, false

	// Flush to opposite edges, with the widths adding up to the whole window. Anchors
	// rather than computed positions: 0 and 100 mean "against that edge" whatever the
	// width works out to in cells, so the two cannot drift into each other on a window
	// size that divides badly.
	rest := 100 - width
	explorer = Rect{x = 0, y = trek.y, width = width, height = trek.height, known = true}
	preview = Rect{x = 100, y = trek.y, width = rest, height = trek.height, known = true}
	return explorer, preview, true
}

Preview :: struct {
	// Inside hexe, with a pane socket to talk to. False everywhere else, and every
	// entry point returns immediately.
	available:   bool,
	// Percent of its own width the explorer gives up while a preview is beside it.
	shrink:      int,
	checked:     time.Time,
	active:      bool,
	socket_path: string,
	fifo_path:   string,
	script_path: string,
	// Held open for writing for as long as the preview is up: it is what keeps the
	// reader from seeing EOF, and closing it is how the float is dismissed.
	fifo:        posix.FD,
	saved:       Rect,
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

// Where this float is, asked of hexe.
//
// `pane` rather than `geometry`, because `pane` is answerable on a pane's own socket
// in every hexe that has one, while `geometry` there is newer. Reading has to work on
// the old one too: it is what the no-overlap guarantee is computed from.
self :: proc(state: ^Preview) -> Rect {
	body, ok := call(state, `{"call":"pane"}`)
	if !ok do return {}
	return parse_self(body)
}

// hexe answers `{"ok":true,"n":1,"result":[{...}]}` -- a *list* of return values, so
// the record is inside `result`, not `result` itself. Anything else, including a
// refusal, reads as "not known" and the preview declines rather than guessing.
parse_self :: proc(body: string) -> Rect {
	parsed, err := json.parse_string(body, allocator = context.temp_allocator)
	if err != nil do return {}
	root, is_object := parsed.(json.Object)
	if !is_object do return {}
	if truth, found := root["ok"].(json.Boolean); !found || !truth do return {}
	results, has_result := root["result"].(json.Array)
	if !has_result || len(results) == 0 do return {}
	record, is_record := results[0].(json.Object)
	if !is_record do return {}
	// A tiled pane has no percentage geometry: the layout owns its rect, so there is
	// no band beside it to put anything in.
	if floating, found := record["is_float"].(json.Boolean); !found || !floating do return {}

	field :: proc(record: json.Object, name: string) -> int {
		#partial switch value in record[name] {
		case json.Integer: return int(value)
		case json.Float: return int(value)
		}
		return 0
	}
	uuid := ""
	if text, is_text := record["uuid"].(json.String); is_text do uuid = string(text)
	return Rect {
		uuid = uuid,
		x = field(record, "pos_x_pct"),
		y = field(record, "pos_y_pct"),
		width = field(record, "width_pct"),
		height = field(record, "height_pct"),
		known = true,
	}
}

// Move this float. A hexe that does not serve `geometry` on a pane's socket refuses
// this by name, which is not an error worth reporting: the preview then goes beside
// trek wherever trek actually is, which is why the caller re-reads afterwards.
move :: proc(state: ^Preview, rect: Rect) {
	request := fmt.aprintf(
		`{{"call":"geometry","arg":{{"x":%d,"width":%d}}}}`,
		rect.x,
		rect.width,
		allocator = context.temp_allocator,
	)
	_, _ = call(state, request)
}

// Ask for the cursor back. Opening a float takes focus, and the explorer is what the
// keys are for -- a preview nobody can navigate away from is worse than no preview.
focus :: proc(state: ^Preview) {
	_, _ = call(state, `{"call":"focus"}`)
}

// Whether hexe says the cursor is here.
holds_focus :: proc(state: ^Preview) -> bool {
	body, ok := call(state, `{"call":"pane"}`)
	if !ok do return true
	parsed, err := json.parse_string(body, allocator = context.temp_allocator)
	if err != nil do return true
	root := parsed.(json.Object) or_else nil
	if root == nil do return true
	results, has_result := root["result"].(json.Array)
	if !has_result || len(results) == 0 do return true
	record, is_record := results[0].(json.Object)
	if !is_record do return true
	held, found := record["focused"].(json.Boolean)
	if !found do return true
	return bool(held)
}

// Take the cursor back if something else has it.
//
// Scrolling the preview -- or clicking it -- moves hexe's focus there, and from that
// moment the arrow keys are scrolling a file instead of choosing one: the explorer
// looks stuck on whatever was open. Since trek wakes every tick anyway, it can notice
// and take the cursor back without the user having to know which pane holds it.
//
// Asked at a slower rate than the loop runs, because this is two round trips and the
// answer cannot change without the user having done something first.
keep_focus :: proc(state: ^Preview) {
	if !state.active do return
	now := time.now()
	if time.duration_milliseconds(time.diff(state.checked, now)) < FOCUS_INTERVAL do return
	state.checked = now
	if !holds_focus(state) do focus(state)
}

// ---------------------------------------------------------------- the float, over the CLI

// The reader is a file rather than a quoted argument: `--command` carries one string
// through hexe's own parsing, and a shell loop with quotes in it does not survive that
// intact.
READER :: `#!/bin/sh
# Written by trek. One line in, one screen out; EOF ends it and the float closes.
#
# Output is cut to the rows the float has. Without that a long file scrolls the pane
# while it is written and settles showing its END, which reads as the preview starting
# somewhere in the middle of the file.
while IFS= read -r target; do
  rows=$(tput lines 2>/dev/null || echo 40)
  printf '\033[H\033[2J'
  if [ -d "$target" ]; then
    { eza -la --icons --color=always -- "$target" 2>/dev/null || ls -la -- "$target"; } | head -n "$rows"
  elif [ -f "$target" ]; then
    { bat --color=always --style=numbers --paging=never --line-range=":$rows" -- "$target" 2>/dev/null \
      || head -c 100000 -- "$target"; } | head -n "$rows"
  fi
done < "%s"
`

runtime_dir :: proc(allocator := context.allocator) -> string {
	base := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	path, _ := filepath.join([]string{base, "trek"}, allocator)
	return path
}


// The environment for the float, with this pane's own identity in it.
//
// A pod inherits `HEXE_PANE_UUID` from whoever launched it rather than being given its
// own, so trek can be carrying the uuid of the pane that *opened* it -- measured: a
// trek float held the uuid of the terminal that spawned it. `hexe terminal float`
// routes on that variable, so leaving it alone asks hexe to put the preview beside
// somebody else's pane, in whatever session that is.
pane_env :: proc(state: ^Preview, rect: Rect, allocator: runtime.Allocator) -> []string {
	current, err := os.environ(allocator)
	if err != nil || rect.uuid == "" do return nil
	out := make([dynamic]string, 0, len(current) + 1, allocator)
	for entry in current {
		if strings.has_prefix(entry, "HEXE_PANE_UUID=") do continue
		append(&out, entry)
	}
	append(&out, fmt.aprintf("HEXE_PANE_UUID=%s", rect.uuid, allocator = allocator))
	return out[:]
}

open :: proc(state: ^Preview, rect: Rect) -> bool {
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
	// `--size` states a shift from centre where geometry states a centre, so the same
	// place has to be said differently to the two APIs.
	size := fmt.aprintf(
		"%d,%d,%d,%d",
		rect.width,
		rect.height,
		rect.x - 50,
		rect.y - 50,
		allocator = context.temp_allocator,
	)
	// Real descriptors, not nil. `Process_Desc` treats a nil handle as "shut that
	// stream down", so a child spawned with three nils has no stdin, stdout or stderr
	// -- and `hexe terminal float` then fails without being able to say so. That is a
	// float that never appears and an empty log to explain it.
	null, null_err := os.open("/dev/null", os.O_RDWR)
	if null_err != nil do return false
	defer os.close(null)

	description := os.Process_Desc {
		env = pane_env(state, rect, context.temp_allocator),
		stdin = null,
		stdout = null,
		stderr = null,
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
	state.saved = self(state)
	if !state.saved.known do return "preview needs a float to sit beside"
	explorer, beside, room := split(state.saved, state.shrink)
	if !room do return "no room beside the explorer"

	// Open first, step aside second. Opening a float puts every other float back at the
	// position it was declared with, so an explorer that moved before this would be
	// moved back underneath the preview -- which is exactly how the two ended up on top
	// of each other.
	if !open(state, beside) {
		close(state)
		return "preview could not start"
	}
	move(state, explorer)

	// Say it rather than assume it. If the move did not take -- an older hexe does not
	// serve `geometry` on a pane's socket -- the two would be sitting on top of each
	// other, and no preview is better than one covering the thing it describes.
	standing := self(state)
	if !standing.known || overlaps(standing, beside) {
		close(state)
		return "this hexe cannot move the explorer aside"
	}

	// Opening a float takes the cursor with it, and the explorer is what the keys are
	// for. An older hexe refuses this too; the preview is still worth having.
	focus(state)
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
		move(state, state.saved)
		focus(state)
	}
	delete(state.shown, state.allocator)
	state.shown = ""
	state.active = false
}

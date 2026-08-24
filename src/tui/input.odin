package tui

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

Key_Code :: enum {
	None,
	Rune,
	Escape,
	Enter,
	Tab,
	Backspace,
	Up,
	Down,
	Left,
	Right,
	Home,
	End,
	Page_Up,
	Page_Down,
	Delete,
	Insert,
	F1,
	F2,
	F3,
	F4,
}

Modifier :: enum {
	Shift,
	Alt,
	Control,
}

Modifiers :: bit_set[Modifier]

Key :: struct {
	code:      Key_Code,
	rune:      rune,
	modifiers: Modifiers,
}

Mouse_Action :: enum {
	Press,
	Release,
	Move,
	Scroll_Up,
	Scroll_Down,
}

Mouse_Event :: struct {
	x:         int,
	y:         int,
	button:    int,
	action:    Mouse_Action,
	modifiers: Modifiers,
}

Event_Kind :: enum {
	Key,
	Mouse,
	Paste,
}

Event :: struct {
	kind:  Event_Kind,
	key:   Key,
	mouse: Mouse_Event,
	text:  string,
}

Decoder :: struct {
	pending: [dynamic]byte,
	paste:   [dynamic]byte,
	in_paste: bool,
}

decoder_init :: proc(decoder: ^Decoder, allocator := context.allocator) {
	decoder.pending = make([dynamic]byte, allocator)
	decoder.paste = make([dynamic]byte, allocator)
}

decoder_destroy :: proc(decoder: ^Decoder) {
	delete(decoder.pending)
	delete(decoder.paste)
	decoder^ = {}
}

events_destroy :: proc(events: ^[dynamic]Event) {
	for event in events {
		if event.kind == .Paste {
			delete(event.text)
		}
	}
	delete(events^)
	events^ = nil
}

starts_with_bytes :: proc(data: []byte, value: string) -> bool {
	if len(data) < len(value) {
		return false
	}
	return string(data[:len(value)]) == value
}

parse_number :: proc(value: string) -> (int, bool) {
	number, ok := strconv.parse_int(value)
	return int(number), ok
}

parse_mouse :: proc(sequence: string) -> (Mouse_Event, bool) {
	if len(sequence) < 7 || sequence[:3] != "\x1b[<" {
		return {}, false
	}
	terminator := sequence[len(sequence) - 1]
	body := sequence[3:len(sequence) - 1]
	parts := strings.split(body, ";", allocator = context.allocator)
	defer delete(parts)
	if len(parts) != 3 {
		return {}, false
	}
	encoded, ok_b := parse_number(parts[0])
	x, ok_x := parse_number(parts[1])
	y, ok_y := parse_number(parts[2])
	if !ok_b || !ok_x || !ok_y {
		return {}, false
	}
	mouse := Mouse_Event{x = max(x - 1, 0), y = max(y - 1, 0), button = encoded & 3}
	if encoded & 4 != 0 do mouse.modifiers += {.Shift}
	if encoded & 8 != 0 do mouse.modifiers += {.Alt}
	if encoded & 16 != 0 do mouse.modifiers += {.Control}
	if encoded & 64 != 0 {
		if encoded & 1 == 0 {
			mouse.action = .Scroll_Up
		} else {
			mouse.action = .Scroll_Down
		}
	} else if encoded & 32 != 0 {
		mouse.action = .Move
	} else if terminator == 'm' {
		mouse.action = .Release
	} else {
		mouse.action = .Press
	}
	return mouse, true
}

special_key :: proc(sequence: string) -> (Key, bool) {
	switch sequence {
	case "\x1b[A": return Key{code = .Up}, true
	case "\x1b[B": return Key{code = .Down}, true
	case "\x1b[C": return Key{code = .Right}, true
	case "\x1b[D": return Key{code = .Left}, true
	case "\x1b[H", "\x1bOH": return Key{code = .Home}, true
	case "\x1b[F", "\x1bOF": return Key{code = .End}, true
	case "\x1b[2~": return Key{code = .Insert}, true
	case "\x1b[3~": return Key{code = .Delete}, true
	case "\x1b[5~": return Key{code = .Page_Up}, true
	case "\x1b[6~": return Key{code = .Page_Down}, true
	case "\x1bOP": return Key{code = .F1}, true
	case "\x1bOQ": return Key{code = .F2}, true
	case "\x1bOR": return Key{code = .F3}, true
	case "\x1bOS": return Key{code = .F4}, true
	}
	return {}, false
}

sequence_end :: proc(data: []byte) -> int {
	if len(data) < 2 || data[0] != 0x1b {
		return 0
	}
	if data[1] == 'O' {
		if len(data) >= 3 do return 3
		return 0
	}
	if data[1] != '[' {
		return 2
	}
	for index in 2 ..< len(data) {
		if data[index] >= 0x40 && data[index] <= 0x7e {
			return index + 1
		}
	}
	return 0
}

discard_prefix :: proc(bytes: ^[dynamic]byte, count: int) {
	n := min(count, len(bytes^))
	for _ in 0 ..< n {
		ordered_remove(bytes, 0)
	}
}

decoder_feed :: proc(decoder: ^Decoder, bytes: []byte, allocator := context.allocator) -> [dynamic]Event {
	append(&decoder.pending, ..bytes)
	events := make([dynamic]Event, allocator)
	for len(decoder.pending) > 0 {
		data := decoder.pending[:]
		if decoder.in_paste {
			end_index := strings.index(string(data), "\x1b[201~")
			if end_index < 0 {
				append(&decoder.paste, ..data)
				clear(&decoder.pending)
				break
			}
			append(&decoder.paste, ..data[:end_index])
			append(&events, Event{kind = .Paste, text = strings.clone(string(decoder.paste[:]), allocator)})
			clear(&decoder.paste)
			decoder.in_paste = false
			discard_prefix(&decoder.pending, end_index + len("\x1b[201~"))
			continue
		}
		if starts_with_bytes(data, "\x1b[200~") {
			decoder.in_paste = true
			discard_prefix(&decoder.pending, len("\x1b[200~"))
			continue
		}
		if data[0] == 0x1b {
			end := sequence_end(data)
			if end == 0 {
				break
			}
			sequence := string(data[:end])
			if mouse, ok := parse_mouse(sequence); ok {
				append(&events, Event{kind = .Mouse, mouse = mouse})
			} else if key, ok := special_key(sequence); ok {
				append(&events, Event{kind = .Key, key = key})
			} else if end == 2 {
				r, _ := utf8.decode_rune(string(data[1:end]))
				append(&events, Event{kind = .Key, key = Key{code = .Rune, rune = r, modifiers = {.Alt}}})
			} else {
				append(&events, Event{kind = .Key, key = Key{code = .Escape}})
			}
			discard_prefix(&decoder.pending, end)
			continue
		}
		byte := data[0]
		switch byte {
		case '\r', '\n': append(&events, Event{kind = .Key, key = Key{code = .Enter}}); ordered_remove(&decoder.pending, 0)
		case '\t': append(&events, Event{kind = .Key, key = Key{code = .Tab}}); ordered_remove(&decoder.pending, 0)
		case 0x7f, 0x08: append(&events, Event{kind = .Key, key = Key{code = .Backspace}}); ordered_remove(&decoder.pending, 0)
		case:
			if byte > 0 && byte < 0x20 {
				append(&events, Event{kind = .Key, key = Key{code = .Rune, rune = rune(byte + 0x60), modifiers = {.Control}}})
				ordered_remove(&decoder.pending, 0)
				continue
			}
			r, width := utf8.decode_rune(string(data))
			if width == 0 || width > len(data) {
				break
			}
			append(&events, Event{kind = .Key, key = Key{code = .Rune, rune = r}})
			discard_prefix(&decoder.pending, width)
		}
	}
	return events
}

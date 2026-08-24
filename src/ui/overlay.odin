package ui

import "base:runtime"
import "core:fmt"
import "core:unicode/utf8"
import model "../model"
import tui "../tui"

Overlay_Kind :: enum {
	None,
	Menu,
	Prompt,
	Confirm,
	Help,
}

Overlay :: struct {
	kind:     Overlay_Kind,
	title:    string,
	entries:  []model.Menu_Entry,
	selected: int,
	action:   model.Action,
	input:    [dynamic]byte,
	help:     []string,
	allocator: runtime.Allocator,
}


Overlay_Result :: struct {
	dismiss: bool,
	submit:  bool,
	action:  model.Action,
	value:   string,
	entry_id: string,
}

overlay_init :: proc(overlay: ^Overlay, allocator := context.allocator) {
	overlay.allocator = allocator
	overlay.input = make([dynamic]byte, allocator)
}

overlay_destroy :: proc(overlay: ^Overlay) {
	delete(overlay.input)
	overlay^ = {}
}

overlay_close :: proc(overlay: ^Overlay) {
	overlay.kind = .None
	overlay.title = ""
	overlay.entries = nil
	overlay.help = nil
	overlay.selected = 0
	clear(&overlay.input)
}

overlay_menu :: proc(overlay: ^Overlay, title: string, entries: []model.Menu_Entry) {
	overlay_close(overlay)
	overlay.kind = .Menu
	overlay.title = title
	overlay.entries = entries
}

overlay_prompt :: proc(overlay: ^Overlay, title: string, action: model.Action, initial := "") {
	overlay_close(overlay)
	overlay.kind = .Prompt
	overlay.title = title
	overlay.action = action
	append(&overlay.input, ..transmute([]byte)(initial))
}

overlay_confirm :: proc(overlay: ^Overlay, title: string, action: model.Action) {
	overlay_close(overlay)
	overlay.kind = .Confirm
	overlay.title = title
	overlay.action = action
}


overlay_append_rune :: proc(overlay: ^Overlay, value: rune) {
	encoded, count := utf8.encode_rune(value)
	append(&overlay.input, ..encoded[:count])
}

overlay_backspace :: proc(overlay: ^Overlay) {
	if len(overlay.input) == 0 do return
	_, width := utf8.decode_last_rune(string(overlay.input[:]))
	n := min(width, len(overlay.input))
	for _ in 0 ..< n do ordered_remove(&overlay.input, len(overlay.input) - 1)
}

overlay_key :: proc(overlay: ^Overlay, key: tui.Key) -> Overlay_Result {
	if overlay.kind == .None do return {}
	if key.code == .Escape {
		return Overlay_Result{dismiss = true}
	}
	switch overlay.kind {
	case .Menu:
		// `q` closes the menu the way it closes everything else. Without this the
		// only way out is Esc, and a menu is the one place a stuck user cannot quit.
		if key.code == .Rune && key.rune == 'q' do return Overlay_Result{dismiss = true}
		if key.code == .Up do overlay.selected = max(overlay.selected - 1, 0)
		if key.code == .Down do overlay.selected = min(overlay.selected + 1, len(overlay.entries) - 1)
		if key.code == .Enter && len(overlay.entries) > 0 {
			entry := &overlay.entries[overlay.selected]
			return Overlay_Result{submit = true, action = entry.action, entry_id = entry.id}
		}
	case .Prompt:
		if key.code == .Backspace do overlay_backspace(overlay)
		if key.code == .Rune do overlay_append_rune(overlay, key.rune)
		if key.code == .Enter {
			return Overlay_Result{submit = true, action = overlay.action, value = string(overlay.input[:])}
		}
	case .Confirm:
		if key.code == .Rune && (key.rune == 'y' || key.rune == 'Y') {
			return Overlay_Result{submit = true, action = overlay.action}
		}
		if key.code == .Rune && (key.rune == 'n' || key.rune == 'N' || key.rune == 'q') {
			return Overlay_Result{dismiss = true}
		}
	case .Help:
		// A reference, not a prompt: every ordinary exit closes it, including the key
		// that opened it.
		if key.code == .Enter do return Overlay_Result{dismiss = true}
		if key.code == .Rune && (key.rune == 'q' || key.rune == '?') do return Overlay_Result{dismiss = true}
	case .None:
	}
	return {}
}

overlay_paste :: proc(overlay: ^Overlay, value: string) {
	if overlay.kind == .Prompt do append(&overlay.input, ..transmute([]byte)(value))
}

overlay_fill :: proc(buffer: ^tui.Buffer, rect: tui.Rect, style: tui.Style) {
	tui.buffer_fill(buffer, rect, style)
}

// One padded, centred panel for every dialog: the context menu, a rename prompt, a
// delete confirmation and the shortcut list all use this, so a new dialog inherits
// the shape rather than inventing one.
OVERLAY_PAD :: 2
OVERLAY_MIN_WIDTH :: 34

// The lines a dialog puts in its body, and the widest of them.
overlay_body :: proc(overlay: ^Overlay, allocator := context.temp_allocator) -> [dynamic]string {
	lines := make([dynamic]string, allocator)
	switch overlay.kind {
	case .Menu:
		for entry in overlay.entries do append(&lines, entry.label)
	case .Prompt:
		append(&lines, "")
	case .Confirm:
		append(&lines, "")
		append(&lines, "y  confirm      n  cancel")
	case .Help:
		for line in overlay.help do append(&lines, line)
	case .None:
	}
	return lines
}

overlay_rect :: proc(overlay: ^Overlay, width, height: int) -> tui.Rect {
	lines := overlay_body(overlay)
	widest := tui.text_width(overlay.title) + 2
	for line in lines do widest = max(widest, tui.text_width(line))
	panel_width := min(max(widest + OVERLAY_PAD * 2 + 2, OVERLAY_MIN_WIDTH), max(width - 2, 8))
	panel_height := min(len(lines) + 4, max(height - 2, 4))
	// Centred, so a dialog lands in the same place whatever opened it.
	x := max((width - panel_width) / 2, 0)
	y := max((height - panel_height) / 2, 0)
	return tui.Rect{x = x, y = y, width = panel_width, height = panel_height}
}

// A rounded frame in the border ramp, with the title inset on the top edge.
overlay_frame :: proc(overlay: ^Overlay, buffer: ^tui.Buffer, rect: tui.Rect) {
	border := tui.Style{fg = tui.RAMP_BORDER}
	overlay_fill(buffer, rect, tui.Style{bg = tui.ACTIVITY_BG})
	right := rect.x + rect.width - 1
	bottom := rect.y + rect.height - 1
	for x in rect.x + 1 ..< right {
		tui.buffer_set(buffer, x, rect.y, tui.Cell{rune = '─', style = border})
		tui.buffer_set(buffer, x, bottom, tui.Cell{rune = '─', style = border})
	}
	for y in rect.y + 1 ..< bottom {
		tui.buffer_set(buffer, rect.x, y, tui.Cell{rune = '│', style = border})
		tui.buffer_set(buffer, right, y, tui.Cell{rune = '│', style = border})
	}
	tui.buffer_set(buffer, rect.x, rect.y, tui.Cell{rune = '╭', style = border})
	tui.buffer_set(buffer, right, rect.y, tui.Cell{rune = '╮', style = border})
	tui.buffer_set(buffer, rect.x, bottom, tui.Cell{rune = '╰', style = border})
	tui.buffer_set(buffer, right, bottom, tui.Cell{rune = '╯', style = border})
	if overlay.title == "" do return
	title := fmt.aprintf(" %s ", overlay.title, allocator = context.temp_allocator)
	tui.buffer_draw_text(buffer, rect.x + OVERLAY_PAD, rect.y, title, tui.Style{fg = tui.ACCENT, bg = tui.ACTIVITY_BG, attrs = {.Bold}}, rect.width - OVERLAY_PAD * 2)
}

overlay_render :: proc(overlay: ^Overlay, buffer: ^tui.Buffer) {
	if overlay.kind == .None || buffer.width < 12 || buffer.height < 5 do return
	rect := overlay_rect(overlay, buffer.width, buffer.height)
	overlay_frame(overlay, buffer, rect)
	lines := overlay_body(overlay)
	inner_x := rect.x + OVERLAY_PAD
	inner_width := max(rect.width - OVERLAY_PAD * 2, 1)
	top := rect.y + 2
	panel := tui.Style{fg = tui.RAMP_TEXT, bg = tui.ACTIVITY_BG}
	selected := tui.Style{fg = tui.RAMP_BRIGHT, bg = tui.ACTIVITY_ACTIVE_BG, attrs = {.Bold}}

	switch overlay.kind {
	case .Menu:
		for label, index in lines {
			row := top + index
			if row >= rect.y + rect.height - 1 do break
			style := panel
			if index == overlay.selected do style = selected
			overlay_fill(buffer, tui.Rect{x = rect.x + 1, y = row, width = rect.width - 2, height = 1}, style)
			tui.buffer_draw_text(buffer, inner_x, row, label, style, inner_width)
		}
	case .Prompt:
		field := tui.Style{fg = tui.RAMP_BRIGHT, bg = tui.RAMP_SELECT}
		overlay_fill(buffer, tui.Rect{x = inner_x, y = top, width = inner_width, height = 1}, field)
		input := tui.input_tail(string(overlay.input[:]), inner_width - 1)
		defer delete(input)
		tui.buffer_draw_text(buffer, inner_x + 1, top, input, field, inner_width - 1)
	case .Confirm:
		for line, index in lines {
			row := top + index
			if row >= rect.y + rect.height - 1 do break
			style := panel
			if index > 0 do style = tui.Style{fg = tui.RAMP_MUTED, bg = tui.ACTIVITY_BG, attrs = {.Dim}}
			tui.buffer_draw_text(buffer, inner_x, row, line, style, inner_width)
		}
	case .Help:
		for line, index in lines {
			row := top + index
			if row >= rect.y + rect.height - 1 do break
			// A blank entry is a group separator; a line with no leading key is a heading.
			style := panel
			if len(line) > 0 && line[0] != ' ' do style = tui.Style{fg = tui.ACCENT, bg = tui.ACTIVITY_BG, attrs = {.Bold}}
			tui.buffer_draw_text(buffer, inner_x, row, line, style, inner_width)
		}
	case .None:
	}
}

overlay_help :: proc(overlay: ^Overlay, lines: []string) {
	overlay_close(overlay)
	overlay.kind = .Help
	overlay.title = "Shortcuts"
	overlay.help = lines
}

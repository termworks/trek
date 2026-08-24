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
	Settings,
}

Overlay :: struct {
	kind:     Overlay_Kind,
	title:    string,
	entries:  []model.Menu_Entry,
	selected: int,
	action:   model.Action,
	input:    [dynamic]byte,
	allocator: runtime.Allocator,
	settings_icons: string,
	settings_hidden: bool,
	settings_git: bool,
	settings_start: string,
}

Setting_Action :: enum {
	None,
	Icons,
	Hidden,
	Git_Decorations,
	Start_Tab,
}

Overlay_Result :: struct {
	dismiss: bool,
	submit:  bool,
	action:  model.Action,
	value:   string,
	entry_id: string,
	setting: Setting_Action,
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

overlay_settings :: proc(overlay: ^Overlay, icons: string, hidden, git_decorations: bool, start_tab: string) {
	overlay_close(overlay)
	overlay.kind = .Settings
	overlay.title = "Settings"
	overlay.settings_icons = icons
	overlay.settings_hidden = hidden
	overlay.settings_git = git_decorations
	overlay.settings_start = start_tab
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
	case .Settings:
		if key.code == .Up do overlay.selected = max(overlay.selected - 1, 0)
		if key.code == .Down do overlay.selected = min(overlay.selected + 1, 3)
		if key.code == .Rune && (key.rune == 'q' || key.rune == ',') do return Overlay_Result{dismiss = true}
		setting := Setting_Action.None
		if key.code == .Enter || (key.code == .Rune && key.rune == ' ') do setting = Setting_Action(overlay.selected + 1)
		if key.code == .Rune {
			switch key.rune {
			case 'i': setting = .Icons
			case '.': setting = .Hidden
			case 'g': setting = .Git_Decorations
			case 's': setting = .Start_Tab
			}
		}
		if setting != .None do return Overlay_Result{setting = setting}
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

overlay_rect :: proc(overlay: ^Overlay, width, height: int) -> tui.Rect {
	panel_width := min(max(tui.text_width(overlay.title) + 8, 32), width - 2)
	panel_height := 4
	if overlay.kind == .Menu do panel_height = min(len(overlay.entries) + 2, height - 2)
	if overlay.kind == .Settings do panel_height = min(13, height - 2)
	x := min(2, max(width - panel_width, 0))
	y := min(HEADER_HEIGHT + 1, max(height - panel_height, 0))
	return tui.Rect{x = x, y = y, width = panel_width, height = panel_height}
}

overlay_frame :: proc(overlay: ^Overlay, buffer: ^tui.Buffer, rect: tui.Rect, style: tui.Style) {
	overlay_fill(buffer, rect, tui.PLAIN_STYLE)
	for x in rect.x + 1 ..< rect.x + rect.width - 1 {
		tui.buffer_set(buffer, x, rect.y, tui.Cell{rune = '─', style = style})
		tui.buffer_set(buffer, x, rect.y + rect.height - 1, tui.Cell{rune = '─', style = style})
	}
	for y in rect.y + 1 ..< rect.y + rect.height - 1 {
		tui.buffer_set(buffer, rect.x, y, tui.Cell{rune = '│', style = style})
		tui.buffer_set(buffer, rect.x + rect.width - 1, y, tui.Cell{rune = '│', style = style})
	}
	tui.buffer_set(buffer, rect.x, rect.y, tui.Cell{rune = '┌', style = style})
	tui.buffer_set(buffer, rect.x + rect.width - 1, rect.y, tui.Cell{rune = '┐', style = style})
	tui.buffer_set(buffer, rect.x, rect.y + rect.height - 1, tui.Cell{rune = '└', style = style})
	tui.buffer_set(buffer, rect.x + rect.width - 1, rect.y + rect.height - 1, tui.Cell{rune = '┘', style = style})
	title := fmt.aprintf("─ %s ", overlay.title, allocator = context.temp_allocator)
	tui.buffer_draw_text(buffer, rect.x + 1, rect.y, title, tui.Style{attrs = {.Dim}}, rect.width - 2)
}

overlay_render :: proc(overlay: ^Overlay, buffer: ^tui.Buffer) {
	if overlay.kind == .None || buffer.width < 12 || buffer.height < 4 do return
	rect := overlay_rect(overlay, buffer.width, buffer.height)
	x, y, width, height := rect.x, rect.y, rect.width, rect.height
	panel := tui.PLAIN_STYLE
	selected := tui.Style{fg = tui.DEFAULT_COLOR, bg = tui.SELECTED_BG, attrs = {.Bold}}
	overlay_frame(overlay, buffer, rect, tui.Style{attrs = {.Dim}})
	switch overlay.kind {
	case .Menu:
		for entry, index in overlay.entries {
			if index + 1 >= height - 1 do break
			style := panel
			if index == overlay.selected do style = selected
			overlay_fill(buffer, tui.Rect{x = x + 1, y = y + index + 1, width = width - 2, height = 1}, style)
			tui.buffer_draw_text(buffer, x + 2, y + index + 1, entry.label, style, width - 4)
		}
	case .Prompt:
		input := tui.input_tail(string(overlay.input[:]), width - 6)
		defer delete(input)
		tui.buffer_draw_text(buffer, x + 2, y + 1, "> ", panel, 2)
		tui.buffer_draw_text(buffer, x + 4, y + 1, input, panel, width - 6)
	case .Confirm:
		tui.buffer_draw_text(buffer, x + 2, y + 1, "y confirm · n cancel", panel, width - 4)
	case .Settings:
		lines := [?]string{
			fmt.aprintf(" Icon theme         %s", overlay.settings_icons),
			fmt.aprintf(" Hidden files       %s", overlay.settings_hidden ? "shown" : "hidden"),
			fmt.aprintf(" Git decorations    %s", overlay.settings_git ? "shown" : "hidden"),
			fmt.aprintf(" Start tab          %s", overlay.settings_start),
		}
		defer {
			for line in lines do delete(line)
		}
		for line, index in lines {
			style := panel
			if index == overlay.selected do style = selected
			overlay_fill(buffer, tui.Rect{x = x + 1, y = y + index + 1, width = width - 2, height = 1}, style)
			tui.buffer_draw_text(buffer, x + 1, y + index + 1, line, style, width - 2)
		}
		hotkey_y := y + 6
		if hotkey_y < y + height - 1 {
			tui.buffer_draw_text(buffer, x + 2, hotkey_y, "Hotkeys", tui.Style{attrs = {.Bold}}, width - 4)
			tui.buffer_draw_text(buffer, x + 3, hotkey_y + 1, "↑↓ move   ←→ fold", tui.Style{attrs = {.Dim}}, width - 5)
			tui.buffer_draw_text(buffer, x + 3, hotkey_y + 2, "⏎ toggle  r refresh", tui.Style{attrs = {.Dim}}, width - 5)
			tui.buffer_draw_text(buffer, x + 3, hotkey_y + 3, ". dotfiles  m menu", tui.Style{attrs = {.Dim}}, width - 5)
			tui.buffer_draw_text(buffer, x + 2, hotkey_y + 4, "click/⏎ toggle · esc close", tui.Style{attrs = {.Dim}}, width - 4)
		}
	case .None:
	}
}

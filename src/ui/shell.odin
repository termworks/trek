package ui

import "base:runtime"
import "core:strings"
import luaconfig "../lua"
import model "../model"
import settings "../settings"
import tabpkg "../tabs"
import tui "../tui"

// The activity bar is a column down the left edge, VS Code style. Each tab owns a
// slot ACTIVITY_SLOT rows tall with its glyph on the middle row, so the icons read
// as a spaced column rather than a stack.
ACTIVITY_WIDTH :: 5
ACTIVITY_SLOT :: 3
// One blank column between the activity strip and the content, so rows do not butt
// straight against the bar.
CONTENT_GUTTER :: 1
HEADER_HEIGHT :: 1
FOOTER_HEIGHT :: 1

Shell :: struct {
	tabs:       [dynamic]tabpkg.Tab,
	active:     int,
	rows:       [dynamic]tabpkg.Row,
	selected:   int,
	scroll:     int,
	hover:      int,
	hover_tab:  int,
	snap:       bool,
	footer:     string,
	overlay:    Overlay,
	config:     ^luaconfig.Engine,
	menu_entries: [dynamic]model.Menu_Entry,
	preferences: ^settings.Preferences,
	allocator:  runtime.Allocator,
	quit:       bool,
}

shell_init :: proc(shell: ^Shell, allocator := context.allocator) {
	shell.allocator = allocator
	shell.tabs = make([dynamic]tabpkg.Tab, allocator)
	shell.rows = make([dynamic]tabpkg.Row, allocator)
	shell.menu_entries = make([dynamic]model.Menu_Entry, allocator)
	shell.selected = -1
	shell.hover = -1
	shell.hover_tab = -1
	shell.footer = strings.clone(" m / right-click: menu", allocator)
	overlay_init(&shell.overlay, allocator)
}

shell_set_footer :: proc(shell: ^Shell, message: string) {
	delete(shell.footer)
	shell.footer = strings.clone(message, shell.allocator)
}

shell_destroy :: proc(shell: ^Shell) {
	tabpkg.rows_destroy(&shell.rows)
	for &tab in shell.tabs do tabpkg.tab_destroy(&tab)
	delete(shell.tabs)
	delete(shell.footer)
	shell_clear_menu(shell)
	delete(shell.menu_entries)
	overlay_destroy(&shell.overlay)
	shell^ = {}
}

shell_set_config :: proc(shell: ^Shell, config: ^luaconfig.Engine) {
	shell.config = config
}

shell_set_preferences :: proc(shell: ^Shell, preferences: ^settings.Preferences) {
	shell.preferences = preferences
}

shell_tree_tab :: proc(shell: ^Shell) -> ^tabpkg.Tab {
	for &tab in shell.tabs {
		if tab.name == "tree" do return &tab
	}
	return nil
}

shell_sync_preferences :: proc(shell: ^Shell) {
	if shell.preferences == nil do return
	hidden, root, expanded, ok := tabpkg.tree_state(shell_tree_tab(shell))
	if !ok do return
	shell.preferences.hidden = hidden
	settings.preferences_set_expanded(shell.preferences, root, expanded)
}

shell_save_preferences :: proc(shell: ^Shell) {
	if shell.preferences == nil do return
	shell_sync_preferences(shell)
	_ = settings.preferences_save(shell.preferences)
}

shell_clear_menu :: proc(shell: ^Shell) {
	for &entry in shell.menu_entries {
		delete(entry.id)
		delete(entry.label)
	}
	clear(&shell.menu_entries)
}

shell_open_menu :: proc(shell: ^Shell) {
	shell_clear_menu(shell)
	tab := shell_active_tab(shell)
	row := shell_selected_row(shell)
	if tab == nil || row == nil do return
	for entry in tabpkg.tab_menu(tab, row) {
		append(&shell.menu_entries, model.Menu_Entry{
			id = strings.clone(entry.id, shell.allocator),
			label = strings.clone(entry.label, shell.allocator),
			action = entry.action,
			danger = entry.danger,
		})
	}
	if shell.config != nil {
		extra, message := luaconfig.engine_menu_entries(shell.config, tab.name, row.path, row.is_dir, shell.allocator)
		append(&shell.menu_entries, ..extra[:])
		delete(extra)
		if message != "" {
			shell_set_footer(shell, message)
			delete(message)
		}
	}
	if len(shell.menu_entries) > 0 do overlay_menu(&shell.overlay, "Actions", shell.menu_entries[:])
}

shell_apply_lua_pending :: proc(shell: ^Shell) {
	if shell.config == nil do return
	if shell.config.pending_tab != "" {
		if !shell_switch_named(shell, shell.config.pending_tab) do shell_set_footer(shell, "Lua requested an unknown tab")
		delete(shell.config.pending_tab)
		shell.config.pending_tab = ""
	}
	if shell.config.pending_reveal != "" {
		shell_set_footer(shell, shell.config.pending_reveal)
		delete(shell.config.pending_reveal)
		shell.config.pending_reveal = ""
	}
	if shell.config.pending_refresh {
		shell_reload(shell)
		shell.config.pending_refresh = false
	}
}

shell_change_root :: proc(shell: ^Shell, root: string) {
	if shell.config != nil do luaconfig.engine_set_root(shell.config, root)
	for &tab in shell.tabs {
		if tab.name == "tree" do continue
		_ = tabpkg.tab_root(&tab, root)
	}
}

shell_add_tab :: proc(shell: ^Shell, tab: tabpkg.Tab) {
	append(&shell.tabs, tab)
	if len(shell.tabs) == 1 do shell_reload(shell)
}

shell_active_tab :: proc(shell: ^Shell) -> ^tabpkg.Tab {
	if shell.active < 0 || shell.active >= len(shell.tabs) do return nil
	return &shell.tabs[shell.active]
}

shell_selected_row :: proc(shell: ^Shell) -> ^tabpkg.Row {
	if shell.selected < 0 || shell.selected >= len(shell.rows) do return nil
	return &shell.rows[shell.selected]
}

shell_reload :: proc(shell: ^Shell) {
	selected_id := ""
	if row := shell_selected_row(shell); row != nil do selected_id = strings.clone(row.id, shell.allocator)
	defer if selected_id != "" do delete(selected_id)
	tabpkg.rows_destroy(&shell.rows)
	tab := shell_active_tab(shell)
	if tab == nil {
		shell.rows = make([dynamic]tabpkg.Row, shell.allocator)
		shell.selected = -1
		return
	}
	shell.rows = tabpkg.tab_rows(tab, shell.allocator)
	shell.selected = -1
	if selected_id != "" {
		for row, index in shell.rows {
			if row.id == selected_id {
				shell.selected = index
				break
			}
		}
	}
	shell.scroll = min(shell.scroll, max(shell_total_height(shell) - 1, 0))
}

shell_switch_tab :: proc(shell: ^Shell, index: int) {
	if index < 0 || index >= len(shell.tabs) || index == shell.active do return
	shell.active = index
	shell.selected = -1
	shell.scroll = 0
	shell.hover = -1
	shell.hover_tab = -1
	result := tabpkg.tab_focus(shell_active_tab(shell))
	if result.message != "" do shell_set_footer(shell, result.message)
	if result.quit do shell.quit = true
	shell_reload(shell)
}

shell_switch_named :: proc(shell: ^Shell, name: string) -> bool {
	for &tab, index in shell.tabs {
		if tab.name == name {
			shell_switch_tab(shell, index)
			return true
		}
	}
	return false
}

shell_total_height :: proc(shell: ^Shell) -> int {
	total := 0
	for row in shell.rows do total += max(row.height, 1)
	return total
}

shell_row_top :: proc(shell: ^Shell, index: int) -> int {
	top := 0
	for current in 0 ..< min(index, len(shell.rows)) do top += max(shell.rows[current].height, 1)
	return top
}

shell_row_at_line :: proc(shell: ^Shell, line: int) -> int {
	if line < 0 do return -1
	top := 0
	for row, index in shell.rows {
		height := max(row.height, 1)
		if line >= top && line < top + height do return index
		top += height
	}
	return -1
}

shell_select_delta :: proc(shell: ^Shell, delta: int, viewport: int) {
	if len(shell.rows) == 0 do return
	index := shell.selected
	if index < 0 {
		if delta >= 0 {
			index = 0
		} else {
			index = len(shell.rows) - 1
		}
	} else {
		index += delta
	}
	step := 1
	if delta < 0 do step = -1
	for index >= 0 && index < len(shell.rows) && !shell.rows[index].selectable do index += step
	if index < 0 || index >= len(shell.rows) do return
	shell.selected = index
	shell.snap = true
	shell_snap_selection(shell, viewport)
}

shell_snap_selection :: proc(shell: ^Shell, viewport: int) {
	if shell.selected < 0 || viewport <= 0 do return
	top := shell_row_top(shell, shell.selected)
	bottom := top + max(shell.rows[shell.selected].height, 1)
	if top < shell.scroll do shell.scroll = top
	if bottom > shell.scroll + viewport do shell.scroll = bottom - viewport
	shell.scroll = max(shell.scroll, 0)
}

shell_wheel :: proc(shell: ^Shell, delta, viewport: int) {
	maximum := max(shell_total_height(shell) - viewport, 0)
	shell.scroll = clamp(shell.scroll + delta, 0, maximum)
	shell.snap = false
}

shell_apply_result :: proc(shell: ^Shell, result: tabpkg.Tab_Result) {
	if result.message != "" do shell_set_footer(shell, result.message)
	if shell.config != nil && result.open_path != "" {
		message := luaconfig.engine_emit(shell.config, "open", result.open_path)
		if message != "" {
			shell_set_footer(shell, message)
			delete(message)
		}
	}
	if result.root_path != "" {
		shell_change_root(shell, result.root_path)
		if shell.config != nil {
			message := luaconfig.engine_emit(shell.config, "root", result.root_path)
			if message != "" {
				shell_set_footer(shell, message)
				delete(message)
			}
		}
	}
	if result.switch_tab != "" do _ = shell_switch_named(shell, result.switch_tab)
	if result.rows_changed {
		shell_sync_preferences(shell)
		if shell.preferences != nil do _ = settings.preferences_save(shell.preferences)
		shell_reload(shell)
	}
	if result.open_menu {
		shell_open_menu(shell)
	}
	if result.quit do shell.quit = true
}

action_needs_prompt :: proc(action: model.Action) -> (string, bool) {
	#partial switch action {
	case .New_File: return "New file", true
	case .New_Folder: return "New folder", true
	case .Rename: return "Rename", true
	case .Change_Folder: return "Change folder", true
	case .Commit: return "Commit message", true
	}
	return "", false
}

shell_run_action :: proc(shell: ^Shell, action: model.Action, value := "") {
	tab := shell_active_tab(shell)
	row := shell_selected_row(shell)
	if tab == nil || row == nil do return
	if action == .Change_Folder do shell_sync_preferences(shell)
	result := tabpkg.tab_action(tab, row, action, value)
	shell_apply_result(shell, result)
}

shell_overlay_result :: proc(shell: ^Shell, result: Overlay_Result) {
	if result.dismiss {
		overlay_close(&shell.overlay)
		shell_clear_menu(shell)
		return
	}
	if !result.submit do return
	action := result.action
	value := result.value
	if action == .Lua {
		tab := shell_active_tab(shell)
		row := shell_selected_row(shell)
		if shell.config != nil && tab != nil && row != nil {
			message := luaconfig.engine_run_menu(shell.config, tab.name, result.entry_id, row.path, row.is_dir)
			if message != "" {
				shell_set_footer(shell, message)
				delete(message)
			}
		}
		overlay_close(&shell.overlay)
		shell_clear_menu(shell)
		shell_apply_lua_pending(shell)
		return
	}
	if shell.overlay.kind == .Menu {
		if title, needed := action_needs_prompt(action); needed {
			initial := ""
			if action == .Rename {
				row := shell_selected_row(shell)
				if row != nil {
					at := strings.last_index_byte(row.path, '/')
					if at >= 0 do initial = row.path[at + 1:]
				}
			}
			overlay_prompt(&shell.overlay, title, action, initial)
			return
		}
		if action == .Delete || action == .Discard_Changes {
			overlay_confirm(&shell.overlay, "Delete permanently?", action)
			if action == .Discard_Changes do shell.overlay.title = "Discard changes permanently?"
			return
		}
	}
	overlay_close(&shell.overlay)
	shell_clear_menu(shell)
	shell_run_action(shell, action, value)
}

shell_key :: proc(shell: ^Shell, key: tui.Key, viewport: int) {
	if shell.overlay.kind != .None {
		shell_overlay_result(shell, overlay_key(&shell.overlay, key))
		return
	}
	if key.code == .Up {
		shell_select_delta(shell, -1, viewport)
		return
	}
	if key.code == .Down {
		shell_select_delta(shell, 1, viewport)
		return
	}
	if key.code == .Page_Up {
		shell_wheel(shell, -viewport, viewport)
		return
	}
	if key.code == .Page_Down {
		shell_wheel(shell, viewport, viewport)
		return
	}
	if key.code == .Tab {
		shell_switch_tab(shell, (shell.active + 1) % max(len(shell.tabs), 1))
		return
	}
	if key.code == .Rune && key.rune >= '1' && key.rune <= '9' {
		shell_switch_tab(shell, int(key.rune - '1'))
		return
	}
	tab := shell_active_tab(shell)
	row := shell_selected_row(shell)
	if key.code == .Enter {
		shell_apply_result(shell, tabpkg.tab_select(tab, row))
		return
	}
	shell_apply_result(shell, tabpkg.tab_key(tab, key, row))
}

shell_paste :: proc(shell: ^Shell, value: string) {
	if shell.overlay.kind != .None {
		overlay_paste(&shell.overlay, value)
		return
	}
	shell_apply_result(shell, tabpkg.tab_paste(shell_active_tab(shell), value, shell_selected_row(shell)))
}

shell_mouse :: proc(shell: ^Shell, mouse: tui.Mouse_Event, width, height: int) {
	viewport := shell_viewport_height(height)
	if mouse.action == .Scroll_Up {
		shell_wheel(shell, -3, viewport)
		return
	}
	if mouse.action == .Scroll_Down {
		shell_wheel(shell, 3, viewport)
		return
	}
	// The activity column owns every event in its width, including hover: a tab lights
	// up before the click lands.
	if mouse.x < ACTIVITY_WIDTH {
		shell.hover = -1
		shell.hover_tab = -1
		for _, index in shell.tabs {
			top, bottom := shell_activity_bounds(shell, index, height)
			if mouse.y >= top && mouse.y < bottom {
				shell.hover_tab = index
				if mouse.action == .Press do shell_switch_tab(shell, index)
				return
			}
		}
		return
	}
	shell.hover_tab = -1
	body_top := HEADER_HEIGHT
	if mouse.y < body_top || mouse.y >= height - FOOTER_HEIGHT do return
	index := shell_row_at_line(shell, shell.scroll + mouse.y - body_top)
	if mouse.action == .Move {
		shell.hover = index
		return
	}
	if mouse.action == .Press && index >= 0 && shell.rows[index].selectable {
		shell.selected = index
		if mouse.button == 2 {
			shell_open_menu(shell)
		}
	}
}

shell_cursor_position :: proc(shell: ^Shell, width, height: int) -> (int, int, bool) {
	if shell.overlay.kind == .Prompt {
		rect := overlay_rect(&shell.overlay, width, height)
		input_width := max(rect.width - 6, 0)
		column := min(tui.text_width(string(shell.overlay.input[:])), input_width)
		return rect.x + 4 + column, rect.y + 1, true
	}
	if shell.overlay.kind != .None do return 0, 0, false
	row := shell_selected_row(shell)
	if row == nil || row.kind != .Commit_Box do return 0, 0, false
	line := shell_row_top(shell, shell.selected) - shell.scroll + HEADER_HEIGHT
	if line < HEADER_HEIGHT || line + 1 >= height - FOOTER_HEIGHT do return 0, 0, false
	column := min(tui.text_width(row.input_value), max(width - ACTIVITY_WIDTH - CONTENT_GUTTER - 5, 0))
	return ACTIVITY_WIDTH + CONTENT_GUTTER + 1 + column, line + 1, true
}

fill_rect :: proc(buffer: ^tui.Buffer, rect: tui.Rect, style: tui.Style) {
	tui.buffer_fill(buffer, rect, style)
}

shell_viewport_height :: proc(height: int) -> int {
	return max(height - HEADER_HEIGHT - FOOTER_HEIGHT, 0)
}

shell_tab_icon :: proc(shell: ^Shell, index: int) -> string {
	if index < 0 || index >= len(shell.tabs) do return ""
	switch shell.tabs[index].name {
	case "tree": return "\uf07b"
	case "changes": return "\uf126"
	case "graph": return "\ue725"
	}
	return shell.tabs[index].icon
}

// Row of the first slot. The icon block is centred in the column's usable height
// rather than stacked at the top, so a tall terminal does not leave the icons
// stranded against the header.
shell_activity_origin :: proc(shell: ^Shell, height: int) -> int {
	usable := max(height - FOOTER_HEIGHT - 2, 0)
	block := len(shell.tabs) * ACTIVITY_SLOT
	return max((usable - block) / 2, 0)
}

shell_activity_bounds :: proc(shell: ^Shell, target, height: int) -> (int, int) {
	if target < 0 || target >= len(shell.tabs) do return 0, 0
	top := shell_activity_origin(shell, height) + target * ACTIVITY_SLOT
	return top, top + ACTIVITY_SLOT
}

// One slot. The active tab lights its whole middle row with the selection colour and
// caps it above and below with half blocks drawn in that same colour, so the
// highlight reads as a capsule around the icon rather than a hard rectangle.
shell_draw_slot :: proc(shell: ^Shell, buffer: ^tui.Buffer, top: int, icon: string, active, hovered: bool) {
	bar := tui.Style{bg = tui.ACTIVITY_BG}
	highlight := active ? tui.ACTIVITY_ACTIVE_BG : tui.HOVER_BG
	middle := top + ACTIVITY_SLOT / 2
	for y in top ..< min(top + ACTIVITY_SLOT, buffer.height) {
		for x in 0 ..< ACTIVITY_WIDTH {
			cell := tui.Cell{rune = ' ', style = bar}
			if active || hovered {
				switch {
				case y == middle:
					cell.style = tui.Style{bg = highlight}
				case y == middle - 1:
					cell = tui.Cell{rune = '▄', style = tui.Style{fg = highlight, bg = tui.ACTIVITY_BG}}
				case y == middle + 1:
					cell = tui.Cell{rune = '▀', style = tui.Style{fg = highlight, bg = tui.ACTIVITY_BG}}
				}
			}
			tui.buffer_set(buffer, x, y, cell)
		}
	}
	if middle >= buffer.height do return
	glyph := tui.Style{fg = active ? tui.RAMP_BRIGHT : tui.RAMP_MUTED, bg = active || hovered ? highlight : tui.ACTIVITY_BG}
	if !active && !hovered do glyph.attrs = {.Dim}
	x := max((ACTIVITY_WIDTH - tui.text_width(icon)) / 2, 0)
	tui.buffer_draw_text(buffer, x, middle, icon, glyph, ACTIVITY_WIDTH - x)
}

shell_draw_activity :: proc(shell: ^Shell, buffer: ^tui.Buffer) {
	fill_rect(buffer, tui.Rect{x = 0, y = 0, width = ACTIVITY_WIDTH, height = buffer.height}, tui.Style{bg = tui.ACTIVITY_BG})
	for _, index in shell.tabs {
		top, _ := shell_activity_bounds(shell, index, buffer.height)
		if top >= buffer.height do break
		shell_draw_slot(shell, buffer, top, shell_tab_icon(shell, index), index == shell.active, index == shell.hover_tab)
	}
}

shell_draw_header :: proc(shell: ^Shell, buffer: ^tui.Buffer, tab: ^tabpkg.Tab) {
	heading := tabpkg.tab_heading(tab)
	y := 0
	x := ACTIVITY_WIDTH + CONTENT_GUTTER
	if tab.name == "tree" {
		label := strings.to_upper(heading.title, context.temp_allocator)
		x += tui.buffer_draw_text(buffer, x, y, " ", tui.PLAIN_STYLE, 1)
		x += tui.buffer_draw_text(buffer, x, y, label, tui.Style{fg = tui.ACCENT, attrs = {.Bold}}, buffer.width - x)
	} else {
		x += tui.buffer_draw_text(buffer, x, y, " ▾ ", tui.Style{attrs = {.Bold}}, min(3, buffer.width))
		x += tui.buffer_draw_text(buffer, x, y, heading.title, tui.Style{attrs = {.Bold}}, buffer.width - x)
		if heading.detail != "" && x < buffer.width {
			x += tui.buffer_draw_text(buffer, x, y, "  ", tui.Style{attrs = {.Dim}}, buffer.width - x)
			x += tui.buffer_draw_text(buffer, x, y, heading.detail, tui.Style{attrs = {.Dim}}, buffer.width - x)
		}
		if heading.meta != "" && x < buffer.width {
			x += tui.buffer_draw_text(buffer, x, y, " · ", tui.Style{attrs = {.Dim}}, buffer.width - x)
			_ = tui.buffer_draw_text(buffer, x, y, heading.meta, tui.Style{attrs = {.Dim}}, buffer.width - x)
		}
	}
	actions := " \ueb37 \ueac5 "
	if tab.name == "tree" do actions = " \uea7f \uea80 \ueb37 \ueac5 "
	actions_width := tui.text_width(actions)
	if actions_width < buffer.width do tui.buffer_draw_text(buffer, buffer.width - actions_width, y, actions, tui.Style{attrs = {.Dim}}, actions_width)
}

shell_render :: proc(shell: ^Shell, buffer: ^tui.Buffer, layout: ^tui.Layout) {
	tui.buffer_clear(buffer)
	tui.layout_clear(layout)
	if buffer.width < ACTIVITY_WIDTH + CONTENT_GUTTER + 8 || buffer.height < HEADER_HEIGHT + FOOTER_HEIGHT do return
	selected_style := tui.Style{fg = tui.DEFAULT_COLOR, bg = tui.SELECTED_BG, attrs = {.Bold}}
	hover_style := tui.Style{fg = tui.DEFAULT_COLOR, bg = tui.HOVER_BG}
	shell_draw_activity(shell, buffer)
	tab := shell_active_tab(shell)
	if tab == nil do return
	shell_draw_header(shell, buffer, tab)
	content_x := ACTIVITY_WIDTH + CONTENT_GUTTER
	content_width := buffer.width - ACTIVITY_WIDTH - CONTENT_GUTTER
	body_top := HEADER_HEIGHT
	footer_y := buffer.height - FOOTER_HEIGHT
	viewport := shell_viewport_height(buffer.height)
	total := shell_total_height(shell)
	body_width := content_width
	if total > viewport do body_width = max(body_width - 1, 0)
	line := -shell.scroll
	for &row, index in shell.rows {
		height := max(row.height, 1)
		if line + height <= 0 {
			line += height
			continue
		}
		if line >= viewport do break
		y := body_top + max(line, 0)
		visible_height := min(height, viewport - max(line, 0))
		style := tui.PLAIN_STYLE
		if shell.selected == index && shell.selected >= 0 {
			if row.kind == .Commit_Box {
				style = tui.Style{fg = tui.BUTTON_BG}
			} else {
				style = selected_style
			}
		} else if shell.hover == index {
			style = hover_style
		}
		fill_rect(buffer, tui.Rect{x = content_x, y = y, width = body_width, height = visible_height}, style)
		tui.render_node(buffer, layout, &row.node, tui.Rect{x = content_x, y = y, width = body_width, height = visible_height}, style)
		line += height
	}
	if total > viewport {
		track_x := buffer.width - 1
		thumb_height := max(viewport * viewport / total, 1)
		maximum := max(total - viewport, 1)
		thumb_y := body_top + shell.scroll * max(viewport - thumb_height, 0) / maximum
		for y in body_top ..< footer_y do tui.buffer_set(buffer, track_x, y, tui.Cell{rune = '│', style = tui.Style{attrs = {.Dim}}})
		for y in thumb_y ..< min(thumb_y + thumb_height, footer_y) do tui.buffer_set(buffer, track_x, y, tui.Cell{rune = '┃', style = tui.PLAIN_STYLE})
	}
	footer_style := tui.Style{attrs = {.Dim, .Italic}}
	footer := tui.truncate_text(shell.footer, max(content_width - 1, 0))
	defer delete(footer)
	tui.buffer_draw_text(buffer, content_x, footer_y, footer, footer_style, max(content_width - 1, 0))
	overlay_render(&shell.overlay, buffer)
}

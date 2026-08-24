package ui

import "base:runtime"
import "core:strings"
import luaconfig "../lua"
import model "../model"
import settings "../settings"
import tabpkg "../tabs"
import tui "../tui"

ACTIVITY_WIDTH :: 3

Shell :: struct {
	tabs:       [dynamic]tabpkg.Tab,
	active:     int,
	rows:       [dynamic]tabpkg.Row,
	selected:   int,
	scroll:     int,
	hover:      int,
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
	shell.footer = strings.clone("↑↓ navigate · Enter open · m menu · 1-9 tabs · q quit", allocator)
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
	tab := shell_tree_tab(shell)
	theme, hidden, git_decorations, root, expanded, ok := tabpkg.tree_state(tab)
	if !ok do return
	settings.preferences_set_icons(shell.preferences, model.icon_theme_name(theme))
	shell.preferences.hidden = hidden
	shell.preferences.git_decorations = git_decorations
	settings.preferences_set_expanded(shell.preferences, root, expanded)
}

shell_save_preferences :: proc(shell: ^Shell) {
	if shell.preferences == nil do return
	shell_sync_preferences(shell)
	_ = settings.preferences_save(shell.preferences)
}

shell_apply_setting :: proc(shell: ^Shell, setting: Setting_Action) {
	if shell.preferences == nil do return
	tab := shell_tree_tab(shell)
	theme, hidden, git_decorations, _, _, ok := tabpkg.tree_state(tab)
	if !ok do return
	switch setting {
	case .Icons: theme = model.icon_theme_toggle(theme)
	case .Hidden: hidden = !hidden
	case .Git_Decorations: git_decorations = !git_decorations
	case .Start_Tab:
		active := shell_active_tab(shell)
		if active != nil do settings.preferences_set_start_tab(shell.preferences, active.name)
	case .None:
	}
	_ = tabpkg.tree_apply_preferences(tab, theme, hidden, git_decorations)
	shell_sync_preferences(shell)
	_ = settings.preferences_save(shell.preferences)
	shell_reload(shell)
	overlay_settings(
		&shell.overlay,
		shell.preferences.icons,
		shell.preferences.hidden,
		shell.preferences.git_decorations,
		shell.preferences.start_tab,
	)
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
	if result.setting != .None {
		shell_apply_setting(shell, result.setting)
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
	if key.code == .Rune && key.rune == ',' {
		if shell.preferences != nil {
			overlay_settings(
				&shell.overlay,
				shell.preferences.icons,
				shell.preferences.hidden,
				shell.preferences.git_decorations,
				shell.preferences.start_tab,
			)
		}
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
	viewport := max(height - 2, 0)
	if mouse.action == .Scroll_Up {
		shell_wheel(shell, -3, viewport)
		return
	}
	if mouse.action == .Scroll_Down {
		shell_wheel(shell, 3, viewport)
		return
	}
	if mouse.x < ACTIVITY_WIDTH && mouse.y >= 1 {
		if mouse.action == .Press do shell_switch_tab(shell, mouse.y - 1)
		return
	}
	if mouse.y < 1 || mouse.y >= height - 1 do return
	index := shell_row_at_line(shell, shell.scroll + mouse.y - 1)
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
		panel_width := min(max(tui.text_width(shell.overlay.title) + 4, 28), width - 2)
		x := (width - panel_width) / 2
		y := (height - 3) / 2
		input_width := max(panel_width - 6, 0)
		column := min(tui.text_width(string(shell.overlay.input[:])), input_width)
		return x + 4 + column, y + 1, true
	}
	if shell.overlay.kind != .None do return 0, 0, false
	row := shell_selected_row(shell)
	if row == nil || row.kind != .Commit_Box do return 0, 0, false
	line := shell_row_top(shell, shell.selected) - shell.scroll + 1
	if line < 1 || line + 1 >= height - 1 do return 0, 0, false
	value := ""
	if len(row.node.children) > 1 {
		input_row := &row.node.children[1]
		if len(input_row.children) > 1 {
			priority := &input_row.children[1]
			if len(priority.children) > 0 {
				truncate := &priority.children[0]
				if len(truncate.children) > 0 do value = truncate.children[0].value
			}
		}
	}
	column := min(tui.text_width(value), max(width - ACTIVITY_WIDTH - 5, 0))
	return ACTIVITY_WIDTH + 3 + column, line + 1, true
}

fill_rect :: proc(buffer: ^tui.Buffer, rect: tui.Rect, style: tui.Style) {
	for y in rect.y ..< rect.y + rect.height {
		for x in rect.x ..< rect.x + rect.width {
			tui.buffer_set(buffer, x, y, tui.Cell{rune = ' ', style = style})
		}
	}
}

shell_render :: proc(shell: ^Shell, buffer: ^tui.Buffer, layout: ^tui.Layout) {
	tui.buffer_clear(buffer)
	tui.layout_clear(layout)
	if buffer.width <= ACTIVITY_WIDTH || buffer.height < 3 do return
	activity_style := tui.Style{fg = tui.rgb(0x9d, 0xa5, 0xb4), bg = tui.rgb(0x18, 0x1a, 0x1f)}
	active_style := tui.Style{fg = tui.rgb(0xff, 0xff, 0xff), bg = tui.rgb(0x32, 0x36, 0x3d), attrs = {.Bold}}
	selected_style := tui.Style{fg = tui.DEFAULT_COLOR, bg = tui.rgb(0x32, 0x36, 0x3d)}
	hover_style := tui.Style{fg = tui.DEFAULT_COLOR, bg = tui.rgb(0x27, 0x2b, 0x33)}
	fill_rect(buffer, tui.Rect{width = ACTIVITY_WIDTH, height = buffer.height}, activity_style)
	for tab, index in shell.tabs {
		style := activity_style
		if index == shell.active do style = active_style
		fill_rect(buffer, tui.Rect{x = 0, y = index + 1, width = ACTIVITY_WIDTH, height = 1}, style)
		tui.buffer_draw_text(buffer, 1, index + 1, tab.icon, style, 2)
	}
	tab := shell_active_tab(shell)
	if tab == nil do return
	content_x := ACTIVITY_WIDTH
	content_width := buffer.width - ACTIVITY_WIDTH
	footer_y := buffer.height - 1
	tui.buffer_draw_text(buffer, content_x + 1, 0, tab.title, tui.Style{attrs = {.Bold}}, content_width - 2)
	viewport := buffer.height - 2
	line := -shell.scroll
	for &row, index in shell.rows {
		height := max(row.height, 1)
		if line + height <= 0 {
			line += height
			continue
		}
		if line >= viewport do break
		y := 1 + max(line, 0)
		visible_height := min(height, viewport - max(line, 0))
		style := tui.PLAIN_STYLE
		if shell.selected == index && shell.selected >= 0 {
			style = selected_style
		} else if shell.hover == index {
			style = hover_style
		}
		fill_rect(buffer, tui.Rect{x = content_x, y = y, width = content_width, height = visible_height}, style)
		tui.render_node(buffer, layout, &row.node, tui.Rect{x = content_x, y = y, width = content_width, height = visible_height}, style)
		line += height
	}
	total := shell_total_height(shell)
	if total > viewport {
		track_x := buffer.width - 1
		thumb_height := max(viewport * viewport / total, 1)
		maximum := max(total - viewport, 1)
		thumb_y := 1 + shell.scroll * max(viewport - thumb_height, 0) / maximum
		for y in 1 ..< footer_y do tui.buffer_set(buffer, track_x, y, tui.Cell{rune = '│', style = tui.Style{attrs = {.Dim}}})
		for y in thumb_y ..< min(thumb_y + thumb_height, footer_y) do tui.buffer_set(buffer, track_x, y, tui.Cell{rune = '┃', style = tui.PLAIN_STYLE})
	}
	footer_style := tui.Style{fg = tui.rgb(0xa0, 0xa7, 0xb4), bg = tui.rgb(0x18, 0x1a, 0x1f), attrs = {.Dim}}
	fill_rect(buffer, tui.Rect{x = content_x, y = footer_y, width = content_width, height = 1}, footer_style)
	footer := tui.truncate_text(shell.footer, content_width - 2)
	defer delete(footer)
	tui.buffer_draw_text(buffer, content_x + 1, footer_y, footer, footer_style, content_width - 2)
	overlay_render(&shell.overlay, buffer)
}

package ui

import "base:runtime"
import "core:strings"
import model "../model"
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
	allocator:  runtime.Allocator,
	quit:       bool,
}

shell_init :: proc(shell: ^Shell, allocator := context.allocator) {
	shell.allocator = allocator
	shell.tabs = make([dynamic]tabpkg.Tab, allocator)
	shell.rows = make([dynamic]tabpkg.Row, allocator)
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
	overlay_destroy(&shell.overlay)
	shell^ = {}
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
	shell_reload(shell)
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
	if result.rows_changed do shell_reload(shell)
	if result.open_menu {
		tab := shell_active_tab(shell)
		row := shell_selected_row(shell)
		entries := tabpkg.tab_menu(tab, row)
		if len(entries) > 0 do overlay_menu(&shell.overlay, "Actions", entries)
	}
	if result.quit do shell.quit = true
}

action_needs_prompt :: proc(action: model.Action) -> (string, bool) {
	#partial switch action {
	case .New_File: return "New file", true
	case .New_Folder: return "New folder", true
	case .Rename: return "Rename", true
	case .Change_Folder: return "Change folder", true
	}
	return "", false
}

shell_run_action :: proc(shell: ^Shell, action: model.Action, value := "") {
	tab := shell_active_tab(shell)
	row := shell_selected_row(shell)
	if tab == nil || row == nil do return
	result := tabpkg.tab_action(tab, row, action, value)
	shell_apply_result(shell, result)
}

shell_overlay_result :: proc(shell: ^Shell, result: Overlay_Result) {
	if result.dismiss {
		overlay_close(&shell.overlay)
		return
	}
	if !result.submit do return
	action := result.action
	value := result.value
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
		if action == .Delete {
			overlay_confirm(&shell.overlay, "Delete permanently?", action)
			return
		}
	}
	overlay_close(&shell.overlay)
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
		overlay_settings(&shell.overlay)
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
	overlay_paste(&shell.overlay, value)
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
			tab := shell_active_tab(shell)
			entries := tabpkg.tab_menu(tab, shell_selected_row(shell))
			if len(entries) > 0 do overlay_menu(&shell.overlay, "Actions", entries)
		}
	}
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

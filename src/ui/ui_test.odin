package ui

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:testing"
import model "../model"
import settings "../settings"
import tabpkg "../tabs"
import tui "../tui"

fake_rows :: proc(data: rawptr, width: int, allocator: runtime.Allocator) -> [dynamic]tabpkg.Row {
	rows := make([dynamic]tabpkg.Row, allocator)
	for index in 0 ..< 12 {
		id := fmt.aprintf("row-%d", index, allocator = allocator)
		append(&rows, tabpkg.Row{
			id = id,
			path = id,
			selectable = true,
			height = 1,
			node = tui.text(id),
		})
	}
	return rows
}

fake_menu :: proc(data: rawptr, selected: ^tabpkg.Row) -> []model.Menu_Entry {
	return model.TREE_FILE_MENU[:]
}

fake_tab :: proc(name: string) -> tabpkg.Tab {
	return tabpkg.Tab{name = name, title = name, icon = "x", rows = fake_rows, menu = fake_menu}
}

@(test)
test_shell_keeps_wheel_and_selection_separate :: proc(t: ^testing.T) {
	shell: Shell
	shell_init(&shell)
	defer shell_destroy(&shell)
	shell_add_tab(&shell, fake_tab("one"))
	testing.expect_value(t, shell.selected, -1)
	shell_select_delta(&shell, 1, 5)
	testing.expect_value(t, shell.selected, 0)
	shell_wheel(&shell, 4, 5)
	testing.expect_value(t, shell.selected, 0)
	testing.expect_value(t, shell.scroll, 4)
}

@(test)
test_shell_switches_tabs_and_resets_selection :: proc(t: ^testing.T) {
	shell: Shell
	shell_init(&shell)
	defer shell_destroy(&shell)
	shell_add_tab(&shell, fake_tab("one"))
	shell_add_tab(&shell, fake_tab("two"))
	shell_select_delta(&shell, 1, 5)
	shell_switch_tab(&shell, 1)
	testing.expect_value(t, shell.active, 1)
	testing.expect_value(t, shell.selected, -1)
	testing.expect_value(t, shell.scroll, 0)
}

@(test)
test_shell_right_click_opens_menu :: proc(t: ^testing.T) {
	shell: Shell
	shell_init(&shell)
	defer shell_destroy(&shell)
	shell_add_tab(&shell, fake_tab("one"))
	shell_mouse(&shell, tui.Mouse_Event{x = ACTIVITY_WIDTH + CONTENT_GUTTER + 2, y = HEADER_HEIGHT, button = 2, action = .Press}, 40, 12)
	testing.expect_value(t, shell.selected, 0)
	testing.expect_value(t, shell.overlay.kind, Overlay_Kind.Menu)
}

@(test)
test_overlay_prompt_edits_unicode :: proc(t: ^testing.T) {
	overlay: Overlay
	overlay_init(&overlay)
	defer overlay_destroy(&overlay)
	overlay_prompt(&overlay, "Rename", .Rename)
	_ = overlay_key(&overlay, tui.Key{code = .Rune, rune = '界'})
	_ = overlay_key(&overlay, tui.Key{code = .Rune, rune = 'x'})
	overlay_backspace(&overlay)
	result := overlay_key(&overlay, tui.Key{code = .Enter})
	testing.expect(t, result.submit)
	testing.expect_value(t, result.value, "界")
}

@(test)
test_prompt_requests_a_visible_cursor :: proc(t: ^testing.T) {
	shell: Shell
	shell_init(&shell)
	defer shell_destroy(&shell)
	overlay_prompt(&shell.overlay, "Rename", .Rename, "name")
	x, y, visible := shell_cursor_position(&shell, 40, 10)
	testing.expect(t, visible)
	testing.expect(t, x > 0)
	testing.expect(t, y > 0)
}

@(test)
test_shell_renders_headless_buffer :: proc(t: ^testing.T) {
	shell: Shell
	shell_init(&shell)
	defer shell_destroy(&shell)
	shell_add_tab(&shell, fake_tab("Explorer"))
	buffer: tui.Buffer
	tui.buffer_init(&buffer, 40, 10)
	defer tui.buffer_destroy(&buffer)
	layout: tui.Layout
	tui.layout_init(&layout)
	defer tui.layout_destroy(&layout)
	shell_render(&shell, &buffer, &layout)
	cell, ok := tui.buffer_get(&buffer, ACTIVITY_WIDTH + CONTENT_GUTTER + 3, 0)
	testing.expect(t, ok)
	testing.expect_value(t, cell.rune, 'E')
	testing.expect(t, len(layout.regions) == 0)
	top, _ := shell_activity_bounds(&shell, 0, buffer.height)
	cap_top, cap_ok := tui.buffer_get(&buffer, 0, top)
	body, _ := tui.buffer_get(&buffer, 0, top + 1)
	cap_bottom, _ := tui.buffer_get(&buffer, 0, top + 2)
	testing.expect(t, cap_ok)
	testing.expect_value(t, cap_top.rune, '▄')
	testing.expect_value(t, cap_top.style.fg, tui.ACTIVITY_ACTIVE_BG)
	testing.expect_value(t, body.style.bg, tui.ACTIVITY_ACTIVE_BG)
	testing.expect_value(t, cap_bottom.rune, '▀')
}

@(test)
test_graph_has_its_own_activity_slot :: proc(t: ^testing.T) {
	shell: Shell
	shell_init(&shell)
	defer shell_destroy(&shell)
	shell_add_tab(&shell, fake_tab("tree"))
	shell_add_tab(&shell, fake_tab("changes"))
	shell_add_tab(&shell, fake_tab("graph"))
	shell_switch_tab(&shell, 2)
	buffer: tui.Buffer
	tui.buffer_init(&buffer, 40, 16)
	defer tui.buffer_destroy(&buffer)
	layout: tui.Layout
	tui.layout_init(&layout)
	defer tui.layout_destroy(&layout)
	shell_render(&shell, &buffer, &layout)
	// Every tab owns a slot; only the active one is lit.
	graph_top, _ := shell_activity_bounds(&shell, 2, buffer.height)
	testing.expect_value(t, graph_top, shell_activity_origin(&shell, buffer.height) + 2 * ACTIVITY_SLOT)
	lit, _ := tui.buffer_get(&buffer, 0, graph_top + 1)
	testing.expect_value(t, lit.style.bg, tui.ACTIVITY_ACTIVE_BG)
	changes_top, _ := shell_activity_bounds(&shell, 1, buffer.height)
	inactive, _ := tui.buffer_get(&buffer, 0, changes_top + 1)
	testing.expect_value(t, inactive.style.bg, tui.ACTIVITY_BG)
}

@(test)
test_tree_expansion_is_persisted :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "trek-ui-tree-*", context.allocator)
	testing.expect(t, err == nil)
	defer { _ = os.remove_all(root); delete(root) }
	dir, _ := filepath.join([]string{root, "src"}, context.allocator)
	defer delete(dir)
	_ = os.make_directory(dir)
	preferences: settings.Preferences
	settings.preferences_init(&preferences, root)
	defer settings.preferences_destroy(&preferences)
	shell: Shell
	shell_init(&shell)
	defer shell_destroy(&shell)
	shell_set_preferences(&shell, &preferences)
	shell_add_tab(&shell, tabpkg.tree_tab(root))
	shell_select_delta(&shell, 1, 8)
	shell_key(&shell, tui.Key{code = .Enter}, 8)
	paths := settings.preferences_expanded(&preferences, root)
	testing.expect_value(t, len(paths), 1)
	if len(paths) == 1 do testing.expect_value(t, paths[0], dir)
}

hidden_tab :: proc(name: string) -> tabpkg.Tab {
	tab := fake_tab(name)
	tab.visible = proc(data: rawptr) -> bool { return false }
	return tab
}

// Slots address what is on screen. A hidden tab occupies none, cannot be reached by
// number key or by name, and never leaves the bar with a gap in it.
@(test)
test_hidden_tabs_leave_the_activity_bar :: proc(t: ^testing.T) {
	shell: Shell
	shell_init(&shell)
	defer shell_destroy(&shell)
	shell_add_tab(&shell, fake_tab("tree"))
	shell_add_tab(&shell, hidden_tab("changes"))
	shell_add_tab(&shell, fake_tab("graph"))

	testing.expect_value(t, shell_visible_count(&shell), 2)
	// The graph tab is index 2 but sits in slot 1, right after the tree.
	testing.expect_value(t, shell_visible_at(&shell, 1), 2)
	testing.expect_value(t, shell_slot_of(&shell, 2), 1)
	testing.expect_value(t, shell_slot_of(&shell, 1), -1)

	// Pressing 2 reaches the graph, not the hidden changes tab.
	shell_key(&shell, tui.Key{code = .Rune, rune = '2'}, 8)
	testing.expect_value(t, shell.active, 2)

	// And a hidden tab refuses to be switched to by name.
	testing.expect(t, shell_switch_named(&shell, "changes"))
	testing.expect_value(t, shell.active, 2)
}

@(test)
test_active_tab_falls_back_when_it_disappears :: proc(t: ^testing.T) {
	shell: Shell
	shell_init(&shell)
	defer shell_destroy(&shell)
	shell_add_tab(&shell, fake_tab("tree"))
	shell_add_tab(&shell, fake_tab("changes"))
	shell_switch_tab(&shell, 1)
	testing.expect_value(t, shell.active, 1)
	// The tab vanishes under the cursor, as walking out of a repository does.
	shell.tabs[1].visible = proc(data: rawptr) -> bool { return false }
	shell_ensure_visible_active(&shell)
	testing.expect_value(t, shell.active, 0)
}

// The scrollbar mirrors the activity strip: rail in the strip's background, thumb in
// its active-slot background. Hovering fills the cell instead of half-filling it, so
// it thickens without taking a column from the content.
@(test)
test_scrollbar_mirrors_the_activity_strip :: proc(t: ^testing.T) {
	shell: Shell
	shell_init(&shell)
	defer shell_destroy(&shell)
	shell_add_tab(&shell, fake_tab("tree"))
	buffer: tui.Buffer
	tui.buffer_init(&buffer, 40, 6)
	defer tui.buffer_destroy(&buffer)
	layout: tui.Layout
	tui.layout_init(&layout)
	defer tui.layout_destroy(&layout)

	// fake_tab yields more rows than this height, so the bar is drawn.
	shell_render(&shell, &buffer, &layout)
	idle, ok := tui.buffer_get(&buffer, buffer.width - 1, HEADER_HEIGHT)
	testing.expect(t, ok)
	testing.expect_value(t, idle.rune, '▐')
	testing.expect_value(t, idle.style.fg, tui.ACTIVITY_ACTIVE_BG)

	// A move over the last column marks it hovered.
	shell_mouse(&shell, tui.Mouse_Event{x = buffer.width - 1, y = HEADER_HEIGHT, action = .Move}, buffer.width, buffer.height)
	testing.expect(t, shell.hover_scrollbar)
	shell_render(&shell, &buffer, &layout)
	hovered, _ := tui.buffer_get(&buffer, buffer.width - 1, HEADER_HEIGHT)
	testing.expect_value(t, hovered.rune, ' ')
	testing.expect_value(t, hovered.style.bg, tui.ACTIVITY_ACTIVE_BG)

	// Moving back into the content releases it.
	shell_mouse(&shell, tui.Mouse_Event{x = ACTIVITY_WIDTH + CONTENT_GUTTER, y = HEADER_HEIGHT, action = .Move}, buffer.width, buffer.height)
	testing.expect(t, !shell.hover_scrollbar)
}

// The footer is not a permanent hint line: it exists only while something is being
// said, and gives the row back to the content otherwise.
@(test)
test_footer_collapses_when_silent :: proc(t: ^testing.T) {
	shell: Shell
	shell_init(&shell)
	defer shell_destroy(&shell)
	shell_add_tab(&shell, fake_tab("tree"))
	testing.expect_value(t, shell_footer_height(&shell), 0)
	quiet := shell_viewport_height(&shell, 20)
	shell_set_footer(&shell, "staged")
	testing.expect_value(t, shell_footer_height(&shell), 1)
	testing.expect_value(t, shell_viewport_height(&shell, 20), quiet - 1)
}

// Every dialog is the same centred panel, so one lands where the last one did.
@(test)
test_dialogs_share_a_centred_panel :: proc(t: ^testing.T) {
	kinds := [?]Overlay_Kind{.Menu, .Prompt, .Confirm, .Help}
	for kind in kinds {
		overlay: Overlay
		overlay_init(&overlay)
		defer overlay_destroy(&overlay)
		switch kind {
		case .Menu: overlay_menu(&overlay, "Actions", model.TREE_FILE_MENU[:])
		case .Prompt: overlay_prompt(&overlay, "Rename", .Rename, "name")
		case .Confirm: overlay_confirm(&overlay, "Delete permanently?", .Delete)
		case .Help: overlay_help(&overlay, []string{"Move", "  ↑ ↓  move"})
		case .None:
		}
		rect := overlay_rect(&overlay, 100, 40)
		left := rect.x
		right := 100 - (rect.x + rect.width)
		top := rect.y
		bottom := 40 - (rect.y + rect.height)
		// Centred to within a column of rounding on each axis.
		testing.expectf(t, abs(left - right) <= 1, "%v not centred horizontally", kind)
		testing.expectf(t, abs(top - bottom) <= 1, "%v not centred vertically", kind)
	}
}

@(test)
test_help_lists_shortcuts_for_the_active_tab :: proc(t: ^testing.T) {
	shell: Shell
	shell_init(&shell)
	defer shell_destroy(&shell)
	shell_add_tab(&shell, fake_tab("tree"))
	shell_key(&shell, tui.Key{code = .Rune, rune = '?'}, 12)
	testing.expect_value(t, shell.overlay.kind, Overlay_Kind.Help)
	joined := strings.concatenate(shell.overlay.help, context.allocator)
	defer delete(joined)
	// The common keys plus the ones only the tree has.
	testing.expect(t, strings.contains(joined, "quit"))
	testing.expect(t, strings.contains(joined, "tree / explorer mode"))
	// And it closes on the key that opened it.
	shell_key(&shell, tui.Key{code = .Rune, rune = '?'}, 12)
	testing.expect_value(t, shell.overlay.kind, Overlay_Kind.None)
}

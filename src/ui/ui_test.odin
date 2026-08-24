package ui

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import model "../model"
import settings "../settings"
import tabpkg "../tabs"
import tui "../tui"

fake_rows :: proc(data: rawptr, allocator: runtime.Allocator) -> [dynamic]tabpkg.Row {
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
	shell_mouse(&shell, tui.Mouse_Event{x = 5, y = 1, button = 2, action = .Press}, 40, 12)
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
	cell, ok := tui.buffer_get(&buffer, ACTIVITY_WIDTH + 1, 0)
	testing.expect(t, ok)
	testing.expect_value(t, cell.rune, 'E')
	testing.expect(t, len(layout.regions) == 0)
}

@(test)
test_settings_overlay_updates_and_persists :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "trek-ui-settings-*", context.allocator)
	testing.expect(t, err == nil)
	defer { _ = os.remove_all(root); delete(root) }
	preferences: settings.Preferences
	settings.preferences_init(&preferences, root)
	defer settings.preferences_destroy(&preferences)
	shell: Shell
	shell_init(&shell)
	defer shell_destroy(&shell)
	shell_set_preferences(&shell, &preferences)
	shell_add_tab(&shell, tabpkg.tree_tab(root, .Emoji, false, true))
	shell_key(&shell, tui.Key{code = .Rune, rune = ','}, 8)
	testing.expect_value(t, shell.overlay.kind, Overlay_Kind.Settings)
	shell_key(&shell, tui.Key{code = .Enter}, 8)
	testing.expect_value(t, preferences.icons, "material")
	_, _, _, _, _, ok := tabpkg.tree_state(shell_tree_tab(&shell))
	testing.expect(t, ok)
	info, stat_error := os.stat(preferences.path, context.allocator)
	testing.expect(t, stat_error == nil)
	if stat_error == nil do os.file_info_delete(info, context.allocator)
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

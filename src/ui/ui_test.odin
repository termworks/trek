package ui

import "base:runtime"
import "core:fmt"
import "core:testing"
import model "../model"
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

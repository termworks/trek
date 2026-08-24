package tabs

import "base:runtime"
import tui "../tui"

changes_rows_proc :: proc(data: rawptr, allocator: runtime.Allocator) -> [dynamic]Row {
	rows := make([dynamic]Row, allocator)
	append(&rows, Row{
		id = "changes:empty",
		selectable = false,
		height = 1,
		node = tui.text(" No repository changes"),
	})
	return rows
}

changes_key_proc :: proc(data: rawptr, key: tui.Key, selected: ^Row) -> Tab_Result {
	if key.code == .Rune && key.rune == 'q' do return Tab_Result{quit = true}
	return {}
}

changes_tab :: proc() -> Tab {
	return Tab{
		name = "changes",
		title = "Changes",
		icon = "±",
		rows = changes_rows_proc,
		on_key = changes_key_proc,
	}
}

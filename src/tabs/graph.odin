package tabs

import "base:runtime"
import tui "../tui"

graph_rows_proc :: proc(data: rawptr, allocator: runtime.Allocator) -> [dynamic]Row {
	rows := make([dynamic]Row, allocator)
	append(&rows, Row{
		id = "graph:empty",
		selectable = false,
		height = 1,
		node = tui.text(" No commit graph"),
	})
	return rows
}

graph_key_proc :: proc(data: rawptr, key: tui.Key, selected: ^Row) -> Tab_Result {
	if key.code == .Rune && key.rune == 'q' do return Tab_Result{quit = true}
	return {}
}

graph_tab :: proc() -> Tab {
	return Tab{
		name = "graph",
		title = "Graph",
		icon = "⑂",
		rows = graph_rows_proc,
		on_key = graph_key_proc,
	}
}

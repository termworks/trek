package tabs

import "base:runtime"
import "core:fmt"
import "core:strings"
import gitcore "../git"
import tui "../tui"

Graph_Tab :: struct {
	root:      string,
	repo:      gitcore.Git_Repo,
	history:   gitcore.History,
	graph:     gitcore.Graph,
	message:   string,
	allocator: runtime.Allocator,
}

graph_clear :: proc(state: ^Graph_Tab) {
	gitcore.graph_destroy(&state.graph)
	gitcore.history_destroy(&state.history)
	gitcore.repo_destroy(&state.repo)
	delete(state.message)
	state.message = ""
}

graph_refresh :: proc(state: ^Graph_Tab) {
	graph_clear(state)
	repo, message, ok := gitcore.discover(state.root, state.allocator)
	if !ok {
		state.message = message
		return
	}
	state.repo = repo
	history, history_message, history_ok := gitcore.repo_history(&state.repo, state.allocator)
	if !history_ok {
		state.message = history_message
		return
	}
	state.history = history
	state.graph = gitcore.assign_lanes(&state.history, allocator = state.allocator)
}

graph_new :: proc(root: string, allocator := context.allocator) -> ^Graph_Tab {
	state := new(Graph_Tab, allocator)
	state.root = strings.clone(root, allocator)
	state.allocator = allocator
	graph_refresh(state)
	return state
}

graph_lane_style :: proc(lane: int) -> tui.Style {
	styles := [?]tui.Style{
		{fg = tui.rgb(0x73, 0xc9, 0x91), bg = tui.DEFAULT_COLOR},
		{fg = tui.rgb(0x6c, 0xae, 0xe4), bg = tui.DEFAULT_COLOR},
		{fg = tui.rgb(0xe2, 0xc0, 0x8d), bg = tui.DEFAULT_COLOR},
		{fg = tui.rgb(0xd1, 0x8c, 0xd1), bg = tui.DEFAULT_COLOR},
		{fg = tui.rgb(0xe4, 0x67, 0x6b), bg = tui.DEFAULT_COLOR},
		{fg = tui.rgb(0x68, 0xc5, 0xcc), bg = tui.DEFAULT_COLOR},
	}
	return styles[lane % len(styles)]
}

graph_cell_text :: proc(cell: rune) -> string {
	switch cell {
	case '●': return "●"
	case '│': return "│"
	case '├': return "├"
	case '╯': return "╯"
	case '╰': return "╰"
	case '┐': return "┐"
	case '┌': return "┌"
	case '┤': return "┤"
	case '─': return "─"
	case '…': return "…"
	}
	return " "
}

graph_lane_nodes :: proc(children: ^[dynamic]tui.Node, cells: []rune) {
	for cell, lane in cells {
		append(children, tui.text(graph_cell_text(cell), graph_lane_style(lane)))
		append(children, tui.text(" "))
	}
}

graph_ref_node :: proc(ref: string, lane: int, allocator: runtime.Allocator) -> tui.Node {
	return tui.styled(tui.row([]tui.Node{
		tui.text(" "),
		tui.text(ref),
		tui.text(" "),
	}, allocator), tui.Style{fg = graph_lane_style(lane).fg, bg = tui.DEFAULT_COLOR, attrs = {.Reverse}}, allocator)
}

graph_commit_node :: proc(state: ^Graph_Tab, row: ^gitcore.Graph_Row, allocator: runtime.Allocator) -> tui.Node {
	commit := &state.history.commits[row.commit_index]
	children := make([dynamic]tui.Node, allocator)
	defer delete(children)
	append(&children, tui.text(" "))
	graph_lane_nodes(&children, row.cells[:])
	short_hash := commit.hash[:min(7, len(commit.hash))]
	append(&children, tui.text(short_hash, tui.Style{attrs = {.Dim}}))
	append(&children, tui.text(" "))
	for ref in commit.refs {
		append(&children, graph_ref_node(ref, row.lane, allocator))
		append(&children, tui.text(" "))
	}
	append(&children, tui.priority(tui.truncate(tui.text(commit.subject), 0), 0, allocator))
	append(&children, tui.spacer())
	append(&children, tui.text(commit.author, tui.Style{attrs = {.Dim}}))
	append(&children, tui.transparent(2))
	return tui.row(children[:], allocator)
}

graph_connector_node :: proc(row: ^gitcore.Graph_Row, allocator: runtime.Allocator) -> tui.Node {
	children := make([dynamic]tui.Node, allocator)
	defer delete(children)
	append(&children, tui.text(" "))
	graph_lane_nodes(&children, row.cells[:])
	return tui.row(children[:], allocator)
}

graph_rows_proc :: proc(data: rawptr, allocator: runtime.Allocator) -> [dynamic]Row {
	state := (^Graph_Tab)(data)
	rows := make([dynamic]Row, allocator)
	if state.message != "" {
		id := strings.clone(state.message, allocator)
		append(&rows, Row{id = id, path = id, height = 1, node = tui.text(state.message)})
		return rows
	}
	if len(state.history.commits) == 0 {
		id := strings.clone("No commits", allocator)
		append(&rows, Row{id = id, path = id, height = 1, node = tui.text(" No commits")})
		return rows
	}
	for &graph_row, index in state.graph.rows {
		if graph_row.connector {
			id := fmt.aprintf("connector:%d", index, allocator = allocator)
			append(&rows, Row{
				id = id,
				path = id,
				height = 1,
				node = graph_connector_node(&graph_row, allocator),
			})
			continue
		}
		commit := &state.history.commits[graph_row.commit_index]
		id := strings.clone(commit.hash, allocator)
		append(&rows, Row{
			id = id,
			path = id,
			selectable = true,
			height = 1,
			kind = .Graph_Commit,
			entry_index = graph_row.commit_index,
			node = graph_commit_node(state, &graph_row, allocator),
		})
	}
	return rows
}

graph_key_proc :: proc(data: rawptr, key: tui.Key, selected: ^Row) -> Tab_Result {
	state := (^Graph_Tab)(data)
	if key.code != .Rune do return {}
	switch key.rune {
	case 'q': return Tab_Result{quit = true}
	case 'r':
		graph_refresh(state)
		return Tab_Result{rows_changed = true, message = "graph refreshed"}
	}
	return {}
}

graph_select_proc :: proc(data: rawptr, selected: ^Row) -> Tab_Result {
	if selected == nil || selected.kind != .Graph_Commit do return {}
	return Tab_Result{message = selected.path}
}

graph_focus_proc :: proc(data: rawptr) -> Tab_Result {
	graph_refresh((^Graph_Tab)(data))
	return Tab_Result{rows_changed = true}
}

graph_destroy_proc :: proc(data: rawptr) {
	state := (^Graph_Tab)(data)
	allocator := state.allocator
	graph_clear(state)
	delete(state.root)
	free(state, allocator)
}

graph_tab :: proc(root: string, allocator := context.allocator) -> Tab {
	state := graph_new(root, allocator)
	return Tab{
		name = "graph",
		title = "Graph",
		icon = "⑂",
		data = state,
		rows = graph_rows_proc,
		on_key = graph_key_proc,
		on_select = graph_select_proc,
		destroy = graph_destroy_proc,
		on_focus = graph_focus_proc,
	}
}

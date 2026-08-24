package tabs

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:time"
import gitcore "../git"
import tui "../tui"

Graph_Tab :: struct {
	root:      string,
	repo:      gitcore.Git_Repo,
	history:   gitcore.History,
	graph:     gitcore.Graph,
	message:   string,
	has_repo:  bool,
	allocator: runtime.Allocator,
}

graph_clear :: proc(state: ^Graph_Tab) {
	gitcore.graph_destroy(&state.graph)
	gitcore.history_destroy(&state.history)
	gitcore.repo_destroy(&state.repo)
	delete(state.message)
	state.message = ""
	state.has_repo = false
}

graph_refresh :: proc(state: ^Graph_Tab) {
	graph_clear(state)
	// git's stderr is diagnostic text for a developer, not UI copy: it leaks absolute
	// paths and internal advice ("detected dubious ownership in repository at ...")
	// straight into the pane. Report a fixed message and drop the raw output.
	repo, message, ok := gitcore.discover(state.root, state.allocator)
	delete(message)
	if !ok {
		state.message = strings.clone(" Not a git repository", state.allocator)
		return
	}
	state.repo = repo
	state.has_repo = true
	history, history_message, history_ok := gitcore.repo_history(&state.repo, state.allocator)
	delete(history_message)
	if !history_ok {
		state.message = strings.clone(" Could not read commit history", state.allocator)
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
	// Lane colours cycle through the ANSI 16 so a themed palette drives them, the same
	// way every other colour in trek is an index rather than a baked hex.
	styles := [?]tui.Style{
		{fg = tui.indexed_color(2), bg = tui.DEFAULT_COLOR},
		{fg = tui.indexed_color(4), bg = tui.DEFAULT_COLOR},
		{fg = tui.indexed_color(3), bg = tui.DEFAULT_COLOR},
		{fg = tui.indexed_color(5), bg = tui.DEFAULT_COLOR},
		{fg = tui.indexed_color(6), bg = tui.DEFAULT_COLOR},
		{fg = tui.indexed_color(1), bg = tui.DEFAULT_COLOR},
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
		append(children, tui.priority(tui.text(graph_cell_text(cell), graph_lane_style(lane)), 100))
		append(children, tui.priority(tui.text(" "), 100))
	}
}

graph_ref_node :: proc(ref: string, lane: int, allocator: runtime.Allocator) -> tui.Node {
	label := ref
	if strings.has_prefix(label, "HEAD -> ") do label = label[len("HEAD -> "):]
	color := graph_lane_style(lane).fg
	if strings.has_prefix(label, "tag: ") do color = tui.STATUS_MODIFIED
	if strings.contains(label, "origin/") do color = tui.indexed_color(4)
	return tui.styled(tui.row([]tui.Node{
		tui.text(" "),
		tui.text(label),
		tui.text(" "),
	}, allocator), tui.Style{fg = tui.BG, bg = color, attrs = {.Bold}}, allocator)
}

graph_relative_time :: proc(timestamp: i64, allocator: runtime.Allocator) -> string {
	delta := max(time.to_unix_seconds(time.now()) - timestamp, 0)
	if delta < 60 do return strings.clone("now", allocator)
	if delta < 60 * 60 do return fmt.aprintf("%dm", delta / 60, allocator = allocator)
	if delta < 24 * 60 * 60 do return fmt.aprintf("%dh", delta / (60 * 60), allocator = allocator)
	if delta < 30 * 24 * 60 * 60 do return fmt.aprintf("%dd", delta / (24 * 60 * 60), allocator = allocator)
	if delta < 365 * 24 * 60 * 60 do return fmt.aprintf("%dmo", delta / (30 * 24 * 60 * 60), allocator = allocator)
	return fmt.aprintf("%dy", delta / (365 * 24 * 60 * 60), allocator = allocator)
}

graph_owned_text :: proc(value: string, style := tui.PLAIN_STYLE) -> tui.Node {
	return tui.owned_text(value, style)
}

graph_commit_node :: proc(state: ^Graph_Tab, row: ^gitcore.Graph_Row, allocator: runtime.Allocator) -> tui.Node {
	commit := &state.history.commits[row.commit_index]
	children := make([dynamic]tui.Node, allocator)
	defer delete(children)
	append(&children, tui.priority(tui.transparent(1), 100))
	graph_lane_nodes(&children, row.cells[:])
	short_hash := commit.hash[:min(7, len(commit.hash))]
	append(&children, tui.priority(tui.truncate(tui.text(commit.subject), 0), 20, allocator))
	for ref in commit.refs {
		append(&children, tui.priority(tui.text(" "), 60))
		append(&children, tui.priority(graph_ref_node(ref, row.lane, allocator), 60, allocator))
	}
	append(&children, tui.spacer())
	relative := graph_relative_time(commit.timestamp, allocator)
	metadata := fmt.aprintf("  %s · %s · %s", short_hash, commit.author, relative, allocator = allocator)
	delete(relative)
	append(&children, tui.priority(tui.truncate(graph_owned_text(metadata, tui.Style{attrs = {.Dim}}), 0), 0, allocator))
	append(&children, tui.priority(tui.transparent(1), 100))
	return tui.row(children[:], allocator)
}

graph_connector_node :: proc(row: ^gitcore.Graph_Row, allocator: runtime.Allocator) -> tui.Node {
	children := make([dynamic]tui.Node, allocator)
	defer delete(children)
	append(&children, tui.priority(tui.transparent(1), 100))
	graph_lane_nodes(&children, row.cells[:])
	return tui.row(children[:], allocator)
}

graph_rows_proc :: proc(data: rawptr, allocator: runtime.Allocator) -> [dynamic]Row {
	state := (^Graph_Tab)(data)
	rows := make([dynamic]Row, allocator)
	if state.message != "" {
		id := strings.clone(state.message, allocator)
		append(&rows, Row{id = id, path = strings.clone(id, allocator), height = 1, node = tui.owned_text(strings.clone(state.message, allocator), tui.Style{fg = tui.RAMP_FAINT, attrs = {.Dim}})})
		return rows
	}
	if len(state.history.commits) == 0 {
		id := strings.clone("No commits", allocator)
		append(&rows, Row{id = id, path = strings.clone(id, allocator), height = 1, node = tui.text(" No commits")})
		return rows
	}
	for &graph_row, index in state.graph.rows {
		if graph_row.connector {
			id := fmt.aprintf("connector:%d", index, allocator = allocator)
			append(&rows, Row{
				id = id,
				path = strings.clone(id, allocator),
				height = 1,
				node = graph_connector_node(&graph_row, allocator),
			})
			continue
		}
		commit := &state.history.commits[graph_row.commit_index]
		id := strings.clone(commit.hash, allocator)
		append(&rows, Row{
			id = id,
			path = strings.clone(id, allocator),
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

graph_root_proc :: proc(data: rawptr, root: string) -> Tab_Result {
	state := (^Graph_Tab)(data)
	delete(state.root)
	state.root = strings.clone(root, state.allocator)
	graph_refresh(state)
	return Tab_Result{rows_changed = true}
}

graph_heading_proc :: proc(data: rawptr) -> Tab_Heading {
	state := (^Graph_Tab)(data)
	return Tab_Heading{title = "Git Graph", detail = filepath.base(state.root)}
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
		on_root = graph_root_proc,
		heading = graph_heading_proc,
		visible = graph_visible_proc,
	}
}

// The graph is meaningless outside a repository, so it leaves the activity bar
// entirely rather than showing an empty pane with an explanation in it.
graph_visible_proc :: proc(data: rawptr) -> bool {
	return (^Graph_Tab)(data).has_repo
}

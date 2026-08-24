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
// git's own `%ar`, reproduced from date.c's show_date_relative so the age column
// agrees with `git tree` exactly. The thresholds are deliberately odd — 90 seconds,
// 90 minutes, 36 hours, 14 days, then weeks — and each step rounds rather than
// truncating, which is why "79 minutes ago" is not "1 hour ago".
graph_relative_time :: proc(timestamp: i64, allocator: runtime.Allocator) -> string {
	unit :: proc(count: i64, name: string, allocator: runtime.Allocator) -> string {
		if count == 1 do return fmt.aprintf("1 %s ago", name, allocator = allocator)
		return fmt.aprintf("%d %ss ago", count, name, allocator = allocator)
	}
	diff := max(time.to_unix_seconds(time.now()) - timestamp, 0)
	if diff < 90 do return unit(diff, "second", allocator)
	diff = (diff + 30) / 60
	if diff < 90 do return unit(diff, "minute", allocator)
	diff = (diff + 30) / 60
	if diff < 36 do return unit(diff, "hour", allocator)
	diff = (diff + 12) / 24
	if diff < 14 do return unit(diff, "day", allocator)
	if diff < 70 do return unit((diff + 3) / 7, "week", allocator)
	if diff < 365 do return unit((diff + 15) / 30, "month", allocator)
	if diff < 1825 {
		total_months := (diff * 12 * 2 + 365) / (365 * 2)
		years := total_months / 12
		months := total_months %% 12
		if months == 0 do return unit(years, "year", allocator)
		year_text := unit(years, "year", allocator)
		defer delete(year_text, allocator)
		// git prints "2 years, 3 months ago", so the leading half drops its "ago".
		head := year_text[:len(year_text) - len(" ago")]
		if months == 1 do return fmt.aprintf("%s, 1 month ago", head, allocator = allocator)
		return fmt.aprintf("%s, %d months ago", head, months, allocator = allocator)
	}
	return unit((diff + 183) / 365, "year", allocator)
}

graph_owned_text :: proc(value: string, style := tui.PLAIN_STYLE) -> tui.Node {
	return tui.owned_text(value, style)
}

// `git tree`'s colours, as palette indices so a theme still drives them.
GRAPH_HASH :: tui.Color{kind = .Indexed, index = 5}
GRAPH_DATE :: tui.RAMP_TEXT
GRAPH_AGE :: tui.RAMP_FAINT
GRAPH_AUTHOR :: tui.RAMP_MUTED
GRAPH_SUBJECT :: tui.RAMP_BRIGHT

// Ref colouring follows git's `%C(auto)`: HEAD cyan, remotes red, tags yellow,
// local branches green.
graph_ref_style :: proc(ref: string) -> tui.Style {
	if strings.has_prefix(ref, "HEAD") do return tui.Style{fg = tui.indexed_color(6), attrs = {.Bold}}
	if strings.has_prefix(ref, "tag: ") do return tui.Style{fg = tui.indexed_color(3), attrs = {.Bold}}
	if strings.contains(ref, "/") do return tui.Style{fg = tui.indexed_color(1), attrs = {.Bold}}
	return tui.Style{fg = tui.indexed_color(2), attrs = {.Bold}}
}

// One commit, laid out the way `git tree` lays it out. `%w(80,0,0)` reflows the
// whole entry as a single paragraph, so hash, date, age, author, refs and subject
// run together and break wherever the width falls — which is why a ref can end a
// line and its branch begin the next. The lane glyphs repeat down every wrapped
// row, and a blank line closes the entry.
graph_commit_node :: proc(state: ^Graph_Tab, row: ^gitcore.Graph_Row, width: int, allocator: runtime.Allocator) -> tui.Node {
	commit := &state.history.commits[row.commit_index]
	segments := graph_entry_text(state, row, context.temp_allocator)

	lane_width := len(row.cells) * 2 + 1
	wrapped := tui.wrap_words(segments, max(width - lane_width - 1, 8), context.temp_allocator)

	rows := make([dynamic]tui.Node, allocator)
	defer delete(rows)
	for line, index in wrapped {
		children := make([dynamic]tui.Node, allocator)
		defer delete(children)
		append(&children, tui.priority(tui.transparent(1), 100, allocator))
		if index == 0 {
			graph_lane_nodes(&children, row.cells[:])
		} else {
			graph_continuation_nodes(&children, row.cells[:], row.lane)
		}
		append(&children, tui.owned_text(strings.clone(line, allocator), graph_entry_style(index)))
		append(&children, tui.spacer())
		append(&rows, tui.row(children[:], allocator))
	}
	gap := make([dynamic]tui.Node, allocator)
	defer delete(gap)
	append(&gap, tui.priority(tui.transparent(1), 100, allocator))
	graph_continuation_nodes(&gap, row.cells[:], row.lane)
	append(&gap, tui.spacer())
	append(&rows, tui.row(gap[:], allocator))
	return tui.column(rows[:], allocator)
}

// The first wrapped line carries the identity; the rest are the message flowing on.
graph_entry_style :: proc(index: int) -> tui.Style {
	if index == 0 do return tui.Style{fg = GRAPH_DATE}
	return tui.Style{fg = GRAPH_SUBJECT, attrs = {.Bold}}
}

// The whole entry as one flowable string, in git tree's field order.
graph_entry_text :: proc(state: ^Graph_Tab, row: ^gitcore.Graph_Row, allocator: runtime.Allocator) -> string {
	commit := &state.history.commits[row.commit_index]
	short_hash := commit.hash[:min(7, len(commit.hash))]
	relative := graph_relative_time(commit.timestamp, context.temp_allocator)
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, short_hash)
	if commit.date != "" {
		strings.write_string(&builder, " ")
		strings.write_string(&builder, commit.date)
	}
	strings.write_string(&builder, " (")
	strings.write_string(&builder, relative)
	strings.write_string(&builder, ") ")
	strings.write_string(&builder, commit.author)
	for ref in commit.refs {
		strings.write_string(&builder, " ")
		strings.write_string(&builder, ref)
	}
	strings.write_string(&builder, " ")
	strings.write_string(&builder, commit.subject)
	return strings.clone(strings.to_string(builder), allocator)
}

// How many terminal rows this entry needs, so the Row height matches what is drawn.
graph_commit_height :: proc(state: ^Graph_Tab, row: ^gitcore.Graph_Row, width: int) -> int {
	segments := graph_entry_text(state, row, context.temp_allocator)
	lane_width := len(row.cells) * 2 + 1
	wrapped := tui.wrap_words(segments, max(width - lane_width - 1, 8), context.temp_allocator)
	return len(wrapped) + 1
}

// The lane row drawn under a commit: the commit's own marker becomes a vertical,
// everything else stays as it was.
graph_continuation_nodes :: proc(children: ^[dynamic]tui.Node, cells: []rune, lane: int) {
	for cell, index in cells {
		glyph := cell
		if index == lane && cell == '●' do glyph = '│'
		append(children, tui.priority(tui.text(graph_cell_text(glyph), graph_lane_style(index)), 100))
		append(children, tui.priority(tui.text(" "), 100))
	}
}

graph_connector_node :: proc(row: ^gitcore.Graph_Row, allocator: runtime.Allocator) -> tui.Node {
	children := make([dynamic]tui.Node, allocator)
	defer delete(children)
	append(&children, tui.priority(tui.transparent(1), 100))
	graph_lane_nodes(&children, row.cells[:])
	return tui.row(children[:], allocator)
}

graph_rows_proc :: proc(data: rawptr, width: int, allocator: runtime.Allocator) -> [dynamic]Row {
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
			height = graph_commit_height(state, &graph_row, width),
			kind = .Graph_Commit,
			entry_index = graph_row.commit_index,
			node = graph_commit_node(state, &graph_row, width, allocator),
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

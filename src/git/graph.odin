package git

import "base:runtime"
import "core:strconv"
import "core:strings"

GRAPH_LANE_CAP :: 12

Commit :: struct {
	hash:      string,
	parents:   [dynamic]string,
	refs:      [dynamic]string,
	author:    string,
	timestamp: i64,
	subject:   string,
}

History :: struct {
	commits:   [dynamic]Commit,
	allocator: runtime.Allocator,
}

commit_destroy :: proc(commit: ^Commit) {
	delete(commit.hash)
	for parent in commit.parents do delete(parent)
	for ref in commit.refs do delete(ref)
	delete(commit.parents)
	delete(commit.refs)
	delete(commit.author)
	delete(commit.subject)
	commit^ = {}
}

history_destroy :: proc(history: ^History) {
	for &commit in history.commits do commit_destroy(&commit)
	delete(history.commits)
	history^ = {}
}

split_owned :: proc(value, separator: string, allocator: runtime.Allocator) -> [dynamic]string {
	result := make([dynamic]string, allocator)
	parts := strings.split(value, separator, allocator)
	defer delete(parts, allocator)
	for part in parts {
		clean := strings.trim_space(part)
		if clean != "" do append(&result, strings.clone(clean, allocator))
	}
	return result
}

parse_log :: proc(raw: string, allocator := context.allocator) -> History {
	history := History{commits = make([dynamic]Commit, allocator), allocator = allocator}
	offset := 0
	for offset < len(raw) {
		fields: [6]string
		complete := true
		for index in 0 ..< len(fields) {
			if offset >= len(raw) {
				complete = false
				break
			}
			fields[index], offset = nul_field(raw, offset)
		}
		if !complete do break
		hash := strings.trim_left(fields[0], "\r\n")
		if hash == "" do continue
		timestamp, _ := strconv.parse_i64(strings.trim_space(fields[4]))
		append(&history.commits, Commit{
			hash = strings.clone(hash, allocator),
			parents = split_owned(fields[1], " ", allocator),
			refs = split_owned(fields[2], ",", allocator),
			author = strings.clone(fields[3], allocator),
			timestamp = timestamp,
			subject = strings.clone(fields[5], allocator),
		})
	}
	return history
}

repo_history :: proc(repo: ^Git_Repo, allocator := context.allocator) -> (History, string, bool) {
	output := run(repo.root, []string{"log", "--all", "--parents", "--date-order", "--pretty=format:%H%x00%P%x00%D%x00%an%x00%at%x00%s%x00"}, allocator)
	defer output_destroy(&output, allocator)
	if !output_ok(&output) do return {}, output_message(&output, allocator), false
	return parse_log(string(output.stdout), allocator), "", true
}

Graph_Row :: struct {
	commit_index: int,
	lane:         int,
	cells:        [dynamic]rune,
	connector:    bool,
	overflow:     bool,
}

Graph :: struct {
	rows:      [dynamic]Graph_Row,
	max_lanes: int,
}

graph_destroy :: proc(graph: ^Graph) {
	for &row in graph.rows do delete(row.cells)
	delete(graph.rows)
	graph^ = {}
}

lane_find :: proc(lanes: []string, hash: string, skip := -1) -> int {
	for lane, index in lanes {
		if index != skip && lane == hash do return index
	}
	return -1
}

lane_allocate :: proc(lanes: ^[dynamic]string, hash: string, cap: int, overflow: ^bool) -> int {
	for lane, index in lanes {
		if lane == "" {
			lanes[index] = strings.clone(hash)
			return index
		}
	}
	if len(lanes^) < cap {
		append(lanes, strings.clone(hash))
		return len(lanes^) - 1
	}
	overflow^ = true
	return cap - 1
}

lane_set :: proc(lanes: ^[dynamic]string, index: int, hash: string) {
	delete(lanes[index])
	lanes[index] = strings.clone(hash)
}

trim_lanes :: proc(lanes: ^[dynamic]string) {
	for len(lanes^) > 0 && lanes[len(lanes^) - 1] == "" do ordered_remove(lanes, len(lanes^) - 1)
}

graph_cells :: proc(lanes: []string, commit_lane: int, overflow: bool, allocator: runtime.Allocator) -> [dynamic]rune {
	cells := make([dynamic]rune, len(lanes), allocator)
	for lane, index in lanes {
		if index == commit_lane {
			cells[index] = '●'
		} else if lane != "" {
			cells[index] = '│'
		} else {
			cells[index] = ' '
		}
	}
	if overflow && len(cells) > 0 do cells[len(cells) - 1] = '…'
	return cells
}

connector_cells :: proc(
	lanes: []string,
	width, commit_lane: int,
	parents: []int,
	collapsed, overflow: bool,
	allocator: runtime.Allocator,
) -> [dynamic]rune {
	cells := make([dynamic]rune, width, allocator)
	for index in 0 ..< width {
		if index < len(lanes) && lanes[index] != "" do cells[index] = '│'
		if cells[index] == 0 do cells[index] = ' '
	}
	if commit_lane < width {
		if len(parents) > 1 {
			cells[commit_lane] = '├'
		} else if collapsed {
			cells[commit_lane] = '╯'
		}
	}
	if len(parents) > 1 {
		for target in parents[1:] {
			if target < 0 || target >= width do continue
			if target > commit_lane {
				for index in commit_lane + 1 ..< target do cells[index] = '─'
				cells[target] = '┐'
			} else if target < commit_lane {
				for index in target + 1 ..< commit_lane do cells[index] = '─'
				cells[target] = '┌'
			}
		}
	}
	if overflow && len(cells) > 0 do cells[len(cells) - 1] = '…'
	return cells
}

assign_lanes :: proc(history: ^History, cap := GRAPH_LANE_CAP, allocator := context.allocator) -> Graph {
	graph := Graph{rows = make([dynamic]Graph_Row, allocator)}
	lanes := make([dynamic]string, allocator)
	defer {
		for lane in lanes do delete(lane)
		delete(lanes)
	}
	for &commit, commit_index in history.commits {
		overflow := false
		lane := lane_find(lanes[:], commit.hash)
		if lane < 0 do lane = lane_allocate(&lanes, commit.hash, cap, &overflow)
		graph.max_lanes = max(graph.max_lanes, len(lanes))
		append(&graph.rows, Graph_Row{
			commit_index = commit_index,
			lane = lane,
			cells = graph_cells(lanes[:], lane, overflow, allocator),
			overflow = overflow,
		})
		old_width := len(lanes)
		parent_lanes := make([dynamic]int, allocator)
		if len(commit.parents) == 0 {
			lane_set(&lanes, lane, "")
		} else {
			first := commit.parents[0]
			existing := lane_find(lanes[:], first, lane)
			if existing >= 0 {
				lane_set(&lanes, lane, "")
				append(&parent_lanes, existing)
			} else {
				lane_set(&lanes, lane, first)
				append(&parent_lanes, lane)
			}
			if len(commit.parents) > 1 {
				for parent in commit.parents[1:] {
					target := lane_find(lanes[:], parent)
					if target < 0 do target = lane_allocate(&lanes, parent, cap, &overflow)
					append(&parent_lanes, target)
				}
			}
		}
		trim_lanes(&lanes)
		graph.max_lanes = max(graph.max_lanes, len(lanes))
		collapsed := len(lanes) < old_width || (len(parent_lanes) > 0 && parent_lanes[0] != lane)
		if len(parent_lanes) > 1 || collapsed {
			width := max(old_width, len(lanes))
			append(&graph.rows, Graph_Row{
				commit_index = -1,
				lane = lane,
				cells = connector_cells(lanes[:], width, lane, parent_lanes[:], collapsed, overflow, allocator),
				connector = true,
				overflow = overflow,
			})
		}
		delete(parent_lanes)
	}
	return graph
}

package git

import "base:runtime"

// A port of git's own graph.c (v2.53.0 -- the version this machine runs), because the
// lanes ARE git's algorithm and an approximation of them is just a different picture.
// Nothing here is invented: the state machine, the mapping array and the collapse rules
// follow the C line for line, so `git log --graph` and this tab draw the same commits the
// same way. master's newer visual-root indentation is deliberately NOT ported -- it would
// disagree with the installed git.

GRAPH_COLORS :: 12

Graph_State :: enum {
	Padding,
	Skip,
	Pre_Commit,
	Commit,
	Post_Merge,
	Collapsing,
}

Graph_Column :: struct {
	commit: int,
	color:  int,
}

// A drawn character and the lane colour it belongs to. NO_COLOR is padding, which git
// leaves uncoloured.
NO_COLOR :: -1

Graph_Cell :: struct {
	glyph: rune,
	color: int,
}

Graph_Line :: [dynamic]Graph_Cell

// One commit's worth of graph output. git emits a commit as: expansion rows, the row
// carrying the commit itself, then post-merge and collapsing rows that the message's
// later lines are printed against -- and `pad` once those run out.
Graph_Entry :: struct {
	commit_index: int,
	pre:          [dynamic]Graph_Line,
	line:         Graph_Line,
	rest:         [dynamic]Graph_Line,
	pad:          Graph_Line,
}

Graph :: struct {
	entries:   [dynamic]Graph_Entry,
	max_width: int,
	allocator: runtime.Allocator,
}

Graph_Engine :: struct {
	commit:               int,
	parents:              []int,
	num_parents:          int,
	width:                int,
	expansion_row:        int,
	state:                Graph_State,
	prev_state:           Graph_State,
	commit_index:         int,
	prev_commit_index:    int,
	merge_layout:         int,
	edges_added:          int,
	prev_edges_added:     int,
	column_capacity:      int,
	num_columns:          int,
	num_new_columns:      int,
	mapping_size:         int,
	columns:              []Graph_Column,
	new_columns:          []Graph_Column,
	mapping:              []int,
	old_mapping:          []int,
	default_column_color: int,
	allocator:            runtime.Allocator,
}

NO_COMMIT :: -1

engine_init :: proc(engine: ^Graph_Engine, allocator := context.allocator) {
	engine.allocator = allocator
	engine.state = .Padding
	engine.prev_state = .Padding
	engine.commit = NO_COMMIT
	// Start at the top of the cycle: the first commit always increments first.
	engine.default_column_color = GRAPH_COLORS - 1
	engine.column_capacity = 30
	engine.columns = make([]Graph_Column, engine.column_capacity, allocator)
	engine.new_columns = make([]Graph_Column, engine.column_capacity, allocator)
	engine.mapping = make([]int, 2 * engine.column_capacity, allocator)
	engine.old_mapping = make([]int, 2 * engine.column_capacity, allocator)
}

engine_destroy :: proc(engine: ^Graph_Engine) {
	delete(engine.columns, engine.allocator)
	delete(engine.new_columns, engine.allocator)
	delete(engine.mapping, engine.allocator)
	delete(engine.old_mapping, engine.allocator)
	engine^ = {}
}

engine_ensure_capacity :: proc(engine: ^Graph_Engine, num_columns: int) {
	if engine.column_capacity >= num_columns do return
	for engine.column_capacity < num_columns do engine.column_capacity *= 2
	grow_columns :: proc(old: []Graph_Column, size: int, allocator: runtime.Allocator) -> []Graph_Column {
		fresh := make([]Graph_Column, size, allocator)
		copy(fresh, old)
		delete(old, allocator)
		return fresh
	}
	grow_ints :: proc(old: []int, size: int, allocator: runtime.Allocator) -> []int {
		fresh := make([]int, size, allocator)
		copy(fresh, old)
		delete(old, allocator)
		return fresh
	}
	engine.columns = grow_columns(engine.columns, engine.column_capacity, engine.allocator)
	engine.new_columns = grow_columns(engine.new_columns, engine.column_capacity, engine.allocator)
	engine.mapping = grow_ints(engine.mapping, 2 * engine.column_capacity, engine.allocator)
	engine.old_mapping = grow_ints(engine.old_mapping, 2 * engine.column_capacity, engine.allocator)
}

line_addch :: proc(line: ^Graph_Line, glyph: rune, color := NO_COLOR) {
	append(line, Graph_Cell{glyph = glyph, color = color})
}

line_addchars :: proc(line: ^Graph_Line, glyph: rune, count: int, color := NO_COLOR) {
	for _ in 0 ..< count do line_addch(line, glyph, color)
}

line_write_column :: proc(line: ^Graph_Line, column: Graph_Column, glyph: rune) {
	line_addch(line, glyph, column.color)
}

engine_update_state :: proc(engine: ^Graph_Engine, state: Graph_State) {
	engine.prev_state = engine.state
	engine.state = state
}

engine_increment_column_color :: proc(engine: ^Graph_Engine) {
	engine.default_column_color = (engine.default_column_color + 1) % GRAPH_COLORS
}

engine_find_commit_color :: proc(engine: ^Graph_Engine, commit: int) -> int {
	for index in 0 ..< engine.num_columns {
		if engine.columns[index].commit == commit do return engine.columns[index].color
	}
	return engine.default_column_color
}

engine_find_new_column_by_commit :: proc(engine: ^Graph_Engine, commit: int) -> int {
	for index in 0 ..< engine.num_new_columns {
		if engine.new_columns[index].commit == commit do return index
	}
	return -1
}

engine_insert_into_new_columns :: proc(engine: ^Graph_Engine, commit: int, idx: int) {
	i := engine_find_new_column_by_commit(engine, commit)
	mapping_idx: int

	if i < 0 {
		i = engine.num_new_columns
		engine.num_new_columns += 1
		engine.new_columns[i] = Graph_Column {
			commit = commit,
			color  = engine_find_commit_color(engine, commit),
		}
	}

	if engine.num_parents > 1 && idx > -1 && engine.merge_layout == -1 {
		// The first parent of a merge picks the layout: whether the parent sits in a
		// column left of the merge decides which way the merge lines lean.
		dist := idx - i
		shift := dist > 1 ? 2 * dist - 3 : 1
		engine.merge_layout = dist > 0 ? 0 : 1
		engine.edges_added = engine.num_parents + engine.merge_layout - 2
		mapping_idx = engine.width + (engine.merge_layout - 1) * shift
		engine.width += 2 * engine.merge_layout
	} else if engine.edges_added > 0 && engine.width >= 2 && i == engine.mapping[engine.width - 2] {
		// A merge added columns but this commit was found in the last existing one, so
		// the two edges join immediately instead of running parallel for a row.
		mapping_idx = engine.width - 2
		engine.edges_added = -1
	} else {
		mapping_idx = engine.width
		engine.width += 2
	}

	engine.mapping[mapping_idx] = i
}

engine_update_columns :: proc(engine: ^Graph_Engine) {
	engine.columns, engine.new_columns = engine.new_columns, engine.columns
	engine.num_columns = engine.num_new_columns
	engine.num_new_columns = 0

	max_new_columns := engine.num_columns + engine.num_parents
	engine_ensure_capacity(engine, max_new_columns)

	engine.mapping_size = 2 * max_new_columns
	for index in 0 ..< engine.mapping_size do engine.mapping[index] = -1

	engine.width = 0
	engine.prev_edges_added = engine.edges_added
	engine.edges_added = 0

	seen_this := false
	is_commit_in_columns := true
	for i := 0; i <= engine.num_columns; i += 1 {
		col_commit: int
		if i == engine.num_columns {
			if seen_this do break
			is_commit_in_columns = false
			col_commit = engine.commit
		} else {
			col_commit = engine.columns[i].commit
		}

		if col_commit == engine.commit {
			seen_this = true
			engine.commit_index = i
			engine.merge_layout = -1
			for parent in engine.parents {
				if engine.num_parents > 1 || !is_commit_in_columns {
					engine_increment_column_color(engine)
				}
				engine_insert_into_new_columns(engine, parent, i)
			}
			// A commit always occupies two spaces even with nothing below it.
			if engine.num_parents == 0 do engine.width += 2
		} else {
			engine_insert_into_new_columns(engine, col_commit, -1)
		}
	}

	for engine.mapping_size > 1 && engine.mapping[engine.mapping_size - 1] < 0 {
		engine.mapping_size -= 1
	}
}

engine_num_dashed_parents :: proc(engine: ^Graph_Engine) -> int {
	return engine.num_parents + engine.merge_layout - 3
}

engine_num_expansion_rows :: proc(engine: ^Graph_Engine) -> int {
	return engine_num_dashed_parents(engine) * 2
}

engine_needs_pre_commit_line :: proc(engine: ^Graph_Engine) -> bool {
	return(
		engine.num_parents >= 3 &&
		engine.commit_index < engine.num_columns - 1 &&
		engine.expansion_row < engine_num_expansion_rows(engine) \
	)
}

engine_update :: proc(engine: ^Graph_Engine, commit: int, parents: []int) {
	engine.commit = commit
	engine.parents = parents
	engine.num_parents = len(parents)
	engine.prev_commit_index = engine.commit_index
	engine_update_columns(engine)
	engine.expansion_row = 0

	// prev_state is deliberately left alone: no line for this state was ever printed.
	if engine.state != .Padding {
		engine.state = .Skip
	} else if engine_needs_pre_commit_line(engine) {
		engine.state = .Pre_Commit
	} else {
		engine.state = .Commit
	}
}

engine_is_mapping_correct :: proc(engine: ^Graph_Engine) -> bool {
	for index in 0 ..< engine.mapping_size {
		target := engine.mapping[index]
		if target < 0 do continue
		if target == index / 2 do continue
		return false
	}
	return true
}

engine_pad_horizontally :: proc(engine: ^Graph_Engine, line: ^Graph_Line) {
	// Every row of a commit is padded to the same width so the text beside the graph
	// stays aligned down the whole column.
	if len(line) < engine.width do line_addchars(line, ' ', engine.width - len(line))
}

engine_output_padding_line :: proc(engine: ^Graph_Engine, line: ^Graph_Line) {
	for index in 0 ..< engine.num_new_columns {
		line_write_column(line, engine.new_columns[index], '|')
		line_addch(line, ' ')
	}
}

engine_output_skip_line :: proc(engine: ^Graph_Engine, line: ^Graph_Line) {
	line_addch(line, '.')
	line_addch(line, '.')
	line_addch(line, '.')
	if engine_needs_pre_commit_line(engine) {
		engine_update_state(engine, .Pre_Commit)
	} else {
		engine_update_state(engine, .Commit)
	}
}

engine_output_pre_commit_line :: proc(engine: ^Graph_Engine, line: ^Graph_Line) {
	seen_this := false
	for i in 0 ..< engine.num_columns {
		col := engine.columns[i]
		if col.commit == engine.commit {
			seen_this = true
			line_write_column(line, col, '|')
			line_addchars(line, ' ', engine.expansion_row)
		} else if seen_this && engine.expansion_row == 0 {
			// Carry on a '\' from the previous commit's post-merge row rather than
			// snapping back to '|' for one row.
			if engine.prev_state == .Post_Merge && engine.prev_commit_index < i {
				line_write_column(line, col, '\\')
			} else {
				line_write_column(line, col, '|')
			}
		} else if seen_this && engine.expansion_row > 0 {
			line_write_column(line, col, '\\')
		} else {
			line_write_column(line, col, '|')
		}
		line_addch(line, ' ')
	}

	engine.expansion_row += 1
	if !engine_needs_pre_commit_line(engine) do engine_update_state(engine, .Commit)
}

engine_draw_octopus_merge :: proc(engine: ^Graph_Engine, line: ^Graph_Line) {
	dashed := engine_num_dashed_parents(engine)
	for i in 0 ..< dashed {
		// Parents can be reordered as they map onto columns, so each dash takes its
		// colour from the mapping rather than from the parent order.
		j := engine.mapping[(engine.commit_index + i + 2) * 2]
		col := engine.new_columns[j]
		line_write_column(line, col, '-')
		line_write_column(line, col, i == dashed - 1 ? '.' : '-')
	}
}

engine_output_commit_line :: proc(engine: ^Graph_Engine, line: ^Graph_Line) {
	seen_this := false
	for i := 0; i <= engine.num_columns; i += 1 {
		col_commit: int
		col: Graph_Column
		if i == engine.num_columns {
			if seen_this do break
			col_commit = engine.commit
		} else {
			col = engine.columns[i]
			col_commit = col.commit
		}

		if col_commit == engine.commit {
			seen_this = true
			line_addch(line, '*', engine_find_commit_color(engine, engine.commit))
			if engine.num_parents > 2 do engine_draw_octopus_merge(engine, line)
		} else if seen_this && engine.edges_added > 1 {
			line_write_column(line, col, '\\')
		} else if seen_this && engine.edges_added == 1 {
			if engine.prev_state == .Post_Merge &&
			   engine.prev_edges_added > 0 &&
			   engine.prev_commit_index < i {
				line_write_column(line, col, '\\')
			} else {
				line_write_column(line, col, '|')
			}
		} else if engine.prev_state == .Collapsing &&
		   engine.old_mapping[2 * i + 1] == i &&
		   engine.mapping[2 * i] < i {
			line_write_column(line, col, '/')
		} else {
			line_write_column(line, col, '|')
		}
		line_addch(line, ' ')
	}

	if engine.num_parents > 1 {
		engine_update_state(engine, .Post_Merge)
	} else if engine_is_mapping_correct(engine) {
		engine_update_state(engine, .Padding)
	} else {
		engine_update_state(engine, .Collapsing)
	}
}

MERGE_CHARS := [3]rune{'/', '|', '\\'}

engine_output_post_merge_line :: proc(engine: ^Graph_Engine, line: ^Graph_Line) {
	seen_this := false
	first_parent := len(engine.parents) > 0 ? engine.parents[0] : NO_COMMIT
	parent_col: Graph_Column
	has_parent_col := false

	for i := 0; i <= engine.num_columns; i += 1 {
		col_commit: int
		col: Graph_Column
		if i == engine.num_columns {
			if seen_this do break
			col_commit = engine.commit
		} else {
			col = engine.columns[i]
			col_commit = col.commit
		}

		if col_commit == engine.commit {
			seen_this = true
			idx := engine.merge_layout
			for j in 0 ..< engine.num_parents {
				par_column := engine_find_new_column_by_commit(engine, engine.parents[j])
				if par_column < 0 do continue
				line_write_column(line, engine.new_columns[par_column], MERGE_CHARS[idx])
				if idx == 2 {
					if engine.edges_added > 0 || j < engine.num_parents - 1 {
						line_addch(line, ' ')
					}
				} else {
					idx += 1
				}
			}
			if engine.edges_added == 0 do line_addch(line, ' ')
		} else if seen_this {
			if engine.edges_added > 0 {
				line_write_column(line, col, '\\')
			} else {
				line_write_column(line, col, '|')
			}
			line_addch(line, ' ')
		} else {
			line_write_column(line, col, '|')
			if engine.merge_layout != 0 || i != engine.commit_index - 1 {
				if has_parent_col {
					line_write_column(line, parent_col, '_')
				} else {
					line_addch(line, ' ')
				}
			}
		}

		if col_commit == first_parent {
			parent_col = col
			has_parent_col = true
		}
	}

	if engine_is_mapping_correct(engine) {
		engine_update_state(engine, .Padding)
	} else {
		engine_update_state(engine, .Collapsing)
	}
}

engine_output_collapsing_line :: proc(engine: ^Graph_Engine, line: ^Graph_Line) {
	used_horizontal := false
	horizontal_edge := -1
	horizontal_edge_target := -1

	engine.mapping, engine.old_mapping = engine.old_mapping, engine.mapping
	for index in 0 ..< engine.mapping_size do engine.mapping[index] = -1

	for i in 0 ..< engine.mapping_size {
		target := engine.old_mapping[i]
		if target < 0 do continue

		// update_columns inserts the leftmost column first, so a branch never has to
		// move right. Only one of two crossing branches changes direction, which is
		// what keeps the picture readable.
		if target * 2 == i {
			engine.mapping[i] = target
		} else if i > 0 && engine.mapping[i - 1] < 0 {
			engine.mapping[i - 1] = target
			if horizontal_edge == -1 {
				horizontal_edge = i
				horizontal_edge_target = target
				for j := target * 2 + 3; j < i - 2; j += 2 do engine.mapping[j] = target
			}
		} else if i > 0 && engine.mapping[i - 1] == target {
			// A branch to our left is already heading for our target, so it has
			// drawn this for us.
		} else if i > 1 {
			engine.mapping[i - 2] = target
			if horizontal_edge == -1 {
				horizontal_edge_target = target
				horizontal_edge = i - 1
				for j := target * 2 + 3; j < i - 2; j += 2 do engine.mapping[j] = target
			}
		}
	}

	copy(engine.old_mapping[:engine.mapping_size], engine.mapping[:engine.mapping_size])
	if engine.mapping_size > 0 && engine.mapping[engine.mapping_size - 1] < 0 {
		engine.mapping_size -= 1
	}

	for i in 0 ..< engine.mapping_size {
		target := engine.mapping[i]
		if target < 0 {
			line_addch(line, ' ')
		} else if target * 2 == i {
			line_write_column(line, engine.new_columns[target], '|')
		} else if target == horizontal_edge_target && i != horizontal_edge - 1 {
			// Everything but the first segment stops here, so the horizontal run
			// does not continue onto the next row.
			if i != target * 2 + 3 do engine.mapping[i] = -1
			used_horizontal = true
			line_write_column(line, engine.new_columns[target], '_')
		} else {
			if used_horizontal && i < horizontal_edge do engine.mapping[i] = -1
			line_write_column(line, engine.new_columns[target], '/')
		}
	}

	if engine_is_mapping_correct(engine) do engine_update_state(engine, .Padding)
}

// Returns true when the line drawn is the one carrying the commit itself.
engine_next_line :: proc(engine: ^Graph_Engine, line: ^Graph_Line) -> bool {
	shown_commit_line := false
	switch engine.state {
	case .Padding:
		engine_output_padding_line(engine, line)
	case .Skip:
		engine_output_skip_line(engine, line)
	case .Pre_Commit:
		engine_output_pre_commit_line(engine, line)
	case .Commit:
		engine_output_commit_line(engine, line)
		shown_commit_line = true
	case .Post_Merge:
		engine_output_post_merge_line(engine, line)
	case .Collapsing:
		engine_output_collapsing_line(engine, line)
	}
	engine_pad_horizontally(engine, line)
	return shown_commit_line
}

engine_is_commit_finished :: proc(engine: ^Graph_Engine) -> bool {
	return engine.state == .Padding
}

graph_line_clone :: proc(line: ^Graph_Line, allocator: runtime.Allocator) -> Graph_Line {
	fresh := make(Graph_Line, allocator)
	append(&fresh, ..line[:])
	return fresh
}

// Walk the loaded history through the engine, keeping every row it draws.
//
// A parent outside the loaded window is not "interesting" -- git only draws lanes for
// commits it is going to show, and drawing a lane to a commit that never arrives leaves
// a line running off the bottom with nothing under it.
build_graph :: proc(history: ^History, allocator := context.allocator) -> Graph {
	graph := Graph{entries = make([dynamic]Graph_Entry, allocator), allocator = allocator}
	index_of := make(map[string]int, len(history.commits), context.temp_allocator)
	defer delete(index_of)
	for commit, index in history.commits do index_of[commit.hash] = index

	engine: Graph_Engine
	engine_init(&engine, context.temp_allocator)
	defer engine_destroy(&engine)

	parents := make([dynamic]int, context.temp_allocator)
	defer delete(parents)

	for commit, index in history.commits {
		clear(&parents)
		for parent in commit.parents {
			if target, found := index_of[parent]; found do append(&parents, target)
		}
		engine_update(&engine, index, parents[:])

		entry := Graph_Entry {
			commit_index = index,
			pre          = make([dynamic]Graph_Line, allocator),
			rest         = make([dynamic]Graph_Line, allocator),
		}
		for !engine_is_commit_finished(&engine) {
			line := make(Graph_Line, allocator)
			if engine_next_line(&engine, &line) {
				entry.line = line
				break
			}
			append(&entry.pre, line)
		}
		for !engine_is_commit_finished(&engine) {
			line := make(Graph_Line, allocator)
			engine_next_line(&engine, &line)
			append(&entry.rest, line)
		}
		// The row a long message keeps printing against once the graph has nothing
		// left to say.
		entry.pad = make(Graph_Line, allocator)
		engine_output_padding_line(&engine, &entry.pad)
		engine_pad_horizontally(&engine, &entry.pad)

		graph.max_width = max(graph.max_width, len(entry.line))
		append(&graph.entries, entry)
	}
	return graph
}

graph_entry_destroy :: proc(entry: ^Graph_Entry) {
	for &line in entry.pre do delete(line)
	for &line in entry.rest do delete(line)
	delete(entry.pre)
	delete(entry.rest)
	delete(entry.line)
	delete(entry.pad)
	entry^ = {}
}

graph_destroy :: proc(graph: ^Graph) {
	for &entry in graph.entries do graph_entry_destroy(&entry)
	delete(graph.entries)
	graph^ = {}
}

// git colours lanes by cycling the ANSI 16: six plain, then six bold. Indexed, so a
// themed palette drives them the way it drives everything else trek draws.
GRAPH_LANE_COLORS := [GRAPH_COLORS]u8{1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14}

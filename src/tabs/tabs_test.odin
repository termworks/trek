package tabs

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"
import gitcore "../git"
import model "../model"
import tui "../tui"

tabs_test_root :: proc(t: ^testing.T) -> string {
	root, err := os.make_directory_temp("", "trek-tabs-*", context.allocator)
	testing.expect(t, err == nil)
	return root
}

tabs_test_join :: proc(root, relative: string) -> string {
	path, _ := filepath.join([]string{root, relative}, context.allocator)
	return path
}

tabs_test_git :: proc(t: ^testing.T, root: string, args: []string) {
	output := gitcore.run(root, args)
	defer gitcore.output_destroy(&output)
	testing.expect(t, gitcore.output_ok(&output), string(output.stderr))
}

tabs_test_repo :: proc(t: ^testing.T) -> string {
	root := tabs_test_root(t)
	tabs_test_git(t, root, []string{"init", "-q"})
	tracked := tabs_test_join(root, "tracked.txt")
	defer delete(tracked)
	_ = os.write_entire_file_from_string(tracked, "one")
	tabs_test_git(t, root, []string{"add", "-A"})
	tabs_test_git(t, root, []string{"-c", "user.name=trek", "-c", "user.email=trek@test", "commit", "-q", "-m", "init"})
	return root
}

@(test)
test_changes_rows_have_three_sections_and_commit_box :: proc(t: ^testing.T) {
	root := tabs_test_repo(t)
	defer { _ = os.remove_all(root); delete(root) }
	tracked := tabs_test_join(root, "tracked.txt")
	new_file := tabs_test_join(root, "new.txt")
	defer delete(tracked)
	defer delete(new_file)
	_ = os.write_entire_file_from_string(tracked, "two")
	_ = os.write_entire_file_from_string(new_file, "new")
	state := changes_new(root)
	defer changes_destroy_proc(rawptr(state))
	rows := changes_rows_proc(rawptr(state), 80, context.allocator)
	defer rows_destroy(&rows)
	commit_boxes := 0
	commit_buttons := 0
	sections := 0
	entries := 0
	for row in rows {
		if row.kind == .Commit_Box {
			commit_boxes += 1
			testing.expect_value(t, row.height, 3)
		}
		if row.kind == .Commit_Button do commit_buttons += 1
		if row.kind == .Section_Header do sections += 1
		if row.kind == .Git_Entry do entries += 1
	}
	// A modified tracked file and an untracked one: NEW and MODIFIED, nothing staged.
	testing.expect_value(t, sections, 2)
	testing.expect_value(t, entries, 2)
	testing.expect_value(t, commit_boxes, 1)
	testing.expect_value(t, commit_buttons, 1)
}

@(test)
test_changes_enter_moves_entry_between_sections :: proc(t: ^testing.T) {
	root := tabs_test_repo(t)
	defer { _ = os.remove_all(root); delete(root) }
	new_file := tabs_test_join(root, "new.txt")
	defer delete(new_file)
	_ = os.write_entire_file_from_string(new_file, "new")
	state := changes_new(root)
	defer changes_destroy_proc(rawptr(state))
	testing.expect_value(t, len(state.status.staged), 0)
	row := Row{kind = .Git_Entry, path = "new.txt", staged = false}
	result := changes_select_proc(rawptr(state), &row)
	testing.expect(t, result.rows_changed)
	testing.expect_value(t, result.message, "staged")
	testing.expect_value(t, len(state.status.staged), 1)
	testing.expect_value(t, len(state.status.unstaged), 0)
	// And back again from the staged side.
	back := Row{kind = .Git_Entry, path = "new.txt", staged = true}
	result = changes_select_proc(rawptr(state), &back)
	testing.expect_value(t, result.message, "unstaged")
	testing.expect_value(t, len(state.status.staged), 0)
	testing.expect_value(t, len(state.status.unstaged), 1)
}

@(test)
test_changes_commit_button_commits_staged :: proc(t: ^testing.T) {
	root := tabs_test_repo(t)
	defer { _ = os.remove_all(root); delete(root) }
	new_file := tabs_test_join(root, "new.txt")
	defer delete(new_file)
	_ = os.write_entire_file_from_string(new_file, "new")
	state := changes_new(root)
	defer changes_destroy_proc(rawptr(state))
	message, staged := gitcore.repo_stage_all(&state.repo)
	delete(message)
	testing.expect(t, staged)
	changes_refresh(state)
	append(&state.message, "add new file")
	row := Row{kind = .Commit_Button}
	result := changes_select_proc(rawptr(state), &row)
	testing.expect(t, result.rows_changed)
	testing.expect_value(t, result.message, "committed")
	testing.expect_value(t, len(state.status.staged), 0)
	testing.expect_value(t, len(state.status.unstaged), 0)
}

@(test)
test_changes_commit_refuses_empty_message :: proc(t: ^testing.T) {
	root := tabs_test_repo(t)
	defer { _ = os.remove_all(root); delete(root) }
	new_file := tabs_test_join(root, "new.txt")
	defer delete(new_file)
	_ = os.write_entire_file_from_string(new_file, "new")
	state := changes_new(root)
	defer changes_destroy_proc(rawptr(state))
	message, staged := gitcore.repo_stage_all(&state.repo)
	delete(message)
	testing.expect(t, staged)
	changes_refresh(state)
	row := Row{kind = .Commit_Button}
	result := changes_select_proc(rawptr(state), &row)
	testing.expect(t, !result.rows_changed)
	testing.expect_value(t, result.message, "commit message is empty")
	testing.expect_value(t, len(state.status.staged), 1)
}

@(test)
test_changes_commit_box_accepts_text_and_paste :: proc(t: ^testing.T) {
	root := tabs_test_repo(t)
	defer { _ = os.remove_all(root); delete(root) }
	state := changes_new(root)
	defer changes_destroy_proc(rawptr(state))
	row := Row{kind = .Commit_Box}
	_ = changes_key_proc(rawptr(state), tui.Key{code = .Rune, rune = 'h'}, &row)
	_ = changes_paste_proc(rawptr(state), "ello", &row)
	testing.expect_value(t, string(state.message[:]), "hello")
	_ = changes_key_proc(rawptr(state), tui.Key{code = .Backspace}, &row)
	testing.expect_value(t, string(state.message[:]), "hell")
}

@(test)
test_graph_rows_render_commits_and_refs :: proc(t: ^testing.T) {
	root := tabs_test_repo(t)
	defer { _ = os.remove_all(root); delete(root) }
	state := graph_new(root)
	defer graph_destroy_proc(rawptr(state))
	rows := graph_rows_proc(rawptr(state), 80, context.allocator)
	defer rows_destroy(&rows)
	commits := 0
	for &row in rows {
		if row.kind == .Graph_Commit {
			commits += 1
			testing.expect(t, row.selectable)
			testing.expect(t, row.path != "")
		}
	}
	testing.expect_value(t, commits, 1)
}

@(test)
test_explorer_row_matches_reference_anatomy :: proc(t: ^testing.T) {
	root := tabs_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	dir := tabs_test_join(root, "src")
	defer delete(dir)
	_ = os.make_directory(dir)
	state := tree_tab_new(root)
	defer tree_destroy_proc(rawptr(state))
	rows := tree_rows_proc(rawptr(state), 80, context.allocator)
	defer rows_destroy(&rows)
	testing.expect(t, len(rows) == 1)
	buffer: tui.Buffer
	tui.buffer_init(&buffer, 40, 1)
	defer tui.buffer_destroy(&buffer)
	layout: tui.Layout
	tui.layout_init(&layout)
	defer tui.layout_destroy(&layout)
	tui.render_node(&buffer, &layout, &rows[0].node, tui.Rect{width = 40, height = 1}, tui.PLAIN_STYLE)
	// Anatomy at depth 0: no guides, chevron (2), icon, gap, name.
	arrow, arrow_ok := tui.buffer_get(&buffer, 0, 0)
	icon, icon_ok := tui.buffer_get(&buffer, 2, 0)
	testing.expect(t, arrow_ok && icon_ok)
	testing.expect_value(t, arrow.rune, '▸')
	testing.expect_value(t, icon.rune, '\uf07b')
	testing.expect_value(t, icon.style.fg, tui.ACCENT)
}

@(test)
test_source_control_rows_match_reference_shapes :: proc(t: ^testing.T) {
	root := tabs_test_repo(t)
	defer { _ = os.remove_all(root); delete(root) }
	state := changes_new(root)
	defer changes_destroy_proc(rawptr(state))
	rows := changes_rows_proc(rawptr(state), 80, context.allocator)
	defer rows_destroy(&rows)
	box: ^Row
	button: ^Row
	for &row in rows {
		if row.kind == .Commit_Box do box = &row
		if row.kind == .Commit_Button do button = &row
	}
	testing.expect(t, box != nil && button != nil)
	if box == nil || button == nil do return
	buffer: tui.Buffer
	tui.buffer_init(&buffer, 40, 3)
	defer tui.buffer_destroy(&buffer)
	layout: tui.Layout
	tui.layout_init(&layout)
	defer tui.layout_destroy(&layout)
	tui.render_node(&buffer, &layout, &box.node, tui.Rect{width = 40, height = 3}, tui.PLAIN_STYLE)
	top_left, _ := tui.buffer_get(&buffer, 0, 0)
	top_right, _ := tui.buffer_get(&buffer, 39, 0)
	bottom_left, _ := tui.buffer_get(&buffer, 0, 2)
	testing.expect_value(t, top_left.rune, '┌')
	testing.expect_value(t, top_right.rune, '┐')
	testing.expect_value(t, bottom_left.rune, '└')
	// The button is one row and renders dim until something is actually staged.
	tui.buffer_clear(&buffer)
	tui.render_node(&buffer, &layout, &button.node, tui.Rect{width = 40, height = 1}, tui.PLAIN_STYLE)
	idle, _ := tui.buffer_get(&buffer, 20, 0)
	testing.expect_value(t, idle.style.bg, tui.DEFAULT_COLOR)
	staged_file := tabs_test_join(root, "staged.txt")
	defer delete(staged_file)
	_ = os.write_entire_file_from_string(staged_file, "x")
	output, ok := gitcore.repo_stage_all(&state.repo)
	delete(output)
	testing.expect(t, ok)
	changes_refresh(state)
	live := changes_rows_proc(rawptr(state), 80, context.allocator)
	defer rows_destroy(&live)
	for &row in live {
		if row.kind != .Commit_Button do continue
		tui.buffer_clear(&buffer)
		tui.render_node(&buffer, &layout, &row.node, tui.Rect{width = 40, height = 1}, tui.PLAIN_STYLE)
		cell, _ := tui.buffer_get(&buffer, 20, 0)
		testing.expect_value(t, cell.style.bg, tui.BUTTON_BG)
	}
}

@(test)
test_graph_lane_survives_narrow_metadata :: proc(t: ^testing.T) {
	root := tabs_test_repo(t)
	defer { _ = os.remove_all(root); delete(root) }
	state := graph_new(root)
	defer graph_destroy_proc(rawptr(state))
	rows := graph_rows_proc(rawptr(state), 80, context.allocator)
	defer rows_destroy(&rows)
	testing.expect(t, len(rows) > 0)
	if len(rows) == 0 do return
	buffer: tui.Buffer
	tui.buffer_init(&buffer, 24, max(rows[0].height, 1))
	defer tui.buffer_destroy(&buffer)
	layout: tui.Layout
	tui.layout_init(&layout)
	defer tui.layout_destroy(&layout)
	tui.render_node(&buffer, &layout, &rows[0].node, tui.Rect{width = 24, height = max(rows[0].height, 1)}, tui.PLAIN_STYLE)
	cell, ok := tui.buffer_get(&buffer, 1, 0)
	testing.expect(t, ok)
	testing.expect_value(t, cell.rune, '●')
}

// rows_destroy frees id and path independently, so no row may point both at one
// allocation. Aliasing them is a double free that the tracking allocator tolerates
// and glibc aborts on, which makes it a crash only in the real binary.
expect_distinct_strings :: proc(t: ^testing.T, rows: []Row, label: string) {
	for row in rows {
		if len(row.id) == 0 || len(row.path) == 0 do continue
		testing.expectf(
			t,
			raw_data(row.id) != raw_data(row.path),
			"%s row %q aliases id and path",
			label,
			row.id,
		)
	}
}

@(test)
test_rows_never_alias_id_and_path :: proc(t: ^testing.T) {
	root := tabs_test_repo(t)
	defer { _ = os.remove_all(root); delete(root) }
	dir := tabs_test_join(root, "src")
	defer delete(dir)
	_ = os.make_directory(dir)
	untracked := tabs_test_join(root, "fresh.txt")
	defer delete(untracked)
	_ = os.write_entire_file_from_string(untracked, "x")

	tree := tree_tab_new(root)
	defer tree_destroy_proc(rawptr(tree))
	tree_rows := tree_rows_proc(rawptr(tree), 80, context.allocator)
	defer rows_destroy(&tree_rows)
	expect_distinct_strings(t, tree_rows[:], "tree")

	changes := changes_new(root)
	defer changes_destroy_proc(rawptr(changes))
	changes_rows := changes_rows_proc(rawptr(changes), 80, context.allocator)
	defer rows_destroy(&changes_rows)
	expect_distinct_strings(t, changes_rows[:], "changes")

	graph := graph_new(root)
	defer graph_destroy_proc(rawptr(graph))
	graph_rows := graph_rows_proc(rawptr(graph), 80, context.allocator)
	defer rows_destroy(&graph_rows)
	expect_distinct_strings(t, graph_rows[:], "graph")
}

// The shell routes Enter to on_select, never to on_key, so the commit box has to be
// handled there. Handling it only in changes_key_proc makes the box's own "⏎ to
// commit" prompt a lie.
@(test)
test_changes_enter_in_message_box_commits :: proc(t: ^testing.T) {
	root := tabs_test_repo(t)
	defer { _ = os.remove_all(root); delete(root) }
	fresh := tabs_test_join(root, "new.txt")
	defer delete(fresh)
	_ = os.write_entire_file_from_string(fresh, "new")
	state := changes_new(root)
	defer changes_destroy_proc(rawptr(state))
	output, staged := gitcore.repo_stage_all(&state.repo)
	delete(output)
	testing.expect(t, staged)
	changes_refresh(state)
	append(&state.message, "from the box")
	box := Row{kind = .Commit_Box}
	result := changes_select_proc(rawptr(state), &box)
	testing.expect(t, result.rows_changed)
	testing.expect_value(t, result.message, "committed")
	testing.expect_value(t, len(state.status.staged), 0)
}

// Explorer mode lists one directory and walks into it; tree mode unfolds in place.
// The two must not share expanded state, or switching modes leaves phantom rows.
@(test)
test_explorer_mode_walks_into_directories :: proc(t: ^testing.T) {
	root := tabs_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	nested := tabs_test_join(root, "src")
	defer delete(nested)
	_ = os.make_directory(nested)
	leaf := tabs_test_join(nested, "deep")
	defer delete(leaf)
	_ = os.make_directory(leaf)

	state := tree_tab_new(root, false, true)
	defer tree_destroy_proc(rawptr(state))
	rows := tree_rows_proc(rawptr(state), 80, context.allocator)
	testing.expect_value(t, len(rows), 1)
	src_row := rows[0]
	testing.expect(t, src_row.is_dir)

	// Entering re-roots rather than expanding, so the listing is the child's.
	result := tree_select_proc(rawptr(state), &rows[0])
	rows_destroy(&rows)
	testing.expect(t, result.rows_changed)
	testing.expect_value(t, result.root_path, nested)
	inner := tree_rows_proc(rawptr(state), 80, context.allocator)
	testing.expect_value(t, len(inner), 1)
	rows_destroy(&inner)

	// And Left climbs back out.
	up := tree_key_proc(rawptr(state), tui.Key{code = .Left}, nil)
	testing.expect(t, up.rows_changed)
	testing.expect_value(t, up.root_path, root)
}

@(test)
test_explorer_mode_toggle_clears_expansion :: proc(t: ^testing.T) {
	root := tabs_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	nested := tabs_test_join(root, "src")
	defer delete(nested)
	_ = os.make_directory(nested)
	child := tabs_test_join(nested, "inner")
	defer delete(child)
	_ = os.make_directory(child)

	state := tree_tab_new(root)
	defer tree_destroy_proc(rawptr(state))
	rows := tree_rows_proc(rawptr(state), 80, context.allocator)
	_ = tree_select_proc(rawptr(state), &rows[0])
	rows_destroy(&rows)
	expanded := tree_rows_proc(rawptr(state), 80, context.allocator)
	testing.expect_value(t, len(expanded), 2)
	rows_destroy(&expanded)

	result := tree_key_proc(rawptr(state), tui.Key{code = .Rune, rune = 'a'}, nil)
	testing.expect_value(t, result.message, "explorer mode")
	flat := tree_rows_proc(rawptr(state), 80, context.allocator)
	testing.expect_value(t, len(flat), 1)
	rows_destroy(&flat)
}

// Walking around explorer mode must not lose your place: entering a directory for
// the first time starts at the top, climbing out lands on the directory you left,
// and going back in returns to wherever you had got to.
@(test)
test_explorer_remembers_selection_per_directory :: proc(t: ^testing.T) {
	root := tabs_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	child := tabs_test_join(root, "child")
	defer delete(child)
	_ = os.make_directory(child)
	inner := tabs_test_join(child, "inner")
	defer delete(inner)
	_ = os.make_directory(inner)
	leaf := tabs_test_join(child, "leaf.txt")
	defer delete(leaf)
	_ = os.write_entire_file_from_string(leaf, "x")

	state := tree_tab_new(root, false, true)
	defer tree_destroy_proc(rawptr(state))

	// First visit: nothing remembered, so the caller is told to take the top row.
	entering := tree_reroot(state, child, child)
	testing.expect(t, entering.select_first)
	testing.expect_value(t, entering.select_id, "")

	// Climbing out lands on the directory just left.
	leaving := tree_parent(state, leaf)
	testing.expect_value(t, leaving.select_id, child)

	// And going back in restores the row that was selected down there.
	returning := tree_reroot(state, child, child)
	testing.expect_value(t, returning.select_id, leaf)
}

// The age column has to agree with `git tree`, and git's thresholds are not the
// obvious ones: it stays in minutes to 90, hours to 36, days to 14, then weeks.
@(test)
test_relative_time_matches_git :: proc(t: ^testing.T) {
	now := time.to_unix_seconds(time.now())
	check :: proc(t: ^testing.T, now, ago: i64, expect: string) {
		text := graph_relative_time(now - ago, context.allocator)
		defer delete(text)
		testing.expectf(t, text == expect, "%d seconds ago -> %q, wanted %q", ago, text, expect)
	}
	check(t, now, 1, "1 second ago")
	check(t, now, 45, "45 seconds ago")
	// 90 seconds is where minutes begin, and the conversion rounds.
	check(t, now, 90, "2 minutes ago")
	check(t, now, 60 * 79, "79 minutes ago")
	// Minutes run to 90, so this is still minutes rather than an hour and a half.
	check(t, now, 60 * 89, "89 minutes ago")
	check(t, now, 60 * 91, "2 hours ago")
	// Hours run to 36.
	check(t, now, 3600 * 35, "35 hours ago")
	check(t, now, 3600 * 40, "2 days ago")
	check(t, now, 86400 * 13, "13 days ago")
	// Then weeks, which trek previously skipped entirely.
	check(t, now, 86400 * 20, "3 weeks ago")
	check(t, now, 86400 * 69, "10 weeks ago")
	check(t, now, 86400 * 200, "7 months ago")
	check(t, now, 86400 * 400, "1 year, 1 month ago")
	check(t, now, 86400 * 365 * 6, "6 years ago")
}

package tabs

import "core:os"
import "core:path/filepath"
import "core:testing"
import gitcore "../git"
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
test_changes_rows_have_sections_and_commit_box :: proc(t: ^testing.T) {
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
	rows := changes_rows_proc(rawptr(state), context.allocator)
	defer rows_destroy(&rows)
	commit_boxes := 0
	entries := 0
	for row in rows {
		if row.kind == .Commit_Box {
			commit_boxes += 1
			testing.expect_value(t, row.height, 2)
		}
		if row.kind == .Git_Entry do entries += 1
	}
	testing.expect_value(t, len(state.repos), 1)
	testing.expect_value(t, commit_boxes, 1)
	testing.expect_value(t, entries, 2)
}

@(test)
test_changes_plain_enter_commits_message :: proc(t: ^testing.T) {
	root := tabs_test_repo(t)
	defer { _ = os.remove_all(root); delete(root) }
	new_file := tabs_test_join(root, "new.txt")
	defer delete(new_file)
	_ = os.write_entire_file_from_string(new_file, "new")
	state := changes_new(root)
	defer changes_destroy_proc(rawptr(state))
	message, staged := gitcore.repo_stage_all(&state.repos[0].repo)
	delete(message)
	testing.expect(t, staged)
	changes_refresh(state)
	append(&state.repos[0].message, "add new file")
	row := Row{kind = .Commit_Box, repo_index = 0}
	result := changes_select_proc(rawptr(state), &row)
	testing.expect(t, result.rows_changed)
	testing.expect_value(t, result.message, "committed")
	testing.expect_value(t, len(state.repos[0].status.staged), 0)
	testing.expect_value(t, len(state.repos[0].status.unstaged), 0)
}

@(test)
test_changes_commit_box_accepts_text_and_paste :: proc(t: ^testing.T) {
	root := tabs_test_repo(t)
	defer { _ = os.remove_all(root); delete(root) }
	state := changes_new(root)
	defer changes_destroy_proc(rawptr(state))
	row := Row{kind = .Commit_Box, repo_index = 0}
	_ = changes_key_proc(rawptr(state), tui.Key{code = .Rune, rune = 'h'}, &row)
	_ = changes_paste_proc(rawptr(state), "ello", &row)
	testing.expect_value(t, string(state.repos[0].message[:]), "hello")
	_ = changes_key_proc(rawptr(state), tui.Key{code = .Backspace}, &row)
	testing.expect_value(t, string(state.repos[0].message[:]), "hell")
}

@(test)
test_changes_discovers_child_repositories :: proc(t: ^testing.T) {
	root := tabs_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	inner := tabs_test_join(root, "vendor/inner")
	defer delete(inner)
	_ = os.make_directory_all(inner)
	tabs_test_git(t, root, []string{"init", "-q"})
	tabs_test_git(t, inner, []string{"init", "-q"})
	state := changes_new(root)
	defer changes_destroy_proc(rawptr(state))
	testing.expect_value(t, len(state.repos), 2)
	rows := changes_rows_proc(rawptr(state), context.allocator)
	defer rows_destroy(&rows)
	boxes := 0
	for row in rows {
		if row.kind == .Commit_Box do boxes += 1
	}
	testing.expect_value(t, boxes, 2)
}

@(test)
test_graph_rows_render_commits_and_refs :: proc(t: ^testing.T) {
	root := tabs_test_repo(t)
	defer { _ = os.remove_all(root); delete(root) }
	state := graph_new(root)
	defer graph_destroy_proc(rawptr(state))
	rows := graph_rows_proc(rawptr(state), context.allocator)
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

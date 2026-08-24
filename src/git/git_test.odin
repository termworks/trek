package git

import "core:os"
import "core:path/filepath"
import "core:testing"

git_test_dir :: proc(t: ^testing.T) -> string {
	path, err := os.make_directory_temp("", "trek-git-*", context.allocator)
	testing.expect(t, err == nil)
	return path
}

git_test_join :: proc(root, relative: string) -> string {
	path, _ := filepath.join([]string{root, relative}, context.allocator)
	return path
}

git_test_run :: proc(t: ^testing.T, root: string, args: []string) {
	output := run(root, args)
	defer output_destroy(&output)
	testing.expect(t, output_ok(&output), string(output.stderr))
}

@(test)
test_status_splits_sides_and_renames :: proc(t: ^testing.T) {
	status := parse_status("## main...origin/main [ahead 3, behind 2]\u0000MM src/app.odin\u0000R  new.odin\u0000old.odin\u0000?? notes.md\u0000")
	defer status_destroy(&status)
	testing.expect_value(t, status.branch, "main")
	testing.expect_value(t, status.ahead, 3)
	testing.expect_value(t, status.behind, 2)
	testing.expect_value(t, len(status.staged), 2)
	testing.expect_value(t, status.staged[1].original, "old.odin")
}

@(test)
test_status_conflicts_and_type_changes :: proc(t: ^testing.T) {
	status := parse_status("UU merge.odin\u0000T  link\u0000 T other\u0000")
	defer status_destroy(&status)
	testing.expect_value(t, status.unstaged[0].letter, '!')
	testing.expect_value(t, status.staged[0].letter, 'M')
	testing.expect_value(t, status.unstaged[1].letter, 'M')
}

@(test)
test_stage_candidates_pair_rename_paths :: proc(t: ^testing.T) {
	status := parse_status(" R src/new.odin\u0000src/old.odin\u0000 M docs/x.md\u0000")
	defer status_destroy(&status)
	paths := paths_under(&status, "src/new.odin", true)
	defer paths_destroy(&paths)
	testing.expect_value(t, len(paths), 2)
	testing.expect_value(t, paths[0], "src/new.odin")
	testing.expect_value(t, paths[1], "src/old.odin")
	testing.expect(t, path_under("src/api/x", "src"))
	testing.expect(t, !path_under("srcfoo/x", "src"))
}

@(test)
test_decorations_aggregate_and_rank :: proc(t: ^testing.T) {
	status := parse_status(" M src/app.odin\u0000?? src/note.txt\u0000UU src/conflict.odin\u0000")
	defer status_destroy(&status)
	decorations: Decorations
	decorations_init(&decorations)
	defer decorations_destroy(&decorations)
	decorations_add_status(&decorations, "/ws", &status)
	file, file_ok := decorations_letter(&decorations, "/ws/src/app.odin", false)
	dir, dir_ok := decorations_letter(&decorations, "/ws/src", true)
	testing.expect(t, file_ok)
	testing.expect_value(t, file, 'M')
	testing.expect(t, dir_ok)
	testing.expect_value(t, dir, '!')
}

@(test)
test_stage_under_stops_at_nested_repo :: proc(t: ^testing.T) {
	root := git_test_dir(t)
	defer { _ = os.remove_all(root); delete(root) }
	src := git_test_join(root, "src")
	inner := git_test_join(root, "vendor/lib")
	defer delete(src)
	defer delete(inner)
	_ = os.make_directory_all(src)
	_ = os.make_directory_all(inner)
	git_test_run(t, root, []string{"init", "-q"})
	git_test_run(t, inner, []string{"init", "-q"})
	outer_file := git_test_join(root, "src/outer.txt")
	inner_file := git_test_join(inner, "inner.txt")
	defer delete(outer_file)
	defer delete(inner_file)
	_ = os.write_entire_file_from_string(outer_file, "outer")
	_ = os.write_entire_file_from_string(inner_file, "inner")
	repo, message, ok := discover(root)
	defer if ok do repo_destroy(&repo)
	defer delete(message)
	testing.expect(t, ok)
	result, stage_message, staged := stage_under(&repo, root)
	defer delete(stage_message)
	testing.expect(t, staged)
	testing.expect_value(t, result.count, 1)
	testing.expect(t, result.skipped_nested >= 1)
}

@(test)
test_stage_under_keeps_rename_pair :: proc(t: ^testing.T) {
	root := git_test_dir(t)
	defer { _ = os.remove_all(root); delete(root) }
	git_test_run(t, root, []string{"init", "-q"})
	old_path := git_test_join(root, "old.txt")
	new_path := git_test_join(root, "new.txt")
	defer delete(old_path)
	defer delete(new_path)
	_ = os.write_entire_file_from_string(old_path, "content")
	git_test_run(t, root, []string{"add", "-A"})
	git_test_run(t, root, []string{"-c", "user.name=trek", "-c", "user.email=trek@test", "commit", "-q", "-m", "init"})
	_ = os.rename(old_path, new_path)
	repo, message, ok := discover(root)
	defer if ok do repo_destroy(&repo)
	defer delete(message)
	testing.expect(t, ok)
	status := parse_status(" R new.txt\u0000old.txt\u0000")
	defer status_destroy(&status)
	result, stage_message, staged := stage_status_paths(&repo, &status, "new.txt", true)
	defer delete(stage_message)
	testing.expect(t, staged)
	testing.expect_value(t, result.count, 2)
}

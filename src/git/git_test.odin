package git

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import "core:time"

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

Commit_Spec :: struct {
	hash:    string,
	parents: string,
}

graph_test_history :: proc(specs: []Commit_Spec) -> History {
	history := History{commits = make([dynamic]Commit, context.allocator), allocator = context.allocator}
	for spec in specs {
		append(&history.commits, Commit{
			hash = strings.clone(spec.hash),
			parents = split_owned(spec.parents, " ", context.allocator),
			refs = make([dynamic]string, context.allocator),
			author = strings.clone("tester"),
			subject = strings.clone(spec.hash),
		})
	}
	return history
}

// The graph is git's algorithm, so the test for it is git's own output. Each fixture
// below was captured from `git log --graph` on a real repository with that exact
// topology; the engine has to redraw it character for character. A picture that merely
// looks plausible is the failure this catches.
graph_render :: proc(graph: ^Graph, allocator := context.allocator) -> [dynamic]string {
	lines := make([dynamic]string, allocator)
	emit :: proc(lines: ^[dynamic]string, line: Graph_Line, allocator: runtime.Allocator) {
		text := make([dynamic]rune, allocator)
		defer delete(text)
		for cell in line do append(&text, cell.glyph)
		append(lines, utf8.runes_to_string(text[:], allocator))
	}
	for &entry in graph.entries {
		for line in entry.pre do emit(&lines, line, allocator)
		emit(&lines, entry.line, allocator)
		for line in entry.rest do emit(&lines, line, allocator)
	}
	return lines
}

expect_graph :: proc(t: ^testing.T, history: ^History, expected: []string, loc := #caller_location) {
	graph := build_graph(history)
	defer graph_destroy(&graph)
	drawn := graph_render(&graph)
	defer { for line in drawn do delete(line); delete(drawn) }
	testing.expectf(t, len(drawn) == len(expected), "drew %d rows, git drew %d", len(drawn), len(expected), loc = loc)
	for line, index in drawn {
		if index >= len(expected) do break
		testing.expectf(t, line == expected[index], "row %d: drew %q, git drew %q", index, line, expected[index], loc = loc)
	}
}

@(test)
test_graph_matches_git_linear :: proc(t: ^testing.T) {
	history := graph_test_history([]Commit_Spec{
		{"d", "b"},
		{"b", "a"},
		{"a", ""},
	})
	defer history_destroy(&history)
	// Captured from `git log --graph` on this exact topology (git 2.53.0).
	expected := []string{
		"* ",
		"* ",
		"* ",
	}

	expect_graph(t, &history, expected)
}


@(test)
test_graph_matches_git_merge :: proc(t: ^testing.T) {
	history := graph_test_history([]Commit_Spec{
		{"e", "M1"},
		{"M1", "d f2"},
		{"f2", "f1"},
		{"f1", "b"},
		{"d", "b"},
		{"b", "a"},
		{"a", ""},
	})
	defer history_destroy(&history)
	// Captured from `git log --graph` on this exact topology (git 2.53.0).
	expected := []string{
		"* ",
		"*   ",
		"|\\  ",
		"| * ",
		"| * ",
		"* | ",
		"|/  ",
		"* ",
		"* ",
	}

	expect_graph(t, &history, expected)
}


@(test)
test_graph_matches_git_octopus :: proc(t: ^testing.T) {
	history := graph_test_history([]Commit_Spec{
		{"g", "OCT"},
		{"OCT", "f b d e"},
		{"e", "a"},
		{"d", "a"},
		{"b", "a"},
		{"f", "a"},
		{"a", ""},
	})
	defer history_destroy(&history)
	// Captured from `git log --graph` on this exact topology (git 2.53.0).
	expected := []string{
		"* ",
		"*---.   ",
		"|\\ \\ \\  ",
		"| | | * ",
		"| | * | ",
		"| | |/  ",
		"| * / ",
		"| |/  ",
		"* / ",
		"|/  ",
		"* ",
	}

	expect_graph(t, &history, expected)
}


@(test)
test_graph_matches_git_crossing :: proc(t: ^testing.T) {
	history := graph_test_history([]Commit_Spec{
		{"z", "MY"},
		{"MY", "MX y1"},
		{"y1", "m1"},
		{"MX", "m1 x1"},
		{"x1", "a"},
		{"m1", "a"},
		{"a", ""},
	})
	defer history_destroy(&history)
	// Captured from `git log --graph` on this exact topology (git 2.53.0).
	expected := []string{
		"* ",
		"*   ",
		"|\\  ",
		"| * ",
		"* |   ",
		"|\\ \\  ",
		"| |/  ",
		"|/|   ",
		"| * ",
		"* | ",
		"|/  ",
		"* ",
	}

	expect_graph(t, &history, expected)
}


@(test)
test_graph_matches_git_wide :: proc(t: ^testing.T) {
	history := graph_test_history([]Commit_Spec{
		{"MR", "MQ r1"},
		{"r1", "a"},
		{"MQ", "MP q1"},
		{"q1", "a"},
		{"MP", "m p1"},
		{"p1", "a"},
		{"m", "a"},
		{"a", ""},
	})
	defer history_destroy(&history)
	// Captured from `git log --graph` on this exact topology (git 2.53.0).
	expected := []string{
		"*   ",
		"|\\  ",
		"| * ",
		"* |   ",
		"|\\ \\  ",
		"| * | ",
		"| |/  ",
		"* |   ",
		"|\\ \\  ",
		"| * | ",
		"| |/  ",
		"* / ",
		"|/  ",
		"* ",
	}

	expect_graph(t, &history, expected)
}


@(test)
test_graph_log_parser_reads_refs :: proc(t: ^testing.T) {
	raw := "abc\u0000def 123\u0000HEAD -> main, tag: v1\u0000Ada\u00001700000000\u0000Mon Nov 14 22:13:20 2023 +0000\u0000subject\u0000"
	history := parse_log(raw)
	defer history_destroy(&history)
	testing.expect_value(t, len(history.commits), 1)
	testing.expect_value(t, len(history.commits[0].parents), 2)
	testing.expect_value(t, len(history.commits[0].refs), 2)
	testing.expect_value(t, history.commits[0].refs[0], "HEAD -> main")
	testing.expect_value(t, history.commits[0].timestamp, i64(1700000000))
	testing.expect_value(t, history.commits[0].date, "Mon Nov 14 22:13:20 2023 +0000")
	testing.expect_value(t, history.commits[0].subject, "subject")
}

// A hook that never returns is the realistic way git hangs, and trek runs git from
// the same thread that draws the screen: without a deadline the whole application
// stops responding with no way out.
@(test)
test_run_kills_a_command_that_exceeds_the_timeout :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "trek-git-timeout-*", context.allocator)
	testing.expect(t, err == nil)
	defer { _ = os.remove_all(root); delete(root) }
	git_test_run(t, root, []string{"init", "-q"})
	hooks, _ := filepath.join([]string{root, ".git", "hooks"}, context.allocator)
	defer delete(hooks)
	_ = os.make_directory_all(hooks)
	hook, _ := filepath.join([]string{hooks, "pre-commit"}, context.allocator)
	defer delete(hook)
	testing.expect(t, os.write_entire_file_from_string(hook, "#!/bin/sh\nsleep 60\n") == nil)
	_ = os.chmod(hook, os.Permissions{.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})

	tracked, _ := filepath.join([]string{root, "a.txt"}, context.allocator)
	defer delete(tracked)
	_ = os.write_entire_file_from_string(tracked, "x")
	git_test_run(t, root, []string{"add", "-A"})


	started := time.now()
	output := run(root, []string{"-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "x"}, timeout = 300 * time.Millisecond)
	elapsed := time.since(started)
	defer output_destroy(&output)

	testing.expect(t, !output_ok(&output), "a killed commit must not report success")
	testing.expect(t, elapsed < 10 * time.Second, "run returned only after the real budget")
	message := output_message(&output)
	defer delete(message)
	testing.expect_value(t, message, "git timed out")
}

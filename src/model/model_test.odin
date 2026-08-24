package model

import "core:os"
import "core:path/filepath"
import "core:testing"

Test_Dir :: struct {
	path: string,
}

test_dir_make :: proc(t: ^testing.T) -> Test_Dir {
	path, err := os.make_directory_temp("", "trek-tree-*", context.allocator)
	testing.expect(t, err == nil)
	return Test_Dir{path = path}
}

test_dir_destroy :: proc(dir: ^Test_Dir) {
	_ = os.remove_all(dir.path)
	delete(dir.path)
	dir^ = {}
}

test_join :: proc(dir: ^Test_Dir, relative: string) -> string {
	path, _ := filepath.join([]string{dir.path, relative}, context.allocator)
	return path
}

test_mkdir :: proc(dir: ^Test_Dir, relative: string) {
	path := test_join(dir, relative)
	defer delete(path)
	_ = os.make_directory_all(path)
}

test_touch :: proc(dir: ^Test_Dir, relative: string) {
	path := test_join(dir, relative)
	defer delete(path)
	_ = os.write_entire_file_from_string(path, "")
}

@(test)
test_tree_orders_and_hides_git :: proc(t: ^testing.T) {
	dir := test_dir_make(t)
	defer test_dir_destroy(&dir)
	test_mkdir(&dir, "b_dir")
	test_mkdir(&dir, "A_dir")
	test_mkdir(&dir, ".git")
	test_touch(&dir, "Zebra.txt")
	test_touch(&dir, "apple.odin")
	tree: Tree
	tree_init(&tree, dir.path)
	defer tree_destroy(&tree)
	rows := tree_rows(&tree)
	defer tree_rows_destroy(&rows)
	testing.expect_value(t, len(rows), 4)
	testing.expect_value(t, rows[0].name, "A_dir")
	testing.expect_value(t, rows[1].name, "b_dir")
	testing.expect_value(t, rows[2].name, "apple.odin")
}

@(test)
test_tree_expands_and_collapses :: proc(t: ^testing.T) {
	dir := test_dir_make(t)
	defer test_dir_destroy(&dir)
	test_mkdir(&dir, "src")
	test_touch(&dir, "src/main.odin")
	test_touch(&dir, "README.md")
	src := test_join(&dir, "src")
	defer delete(src)
	tree: Tree
	tree_init(&tree, dir.path)
	defer tree_destroy(&tree)
	tree_toggle(&tree, src)
	rows := tree_rows(&tree)
	testing.expect_value(t, len(rows), 3)
	testing.expect_value(t, rows[1].name, "main.odin")
	testing.expect_value(t, rows[1].depth, 1)
	tree_rows_destroy(&rows)
	tree_collapse_all(&tree)
	rows = tree_rows(&tree)
	defer tree_rows_destroy(&rows)
	testing.expect_value(t, len(rows), 2)
}

@(test)
test_tree_hidden_and_refresh :: proc(t: ^testing.T) {
	dir := test_dir_make(t)
	defer test_dir_destroy(&dir)
	test_touch(&dir, ".env")
	test_touch(&dir, "one.txt")
	tree: Tree
	tree_init(&tree, dir.path)
	defer tree_destroy(&tree)
	rows := tree_rows(&tree)
	testing.expect_value(t, len(rows), 2)
	tree_rows_destroy(&rows)
	test_touch(&dir, "two.txt")
	rows = tree_rows(&tree)
	testing.expect_value(t, len(rows), 2)
	tree_rows_destroy(&rows)
	tree.show_hidden = false
	rows = tree_rows(&tree)
	testing.expect_value(t, len(rows), 1)
	tree_rows_destroy(&rows)
	tree_refresh(&tree)
	rows = tree_rows(&tree)
	defer tree_rows_destroy(&rows)
	testing.expect_value(t, len(rows), 2)
}

@(test)
test_tree_restores_only_paths_in_root :: proc(t: ^testing.T) {
	dir := test_dir_make(t)
	defer test_dir_destroy(&dir)
	test_mkdir(&dir, "src")
	src := test_join(&dir, "src")
	defer delete(src)
	tree: Tree
	tree_init(&tree, dir.path)
	defer tree_destroy(&tree)
	tree_set_expanded(&tree, []string{src, "/somewhere/else/src"})
	testing.expect_value(t, len(tree.expanded), 1)
	testing.expect_value(t, tree.expanded[0], src)
}

@(test)
test_icons_classify_names_and_extensions :: proc(t: ^testing.T) {
	testing.expect_value(t, file_icon(.Emoji, "src", true, false).glyph, "📁")
	testing.expect_value(t, file_icon(.Emoji, "src", true, true).glyph, "📂")
	testing.expect_value(t, file_icon(.Emoji, "Cargo.toml", false, false).glyph, "📦")
	testing.expect_value(t, file_icon(.Emoji, "README.md", false, false).glyph, "📖")
	testing.expect_value(t, file_icon(.Emoji, "MAIN.ODIN", false, false).glyph, "⚔")
}

@(test)
test_names_reject_path_segments :: proc(t: ^testing.T) {
	_, empty := validate_name("")
	_, parent := validate_name("..")
	_, nested := validate_name("src/main")
	_, valid := validate_name("main.odin")
	testing.expect(t, !empty)
	testing.expect(t, !parent)
	testing.expect(t, !nested)
	testing.expect(t, valid)
}

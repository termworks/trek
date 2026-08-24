package model

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Entry :: struct {
	name:   string,
	is_dir: bool,
}

Tree_Row :: struct {
	path:     string,
	name:     string,
	is_dir:   bool,
	depth:    int,
	expanded: bool,
	// Guide data: whether this row is its parent's last child, and for each ancestor
	// level whether that ancestor still has siblings below. Together they decide
	// between "│" and blank for every indent column.
	is_last:  bool,
	ancestors: []bool,
}

Cached_Listing :: struct {
	dir:     string,
	entries: [dynamic]Entry,
}

Tree :: struct {
	root:        string,
	expanded:    [dynamic]string,
	cache:       [dynamic]Cached_Listing,
	show_hidden: bool,
	// Explorer mode: list only the current directory and never descend, so entering
	// a folder re-roots the tree instead of unfolding it in place.
	flat:        bool,
	allocator:   runtime.Allocator,
}

tree_init :: proc(tree: ^Tree, root: string, allocator := context.allocator) {
	tree.allocator = allocator
	tree.root = strings.clone(root, allocator)
	tree.expanded = make([dynamic]string, allocator)
	tree.cache = make([dynamic]Cached_Listing, allocator)
	tree.show_hidden = true
}

free_listing :: proc(listing: ^Cached_Listing) {
	delete(listing.dir)
	for entry in listing.entries do delete(entry.name)
	delete(listing.entries)
	listing^ = {}
}

tree_refresh :: proc(tree: ^Tree) {
	for &listing in tree.cache do free_listing(&listing)
	clear(&tree.cache)
}

tree_destroy :: proc(tree: ^Tree) {
	tree_refresh(tree)
	delete(tree.cache)
	for path in tree.expanded do delete(path)
	delete(tree.expanded)
	delete(tree.root)
	tree^ = {}
}

tree_root_name :: proc(tree: ^Tree) -> string {
	name := filepath.base(tree.root)
	if name == "." || name == "" {
		return tree.root
	}
	return name
}

tree_is_expanded :: proc(tree: ^Tree, path: string) -> bool {
	for expanded in tree.expanded {
		if expanded == path do return true
	}
	return false
}

tree_expand :: proc(tree: ^Tree, path: string) {
	if !tree_is_expanded(tree, path) {
		append(&tree.expanded, strings.clone(path, tree.allocator))
	}
}

tree_collapse :: proc(tree: ^Tree, path: string) {
	for expanded, index in tree.expanded {
		if expanded == path {
			delete(expanded)
			ordered_remove(&tree.expanded, index)
			return
		}
	}
}

tree_toggle :: proc(tree: ^Tree, path: string) {
	if tree_is_expanded(tree, path) {
		tree_collapse(tree, path)
	} else {
		tree_expand(tree, path)
	}
}

tree_collapse_all :: proc(tree: ^Tree) {
	for path in tree.expanded do delete(path)
	clear(&tree.expanded)
}

path_within :: proc(root, path: string) -> bool {
	if path == root do return true
	if !strings.has_prefix(path, root) do return false
	if len(root) > 0 && os.is_path_separator(root[len(root) - 1]) do return true
	return len(path) > len(root) && os.is_path_separator(path[len(root)])
}

tree_set_expanded :: proc(tree: ^Tree, paths: []string) {
	tree_collapse_all(tree)
	for path in paths {
		if path_within(tree.root, path) do tree_expand(tree, path)
	}
	tree_refresh(tree)
}

visible_entry :: proc(name: string, show_hidden: bool) -> bool {
	return name != ".git" && (show_hidden || len(name) == 0 || name[0] != '.')
}

entry_less :: proc(left, right: Entry) -> bool {
	if left.is_dir != right.is_dir do return left.is_dir
	left_lower := strings.to_lower(left.name)
	right_lower := strings.to_lower(right.name)
	defer delete(left_lower)
	defer delete(right_lower)
	if left_lower == right_lower do return left.name < right.name
	return left_lower < right_lower
}

find_listing :: proc(tree: ^Tree, dir: string) -> ^Cached_Listing {
	for &listing in tree.cache {
		if listing.dir == dir do return &listing
	}
	return nil
}

tree_children :: proc(tree: ^Tree, dir: string) -> []Entry {
	if listing := find_listing(tree, dir); listing != nil {
		return listing.entries[:]
	}
	listing := Cached_Listing{
		dir = strings.clone(dir, tree.allocator),
		entries = make([dynamic]Entry, tree.allocator),
	}
	infos, err := os.read_all_directory_by_path(dir, tree.allocator)
	if err == nil {
		for info in infos {
			append(&listing.entries, Entry{
				name = strings.clone(info.name, tree.allocator),
				is_dir = info.type == .Directory,
			})
		}
		os.file_info_slice_delete(infos, tree.allocator)
	}
	slice.sort_by(listing.entries[:], entry_less)
	append(&tree.cache, listing)
	return tree.cache[len(tree.cache) - 1].entries[:]
}

tree_walk :: proc(tree: ^Tree, dir: string, depth: int, trail: []bool, rows: ^[dynamic]Tree_Row) {
	visible := make([dynamic]Entry, context.temp_allocator)
	for entry in tree_children(tree, dir) {
		if !visible_entry(entry.name, tree.show_hidden) do continue
		append(&visible, entry)
	}
	for entry, index in visible {
		path, _ := filepath.join([]string{dir, entry.name}, tree.allocator)
		expanded := entry.is_dir && !tree.flat && tree_is_expanded(tree, path)
		last := index == len(visible) - 1
		ancestors := make([]bool, len(trail), tree.allocator)
		copy(ancestors, trail)
		append(rows, Tree_Row{
			path = path,
			name = entry.name,
			is_dir = entry.is_dir,
			depth = depth,
			expanded = expanded,
			is_last = last,
			ancestors = ancestors,
		})
		if expanded && !tree.flat {
			// A row's own connector already shows its relationship to its parent, so
			// the ancestor columns start one level up: top-level children carry none.
			child_trail: []bool
			if depth > 0 {
				child_trail = make([]bool, len(trail) + 1, context.temp_allocator)
				copy(child_trail, trail)
				child_trail[len(trail)] = !last
			}
			tree_walk(tree, path, depth + 1, child_trail, rows)
		}
	}
}

tree_rows :: proc(tree: ^Tree, allocator := context.allocator) -> [dynamic]Tree_Row {
	rows := make([dynamic]Tree_Row, allocator)
	tree_walk(tree, tree.root, 0, nil, &rows)
	return rows
}

tree_rows_destroy :: proc(rows: ^[dynamic]Tree_Row) {
	for row in rows {
		delete(row.path)
		delete(row.ancestors)
	}
	delete(rows^)
	rows^ = nil
}

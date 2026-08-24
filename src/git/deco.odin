package git

import "core:path/filepath"
import "core:strings"

Decoration :: struct {
	path:   string,
	letter: rune,
}

Decorations :: struct {
	files:   [dynamic]Decoration,
	dirs:    [dynamic]Decoration,
	ignored: [dynamic]string,
}

decorations_init :: proc(decorations: ^Decorations, allocator := context.allocator) {
	decorations.files = make([dynamic]Decoration, allocator)
	decorations.dirs = make([dynamic]Decoration, allocator)
	decorations.ignored = make([dynamic]string, allocator)
}

decorations_destroy :: proc(decorations: ^Decorations) {
	for item in decorations.files do delete(item.path)
	for item in decorations.dirs do delete(item.path)
	for path in decorations.ignored do delete(path)
	delete(decorations.files)
	delete(decorations.dirs)
	delete(decorations.ignored)
	decorations^ = {}
}

status_rank :: proc(letter: rune) -> int {
	switch letter {
	case '!': return 3
	case 'M', 'A', 'D', 'R', 'C': return 2
	case 'U': return 1
	}
	return 0
}

directory_letter :: proc(letter: rune) -> rune {
	rank := status_rank(letter)
	if rank >= 3 do return '!'
	if rank >= 2 do return 'M'
	return 'U'
}

decoration_set :: proc(items: ^[dynamic]Decoration, path: string, letter: rune, replace_equal := true) {
	for &item in items {
		if item.path != path do continue
		if status_rank(letter) > status_rank(item.letter) ||
		   (replace_equal && status_rank(letter) == status_rank(item.letter)) {
			item.letter = letter
		}
		return
	}
	append(items, Decoration{path = strings.clone(path), letter = letter})
}

decorations_add :: proc(decorations: ^Decorations, root, relative: string, letter: rune) {
	path := repo_abs(root, relative)
	defer delete(path)
	decoration_set(&decorations.files, path, letter)
	mark := directory_letter(letter)
	parent := filepath.dir(path)
	defer delete(parent)
	for strings.has_prefix(parent, root) {
		decoration_set(&decorations.dirs, parent, mark, false)
		if parent == root do break
		next := filepath.dir(parent)
		delete(parent)
		parent = next
	}
}

decorations_add_status :: proc(decorations: ^Decorations, root: string, status: ^Status, ignored: []string = nil) {
	for entry in status.staged {
		decorations_add(decorations, root, entry.path, entry.letter)
		if entry.original != "" do decorations_add(decorations, root, entry.original, 'D')
	}
	for entry in status.unstaged {
		decorations_add(decorations, root, entry.path, entry.letter)
		if entry.original != "" do decorations_add(decorations, root, entry.original, 'D')
	}
	for relative in ignored {
		append(&decorations.ignored, repo_abs(root, relative))
	}
}

decoration_find :: proc(items: []Decoration, path: string) -> (rune, bool) {
	for item in items {
		if item.path == path do return item.letter, true
	}
	return 0, false
}

decorations_letter :: proc(decorations: ^Decorations, path: string, is_dir: bool) -> (rune, bool) {
	own, has_own := decoration_find(decorations.files[:], path)
	aggregate, has_aggregate := decoration_find(decorations.dirs[:], path)
	if is_dir && has_aggregate && (!has_own || status_rank(aggregate) > status_rank(own)) {
		return aggregate, true
	}
	if has_own do return own, true
	for root in decorations.ignored {
		if path == root || (strings.has_prefix(path, root) && len(path) > len(root) && path[len(root)] == filepath.SEPARATOR_CHARS[0]) {
			return 'I', true
		}
	}
	return 0, false
}

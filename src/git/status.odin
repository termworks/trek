package git

import "base:runtime"
import "core:strconv"
import "core:strings"

File_Entry :: struct {
	path:     string,
	original: string,
	letter:   rune,
}

Status :: struct {
	branch:       string,
	staged:       [dynamic]File_Entry,
	unstaged:     [dynamic]File_Entry,
	ahead:        int,
	behind:       int,
	has_upstream: bool,
	allocator:    runtime.Allocator,
}

status_init :: proc(status: ^Status, allocator := context.allocator) {
	status.allocator = allocator
	status.staged = make([dynamic]File_Entry, allocator)
	status.unstaged = make([dynamic]File_Entry, allocator)
}

entry_destroy :: proc(entry: ^File_Entry) {
	delete(entry.path)
	delete(entry.original)
	entry^ = {}
}

status_destroy :: proc(status: ^Status) {
	delete(status.branch)
	for &entry in status.staged do entry_destroy(&entry)
	for &entry in status.unstaged do entry_destroy(&entry)
	delete(status.staged)
	delete(status.unstaged)
	status^ = {}
}

is_conflict :: proc(x, y: byte) -> bool {
	return (x == 'D' && y == 'D') || (x == 'A' && y == 'U') ||
	       (x == 'U' && y == 'D') || (x == 'U' && y == 'A') ||
	       (x == 'D' && y == 'U') || (x == 'A' && y == 'A') ||
	       (x == 'U' && y == 'U')
}

display_letter :: proc(value: byte) -> rune {
	if value == 'T' do return 'M'
	return rune(value)
}

parse_count_after :: proc(header, tag: string) -> int {
	index := strings.index(header, tag)
	if index < 0 do return 0
	start := index + len(tag)
	end := start
	for end < len(header) && header[end] >= '0' && header[end] <= '9' do end += 1
	if end == start do return 0
	value, ok := strconv.parse_int(header[start:end])
	if !ok do return 0
	return int(value)
}

parse_branch :: proc(header: string, allocator: runtime.Allocator) -> string {
	end := strings.index(header, "...")
	if end < 0 do end = len(header)
	branch := header[:end]
	prefix := "No commits yet on "
	if strings.has_prefix(branch, prefix) do branch = branch[len(prefix):]
	return strings.clone(branch, allocator)
}

nul_field :: proc(raw: string, start: int) -> (string, int) {
	if start >= len(raw) do return "", len(raw)
	relative := strings.index_byte(raw[start:], 0)
	if relative < 0 do return raw[start:], len(raw)
	return raw[start:start + relative], start + relative + 1
}

append_entry :: proc(entries: ^[dynamic]File_Entry, path, original: string, letter: rune, allocator: runtime.Allocator) {
	append(entries, File_Entry{
		path = strings.clone(path, allocator),
		original = strings.clone(original, allocator),
		letter = letter,
	})
}

parse_status :: proc(raw: string, allocator := context.allocator) -> Status {
	status: Status
	status_init(&status, allocator)
	offset := 0
	for offset < len(raw) {
		field, next := nul_field(raw, offset)
		offset = next
		if field == "" do continue
		if strings.has_prefix(field, "## ") {
			header := field[3:]
			delete(status.branch)
			status.branch = parse_branch(header, allocator)
			status.ahead = parse_count_after(header, "ahead ")
			status.behind = parse_count_after(header, "behind ")
			status.has_upstream = strings.contains(header, "...")
			continue
		}
		if len(field) < 4 || field[2] != ' ' do continue
		x, y := field[0], field[1]
		path := field[3:]
		original := ""
		if x == 'R' || x == 'C' || y == 'R' || y == 'C' {
			original, offset = nul_field(raw, offset)
		}
		if x == '?' && y == '?' {
			append_entry(&status.unstaged, path, "", 'U', allocator)
			continue
		}
		if x == '!' do continue
		if is_conflict(x, y) {
			append_entry(&status.unstaged, path, original, '!', allocator)
			continue
		}
		if x != ' ' do append_entry(&status.staged, path, original, display_letter(x), allocator)
		if y != ' ' do append_entry(&status.unstaged, path, original, display_letter(y), allocator)
	}
	return status
}

repo_status :: proc(repo: ^Git_Repo, allocator := context.allocator) -> (Status, string, bool) {
	output := run(repo.root, []string{
		"status", "--porcelain", "-z", "--branch", "--renames", "--untracked-files=all",
	}, allocator)
	defer output_destroy(&output, allocator)
	if !output_ok(&output) do return {}, output_message(&output, allocator), false
	return parse_status(string(output.stdout), allocator), "", true
}

parse_ignored :: proc(raw: string, allocator := context.allocator) -> [dynamic]string {
	ignored := make([dynamic]string, allocator)
	offset := 0
	for offset < len(raw) {
		field, next := nul_field(raw, offset)
		offset = next
		if !strings.has_prefix(field, "!! ") do continue
		path := strings.trim_right(field[3:], "/")
		if path != "" do append(&ignored, strings.clone(path, allocator))
	}
	return ignored
}

repo_ignored :: proc(repo: ^Git_Repo, allocator := context.allocator) -> ([dynamic]string, string, bool) {
	output := run(repo.root, []string{
		"status", "--porcelain", "-z", "--ignored=traditional", "--untracked-files=normal",
	}, allocator)
	defer output_destroy(&output, allocator)
	if !output_ok(&output) do return nil, output_message(&output, allocator), false
	return parse_ignored(string(output.stdout), allocator), "", true
}

ignored_destroy :: proc(paths: ^[dynamic]string) {
	for path in paths do delete(path)
	delete(paths^)
	paths^ = nil
}

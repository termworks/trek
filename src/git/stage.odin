package git

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Stage_Result :: struct {
	count:          int,
	skipped_nested: int,
}

path_under :: proc(path, prefix: string, has_prefix := true) -> bool {
	clean_path := strings.trim_right(path, "/")
	if !has_prefix do return true
	clean_prefix := strings.trim_right(prefix, "/")
	return clean_path == clean_prefix ||
	       (len(clean_path) > len(clean_prefix) && strings.has_prefix(clean_path, clean_prefix) && clean_path[len(clean_prefix)] == '/')
}

append_unique_path :: proc(paths: ^[dynamic]string, path: string, allocator: runtime.Allocator) {
	for existing in paths {
		if existing == path do return
	}
	append(paths, strings.clone(path, allocator))
}

paths_under :: proc(status: ^Status, prefix := "", has_prefix := false, allocator := context.allocator) -> [dynamic]string {
	paths := make([dynamic]string, allocator)
	for entry in status.unstaged {
		original_matches := entry.original != "" && path_under(entry.original, prefix, has_prefix)
		if !path_under(entry.path, prefix, has_prefix) && !original_matches do continue
		append_unique_path(&paths, entry.path, allocator)
		if entry.original != "" do append_unique_path(&paths, entry.original, allocator)
	}
	slice.sort_by(paths[:], proc(left, right: string) -> bool {return left < right})
	return paths
}

paths_destroy :: proc(paths: ^[dynamic]string) {
	for path in paths do delete(path)
	delete(paths^)
	paths^ = nil
}

contains_path :: proc(paths: []string, path: string) -> bool {
	for existing in paths {
		if existing == path do return true
	}
	return false
}

nested_roots_for :: proc(repo: ^Git_Repo, paths: []string, allocator := context.allocator) -> [dynamic]string {
	roots := make([dynamic]string, allocator)
	for path in paths {
		trimmed := strings.trim_right(path, "/")
		for end in 1 ..= len(trimmed) {
			if end < len(trimmed) && trimmed[end] != '/' do continue
			prefix := trimmed[:end]
			if contains_path(roots[:], prefix) do continue
			absolute := repo_abs(repo.root, prefix, allocator)
			git_path, _ := filepath.join([]string{absolute, ".git"}, allocator)
			info, err := os.stat(git_path, allocator)
			if err == nil {
				os.file_info_delete(info, allocator)
				append(&roots, strings.clone(prefix, allocator))
			}
			delete(git_path, allocator)
			delete(absolute, allocator)
		}
	}
	return roots
}

is_nested_path :: proc(path: string, roots: []string) -> bool {
	for root in roots {
		if path_under(path, root) do return true
	}
	return false
}

run_checked :: proc(repo: ^Git_Repo, args: []string, allocator := context.allocator) -> (string, bool) {
	output := run(repo.root, args, allocator)
	defer output_destroy(&output, allocator)
	if output_ok(&output) do return "", true
	return output_message(&output, allocator), false
}

repo_stage_entry :: proc(repo: ^Git_Repo, entry: ^File_Entry, allocator := context.allocator) -> (string, bool) {
	args := make([dynamic]string, 0, 6, allocator)
	defer delete(args)
	append(&args, "add", "-A", "--", entry.path)
	if entry.original != "" do append(&args, entry.original)
	return run_checked(repo, args[:], allocator)
}

stage_under :: proc(repo: ^Git_Repo, target: string, allocator := context.allocator) -> (Stage_Result, string, bool) {
	if target != repo.root && (!strings.has_prefix(target, repo.root) ||
	   len(target) <= len(repo.root) || !os.is_path_separator(target[len(repo.root)])) {
		return {}, strings.clone("target is outside repository", allocator), false
	}
	has_prefix := target != repo.root
	prefix := ""
	if has_prefix {
		relative, rel_error := filepath.rel(repo.root, target, allocator)
		if rel_error != .None do return {}, strings.clone("target is outside repository", allocator), false
		defer delete(relative, allocator)
		normalized, norm_error := filepath.replace_path_separators(relative, '/', allocator)
		if norm_error != nil do return {}, strings.clone("could not normalize target", allocator), false
		defer delete(normalized, allocator)
		prefix = normalized
		status, message, ok := repo_status(repo, allocator)
		if !ok do return {}, message, false
		defer status_destroy(&status)
		return stage_status_paths(repo, &status, prefix, true, allocator)
	}
	status, message, ok := repo_status(repo, allocator)
	if !ok do return {}, message, false
	defer status_destroy(&status)
	return stage_status_paths(repo, &status, "", false, allocator)
}

stage_status_paths :: proc(
	repo: ^Git_Repo,
	status: ^Status,
	prefix: string,
	has_prefix: bool,
	allocator := context.allocator,
) -> (Stage_Result, string, bool) {
	paths := paths_under(status, prefix, has_prefix, allocator)
	defer paths_destroy(&paths)
	nested := nested_roots_for(repo, paths[:], allocator)
	defer paths_destroy(&nested)
	stageable := make([dynamic]string, allocator)
	defer delete(stageable)
	result: Stage_Result
	for path in paths {
		if is_nested_path(path, nested[:]) {
			result.skipped_nested += 1
		} else {
			append(&stageable, path)
		}
	}
	for start := 0; start < len(stageable); start += 64 {
		end := min(start + 64, len(stageable))
		args := make([dynamic]string, 0, end - start + 3, allocator)
		append(&args, "add", "-A", "--")
		append(&args, ..stageable[start:end])
		message, ok := run_checked(repo, args[:], allocator)
		delete(args)
		if !ok do return result, message, false
	}
	result.count = len(stageable)
	return result, "", true
}

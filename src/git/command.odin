package git

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"

Output :: struct {
	stdout: []byte,
	stderr: []byte,
	state:  os.Process_State,
	error:  os.Error,
}

output_destroy :: proc(output: ^Output, allocator := context.allocator) {
	delete(output.stdout, allocator)
	delete(output.stderr, allocator)
	output^ = {}
}

output_ok :: proc(output: ^Output) -> bool {
	return output.error == nil && output.state.exited && output.state.success && output.state.exit_code == 0
}

output_message :: proc(output: ^Output, allocator := context.allocator) -> string {
	text := strings.trim_space(string(output.stderr))
	if text == "" do text = strings.trim_space(string(output.stdout))
	if text == "" do text = "git failed"
	if newline := strings.index_byte(text, '\n'); newline >= 0 do text = text[:newline]
	return strings.clone(text, allocator)
}

run :: proc(dir: string, args: []string, allocator := context.allocator) -> Output {
	command := make([dynamic]string, 0, len(args) + 3, context.allocator)
	defer delete(command)
	append(&command, "git", "-c", "color.ui=false")
	append(&command, ..args)
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{
		working_dir = dir,
		command = command[:],
	}, allocator)
	return Output{stdout = stdout, stderr = stderr, state = state, error = err}
}

Git_Repo :: struct {
	root:      string,
	allocator: runtime.Allocator,
}

repo_destroy :: proc(repo: ^Git_Repo) {
	delete(repo.root, repo.allocator)
	repo^ = {}
}

discover :: proc(dir: string, allocator := context.allocator) -> (Git_Repo, string, bool) {
	output := run(dir, []string{"rev-parse", "--show-toplevel"}, allocator)
	defer output_destroy(&output, allocator)
	if !output_ok(&output) {
		return {}, output_message(&output, allocator), false
	}
	root := strings.trim_space(string(output.stdout))
	if root == "" do return {}, strings.clone("not inside a git repository", allocator), false
	return Git_Repo{root = strings.clone(root, allocator), allocator = allocator}, "", true
}

owner_of :: proc(path: string, allocator := context.allocator) -> (Git_Repo, string, bool) {
	dir := path
	owned_dir := ""
	info, err := os.stat(path, allocator)
	if err == nil {
		if info.type != .Directory {
			owned_dir = filepath.dir(path, allocator)
			dir = owned_dir
		}
		os.file_info_delete(info, allocator)
	} else {
		owned_dir = filepath.dir(path, allocator)
		dir = owned_dir
	}
	defer if owned_dir != "" do delete(owned_dir, allocator)
	return discover(dir, allocator)
}

repos_destroy :: proc(repos: ^[dynamic]Git_Repo) {
	for &repo in repos do repo_destroy(&repo)
	delete(repos^)
	repos^ = nil
}

repo_list_contains :: proc(repos: []Git_Repo, root: string) -> bool {
	for repo in repos {
		if repo.root == root do return true
	}
	return false
}

discover_children :: proc(repos: ^[dynamic]Git_Repo, dir: string, depth: int, allocator: runtime.Allocator) {
	if depth <= 0 do return
	infos, err := os.read_all_directory_by_path(dir, allocator)
	if err != nil do return
	defer os.file_info_slice_delete(infos, allocator)
	for info in infos {
		if info.type != .Directory do continue
		if info.name == ".git" || info.name == "target" || info.name == "node_modules" do continue
		child, _ := filepath.join([]string{dir, info.name}, allocator)
		git_path, _ := filepath.join([]string{child, ".git"}, allocator)
		git_info, git_err := os.stat(git_path, allocator)
		if git_err == nil {
			os.file_info_delete(git_info, allocator)
			if repo, message, ok := discover(child, allocator); ok {
				if !repo_list_contains(repos[:], repo.root) {
					append(repos, repo)
				} else {
					repo_destroy(&repo)
				}
				delete(message, allocator)
			} else {
				delete(message, allocator)
			}
		}
		delete(git_path, allocator)
		discover_children(repos, child, depth - 1, allocator)
		delete(child, allocator)
	}
}

discover_all :: proc(dir: string, depth := 2, allocator := context.allocator) -> [dynamic]Git_Repo {
	repos := make([dynamic]Git_Repo, allocator)
	if repo, message, ok := discover(dir, allocator); ok {
		append(&repos, repo)
		delete(message, allocator)
	} else {
		delete(message, allocator)
	}
	discover_children(&repos, dir, depth, allocator)
	return repos
}

repo_abs :: proc(root, relative: string, allocator := context.allocator) -> string {
	parts := strings.split(strings.trim_right(relative, "/"), "/", allocator)
	defer delete(parts, allocator)
	all := make([dynamic]string, 0, len(parts) + 1, allocator)
	defer delete(all)
	append(&all, root)
	for part in parts {
		if part != "" do append(&all, part)
	}
	path, _ := filepath.join(all[:], allocator)
	return path
}

package git

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

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

// trek runs git from an interactive loop with nothing else driving the screen, so a
// git that never returns freezes the whole application with no way out. A commit
// hook is the realistic case: it can block on a lock, or on input it will never get.
GIT_TIMEOUT :: 10 * time.Second

// Poll interval while a command is in flight. Short enough that a fast git is not
// noticeably delayed, long enough that waiting is not a spin.
GIT_POLL :: 2 * time.Millisecond

// Refuse to accumulate an unbounded amount of output. `git log` on a large history
// runs to megabytes, and none of trek's callers can use more than this.
GIT_MAX_OUTPUT :: 16 * 1024 * 1024

@(private = "file")
drain_pipe :: proc(reader: ^os.File, sink: ^[dynamic]byte) -> bool {
	moved := false
	scratch: [4096]byte
	for {
		has_data, has_err := os.pipe_has_data(reader)
		if has_err != nil || !has_data do break
		count, read_err := os.read(reader, scratch[:])
		if count <= 0 || read_err != nil do break
		if len(sink) < GIT_MAX_OUTPUT do append(sink, ..scratch[:count])
		moved = true
	}
	return moved
}

// Run git with a deadline. Output is drained while the command runs: a pipe holds
// only ~64KiB, so a caller that waits first and reads afterwards deadlocks against
// any command that produces more than that.
run :: proc(dir: string, args: []string, allocator := context.allocator, timeout := GIT_TIMEOUT) -> Output {
	command := make([dynamic]string, 0, len(args) + 3, context.allocator)
	defer delete(command)
	append(&command, "git", "-c", "color.ui=false")
	append(&command, ..args)

	stdout_r, stdout_w, stdout_err := os.pipe()
	if stdout_err != nil do return Output{error = stdout_err}
	stderr_r, stderr_w, stderr_err := os.pipe()
	if stderr_err != nil {
		os.close(stdout_r)
		os.close(stdout_w)
		return Output{error = stderr_err}
	}

	// stdin is closed, not inherited: a hook that prompts then reads EOF and fails
	// instead of waiting on a terminal trek is already drawing over.
	process, start_err := os.process_start(os.Process_Desc{
		working_dir = dir,
		command = command[:],
		stdout = stdout_w,
		stderr = stderr_w,
	})
	// The parent's write ends must close here or the readers never see EOF.
	os.close(stdout_w)
	os.close(stderr_w)
	if start_err != nil {
		os.close(stdout_r)
		os.close(stderr_r)
		return Output{error = start_err}
	}

	out := make([dynamic]byte, allocator)
	errs := make([dynamic]byte, allocator)
	started := time.now()
	state: os.Process_State
	timed_out := false
	for {
		moved := drain_pipe(stdout_r, &out)
		moved |= drain_pipe(stderr_r, &errs)
		polled, wait_err := os.process_wait(process, 0)
		if wait_err == nil && polled.exited {
			state = polled
			break
		}
		if time.since(started) >= timeout {
			_ = os.process_kill(process)
			state, _ = os.process_wait(process)
			timed_out = true
			break
		}
		if !moved do time.sleep(GIT_POLL)
	}
	drain_pipe(stdout_r, &out)
	drain_pipe(stderr_r, &errs)
	os.close(stdout_r)
	os.close(stderr_r)


	result := Output{stdout = out[:], stderr = errs[:], state = state}
	if timed_out {
		result.error = .Timeout
		clear(&errs)
		append(&errs, ..transmute([]byte)string("git timed out"))
		result.stderr = errs[:]
	}
	return result
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

package git

import "base:runtime"
import "core:strconv"
import "core:strings"


Commit :: struct {
	hash:      string,
	parents:   [dynamic]string,
	refs:      [dynamic]string,
	author:    string,
	timestamp: i64,
	subject:   string,
	// git's own default %ad rendering, so the date reads exactly as `git tree` shows it.
	date:      string,
}

History :: struct {
	commits:   [dynamic]Commit,
	allocator: runtime.Allocator,
}

commit_destroy :: proc(commit: ^Commit) {
	delete(commit.hash)
	for parent in commit.parents do delete(parent)
	for ref in commit.refs do delete(ref)
	delete(commit.parents)
	delete(commit.refs)
	delete(commit.author)
	delete(commit.subject)
	delete(commit.date)
	commit^ = {}
}

history_destroy :: proc(history: ^History) {
	for &commit in history.commits do commit_destroy(&commit)
	delete(history.commits)
	history^ = {}
}

split_owned :: proc(value, separator: string, allocator: runtime.Allocator) -> [dynamic]string {
	result := make([dynamic]string, allocator)
	parts := strings.split(value, separator, allocator)
	defer delete(parts, allocator)
	for part in parts {
		clean := strings.trim_space(part)
		if clean != "" do append(&result, strings.clone(clean, allocator))
	}
	return result
}

parse_log :: proc(raw: string, allocator := context.allocator) -> History {
	history := History{commits = make([dynamic]Commit, allocator), allocator = allocator}
	offset := 0
	for offset < len(raw) {
		fields: [7]string
		complete := true
		for index in 0 ..< len(fields) {
			if offset >= len(raw) {
				complete = false
				break
			}
			fields[index], offset = nul_field(raw, offset)
		}
		if !complete do break
		hash := strings.trim_left(fields[0], "\r\n")
		if hash == "" do continue
		timestamp, _ := strconv.parse_i64(strings.trim_space(fields[4]))
		append(&history.commits, Commit{
			hash = strings.clone(hash, allocator),
			parents = split_owned(fields[1], " ", allocator),
			refs = split_owned(fields[2], ",", allocator),
			author = strings.clone(fields[3], allocator),
			timestamp = timestamp,
			date = strings.clone(strings.trim_space(fields[5]), allocator),
			subject = strings.clone(fields[6], allocator),
		})
	}
	return history
}

// --topo-order, not --date-order: `git log --graph` implies topological order, and the
// lane layout is a function of the order commits arrive in. Feeding the engine a
// different order draws a different -- and correct-looking -- wrong picture.
repo_history :: proc(repo: ^Git_Repo, allocator := context.allocator) -> (History, string, bool) {
	output := run(repo.root, []string{"log", "--all", "--parents", "--topo-order", "--pretty=format:%H%x00%P%x00%D%x00%an%x00%at%x00%ad%x00%s%x00"}, allocator)
	defer output_destroy(&output, allocator)
	if !output_ok(&output) do return {}, output_message(&output, allocator), false
	return parse_log(string(output.stdout), allocator), "", true
}


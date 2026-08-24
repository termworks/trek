package tabs

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
import gitcore "../git"
import model "../model"
import tui "../tui"

Changes_Repo :: struct {
	repo:    gitcore.Git_Repo,
	status:  gitcore.Status,
	message: [dynamic]byte,
}

Changes_Tab :: struct {
	root:      string,
	repos:     [dynamic]Changes_Repo,
	allocator: runtime.Allocator,
}

changes_repo_destroy :: proc(view: ^Changes_Repo) {
	gitcore.repo_destroy(&view.repo)
	gitcore.status_destroy(&view.status)
	delete(view.message)
	view^ = {}
}

changes_clear :: proc(state: ^Changes_Tab) {
	for &view in state.repos do changes_repo_destroy(&view)
	delete(state.repos)
	state.repos = nil
}

changes_take_message :: proc(old: ^[dynamic]Changes_Repo, root: string, allocator: runtime.Allocator) -> [dynamic]byte {
	for &view in old {
		if view.repo.root == root {
			message := view.message
			view.message = nil
			return message
		}
	}
	return make([dynamic]byte, allocator)
}

changes_refresh :: proc(state: ^Changes_Tab) {
	old := state.repos
	state.repos = make([dynamic]Changes_Repo, state.allocator)
	repos := gitcore.discover_all(state.root, allocator = state.allocator)
	for &repo in repos {
		status, message, ok := gitcore.repo_status(&repo, state.allocator)
		delete(message)
		if !ok {
			gitcore.repo_destroy(&repo)
			continue
		}
		append(&state.repos, Changes_Repo{
			repo = repo,
			status = status,
			message = changes_take_message(&old, repo.root, state.allocator),
		})
		repo = {}
	}
	delete(repos)
	for &view in old do changes_repo_destroy(&view)
	delete(old)
}

changes_new :: proc(root: string, allocator := context.allocator) -> ^Changes_Tab {
	state := new(Changes_Tab, allocator)
	state.root = strings.clone(root, allocator)
	state.allocator = allocator
	changes_refresh(state)
	return state
}

changes_row_id :: proc(format: string, args: ..any, allocator := context.allocator) -> string {
	return fmt.aprintf(format, ..args, allocator = allocator)
}

changes_entry_node :: proc(entry: ^gitcore.File_Entry, allocator: runtime.Allocator) -> tui.Node {
	return tui.row([]tui.Node{
		tui.text("  "),
		tui.text(status_text(entry.letter), status_style(entry.letter)),
		tui.text(" "),
		tui.priority(tui.truncate(tui.text(entry.path), 0), 0, allocator),
		tui.spacer(),
		tui.transparent(2),
	}, allocator)
}

changes_append_entry :: proc(
	rows: ^[dynamic]Row,
	entry: ^gitcore.File_Entry,
	repo_index, entry_index: int,
	staged: bool,
	allocator: runtime.Allocator,
) {
	id := changes_row_id("entry:%d:%s:%s", repo_index, staged ? "staged" : "changed", entry.path, allocator = allocator)
	append(rows, Row{
		id = id,
		path = id,
		selectable = true,
		height = 1,
		kind = .Git_Entry,
		repo_index = repo_index,
		entry_index = entry_index,
		staged = staged,
		node = changes_entry_node(entry, allocator),
	})
}

changes_rows_proc :: proc(data: rawptr, allocator: runtime.Allocator) -> [dynamic]Row {
	state := (^Changes_Tab)(data)
	rows := make([dynamic]Row, allocator)
	if len(state.repos) == 0 {
		id := strings.clone(" No Git repositories found", allocator)
		append(&rows, Row{id = id, path = id, selectable = false, height = 1, node = tui.text(id)})
		return rows
	}
	for &view, repo_index in state.repos {
		name := filepath.base(view.repo.root)
		header := changes_row_id(" %s  %s", name, view.status.branch, allocator = allocator)
		append(&rows, Row{
			id = header,
			path = header,
			selectable = false,
			height = 1,
			kind = .Repo_Header,
			repo_index = repo_index,
			node = tui.text(header, tui.Style{attrs = {.Bold}}),
		})
		commit_id := changes_row_id("commit:%d:%s", repo_index, view.repo.root, allocator = allocator)
		commit_value := string(view.message[:])
		commit_node := tui.column([]tui.Node{
			tui.text(" Commit message", tui.Style{attrs = {.Dim}}),
			tui.row([]tui.Node{
				tui.text(" > "),
				tui.priority(tui.truncate(tui.text(commit_value), 0), 0, allocator),
				tui.spacer(),
				tui.transparent(2),
			}, allocator),
		}, allocator)
		append(&rows, Row{
			id = commit_id,
			path = commit_id,
			selectable = true,
			height = 2,
			kind = .Commit_Box,
			repo_index = repo_index,
			node = commit_node,
		})
		staged_header := changes_row_id(" Staged  %d", len(view.status.staged), allocator = allocator)
		append(&rows, Row{
			id = staged_header,
			path = staged_header,
			selectable = false,
			height = 1,
			kind = .Section_Header,
			repo_index = repo_index,
			node = tui.text(staged_header, tui.Style{attrs = {.Bold}}),
		})
		for &entry, entry_index in view.status.staged {
			changes_append_entry(&rows, &entry, repo_index, entry_index, true, allocator)
		}
		changes_header := changes_row_id(" Changes  %d", len(view.status.unstaged), allocator = allocator)
		append(&rows, Row{
			id = changes_header,
			path = changes_header,
			selectable = false,
			height = 1,
			kind = .Section_Header,
			repo_index = repo_index,
			node = tui.text(changes_header, tui.Style{attrs = {.Bold}}),
		})
		for &entry, entry_index in view.status.unstaged {
			changes_append_entry(&rows, &entry, repo_index, entry_index, false, allocator)
		}
	}
	return rows
}

changes_view :: proc(state: ^Changes_Tab, row: ^Row) -> ^Changes_Repo {
	if row == nil || row.repo_index < 0 || row.repo_index >= len(state.repos) do return nil
	return &state.repos[row.repo_index]
}

changes_entry :: proc(view: ^Changes_Repo, row: ^Row) -> ^gitcore.File_Entry {
	if view == nil || row == nil || row.kind != .Git_Entry do return nil
	if row.staged {
		if row.entry_index >= 0 && row.entry_index < len(view.status.staged) do return &view.status.staged[row.entry_index]
	} else {
		if row.entry_index >= 0 && row.entry_index < len(view.status.unstaged) do return &view.status.unstaged[row.entry_index]
	}
	return nil
}

changes_operation_result :: proc(state: ^Changes_Tab, message: string, ok: bool, success: string) -> Tab_Result {
	delete(message)
	if !ok do return Tab_Result{message = "Git operation failed"}
	changes_refresh(state)
	return Tab_Result{rows_changed = true, message = success}
}

changes_commit :: proc(state: ^Changes_Tab, view: ^Changes_Repo) -> Tab_Result {
	if view == nil do return {}
	message, ok := gitcore.repo_commit(&view.repo, string(view.message[:]), state.allocator)
	if ok do clear(&view.message)
	return changes_operation_result(state, message, ok, "committed")
}

changes_select_proc :: proc(data: rawptr, selected: ^Row) -> Tab_Result {
	state := (^Changes_Tab)(data)
	view := changes_view(state, selected)
	if selected == nil do return {}
	if selected.kind == .Commit_Box do return changes_commit(state, view)
	entry := changes_entry(view, selected)
	if entry == nil do return {}
	if selected.staged {
		message, ok := gitcore.repo_unstage_entry(&view.repo, entry, state.allocator)
		return changes_operation_result(state, message, ok, "changes unstaged")
	}
	message, ok := gitcore.repo_stage_entry(&view.repo, entry, state.allocator)
	return changes_operation_result(state, message, ok, "changes staged")
}

changes_backspace :: proc(message: ^[dynamic]byte) {
	if len(message^) == 0 do return
	_, width := utf8.decode_last_rune(string(message^[:]))
	n := min(width, len(message^))
	for _ in 0 ..< n do ordered_remove(message, len(message^) - 1)
}

changes_append_rune :: proc(message: ^[dynamic]byte, value: rune) {
	encoded, count := utf8.encode_rune(value)
	append(message, ..encoded[:count])
}

changes_key_proc :: proc(data: rawptr, key: tui.Key, selected: ^Row) -> Tab_Result {
	state := (^Changes_Tab)(data)
	view := changes_view(state, selected)
	if selected != nil && selected.kind == .Commit_Box && view != nil {
		if key.code == .Backspace {
			changes_backspace(&view.message)
			return Tab_Result{rows_changed = true}
		}
		if key.code == .Rune && key.modifiers == {} {
			changes_append_rune(&view.message, key.rune)
			return Tab_Result{rows_changed = true}
		}
		return {}
	}
	if key.code != .Rune do return {}
	switch key.rune {
	case 'q': return Tab_Result{quit = true}
	case 'r':
		changes_refresh(state)
		return Tab_Result{rows_changed = true, message = "changes refreshed"}
	case 'm':
		return Tab_Result{open_menu = selected != nil && selected.kind == .Git_Entry}
	case 'a':
		if view == nil do return {}
		message, ok := gitcore.repo_stage_all(&view.repo, state.allocator)
		return changes_operation_result(state, message, ok, "all changes staged")
	case 'u':
		if view == nil do return {}
		message, ok := gitcore.repo_unstage_all(&view.repo, state.allocator)
		return changes_operation_result(state, message, ok, "all changes unstaged")
	}
	return {}
}

changes_menu_proc :: proc(data: rawptr, selected: ^Row) -> []model.Menu_Entry {
	if selected == nil || selected.kind != .Git_Entry do return nil
	if selected.staged do return model.CHANGES_STAGED_MENU[:]
	return model.CHANGES_UNSTAGED_MENU[:]
}

changes_action_proc :: proc(data: rawptr, selected: ^Row, action: model.Action, value: string) -> Tab_Result {
	state := (^Changes_Tab)(data)
	view := changes_view(state, selected)
	if view == nil do return {}
	entry := changes_entry(view, selected)
	#partial switch action {
	case .Stage_Changes:
		if entry == nil do return {}
		message, ok := gitcore.repo_stage_entry(&view.repo, entry, state.allocator)
		return changes_operation_result(state, message, ok, "changes staged")
	case .Unstage_Changes:
		if entry == nil do return {}
		message, ok := gitcore.repo_unstage_entry(&view.repo, entry, state.allocator)
		return changes_operation_result(state, message, ok, "changes unstaged")
	case .Discard_Changes:
		if entry == nil do return {}
		message, ok := gitcore.repo_discard(&view.repo, entry, state.allocator)
		return changes_operation_result(state, message, ok, "changes discarded")
	case .Commit:
		if value != "" {
			clear(&view.message)
			append(&view.message, ..transmute([]byte)(value))
		}
		return changes_commit(state, view)
	}
	return {}
}

changes_focus_proc :: proc(data: rawptr) -> Tab_Result {
	changes_refresh((^Changes_Tab)(data))
	return Tab_Result{rows_changed = true}
}

changes_paste_proc :: proc(data: rawptr, value: string, selected: ^Row) -> Tab_Result {
	state := (^Changes_Tab)(data)
	if selected == nil || selected.kind != .Commit_Box do return {}
	view := changes_view(state, selected)
	if view == nil do return {}
	append(&view.message, ..transmute([]byte)(value))
	return Tab_Result{rows_changed = true}
}

changes_destroy_proc :: proc(data: rawptr) {
	state := (^Changes_Tab)(data)
	allocator := state.allocator
	changes_clear(state)
	delete(state.root)
	free(state, allocator)
}

changes_root_proc :: proc(data: rawptr, root: string) -> Tab_Result {
	state := (^Changes_Tab)(data)
	delete(state.root)
	state.root = strings.clone(root, state.allocator)
	changes_refresh(state)
	return Tab_Result{rows_changed = true}
}

changes_tab :: proc(root: string, allocator := context.allocator) -> Tab {
	state := changes_new(root, allocator)
	return Tab{
		name = "changes",
		title = "Changes",
		icon = "±",
		data = state,
		rows = changes_rows_proc,
		on_key = changes_key_proc,
		on_select = changes_select_proc,
		menu = changes_menu_proc,
		action = changes_action_proc,
		destroy = changes_destroy_proc,
		on_focus = changes_focus_proc,
		on_paste = changes_paste_proc,
		on_root = changes_root_proc,
	}
}

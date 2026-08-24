package tabs

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
import gitcore "../git"
import model "../model"
import tui "../tui"

// One repository, three lists and a commit box. Enter moves a file between
// unstaged and staged; that plus committing is the whole tab.
Changes_Section :: enum {
	New,
	Modified,
	Staged,
}

Changes_Tab :: struct {
	root:      string,
	repo:      gitcore.Git_Repo,
	status:    gitcore.Status,
	message:   [dynamic]byte,
	theme:     model.Icon_Theme,
	has_repo:  bool,
	allocator: runtime.Allocator,
}

changes_clear :: proc(state: ^Changes_Tab) {
	if state.has_repo {
		gitcore.repo_destroy(&state.repo)
		gitcore.status_destroy(&state.status)
	}
	state.has_repo = false
}

changes_refresh :: proc(state: ^Changes_Tab) {
	changes_clear(state)
	repo, discover_output, found := gitcore.discover(state.root, state.allocator)
	delete(discover_output)
	if !found do return
	state.repo = repo
	status, status_output, ok := gitcore.repo_status(&repo, state.allocator)
	delete(status_output)
	if !ok {
		gitcore.repo_destroy(&state.repo)
		return
	}
	state.status = status
	state.has_repo = true
}

changes_new :: proc(root: string, theme := model.Icon_Theme.Emoji, allocator := context.allocator) -> ^Changes_Tab {
	state := new(Changes_Tab, allocator)
	state.allocator = allocator
	state.root = strings.clone(root, allocator)
	state.theme = theme
	state.message = make([dynamic]byte, allocator)
	changes_refresh(state)
	return state
}

changes_row_id :: proc(format: string, args: ..any, allocator := context.allocator) -> string {
	return fmt.aprintf(format, ..args, allocator = allocator)
}

changes_owned_text :: proc(value: string, style := tui.PLAIN_STYLE) -> tui.Node {
	return tui.text(value, style)
}

// Untracked files are the New list; everything else unstaged is Modified.
changes_is_new :: proc(entry: gitcore.File_Entry) -> bool {
	return entry.letter == 'U'
}

changes_section_node :: proc(title: string, count: int, allocator: runtime.Allocator) -> tui.Node {
	badge := fmt.aprintf(" %d", count, allocator = allocator)
	return tui.row([]tui.Node{
		tui.text(" "),
		tui.text(title, tui.Style{fg = tui.RAMP_TEXT, attrs = {.Bold}}),
		changes_owned_text(badge, tui.Style{fg = tui.RAMP_FAINT}),
		tui.spacer(),
	}, allocator)
}

changes_entry_node :: proc(state: ^Changes_Tab, entry: ^gitcore.File_Entry, allocator: runtime.Allocator) -> tui.Node {
	name := filepath.base(entry.path)
	dir := filepath.dir(entry.path, allocator)
	if dir == "." {
		delete(dir)
		dir = ""
	}
	icon := model.file_icon(state.theme, name, false, false)
	children := make([dynamic]tui.Node, allocator)
	defer delete(children)
	append(&children, tui.text("   "))
	append(&children, tui.text(tree_git_glyph(entry.letter), tui.merge_style(status_style(entry.letter), tui.Style{attrs = {.Bold}})))
	append(&children, tui.text(" "))
	append(&children, tui.text(icon.glyph, tree_icon_style(icon)))
	append(&children, tui.text(" "))
	append(&children, tui.text(name))
	if dir != "" {
		append(&children, tui.text(" "))
		append(&children, tui.priority(tui.truncate(changes_owned_text(dir, tui.Style{fg = tui.RAMP_FAINT, attrs = {.Dim}}), 0), 0, allocator))
	}
	append(&children, tui.spacer())
	append(&children, tui.transparent(2))
	return tui.row(children[:], allocator)
}

changes_message_node :: proc(state: ^Changes_Tab, allocator: runtime.Allocator) -> tui.Node {
	border := tui.Style{fg = tui.RAMP_BORDER, attrs = {.Dim}}
	message := string(state.message[:])
	content := tui.text(message)
	if message == "" {
		content = changes_owned_text("Commit message", tui.Style{fg = tui.RAMP_FAINT, attrs = {.Dim, .Italic}})
	}
	return tui.column([]tui.Node{
		tui.row([]tui.Node{tui.text("┌", border), tui.fill('─', border), tui.text("┐", border)}, allocator),
		tui.row([]tui.Node{
			tui.text("│", border),
			tui.priority(tui.truncate(content, 0), 0, allocator),
			tui.spacer(),
			tui.text("│", border),
		}, allocator),
		tui.row([]tui.Node{tui.text("└", border), tui.fill('─', border), tui.text("┘", border)}, allocator),
	}, allocator)
}

changes_commit_node :: proc(state: ^Changes_Tab, allocator: runtime.Allocator) -> tui.Node {
	label := fmt.aprintf(" Commit %d staged ", len(state.status.staged), allocator = allocator)
	style := tui.Style{fg = tui.BUTTON_FG, bg = tui.BUTTON_BG, attrs = {.Bold}}
	if len(state.status.staged) == 0 do style = tui.Style{fg = tui.RAMP_FAINT, attrs = {.Dim}}
	return tui.row([]tui.Node{
		tui.spacer(),
		tui.styled(changes_owned_text(label), style, allocator),
		tui.spacer(),
	}, allocator)
}

changes_append_section :: proc(
	state: ^Changes_Tab,
	rows: ^[dynamic]Row,
	section: Changes_Section,
	title: string,
	entries: []gitcore.File_Entry,
	allocator: runtime.Allocator,
) {
	if len(entries) == 0 do return
	header := changes_row_id("section:%v", section, allocator = allocator)
	append(rows, Row{
		id = header,
		path = header,
		selectable = false,
		height = 1,
		kind = .Section_Header,
		node = changes_section_node(title, len(entries), allocator),
	})
	for &entry in entries {
		id := changes_row_id("entry:%v:%s", section, entry.path, allocator = allocator)
		append(rows, Row{
			id = id,
			path = strings.clone(entry.path, allocator),
			selectable = true,
			height = 1,
			kind = .Git_Entry,
			staged = section == .Staged,
			node = changes_entry_node(state, &entry, allocator),
		})
	}
}

changes_rows_proc :: proc(data: rawptr, allocator: runtime.Allocator) -> [dynamic]Row {
	state := (^Changes_Tab)(data)
	rows := make([dynamic]Row, allocator)
	if !state.has_repo {
		id := strings.clone(" Not a git repository", allocator)
		append(&rows, Row{id = id, path = id, selectable = false, height = 1, node = tui.text(id, tui.Style{fg = tui.RAMP_FAINT, attrs = {.Dim}})})
		return rows
	}
	fresh := make([dynamic]gitcore.File_Entry, allocator)
	changed := make([dynamic]gitcore.File_Entry, allocator)
	defer delete(fresh)
	defer delete(changed)
	for entry in state.status.unstaged {
		if changes_is_new(entry) {
			append(&fresh, entry)
		} else {
			append(&changed, entry)
		}
	}
	changes_append_section(state, &rows, .New, "NEW", fresh[:], allocator)
	changes_append_section(state, &rows, .Modified, "MODIFIED", changed[:], allocator)
	changes_append_section(state, &rows, .Staged, "STAGED", state.status.staged[:], allocator)
	if len(rows) == 0 {
		id := strings.clone(" Working tree clean", allocator)
		append(&rows, Row{id = id, path = id, selectable = false, height = 1, node = tui.text(id, tui.Style{fg = tui.RAMP_FAINT, attrs = {.Dim}})})
	}
	spacer_id := changes_row_id("spacer", allocator = allocator)
	append(&rows, Row{id = spacer_id, path = spacer_id, selectable = false, height = 1, node = tui.text("")})
	box_id := changes_row_id("message", allocator = allocator)
	append(&rows, Row{
		id = box_id,
		path = box_id,
		selectable = true,
		height = 3,
		kind = .Commit_Box,
		input_value = string(state.message[:]),
		node = changes_message_node(state, allocator),
	})
	button_id := changes_row_id("commit", allocator = allocator)
	append(&rows, Row{
		id = button_id,
		path = button_id,
		selectable = true,
		height = 1,
		kind = .Commit_Button,
		node = changes_commit_node(state, allocator),
	})
	return rows
}

// The selected row's entry, looked up by path in whichever list it belongs to.
changes_entry :: proc(state: ^Changes_Tab, row: ^Row) -> ^gitcore.File_Entry {
	if row == nil || row.kind != .Git_Entry do return nil
	list := row.staged ? &state.status.staged : &state.status.unstaged
	for &entry in list {
		if entry.path == row.path do return &entry
	}
	return nil
}

changes_operation_result :: proc(state: ^Changes_Tab, message: string, ok: bool, success: string) -> Tab_Result {
	if !ok do return Tab_Result{message = message}
	delete(message)
	changes_refresh(state)
	return Tab_Result{rows_changed = true, message = success}
}

// Enter on a file moves it across: unstaged becomes staged, staged goes back.
changes_toggle :: proc(state: ^Changes_Tab, row: ^Row) -> Tab_Result {
	entry := changes_entry(state, row)
	if entry == nil do return Tab_Result{}
	if row.staged {
		output, ok := gitcore.repo_unstage_entry(&state.repo, entry, state.allocator)
		return changes_operation_result(state, output, ok, "unstaged")
	}
	output, ok := gitcore.repo_stage_entry(&state.repo, entry, state.allocator)
	return changes_operation_result(state, output, ok, "staged")
}

changes_commit :: proc(state: ^Changes_Tab) -> Tab_Result {
	if !state.has_repo do return Tab_Result{}
	if len(state.status.staged) == 0 do return Tab_Result{message = "nothing staged"}
	message := strings.trim_space(string(state.message[:]))
	if message == "" do return Tab_Result{message = "commit message is empty"}
	output, ok := gitcore.repo_commit(&state.repo, message, state.allocator)
	if !ok do return Tab_Result{message = output}
	delete(output)
	clear(&state.message)
	changes_refresh(state)
	return Tab_Result{rows_changed = true, message = "committed"}
}

changes_select_proc :: proc(data: rawptr, selected: ^Row) -> Tab_Result {
	state := (^Changes_Tab)(data)
	if selected == nil do return Tab_Result{}
	#partial switch selected.kind {
	case .Git_Entry: return changes_toggle(state, selected)
	case .Commit_Button: return changes_commit(state)
	}
	return Tab_Result{}
}

changes_backspace :: proc(message: ^[dynamic]byte) {
	if len(message) == 0 do return
	text := string(message[:])
	_, width := utf8.decode_last_rune(transmute([]byte)text)
	resize(message, len(message) - width)
}

changes_append_rune :: proc(message: ^[dynamic]byte, value: rune) {
	bytes, width := utf8.encode_rune(value)
	append(message, ..bytes[:width])
}

changes_key_proc :: proc(data: rawptr, key: tui.Key, selected: ^Row) -> Tab_Result {
	state := (^Changes_Tab)(data)
	if selected != nil && selected.kind == .Commit_Box {
		#partial switch key.code {
		case .Enter: return changes_commit(state)
		case .Backspace:
			changes_backspace(&state.message)
			return Tab_Result{rows_changed = true}
		case .Rune:
			changes_append_rune(&state.message, key.rune)
			return Tab_Result{rows_changed = true}
		}
		return Tab_Result{}
	}
	if key.code == .Rune && key.rune == 'r' {
		changes_refresh(state)
		return Tab_Result{rows_changed = true, message = "refreshed"}
	}
	return Tab_Result{}
}

changes_menu_proc :: proc(data: rawptr, selected: ^Row) -> []model.Menu_Entry {
	return nil
}

changes_action_proc :: proc(data: rawptr, selected: ^Row, action: model.Action, value: string) -> Tab_Result {
	return Tab_Result{}
}

changes_focus_proc :: proc(data: rawptr) -> Tab_Result {
	state := (^Changes_Tab)(data)
	changes_refresh(state)
	return Tab_Result{rows_changed = true}
}

changes_paste_proc :: proc(data: rawptr, value: string, selected: ^Row) -> Tab_Result {
	state := (^Changes_Tab)(data)
	if selected == nil || selected.kind != .Commit_Box do return Tab_Result{}
	append(&state.message, ..transmute([]byte)value)
	return Tab_Result{rows_changed = true}
}

changes_destroy_proc :: proc(data: rawptr) {
	state := (^Changes_Tab)(data)
	changes_clear(state)
	delete(state.message)
	delete(state.root)
	free(state, state.allocator)
}

changes_root_proc :: proc(data: rawptr, root: string) -> Tab_Result {
	state := (^Changes_Tab)(data)
	delete(state.root)
	state.root = strings.clone(root, state.allocator)
	changes_refresh(state)
	return Tab_Result{rows_changed = true}
}

changes_heading_proc :: proc(data: rawptr) -> Tab_Heading {
	state := (^Changes_Tab)(data)
	if !state.has_repo do return Tab_Heading{title = "Changes"}
	return Tab_Heading{title = "Changes", detail = state.status.branch}
}

changes_theme_proc :: proc(data: rawptr, theme: model.Icon_Theme) {
	state := (^Changes_Tab)(data)
	state.theme = theme
}

changes_tab :: proc(root: string, theme := model.Icon_Theme.Emoji, allocator := context.allocator) -> Tab {
	state := changes_new(root, theme, allocator)
	return Tab{
		name = "changes",
		title = "Changes",
		icon = "",
		data = rawptr(state),
		rows = changes_rows_proc,
		on_select = changes_select_proc,
		on_key = changes_key_proc,
		menu = changes_menu_proc,
		action = changes_action_proc,
		on_focus = changes_focus_proc,
		on_paste = changes_paste_proc,
		destroy = changes_destroy_proc,
		on_root = changes_root_proc,
		heading = changes_heading_proc,
		set_theme = changes_theme_proc,
	}
}

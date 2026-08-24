package tabs

import "base:runtime"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import gitcore "../git"
import model "../model"
import tui "../tui"

Tree_Tab :: struct {
	tree:        model.Tree,
	theme:       model.Icon_Theme,
	repos:       [dynamic]gitcore.Git_Repo,
	decorations: gitcore.Decorations,
	git_decorations: bool,
}

tree_tab_new :: proc(
	root: string,
	theme := model.Icon_Theme.Emoji,
	show_hidden := false,
	git_decorations := true,
	allocator := context.allocator,
) -> ^Tree_Tab {
	state := new(Tree_Tab, allocator)
	model.tree_init(&state.tree, root, allocator)
	state.theme = theme
	state.tree.show_hidden = show_hidden
	state.git_decorations = git_decorations
	gitcore.decorations_init(&state.decorations, allocator)
	tree_git_refresh(state)
	return state
}

tree_git_refresh :: proc(state: ^Tree_Tab) {
	gitcore.repos_destroy(&state.repos)
	gitcore.decorations_destroy(&state.decorations)
	gitcore.decorations_init(&state.decorations, state.tree.allocator)
	if !state.git_decorations do return
	state.repos = gitcore.discover_all(state.tree.root, allocator = state.tree.allocator)
	for &repo in state.repos {
		status, status_message, ok := gitcore.repo_status(&repo, state.tree.allocator)
		delete(status_message)
		if !ok do continue
		ignored, ignored_message, have_ignored := gitcore.repo_ignored(&repo, state.tree.allocator)
		delete(ignored_message)
		if have_ignored {
			gitcore.decorations_add_status(&state.decorations, repo.root, &status, ignored[:])
			gitcore.ignored_destroy(&ignored)
		} else {
			gitcore.decorations_add_status(&state.decorations, repo.root, &status)
		}
		gitcore.status_destroy(&status)
	}
}

tree_icon_style :: proc(icon: model.Icon) -> tui.Style {
	if !icon.colored do return tui.PLAIN_STYLE
	return tui.Style{fg = tui.rgb(icon.r, icon.g, icon.b), bg = tui.DEFAULT_COLOR}
}

status_style :: proc(letter: rune) -> tui.Style {
	style := tui.Style{fg = tui.status_color(letter), bg = tui.DEFAULT_COLOR}
	if letter == 'I' do style.attrs = {.Dim}
	return style
}

status_text :: proc(letter: rune) -> string {
	switch letter {
	case 'M': return "M"
	case 'U': return "U"
	case 'A': return "A"
	case 'R': return "R"
	case 'C': return "C"
	case 'D': return "D"
	case '!': return "!"
	}
	return ""
}

tree_row_node :: proc(
	state: ^Tree_Tab,
	row: ^model.Tree_Row,
	letter: rune,
	has_status: bool,
	allocator: runtime.Allocator,
) -> tui.Node {
	chevron := "  "
	if row.is_dir {
		if row.expanded {
			chevron = "▾ "
		} else {
			chevron = "▸ "
		}
	}
	icon := model.file_icon(state.theme, row.name, row.is_dir, row.expanded)
	name_style := tui.PLAIN_STYLE
	if has_status do name_style = status_style(letter)
	marker := ""
	if has_status && letter != 'I' {
		if row.is_dir {
			marker = "●"
		} else {
			marker = status_text(letter)
		}
	}
	content := tui.row([]tui.Node{
		tui.transparent(row.depth * 2),
		tui.text(chevron, tui.Style{attrs = {.Dim}}),
		tui.text(icon.glyph, tree_icon_style(icon)),
		tui.text(" "),
		tui.priority(tui.truncate(tui.text(row.name, name_style), 0), 0, allocator),
		tui.spacer(),
		tui.text(marker, tui.merge_style(status_style(letter), tui.Style{attrs = {.Bold}})),
		tui.transparent(2),
	}, allocator)
	return tui.region(content, row.path, []string{"open", "menu"}, allocator = allocator)
}

tree_rows_proc :: proc(data: rawptr, allocator: runtime.Allocator) -> [dynamic]Row {
	state := (^Tree_Tab)(data)
	model_rows := model.tree_rows(&state.tree, allocator)
	rows := make([dynamic]Row, 0, len(model_rows), allocator)
	for &model_row in model_rows {
		letter, has_status := gitcore.decorations_letter(&state.decorations, model_row.path, model_row.is_dir)
		append(&rows, Row{
			id = model_row.path,
			path = model_row.path,
			depth = model_row.depth,
			selectable = true,
			height = 1,
			is_dir = model_row.is_dir,
			expanded = model_row.expanded,
			node = tree_row_node(state, &model_row, letter, has_status, allocator),
		})
		model_row.path = ""
	}
	delete(model_rows)
	return rows
}

tree_selected_toggle :: proc(state: ^Tree_Tab, selected: ^Row) -> Tab_Result {
	if selected == nil || !selected.is_dir do return {}
	model.tree_toggle(&state.tree, selected.path)
	return Tab_Result{rows_changed = true, open_path = selected.path}
}

tree_select_proc :: proc(data: rawptr, selected: ^Row) -> Tab_Result {
	return tree_selected_toggle((^Tree_Tab)(data), selected)
}

tree_key_proc :: proc(data: rawptr, key: tui.Key, selected: ^Row) -> Tab_Result {
	state := (^Tree_Tab)(data)
	if key.code == .Enter || key.code == .Right {
		if selected != nil && selected.is_dir && !selected.expanded do return tree_selected_toggle(state, selected)
		if key.code == .Enter do return tree_selected_toggle(state, selected)
	}
	if key.code == .Left && selected != nil && selected.is_dir && selected.expanded do return tree_selected_toggle(state, selected)
	if key.code != .Rune do return {}
	switch key.rune {
	case '.':
		state.tree.show_hidden = !state.tree.show_hidden
		return Tab_Result{rows_changed = true, message = "hidden files toggled"}
	case 'i':
		state.theme = model.icon_theme_toggle(state.theme)
		return Tab_Result{rows_changed = true, message = "icon theme toggled"}
	case 'r':
		model.tree_refresh(&state.tree)
		tree_git_refresh(state)
		return Tab_Result{rows_changed = true, message = "tree refreshed"}
	case 'c':
		model.tree_collapse_all(&state.tree)
		return Tab_Result{rows_changed = true, message = "all folders collapsed"}
	case 'm':
		return Tab_Result{open_menu = selected != nil}
	case 'q':
		return Tab_Result{quit = true}
	}
	return {}
}

tree_menu_proc :: proc(data: rawptr, selected: ^Row) -> []model.Menu_Entry {
	if selected == nil do return nil
	repo, message, in_repo := gitcore.owner_of(selected.path)
	delete(message)
	if in_repo do gitcore.repo_destroy(&repo)
	return model.tree_menu(selected.is_dir, in_repo)
}

tree_copy_path :: proc(state: ^Tree_Tab, selected: ^Row, relative: bool) -> (string, bool) {
	value := strings.clone(selected.path, context.allocator)
	if relative {
		relative_value, err := filepath.rel(state.tree.root, selected.path, context.allocator)
		delete(value)
		if err != nil do return "", false
		value = relative_value
	}
	encoded := base64.encode(transmute([]byte)(value), allocator = context.allocator)
	defer delete(encoded)
	sequence := fmt.aprintf("\x1b]52;c;%s\x07", encoded)
	defer delete(sequence)
	_, write_error := os.write_string(os.stdout, sequence)
	if write_error != nil {
		delete(value)
		return "", false
	}
	return value, true
}

tree_action_proc :: proc(data: rawptr, selected: ^Row, action: model.Action, value: string) -> Tab_Result {
	state := (^Tree_Tab)(data)
	if selected == nil do return {}
	parent := filepath.dir(selected.path, context.allocator)
	defer delete(parent)
	target_dir := parent
	if selected.is_dir do target_dir = selected.path
	#partial switch action {
	case .New_File, .New_Folder:
		if _, ok := model.validate_name(value); !ok do return Tab_Result{message = "invalid name"}
		path, _ := filepath.join([]string{target_dir, value}, context.allocator)
		defer delete(path)
		err := model.create_file(path)
		if action == .New_Folder do err = model.create_folder(path)
		if err != nil do return Tab_Result{message = "could not create entry"}
	case .Rename:
		if _, ok := model.validate_name(value); !ok do return Tab_Result{message = "invalid name"}
		path, _ := filepath.join([]string{parent, value}, context.allocator)
		defer delete(path)
		if model.rename_entry(selected.path, path) != nil do return Tab_Result{message = "could not rename entry"}
	case .Delete:
		if model.delete_entry(selected.path) != nil do return Tab_Result{message = "could not delete entry"}
	case .Change_Folder:
		info, err := os.stat(value, context.allocator)
		if err != nil || info.type != .Directory {
			if err == nil do os.file_info_delete(info, context.allocator)
			return Tab_Result{message = "folder does not exist"}
		}
		os.file_info_delete(info, context.allocator)
		model.tree_destroy(&state.tree)
		model.tree_init(&state.tree, value)
		model.tree_refresh(&state.tree)
		tree_git_refresh(state)
		return Tab_Result{rows_changed = true, message = "tree updated", root_path = state.tree.root}
	case .Copy_Path, .Copy_Relative_Path:
		path, copied := tree_copy_path(state, selected, action == .Copy_Relative_Path)
		if !copied do return Tab_Result{message = "could not copy path"}
		delete(path)
		return Tab_Result{message = "path copied"}
	case .Stage_Changes:
		repo, message, ok := gitcore.owner_of(selected.path)
		if !ok {
			delete(message)
			return Tab_Result{message = "not inside a git repository"}
		}
		defer gitcore.repo_destroy(&repo)
		delete(message)
		result, stage_message, staged := gitcore.stage_under(&repo, selected.path)
		if !staged {
			delete(stage_message)
			return Tab_Result{message = "staging failed"}
		}
		delete(stage_message)
		if result.count == 0 && result.skipped_nested > 0 {
			return Tab_Result{message = "nothing staged; nested repository boundary"}
		}
		tree_git_refresh(state)
		return Tab_Result{rows_changed = true, message = "changes staged"}
	}
	model.tree_refresh(&state.tree)
	tree_git_refresh(state)
	return Tab_Result{rows_changed = true, message = "tree updated"}
}

tree_destroy_proc :: proc(data: rawptr) {
	state := (^Tree_Tab)(data)
	allocator := state.tree.allocator
	gitcore.repos_destroy(&state.repos)
	gitcore.decorations_destroy(&state.decorations)
	model.tree_destroy(&state.tree)
	free(state, allocator)
}

tree_heading_proc :: proc(data: rawptr) -> Tab_Heading {
	state := (^Tree_Tab)(data)
	return Tab_Heading{title = filepath.base(state.tree.root)}
}

tree_tab :: proc(
	root: string,
	theme := model.Icon_Theme.Emoji,
	show_hidden := false,
	git_decorations := true,
	allocator := context.allocator,
) -> Tab {
	state := tree_tab_new(root, theme, show_hidden, git_decorations, allocator)
	return Tab{
		name = "tree",
		title = "Explorer",
		icon = "▤",
		data = state,
		rows = tree_rows_proc,
		on_key = tree_key_proc,
		on_select = tree_select_proc,
		menu = tree_menu_proc,
		action = tree_action_proc,
		destroy = tree_destroy_proc,
		heading = tree_heading_proc,
	}
}

tree_apply_preferences :: proc(tab: ^Tab, theme: model.Icon_Theme, hidden, git_decorations: bool) -> bool {
	if tab == nil || tab.name != "tree" do return false
	state := (^Tree_Tab)(tab.data)
	state.theme = theme
	state.tree.show_hidden = hidden
	if state.git_decorations != git_decorations {
		state.git_decorations = git_decorations
		tree_git_refresh(state)
	}
	return true
}

tree_state :: proc(tab: ^Tab) -> (model.Icon_Theme, bool, bool, string, []string, bool) {
	if tab == nil || tab.name != "tree" do return .Emoji, false, true, "", nil, false
	state := (^Tree_Tab)(tab.data)
	return state.theme, state.tree.show_hidden, state.git_decorations, state.tree.root, state.tree.expanded[:], true
}

tree_restore_expanded :: proc(tab: ^Tab, paths: []string) -> bool {
	if tab == nil || tab.name != "tree" do return false
	state := (^Tree_Tab)(tab.data)
	model.tree_set_expanded(&state.tree, paths)
	return true
}

package tabs

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import model "../model"
import tui "../tui"

Tree_Tab :: struct {
	tree:  model.Tree,
	theme: model.Icon_Theme,
}

tree_tab_new :: proc(root: string, theme := model.Icon_Theme.Emoji, allocator := context.allocator) -> ^Tree_Tab {
	state := new(Tree_Tab, allocator)
	model.tree_init(&state.tree, root, allocator)
	state.theme = theme
	return state
}

tree_icon_style :: proc(icon: model.Icon) -> tui.Style {
	if !icon.colored do return tui.PLAIN_STYLE
	return tui.Style{fg = tui.rgb(icon.r, icon.g, icon.b), bg = tui.DEFAULT_COLOR}
}

tree_row_node :: proc(state: ^Tree_Tab, row: ^model.Tree_Row, allocator: runtime.Allocator) -> tui.Node {
	chevron := " "
	if row.is_dir {
		if row.expanded {
			chevron = "⌄"
		} else {
			chevron = "›"
		}
	}
	icon := model.file_icon(state.theme, row.name, row.is_dir, row.expanded)
	content := tui.row([]tui.Node{
		tui.transparent(row.depth * 2),
		tui.text(chevron),
		tui.text(" "),
		tui.text(icon.glyph, tree_icon_style(icon)),
		tui.text(" "),
		tui.priority(tui.truncate(tui.text(row.name), 0), 0, allocator),
		tui.spacer(),
		tui.transparent(2),
	}, allocator)
	return tui.region(content, row.path, []string{"open", "menu"}, allocator = allocator)
}

tree_rows_proc :: proc(data: rawptr, allocator: runtime.Allocator) -> [dynamic]Row {
	state := (^Tree_Tab)(data)
	model_rows := model.tree_rows(&state.tree, allocator)
	rows := make([dynamic]Row, 0, len(model_rows), allocator)
	for &model_row in model_rows {
		append(&rows, Row{
			id = model_row.path,
			path = model_row.path,
			depth = model_row.depth,
			selectable = true,
			height = 1,
			is_dir = model_row.is_dir,
			expanded = model_row.expanded,
			node = tree_row_node(state, &model_row, allocator),
		})
		model_row.path = ""
	}
	delete(model_rows)
	return rows
}

tree_selected_toggle :: proc(state: ^Tree_Tab, selected: ^Row) -> Tab_Result {
	if selected == nil || !selected.is_dir do return {}
	model.tree_toggle(&state.tree, selected.path)
	return Tab_Result{rows_changed = true}
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
	return model.tree_menu(selected.is_dir, false)
}

tree_action_proc :: proc(data: rawptr, selected: ^Row, action: model.Action, value: string) -> Tab_Result {
	state := (^Tree_Tab)(data)
	if selected == nil do return {}
	parent := filepath.dir(selected.path, context.allocator)
	defer delete(parent)
	target_dir := parent
	if selected.is_dir do target_dir = selected.path
	switch action {
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
	case .Copy_Path, .Copy_Relative_Path:
		return Tab_Result{message = selected.path}
	case .Stage_Changes:
		return Tab_Result{message = "not inside a git repository"}
	}
	model.tree_refresh(&state.tree)
	return Tab_Result{rows_changed = true, message = "tree updated"}
}

tree_destroy_proc :: proc(data: rawptr) {
	state := (^Tree_Tab)(data)
	allocator := state.tree.allocator
	model.tree_destroy(&state.tree)
	free(state, allocator)
}

tree_tab :: proc(root: string, theme := model.Icon_Theme.Emoji, allocator := context.allocator) -> Tab {
	state := tree_tab_new(root, theme, allocator)
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
	}
}

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
	// Directory -> the row that was selected there.
	history: map[string]string,
	tree: model.Tree,
}

tree_tab_new :: proc(root: string, show_hidden := false, explore := false, allocator := context.allocator) -> ^Tree_Tab {
	state := new(Tree_Tab, allocator)
	model.tree_init(&state.tree, root, allocator)
	state.tree.show_hidden = show_hidden
	state.tree.flat = explore
	state.history = make(map[string]string, allocator)
	return state
}

tree_icon_style :: proc(icon: model.Icon) -> tui.Style {
	if !icon.colored do return tui.PLAIN_STYLE
	return tui.Style{fg = tui.cube(icon.r, icon.g, icon.b), bg = tui.DEFAULT_COLOR}
}

// elbow or tee that joins this row to its parent.
tree_guides :: proc(row: ^model.Tree_Row, allocator: runtime.Allocator) -> string {
	if row.depth == 0 do return ""
	builder := strings.builder_make(allocator)
	for more in row.ancestors {
		strings.write_string(&builder, more ? "│ " : "  ")
	}
	strings.write_string(&builder, row.is_last ? "└ " : "├ ")
	return strings.to_string(builder)
}

// The guide columns a wrapped line sits under: the same ancestors, plus this row's
// own level. A row that is its parent's last child has nothing below it, so that
// column becomes blank rather than a pipe.
tree_guides_continued :: proc(row: ^model.Tree_Row, allocator: runtime.Allocator) -> string {
	if row.depth == 0 do return strings.clone("", allocator)
	builder := strings.builder_make(allocator)
	for more in row.ancestors {
		strings.write_string(&builder, more ? "│ " : "  ")
	}
	strings.write_string(&builder, row.is_last ? "  " : "│ ")
	return strings.to_string(builder)
}

// Columns before the name: the guides, the disclosure chevron, the icon and a space.
tree_prefix_width :: proc(row: ^model.Tree_Row) -> int {
	guides := 0
	if row.depth > 0 do guides = (len(row.ancestors) + 1) * 2
	return guides + 4
}

// The name as it is drawn: directories carry a trailing separator.
tree_display_name :: proc(row: ^model.Tree_Row, allocator: runtime.Allocator) -> string {
	if row.is_dir do return strings.concatenate([]string{row.name, "/"}, allocator)
	return strings.clone(row.name, allocator)
}

// A name too long for the pane wraps under itself rather than ending in an ellipsis.
// Filenames differ at the end at least as often as at the start — `report-2026-01.csv`
// against `report-2026-02.csv` — so cutting the tail hides exactly what identifies them.
tree_name_lines :: proc(row: ^model.Tree_Row, width: int) -> [dynamic]string {
	name := tree_display_name(row, context.temp_allocator)
	room := max(width - tree_prefix_width(row) - 2, 8)
	return tui.wrap_name(name, room, context.temp_allocator)
}

tree_row_height :: proc(row: ^model.Tree_Row, width: int) -> int {
	return len(tree_name_lines(row, width))
}

tree_row_node :: proc(state: ^Tree_Tab, row: ^model.Tree_Row, width: int, allocator: runtime.Allocator) -> tui.Node {
	chevron := "  "
	if row.is_dir {
		chevron = row.expanded ? "▾ " : "▸ "
	}
	icon := model.file_icon(row.name, row.is_dir, row.expanded)
	icon_style := tree_icon_style(icon)
	// A directory takes the accent for both glyph and name; a file takes its own type
	// colour for both, so icon and name always agree about what the row is.
	name_style := icon_style
	if row.is_dir {
		icon_style = tui.Style{fg = tui.ACCENT}
		name_style = tui.Style{fg = tui.ACCENT}
	}
	guide_style := tui.Style{fg = tui.RAMP_BORDER, attrs = {.Dim}}

	lines := tree_name_lines(row, width)
	rows := make([dynamic]tui.Node, allocator)
	defer delete(rows)
	for line, index in lines {
		children := make([dynamic]tui.Node, allocator)
		defer delete(children)
		if index == 0 {
			append(&children, tui.owned_text(tree_guides(row, allocator), guide_style))
			append(&children, tui.text(chevron, tui.Style{attrs = {.Dim}}))
			append(&children, tui.text(icon.glyph, icon_style))
			append(&children, tui.text(" "))
		} else {
			append(&children, tui.owned_text(tree_guides_continued(row, allocator), guide_style))
			append(&children, tui.priority(tui.transparent(4), 100, allocator))
		}
		append(&children, tui.owned_text(strings.clone(line, allocator), name_style))
		append(&children, tui.spacer())
		append(&children, tui.priority(tui.transparent(2), 100, allocator))
		append(&rows, tui.row(children[:], allocator))
	}
	content := tui.column(rows[:], allocator)
	return tui.region(content, row.path, []string{"open", "menu"}, allocator = allocator)
}

tree_rows_proc :: proc(data: rawptr, width: int, allocator: runtime.Allocator) -> [dynamic]Row {
	state := (^Tree_Tab)(data)
	model_rows := model.tree_rows(&state.tree, allocator)
	rows := make([dynamic]Row, 0, len(model_rows), allocator)
	for &model_row in model_rows {
		append(&rows, Row{
			id = strings.clone(model_row.path, allocator),
			path = model_row.path,
			depth = model_row.depth,
			selectable = true,
			height = tree_row_height(&model_row, width),
			is_dir = model_row.is_dir,
			expanded = model_row.expanded,
			node = tree_row_node(state, &model_row, width, allocator),
		})
		model_row.path = ""
	}
	delete(model_rows)
	return rows
}

// Remember which row was selected in a directory, so returning to it puts the cursor
// back where it was rather than at the top.
tree_remember :: proc(state: ^Tree_Tab, dir, selected: string) {
	if dir == "" || selected == "" do return
	if existing, found := state.history[dir]; found {
		delete(existing)
		state.history[dir] = strings.clone(selected, state.tree.allocator)
		return
	}
	state.history[strings.clone(dir, state.tree.allocator)] = strings.clone(selected, state.tree.allocator)
}

// Re-root the tree somewhere else, keeping the explorer mode and hidden-file choice.
// `selected` is the row the cursor was on, which is what makes coming back work.
tree_reroot :: proc(state: ^Tree_Tab, path: string, selected: string) -> Tab_Result {
	previous := strings.clone(state.tree.root, context.temp_allocator)
	tree_remember(state, previous, selected)
	// Climbing out: the directory just left is the row to land on up there.
	parent := filepath.dir(previous, context.temp_allocator)
	if parent == path do tree_remember(state, path, previous)

	flat := state.tree.flat
	hidden := state.tree.show_hidden
	allocator := state.tree.allocator
	root := strings.clone(path, allocator)
	defer delete(root, allocator)
	model.tree_destroy(&state.tree)
	model.tree_init(&state.tree, root, allocator)
	state.tree.flat = flat
	state.tree.show_hidden = hidden

	remembered := ""
	if value, found := state.history[state.tree.root]; found do remembered = value
	return Tab_Result{
		rows_changed = true,
		root_path = state.tree.root,
		open_path = state.tree.root,
		select_id = remembered,
		select_first = true,
	}
}

// The parent of the current root, or nothing when already at the filesystem top.
tree_parent :: proc(state: ^Tree_Tab, selected: string) -> Tab_Result {
	parent := filepath.dir(state.tree.root, context.temp_allocator)
	if parent == "" || parent == state.tree.root do return Tab_Result{message = "already at the top"}
	return tree_reroot(state, parent, selected)
}

tree_selected_toggle :: proc(state: ^Tree_Tab, selected: ^Row) -> Tab_Result {
	if selected == nil || !selected.is_dir do return {}
	// Explorer mode walks into a directory; tree mode unfolds it where it stands.
	if state.tree.flat do return tree_reroot(state, selected.path, selected.path)
	model.tree_toggle(&state.tree, selected.path)
	return Tab_Result{rows_changed = true, open_path = selected.path}
}

tree_select_proc :: proc(data: rawptr, selected: ^Row) -> Tab_Result {
	return tree_selected_toggle((^Tree_Tab)(data), selected)
}

tree_key_proc :: proc(data: rawptr, key: tui.Key, selected: ^Row) -> Tab_Result {
	state := (^Tree_Tab)(data)
	if key.code == .Enter || key.code == .Right {
		if selected != nil && selected.is_dir && (state.tree.flat || !selected.expanded) {
			return tree_selected_toggle(state, selected)
		}
		if key.code == .Enter do return tree_selected_toggle(state, selected)
	}
	if key.code == .Left {
		// In explorer mode Left is "go up"; in tree mode it folds the row back.
		if state.tree.flat do return tree_parent(state, selected_path(selected))
		if selected != nil && selected.is_dir && selected.expanded do return tree_selected_toggle(state, selected)
	}
	if key.code == .Backspace && state.tree.flat do return tree_parent(state, selected_path(selected))
	if key.code != .Rune do return {}
	switch key.rune {
	case '.':
		state.tree.show_hidden = !state.tree.show_hidden
		return Tab_Result{rows_changed = true, message = "hidden files toggled"}
	case 'a':
		state.tree.flat = !state.tree.flat
		model.tree_collapse_all(&state.tree)
		model.tree_refresh(&state.tree)
		return Tab_Result{rows_changed = true, message = state.tree.flat ? "explorer mode" : "tree mode"}
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
		return Tab_Result{rows_changed = true, message = "changes staged"}
	}
	model.tree_refresh(&state.tree)
	return Tab_Result{rows_changed = true, message = "tree updated"}
}

tree_destroy_proc :: proc(data: rawptr) {
	state := (^Tree_Tab)(data)
	allocator := state.tree.allocator
	for key, value in state.history {
		delete(key)
		delete(value)
	}
	delete(state.history)
	model.tree_destroy(&state.tree)
	free(state, allocator)
}

tree_heading_proc :: proc(data: rawptr) -> Tab_Heading {
	state := (^Tree_Tab)(data)
	// Explorer mode moves between directories, so the full path is the context that
	// matters; tree mode stays rooted and only needs the folder name.
	if state.tree.flat do return Tab_Heading{title = state.tree.root, is_path = true}
	return Tab_Heading{title = filepath.base(state.tree.root)}
}

tree_tab :: proc(
	root: string,
	show_hidden := false,
	explore := false,
	allocator := context.allocator,
) -> Tab {
	state := tree_tab_new(root, show_hidden, explore, allocator)
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

tree_apply_preferences :: proc(tab: ^Tab, hidden: bool) -> bool {
	if tab == nil || tab.name != "tree" do return false
	state := (^Tree_Tab)(tab.data)
	state.tree.show_hidden = hidden
	return true
}

tree_state :: proc(tab: ^Tab) -> (bool, string, []string, bool) {
	if tab == nil || tab.name != "tree" do return false, "", nil, false
	state := (^Tree_Tab)(tab.data)
	return state.tree.show_hidden, state.tree.root, state.tree.expanded[:], true
}

tree_restore_expanded :: proc(tab: ^Tab, paths: []string) -> bool {
	if tab == nil || tab.name != "tree" do return false
	state := (^Tree_Tab)(tab.data)
	model.tree_set_expanded(&state.tree, paths)
	return true
}


selected_path :: proc(selected: ^Row) -> string {
	if selected == nil do return ""
	return selected.path
}

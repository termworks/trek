package tabs

import "base:runtime"
import model "../model"
import tui "../tui"

Row_Kind :: enum {
	Generic,
	Commit_Box,
	Commit_Button,
	Section_Header,
	Git_Entry,
	Graph_Commit,
}

Row :: struct {
	id:         string,
	path:       string,
	depth:      int,
	selectable: bool,
	height:     int,
	is_dir:     bool,
	expanded:   bool,
	kind:       Row_Kind,
	entry_index: int,
	staged:     bool,
	input_value: string,
	node:       tui.Node,
}

Tab_Heading :: struct {
	title:  string,
	// A filesystem path, which the header abbreviates from the root end when it does
	// not fit rather than clipping the part the reader cares about.
	is_path: bool,
	detail: string,
	meta:   string,
}

// A Row owns both strings. They are never aliased: freeing one and hoping the other
// pointed at it is how the changes tab leaked an id per entry.
rows_destroy :: proc(rows: ^[dynamic]Row) {
	for &row in rows {
		tui.node_destroy(&row.node)
		delete(row.id)
		delete(row.path)
	}
	delete(rows^)
	rows^ = nil
}

Tab_Result :: struct {
	rows_changed: bool,
	open_menu:    bool,
	quit:         bool,
	// Usually a literal. A tab that computed the string sets owns_message, and the
	// shell frees it after copying it into the footer; without that flag every
	// computed message leaks, because the shell always clones what it is given.
	message:      string,
	owns_message: bool,
	open_path:    string,
	root_path:    string,
	switch_tab:   string,
	// After the rows are rebuilt, put the cursor on this row if it still exists;
	// otherwise, when select_first is set, on the first selectable row.
	select_id:    string,
	select_first: bool,
}

// `width` is the content width the rows will be drawn into. A provider that wraps
// text needs it at build time, because a Row's height is fixed once it is built.
Rows_Proc :: proc(data: rawptr, width: int, allocator: runtime.Allocator) -> [dynamic]Row
Key_Proc :: proc(data: rawptr, key: tui.Key, selected: ^Row) -> Tab_Result
Select_Proc :: proc(data: rawptr, selected: ^Row) -> Tab_Result
Menu_Proc :: proc(data: rawptr, selected: ^Row) -> []model.Menu_Entry
Action_Proc :: proc(data: rawptr, selected: ^Row, action: model.Action, value: string) -> Tab_Result
Destroy_Proc :: proc(data: rawptr)
Focus_Proc :: proc(data: rawptr) -> Tab_Result
Paste_Proc :: proc(data: rawptr, value: string, selected: ^Row) -> Tab_Result
Root_Proc :: proc(data: rawptr, root: string) -> Tab_Result
Heading_Proc :: proc(data: rawptr) -> Tab_Heading
// Whether the tab belongs in the activity bar right now. Called every frame, so it
// must only read state the tab already computed, never spawn a process.
Visible_Proc :: proc(data: rawptr) -> bool

// A second chance to answer that question. A `when` predicate that had to ask a
// background process was necessarily wrong the first time -- the answer had not
// arrived yet -- and without this the tab stays hidden until the root next changes.
Revisit_Proc :: proc(data: rawptr) -> Tab_Result

Tab :: struct {
	name:      string,
	title:     string,
	icon:      string,
	data:      rawptr,
	rows:      Rows_Proc,
	on_key:    Key_Proc,
	on_select: Select_Proc,
	menu:      Menu_Proc,
	action:    Action_Proc,
	destroy:   Destroy_Proc,
	on_focus:  Focus_Proc,
	on_paste:  Paste_Proc,
	on_root:   Root_Proc,
	heading:   Heading_Proc,
	visible:   Visible_Proc,
	revisit:   Revisit_Proc,
}

tab_rows :: proc(tab: ^Tab, width: int, allocator := context.allocator) -> [dynamic]Row {
	if tab.rows == nil do return make([dynamic]Row, allocator)
	return tab.rows(tab.data, width, allocator)
}

tab_key :: proc(tab: ^Tab, key: tui.Key, selected: ^Row) -> Tab_Result {
	if tab.on_key == nil do return {}
	return tab.on_key(tab.data, key, selected)
}

tab_select :: proc(tab: ^Tab, selected: ^Row) -> Tab_Result {
	if tab.on_select == nil do return {}
	return tab.on_select(tab.data, selected)
}

tab_menu :: proc(tab: ^Tab, selected: ^Row) -> []model.Menu_Entry {
	if tab.menu == nil do return nil
	return tab.menu(tab.data, selected)
}

tab_action :: proc(tab: ^Tab, selected: ^Row, action: model.Action, value := "") -> Tab_Result {
	if tab.action == nil do return {}
	return tab.action(tab.data, selected, action, value)
}

tab_destroy :: proc(tab: ^Tab) {
	if tab.destroy != nil do tab.destroy(tab.data)
	tab^ = {}
}

tab_focus :: proc(tab: ^Tab) -> Tab_Result {
	if tab.on_focus == nil do return {}
	return tab.on_focus(tab.data)
}

tab_paste :: proc(tab: ^Tab, value: string, selected: ^Row) -> Tab_Result {
	if tab.on_paste == nil do return {}
	return tab.on_paste(tab.data, value, selected)
}

tab_root :: proc(tab: ^Tab, root: string) -> Tab_Result {
	if tab.on_root == nil do return {}
	return tab.on_root(tab.data, root)
}

tab_heading :: proc(tab: ^Tab) -> Tab_Heading {
	if tab.heading == nil do return Tab_Heading{title = tab.title}
	return tab.heading(tab.data)
}


// A tab with no predicate is always shown.
tab_visible :: proc(tab: ^Tab) -> bool {
	if tab == nil do return false
	if tab.visible == nil do return true
	return tab.visible(tab.data)
}

tab_revisit :: proc(tab: ^Tab) -> Tab_Result {
	if tab == nil || tab.revisit == nil do return {}
	return tab.revisit(tab.data)
}

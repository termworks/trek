package tabs

import "base:runtime"
import model "../model"
import tui "../tui"

Row :: struct {
	id:         string,
	path:       string,
	depth:      int,
	selectable: bool,
	height:     int,
	is_dir:     bool,
	expanded:   bool,
	node:       tui.Node,
}

rows_destroy :: proc(rows: ^[dynamic]Row) {
	for &row in rows {
		tui.node_destroy(&row.node)
		delete(row.path)
	}
	delete(rows^)
	rows^ = nil
}

Tab_Result :: struct {
	rows_changed: bool,
	open_menu:    bool,
	quit:         bool,
	message:      string,
}

Rows_Proc :: proc(data: rawptr, allocator: runtime.Allocator) -> [dynamic]Row
Key_Proc :: proc(data: rawptr, key: tui.Key, selected: ^Row) -> Tab_Result
Select_Proc :: proc(data: rawptr, selected: ^Row) -> Tab_Result
Menu_Proc :: proc(data: rawptr, selected: ^Row) -> []model.Menu_Entry
Action_Proc :: proc(data: rawptr, selected: ^Row, action: model.Action, value: string) -> Tab_Result
Destroy_Proc :: proc(data: rawptr)

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
}

tab_rows :: proc(tab: ^Tab, allocator := context.allocator) -> [dynamic]Row {
	if tab.rows == nil do return make([dynamic]Row, allocator)
	return tab.rows(tab.data, allocator)
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

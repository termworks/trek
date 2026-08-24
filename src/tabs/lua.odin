package tabs

import "base:runtime"
import "core:fmt"
import "core:strings"
import luaconfig "../lua"
import tui "../tui"

Lua_Tab :: struct {
	engine:    ^luaconfig.Engine,
	name:      string,
	allocator: runtime.Allocator,
}

lua_rows_proc :: proc(data: rawptr, allocator: runtime.Allocator) -> [dynamic]Row {
	state := (^Lua_Tab)(data)
	nodes, message := luaconfig.engine_tab_rows(state.engine, state.name, allocator)
	rows := make([dynamic]Row, allocator)
	if message != "" {
		id := strings.clone("lua:error", allocator)
		node := tui.text(message)
		node.owns_values = true
		append(&rows, Row{id = id, path = id, height = 1, node = node})
		delete(nodes)
		return rows
	}
	for &node, index in nodes {
		id := fmt.aprintf("lua:%s:%d", state.name, index, allocator = allocator)
		append(&rows, Row{
			id = id,
			path = id,
			selectable = true,
			height = max(tui.node_height(&node), 1),
			node = node,
		})
	}
	delete(nodes)
	return rows
}

lua_key_proc :: proc(data: rawptr, key: tui.Key, selected: ^Row) -> Tab_Result {
	state := (^Lua_Tab)(data)
	path := ""
	if selected != nil do path = selected.path
	handled, message := luaconfig.engine_handle_key(state.engine, state.name, key, path)
	if handled do return Tab_Result{message = message}
	if key.code == .Rune && key.rune == 'q' do return Tab_Result{quit = true}
	return {}
}

lua_select_proc :: proc(data: rawptr, selected: ^Row) -> Tab_Result {
	if selected == nil do return {}
	state := (^Lua_Tab)(data)
	message := luaconfig.engine_tab_select(state.engine, state.name, selected.path, selected.is_dir)
	return Tab_Result{message = message}
}

lua_focus_proc :: proc(data: rawptr) -> Tab_Result {
	return Tab_Result{rows_changed = true}
}

lua_destroy_proc :: proc(data: rawptr) {
	state := (^Lua_Tab)(data)
	allocator := state.allocator
	delete(state.name)
	free(state, allocator)
}

lua_tab :: proc(engine: ^luaconfig.Engine, definition: ^luaconfig.Tab_Def, allocator := context.allocator) -> Tab {
	state := new(Lua_Tab, allocator)
	state.engine = engine
	state.name = strings.clone(definition.name, allocator)
	state.allocator = allocator
	return Tab{
		name = definition.name,
		title = definition.title,
		icon = definition.icon,
		data = state,
		rows = lua_rows_proc,
		on_key = lua_key_proc,
		on_select = lua_select_proc,
		destroy = lua_destroy_proc,
		on_focus = lua_focus_proc,
	}
}

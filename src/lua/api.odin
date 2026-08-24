package lua

import c "core:c/libc"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import model "../model"
import tui "../tui"
import clua "vendor:lua/5.4"

get_trek :: proc(L: ^clua.State) -> bool {
	clua.getglobal(L, "require")
	clua.pushstring(L, "trek")
	if clua.pcall(L, 1, 1, 0) != 0 do return false
	return clua.istable(L, -1)
}

table_string :: proc(L: ^clua.State, table: c.int, field: cstring, allocator := context.allocator) -> string {
	clua.getfield(L, table, field)
	defer clua.pop(L, 1)
	return lua_string(L, -1, allocator)
}

table_bool :: proc(L: ^clua.State, table: c.int, field: cstring, fallback: bool) -> bool {
	clua.getfield(L, table, field)
	defer clua.pop(L, 1)
	if !clua.isboolean(L, -1) do return fallback
	return bool(clua.toboolean(L, -1))
}

engine_read_settings :: proc(engine: ^Engine, trek_index: c.int) {
	delete(engine.settings.icons)
	delete(engine.settings.start_tab)
	engine.settings.icons = table_string(engine.state, trek_index, "icons", engine.allocator)
	engine.settings.hidden = table_bool(engine.state, trek_index, "hidden", false)
	engine.settings.git_decorations = table_bool(engine.state, trek_index, "git_decorations", true)
	engine.settings.start_tab = table_string(engine.state, trek_index, "start_tab", engine.allocator)
}

engine_read_tabs :: proc(engine: ^Engine, trek_index: c.int) {
	for &tab in engine.tabs do tab_def_destroy(&tab)
	clear(&engine.tabs)
	L := engine.state
	clua.getfield(L, trek_index, "_tab_order")
	if !clua.istable(L, -1) {
		clua.pop(L, 1)
		return
	}
	order_index := clua.absindex(L, -1)
	clua.getfield(L, trek_index, "_tabs")
	if !clua.istable(L, -1) {
		clua.pop(L, 2)
		return
	}
	tabs_index := clua.absindex(L, -1)
	count := int(clua.rawlen(L, order_index))
	for index in 1 ..= count {
		clua.rawgeti(L, order_index, clua.Integer(index))
		name := lua_string(L, -1, engine.allocator)
		clua.pop(L, 1)
		if name == "" do continue
		push_string(L, name)
		clua.gettable(L, tabs_index)
		if !clua.istable(L, -1) {
			clua.pop(L, 1)
			delete(name)
			continue
		}
		spec_index := clua.absindex(L, -1)
		title := table_string(L, spec_index, "title", engine.allocator)
		icon := table_string(L, spec_index, "icon", engine.allocator)
		if title == "" do title = strings.clone(name, engine.allocator)
		if icon == "" do icon = strings.clone("•", engine.allocator)
		append(&engine.tabs, Tab_Def{name = name, title = title, icon = icon})
		clua.pop(L, 1)
	}
	clua.pop(L, 2)
}

engine_read_api :: proc(engine: ^Engine) -> bool {
	L := engine.state
	if !get_trek(L) {
		stack_error(engine, "trek Lua API")
		return false
	}
	trek_index := clua.absindex(L, -1)
	engine_read_settings(engine, trek_index)
	engine_read_tabs(engine, trek_index)
	clua.pop(L, 1)
	return true
}

engine_apply_defaults :: proc(engine: ^Engine, icons: string, hidden, git_decorations: bool, start_tab: string) -> bool {
	L := engine.state
	if !get_trek(L) do return false
	push_string(L, icons)
	clua.setfield(L, -2, "icons")
	clua.pushboolean(L, b32(hidden))
	clua.setfield(L, -2, "hidden")
	clua.pushboolean(L, b32(git_decorations))
	clua.setfield(L, -2, "git_decorations")
	push_string(L, start_tab)
	clua.setfield(L, -2, "start_tab")
	clua.pop(L, 1)
	return true
}

push_context :: proc(engine: ^Engine, tab_name, row_path: string, is_dir: bool) {
	L := engine.state
	clua.createtable(L, 0, 10)
	push_string(L, engine.root)
	clua.setfield(L, -2, "root")
	push_string(L, tab_name)
	clua.setfield(L, -2, "tab")
	clua.createtable(L, 0, 2)
	push_string(L, row_path)
	clua.setfield(L, -2, "path")
	clua.pushboolean(L, b32(is_dir))
	clua.setfield(L, -2, "is_dir")
	clua.setfield(L, -2, "row")
	clua.getglobal(L, "__trek_host")
	fields := [?]cstring{"exec", "goto_tab", "reveal", "stage", "suspend"}
	for field in fields {
		clua.getfield(L, -1, field)
		clua.setfield(L, -3, field)
	}
	clua.pop(L, 1)
}

call_error :: proc(engine: ^Engine, prefix: string) -> string {
	message := lua_string(engine.state, -1, engine.allocator)
	clua.pop(engine.state, 1)
	defer delete(message)
	if message == "" do return strings.clone(prefix, engine.allocator)
	return fmt.aprintf("%s: %s", prefix, message, allocator = engine.allocator)
}

push_tab_spec :: proc(engine: ^Engine, name: string) -> bool {
	L := engine.state
	if !get_trek(L) do return false
	clua.getfield(L, -1, "_tabs")
	if !clua.istable(L, -1) do return false
	push_string(L, name)
	clua.gettable(L, -2)
	return clua.istable(L, -1)
}

engine_tab_rows :: proc(engine: ^Engine, name: string, allocator := context.allocator) -> ([dynamic]tui.Node, string) {
	nodes := make([dynamic]tui.Node, allocator)
	L := engine.state
	base := clua.gettop(L)
	defer clua.settop(L, base)
	if !push_tab_spec(engine, name) do return nodes, strings.clone("Lua tab is not registered", allocator)
	clua.getfield(L, -1, "rows")
	if !clua.isfunction(L, -1) do return nodes, strings.clone("Lua tab rows must be a function", allocator)
	push_context(engine, name, "", false)
	if clua.pcall(L, 1, 1, 0) != 0 do return nodes, call_error(engine, "Lua rows")
	if !clua.istable(L, -1) do return nodes, strings.clone("Lua rows must return a list", allocator)
	rows_table := clua.absindex(L, -1)
	for index in 1 ..= int(clua.rawlen(L, rows_table)) {
		clua.rawgeti(L, rows_table, clua.Integer(index))
		node, ok := lua_to_node(L, -1, allocator)
		clua.pop(L, 1)
		if ok do append(&nodes, node)
	}
	return nodes, ""
}

engine_tab_select :: proc(engine: ^Engine, name, row_path: string, is_dir: bool) -> string {
	L := engine.state
	base := clua.gettop(L)
	defer clua.settop(L, base)
	if !push_tab_spec(engine, name) do return ""
	clua.getfield(L, -1, "on_select")
	if !clua.isfunction(L, -1) do return ""
	push_context(engine, name, row_path, is_dir)
	clua.getfield(L, -1, "row")
	if clua.pcall(L, 2, 0, 0) != 0 do return call_error(engine, "Lua on_select")
	return ""
}

key_text :: proc(key: tui.Key, allocator := context.allocator) -> string {
	if key.code != .Rune do return ""
	encoded, count := utf8.encode_rune(key.rune)
	return strings.clone(string(encoded[:count]), allocator)
}

push_key_handler :: proc(engine: ^Engine, tab_name, key: string) -> bool {
	L := engine.state
	if !get_trek(L) do return false
	clua.getfield(L, -1, "keys")
	if !clua.istable(L, -1) do return false
	clua.getfield(L, -1, strings.clone_to_cstring(tab_name, context.temp_allocator))
	if clua.istable(L, -1) {
		push_string(L, key)
		clua.gettable(L, -2)
		if clua.isfunction(L, -1) do return true
		clua.pop(L, 1)
	}
	clua.pop(L, 1)
	push_string(L, key)
	clua.gettable(L, -2)
	return clua.isfunction(L, -1)
}

engine_handle_key :: proc(engine: ^Engine, tab_name: string, key: tui.Key, row_path := "", is_dir := false) -> (bool, string) {
	text := key_text(key, context.temp_allocator)
	if text == "" do return false, ""
	L := engine.state
	base := clua.gettop(L)
	defer clua.settop(L, base)
	if !push_key_handler(engine, tab_name, text) do return false, ""
	push_context(engine, tab_name, row_path, is_dir)
	if clua.pcall(L, 1, 0, 0) != 0 do return true, call_error(engine, "Lua key handler")
	return true, ""
}

engine_emit :: proc(engine: ^Engine, event, value: string) -> string {
	L := engine.state
	base := clua.gettop(L)
	defer clua.settop(L, base)
	if !get_trek(L) do return ""
	clua.getfield(L, -1, "_handlers")
	clua.getfield(L, -1, strings.clone_to_cstring(event, context.temp_allocator))
	if !clua.istable(L, -1) do return ""
	first_error := ""
	count := int(clua.rawlen(L, -1))
	for index in 1 ..= count {
		clua.rawgeti(L, -1, clua.Integer(index))
		if !clua.isfunction(L, -1) {
			clua.pop(L, 1)
			continue
		}
		push_string(L, value)
		if clua.pcall(L, 1, 0, 0) != 0 {
			message := call_error(engine, "Lua event handler")
			if first_error == "" {
				first_error = message
			} else {
				delete(message)
			}
		}
	}
	return first_error
}

engine_menu_entries :: proc(
	engine: ^Engine,
	tab_name, row_path: string,
	is_dir: bool,
	allocator := context.allocator,
) -> ([dynamic]model.Menu_Entry, string) {
	entries := make([dynamic]model.Menu_Entry, allocator)
	L := engine.state
	base := clua.gettop(L)
	defer clua.settop(L, base)
	if !get_trek(L) do return entries, ""
	clua.getfield(L, -1, "menu")
	clua.getfield(L, -1, strings.clone_to_cstring(tab_name, context.temp_allocator))
	if !clua.istable(L, -1) do return entries, ""
	menu_table := clua.absindex(L, -1)
	first_error := ""
	clua.pushnil(L)
	for clua.next(L, menu_table) != 0 {
		id := lua_string(L, -2, allocator)
		if id == "" || !clua.istable(L, -1) {
			delete(id)
			clua.pop(L, 1)
			continue
		}
		spec := clua.absindex(L, -1)
		visible := true
		clua.getfield(L, spec, "when")
		if clua.isfunction(L, -1) {
			push_context(engine, tab_name, row_path, is_dir)
			if clua.pcall(L, 1, 1, 0) != 0 {
				message := call_error(engine, "Lua menu when")
				if first_error == "" {
					first_error = message
				} else {
					delete(message)
				}
				visible = false
			} else {
				visible = bool(clua.toboolean(L, -1))
				clua.pop(L, 1)
			}
		} else {
			clua.pop(L, 1)
		}
		if visible {
			label := table_string(L, spec, "label", allocator)
			if label == "" {
				delete(label)
				label = strings.clone(id, allocator)
			}
			append(&entries, model.Menu_Entry{
				id = id,
				label = label,
				action = .Lua,
				danger = table_bool(L, spec, "danger", false),
			})
		} else {
			delete(id)
		}
		clua.pop(L, 1)
	}
	return entries, first_error
}

engine_run_menu :: proc(engine: ^Engine, tab_name, id, row_path: string, is_dir: bool) -> string {
	L := engine.state
	base := clua.gettop(L)
	defer clua.settop(L, base)
	if !get_trek(L) do return ""
	clua.getfield(L, -1, "menu")
	clua.getfield(L, -1, strings.clone_to_cstring(tab_name, context.temp_allocator))
	if !clua.istable(L, -1) do return ""
	clua.getfield(L, -1, strings.clone_to_cstring(id, context.temp_allocator))
	if !clua.istable(L, -1) do return ""
	clua.getfield(L, -1, "run")
	if !clua.isfunction(L, -1) do return strings.clone("Lua menu run must be a function", engine.allocator)
	push_context(engine, tab_name, row_path, is_dir)
	if clua.pcall(L, 1, 0, 0) != 0 do return call_error(engine, "Lua menu run")
	return ""
}

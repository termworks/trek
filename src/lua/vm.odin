package lua

import "base:runtime"
import c "core:c/libc"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import clua "vendor:lua/5.4"

NODES_SOURCE :: #load("../../lua/trek/nodes.lua")
INIT_SOURCE :: #load("../../lua/trek/init.lua")
DEFAULT_SOURCE :: #load("../../lua/trek/default.lua")

Settings :: struct {
	icons:           string,
	hidden:          bool,
	git_decorations: bool,
	start_tab:       string,
}

Tab_Def :: struct {
	name:  string,
	title: string,
	icon:  string,
}

Engine :: struct {
	state:          ^clua.State,
	root:           string,
	config_path:    string,
	state_path:     string,
	error:          string,
	tabs:           [dynamic]Tab_Def,
	settings:       Settings,
	pending_tab:    string,
	pending_reveal: string,
	pending_refresh: bool,
	pending_suspend: [dynamic]string,
	execs:          [dynamic]^Exec_Entry,
	process_mutex:  sync.Mutex,
	exec_generation: u64,
	seen_generation: u64,
	allocator:      runtime.Allocator,
}

lua_string :: proc(L: ^clua.State, index: c.int, allocator := context.allocator) -> string {
	if clua.type(L, index) != .STRING do return ""
	length: c.size_t
	value := clua.tolstring(L, index, &length)
	if value == nil do return ""
	bytes := cast([^]byte)value
	return strings.clone(string(bytes[:int(length)]), allocator)
}

push_string :: proc(L: ^clua.State, value: string) {
	clua.pushlstring(L, cstring(raw_data(value)), c.size_t(len(value)))
}

stack_error :: proc(engine: ^Engine, prefix: string) {
	message := lua_string(engine.state, -1, engine.allocator)
	defer delete(message)
	delete(engine.error)
	if message == "" {
		engine.error = strings.clone(prefix, engine.allocator)
	} else {
		engine.error = fmt.aprintf("%s: %s", prefix, message, allocator = engine.allocator)
	}
	clua.pop(engine.state, 1)
}

run_source :: proc(engine: ^Engine, source, name: string) -> bool {
	c_name := strings.clone_to_cstring(name, context.temp_allocator)
	if clua.L_loadbuffer(engine.state, raw_data(source), c.size_t(len(source)), c_name) != .OK {
		stack_error(engine, name)
		return false
	}
	if clua.pcall(engine.state, 0, 0, 0) != 0 {
		stack_error(engine, name)
		return false
	}
	return true
}

config_path :: proc(allocator := context.allocator) -> (string, bool) {
	explicit := os.get_env("TREK_C", context.temp_allocator)
	if explicit != "" do return strings.clone(explicit, allocator), true
	config_home := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if config_home == "" {
		home := os.get_env("HOME", context.temp_allocator)
		config_home, _ = filepath.join([]string{home, ".config"}, context.temp_allocator)
	}
	path, _ := filepath.join([]string{config_home, "trek", "init.lua"}, allocator)
	return path, false
}

state_dir :: proc(allocator := context.allocator) -> string {
	state_home := os.get_env("XDG_STATE_HOME", context.temp_allocator)
	if state_home == "" {
		home := os.get_env("HOME", context.temp_allocator)
		state_home, _ = filepath.join([]string{home, ".local", "state"}, context.temp_allocator)
	}
	path, _ := filepath.join([]string{state_home, "trek"}, allocator)
	return path
}

engine_init :: proc(engine: ^Engine, root: string, allocator := context.allocator) -> bool {
	engine.allocator = allocator
	engine.root = strings.clone(root, allocator)
	engine.tabs = make([dynamic]Tab_Def, allocator)
	engine.execs = make([dynamic]^Exec_Entry, allocator)
	engine.pending_suspend = make([dynamic]string, allocator)
	engine.state_path = state_dir(allocator)
	engine.config_path, _ = config_path(allocator)
	engine.state = clua.L_newstate()
	if engine.state == nil {
		engine.error = strings.clone("could not create Lua 5.4 state", allocator)
		return false
	}
	clua.L_openlibs(engine.state)
	engine_register_host(engine)
	if !run_source(engine, string(NODES_SOURCE), "@trek/nodes.lua") do return false
	if !run_source(engine, string(INIT_SOURCE), "@trek/init.lua") do return false
	if !run_source(engine, string(DEFAULT_SOURCE), "@trek/default.lua") do return false
	return true
}

engine_load_config :: proc(engine: ^Engine) -> bool {
	if engine.state == nil do return false
	path, explicit := config_path(context.temp_allocator)
	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil {
		if explicit {
			delete(engine.error)
			engine.error = fmt.aprintf("%s: config file not found", path, allocator = engine.allocator)
			return false
		}
		return engine_read_api(engine)
	}
	contents, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		delete(engine.error)
		engine.error = fmt.aprintf("%s: could not read config", path, allocator = engine.allocator)
		return false
	}
	if !run_source(engine, string(contents), path) do return false
	return engine_read_api(engine)
}

tab_def_destroy :: proc(tab: ^Tab_Def) {
	delete(tab.name)
	delete(tab.title)
	delete(tab.icon)
	tab^ = {}
}

engine_destroy :: proc(engine: ^Engine) {
	if engine.state != nil do clua.close(engine.state)
	for &tab in engine.tabs do tab_def_destroy(&tab)
	for entry in engine.execs do exec_entry_destroy(entry)
	delete(engine.tabs)
	delete(engine.execs)
	for arg in engine.pending_suspend do delete(arg)
	delete(engine.pending_suspend)
	delete(engine.settings.icons)
	delete(engine.settings.start_tab)
	delete(engine.root)
	delete(engine.config_path)
	delete(engine.state_path)
	delete(engine.error)
	delete(engine.pending_tab)
	delete(engine.pending_reveal)
	engine^ = {}
}

engine_poll :: proc(engine: ^Engine) -> bool {
	generation := sync.atomic_load(&engine.exec_generation)
	if generation == engine.seen_generation do return false
	engine.seen_generation = generation
	return true
}

engine_set_root :: proc(engine: ^Engine, root: string) {
	delete(engine.root)
	engine.root = strings.clone(root, engine.allocator)
}

package lua

import "base:runtime"
import c "core:c/libc"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import tui "../tui"
import clua "vendor:lua/5.4"

NODES_SOURCE :: #load("../../lua/trek/nodes.lua")
INIT_SOURCE :: #load("../../lua/trek/init.lua")
DEFAULT_SOURCE :: #load("../../lua/trek/default.lua")

Settings :: struct {
	hidden:          bool,
	start_tab:       string,
	width:           tui.Extent,
	height:          tui.Extent,
	align:           string,
	border:          bool,
	preview_shrink:  int,
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
	// A plugin that failed to load. Reported once in the footer; the others still ran.
	plugin_error:   string,
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

// The directory of discovered fragments, beside init.lua. A plugin registers itself and
// returns nothing, so a config never has to require, shape-check and merge a returned
// table by hand -- the merge exists once, here, rather than in every config that wants
// somebody else's tab.
plugins_dir :: proc(allocator := context.allocator) -> string {
	explicit := os.get_env("TREK_C", context.temp_allocator)
	if explicit != "" {
		return filepath.join([]string{filepath.dir(explicit, context.temp_allocator), "plugins"}, allocator) or_else ""
	}
	config_home := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if config_home == "" {
		home := os.get_env("HOME", context.temp_allocator)
		config_home, _ = filepath.join([]string{home, ".config"}, context.temp_allocator)
	}
	path, _ := filepath.join([]string{config_home, "trek", "plugins"}, allocator)
	return path
}

// Run every plugin, in name order so the result does not depend on the filesystem.
//
// A raise here is reported and the rest still load. That is deliberately unlike init.lua,
// where a raise is fatal: init.lua is the user's own file and carrying on would silently
// apply settings they did not ask for, while a plugin is somebody else's code and one bad
// one must not take the tool down with it.
engine_load_plugins :: proc(engine: ^Engine) -> string {
	dir := plugins_dir(context.temp_allocator)
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return ""
	names := make([dynamic]string, context.temp_allocator)
	for info in infos {
		if info.type == .Directory do continue
		if !strings.has_suffix(info.name, ".lua") do continue
		append(&names, info.name)
	}
	slice.sort(names[:])
	first_error := ""
	for name in names {
		path, _ := filepath.join([]string{dir, name}, context.temp_allocator)
		contents, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil do continue
		if !run_source(engine, string(contents), path) {
			if first_error == "" do first_error = strings.clone(engine.error, engine.allocator)
			delete(engine.error)
			engine.error = ""
		}
	}
	return first_error
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
		engine.plugin_error = engine_load_plugins(engine)
		return engine_read_api(engine)
	}
	contents, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		delete(engine.error)
		engine.error = fmt.aprintf("%s: could not read config", path, allocator = engine.allocator)
		return false
	}
	// Plugins load BEFORE init.lua so the config wins. A keyed registrar takes the last
	// write, so whichever runs later overrides -- and the user's own file overriding
	// somebody else's plugin is the only order that makes a preset overridable.
	engine.plugin_error = engine_load_plugins(engine)
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
	delete(engine.settings.start_tab)
	delete(engine.settings.align)
	delete(engine.root)
	delete(engine.config_path)
	delete(engine.state_path)
	delete(engine.error)
	delete(engine.plugin_error)
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

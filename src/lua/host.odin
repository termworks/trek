package lua

import "base:runtime"
import c "core:c/libc"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import gitcore "../git"
import tui "../tui"
import clua "vendor:lua/5.4"

EXEC_OUTPUT_CAP :: 1024 * 1024
EXEC_WORKER_CAP :: 4
EXEC_TIMEOUT :: 5 * time.Second

Exec_Entry :: struct {
	engine:    ^Engine,
	key:       string,
	argv:      [dynamic]string,
	stdout:    []byte,
	stderr:    []byte,
	exit_code: int,
	success:   bool,
	timed_out: bool,
	thread:    ^thread.Thread,
	allocator: runtime.Allocator,
	result_allocator: runtime.Allocator,
}

exec_entry_destroy :: proc(entry: ^Exec_Entry) {
	if entry == nil do return
	if entry.thread != nil {
		thread.join(entry.thread)
		thread.destroy(entry.thread)
	}
	delete(entry.key, entry.allocator)
	for arg in entry.argv do delete(arg, entry.allocator)
	delete(entry.argv)
	delete(entry.stdout, entry.result_allocator)
	delete(entry.stderr, entry.result_allocator)
	allocator := entry.allocator
	free(entry, allocator)
}

read_capped :: proc(path: string, allocator: runtime.Allocator) -> []byte {
	file, err := os.open(path, {.Read})
	if err != nil do return nil
	defer os.close(file)
	buffer := make([]byte, EXEC_OUTPUT_CAP, allocator)
	count, _ := os.read_at(file, buffer, 0)
	if count <= 0 {
		delete(buffer)
		return nil
	}
	return buffer[:count]
}

exec_worker :: proc(worker: ^thread.Thread) {
	entry := cast(^Exec_Entry)worker.data
	defer sync.atomic_add(&entry.engine.exec_generation, 1)
	temp, temp_error := os.make_directory_temp("", "trek-exec-*", context.allocator)
	if temp_error != nil {
		entry.stderr = transmute([]byte)strings.clone("could not create command output directory", entry.result_allocator)
		return
	}
	defer { _ = os.remove_all(temp); delete(temp) }
	stdout_path, _ := filepath.join([]string{temp, "stdout"}, context.allocator)
	stderr_path, _ := filepath.join([]string{temp, "stderr"}, context.allocator)
	defer delete(stdout_path)
	defer delete(stderr_path)
	stdout_file, stdout_error := os.open(stdout_path, {.Write, .Create, .Trunc, .Inheritable})
	if stdout_error != nil {
		entry.stderr = transmute([]byte)strings.clone("could not capture command output", entry.result_allocator)
		return
	}
	stderr_file, stderr_error := os.open(stderr_path, {.Write, .Create, .Trunc, .Inheritable})
	if stderr_error != nil {
		os.close(stdout_file)
		entry.stderr = transmute([]byte)strings.clone("could not capture command errors", entry.result_allocator)
		return
	}
	sync.mutex_lock(&entry.engine.process_mutex)
	process, start_error := os.process_start(os.Process_Desc{
		working_dir = entry.engine.root,
		command = entry.argv[:],
		stdout = stdout_file,
		stderr = stderr_file,
	})
	sync.mutex_unlock(&entry.engine.process_mutex)
	if start_error != nil {
		os.close(stdout_file)
		os.close(stderr_file)
		entry.stderr = transmute([]byte)strings.clone("could not start command", entry.result_allocator)
		return
	}
	state, wait_error := os.process_wait(process, EXEC_TIMEOUT)
	if wait_error != nil && !state.exited {
		entry.timed_out = true
		_ = os.process_kill(process)
		state, _ = os.process_wait(process)
	}
	os.close(stdout_file)
	os.close(stderr_file)
	entry.stdout = read_capped(stdout_path, entry.result_allocator)
	entry.stderr = read_capped(stderr_path, entry.result_allocator)
	entry.exit_code = state.exit_code
	entry.success = state.exited && state.success && state.exit_code == 0 && !entry.timed_out
}

engine_from_state :: proc(L: ^clua.State) -> ^Engine {
	clua.getfield(L, clua.REGISTRYINDEX, "__trek_engine")
	engine := cast(^Engine)clua.touserdata(L, -1)
	clua.pop(L, 1)
	return engine
}

host_argument :: proc(L: ^clua.State, index: c.int) -> string {
	if clua.type(L, index) != .STRING do return ""
	value := clua.tostring(L, index)
	if value == nil do return ""
	return string(value)
}

path_inside :: proc(path, root: string) -> bool {
	if path == root do return true
	if !strings.has_prefix(path, root) do return false
	return len(path) > len(root) && os.is_path_separator(path[len(root)])
}

trusted_path :: proc(engine: ^Engine, path: string) -> (string, bool) {
	abs, err := filepath.abs(path, context.temp_allocator)
	if err != nil do return "", false
	config_root := filepath.dir(engine.config_path, context.temp_allocator)
	if path_inside(abs, engine.root) || path_inside(abs, config_root) || path_inside(abs, engine.state_path) {
		return abs, true
	}
	return "", false
}

host_env :: proc "c" (L: ^clua.State) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	name := host_argument(L, 1)
	if name == "" {
		clua.pushnil(L)
		return 1
	}
	value := os.get_env(name, context.temp_allocator)
	if value == "" {
		clua.pushnil(L)
	} else {
		push_string(L, value)
	}
	return 1
}

host_read :: proc "c" (L: ^clua.State) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	engine := engine_from_state(L)
	path, trusted := trusted_path(engine, host_argument(L, 1))
	if !trusted {
		clua.pushnil(L)
		return 1
	}
	contents, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(contents) > 1024 * 1024 {
		clua.pushnil(L)
		return 1
	}
	push_string(L, string(contents))
	return 1
}

host_scandir :: proc "c" (L: ^clua.State) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	engine := engine_from_state(L)
	path, trusted := trusted_path(engine, host_argument(L, 1))
	if !trusted {
		clua.pushnil(L)
		return 1
	}
	entries, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil {
		clua.pushnil(L)
		return 1
	}
	clua.createtable(L, c.int(min(len(entries), 4096)), 0)
	for entry, index in entries[:min(len(entries), 4096)] {
		clua.createtable(L, 0, 2)
		push_string(L, entry.name)
		clua.setfield(L, -2, "name")
		clua.pushboolean(L, b32(entry.type == .Directory))
		clua.setfield(L, -2, "is_dir")
		clua.rawseti(L, -2, clua.Integer(index + 1))
	}
	return 1
}

host_cell_width :: proc "c" (L: ^clua.State) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	clua.pushinteger(L, clua.Integer(tui.text_width(host_argument(L, 1))))
	return 1
}

host_state_dir :: proc "c" (L: ^clua.State) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	engine := engine_from_state(L)
	push_string(L, engine.state_path)
	return 1
}

host_goto_tab :: proc "c" (L: ^clua.State) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	engine := engine_from_state(L)
	delete(engine.pending_tab, engine.allocator)
	engine.pending_tab = strings.clone(host_argument(L, 1), engine.allocator)
	return 0
}

host_reveal :: proc "c" (L: ^clua.State) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	engine := engine_from_state(L)
	delete(engine.pending_reveal, engine.allocator)
	engine.pending_reveal = strings.clone(host_argument(L, 1), engine.allocator)
	return 0
}

host_stage :: proc "c" (L: ^clua.State) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	path := host_argument(L, 1)
	repo, message, ok := gitcore.owner_of(path)
	delete(message)
	if !ok {
		clua.pushboolean(L, false)
		return 1
	}
	defer gitcore.repo_destroy(&repo)
	result, stage_message, staged := gitcore.stage_under(&repo, path)
	delete(stage_message)
	engine := engine_from_state(L)
	if staged && result.count > 0 do engine.pending_refresh = true
	clua.pushboolean(L, b32(staged && result.count > 0))
	return 1
}

host_argv :: proc(L: ^clua.State, index: c.int, allocator: runtime.Allocator) -> ([dynamic]string, bool) {
	argv := make([dynamic]string, allocator)
	if !clua.istable(L, index) do return argv, false
	table := clua.absindex(L, index)
	count := min(int(clua.rawlen(L, table)), 64)
	if count == 0 do return argv, false
	for arg_index in 1 ..= count {
		clua.rawgeti(L, table, clua.Integer(arg_index))
		arg := lua_string(L, -1, allocator)
		clua.pop(L, 1)
		if arg == "" {
			delete(arg, allocator)
			for old in argv do delete(old, allocator)
			clear(&argv)
			return argv, false
		}
		append(&argv, arg)
	}
	return argv, true
}

argv_key :: proc(argv: []string, allocator: runtime.Allocator) -> string {
	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	for arg in argv {
		fmt.sbprintf(&builder, "%d:", len(arg))
		strings.write_string(&builder, arg)
	}
	return strings.clone(strings.to_string(builder), allocator)
}

push_exec_result :: proc(L: ^clua.State, entry: ^Exec_Entry) {
	clua.createtable(L, 0, 5)
	push_string(L, string(entry.stdout))
	clua.setfield(L, -2, "stdout")
	push_string(L, string(entry.stderr))
	clua.setfield(L, -2, "stderr")
	clua.pushinteger(L, clua.Integer(entry.exit_code))
	clua.setfield(L, -2, "code")
	clua.pushboolean(L, b32(entry.success))
	clua.setfield(L, -2, "success")
	clua.pushboolean(L, b32(entry.timed_out))
	clua.setfield(L, -2, "timed_out")
}

host_exec :: proc "c" (L: ^clua.State) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	engine := engine_from_state(L)
	argv, valid := host_argv(L, 1, engine.allocator)
	if !valid {
		delete(argv)
		clua.pushnil(L)
		return 1
	}
	key := argv_key(argv[:], engine.allocator)
	for entry in engine.execs {
		if entry.key != key do continue
		for arg in argv do delete(arg, engine.allocator)
		delete(argv)
		delete(key, engine.allocator)
		if !thread.is_done(entry.thread) {
			clua.pushnil(L)
		} else {
			push_exec_result(L, entry)
		}
		return 1
	}
	active := 0
	for entry in engine.execs {
		if !thread.is_done(entry.thread) do active += 1
	}
	if active >= EXEC_WORKER_CAP {
		for arg in argv do delete(arg, engine.allocator)
		delete(argv)
		delete(key, engine.allocator)
		clua.pushnil(L)
		return 1
	}
	entry := new(Exec_Entry, engine.allocator)
	entry.engine = engine
	entry.key = key
	entry.argv = argv
	entry.allocator = engine.allocator
	entry.result_allocator = runtime.heap_allocator()
	entry.thread = thread.create(exec_worker)
	entry.thread.data = rawptr(entry)
	append(&engine.execs, entry)
	thread.start(entry.thread)
	clua.pushnil(L)
	return 1
}

host_suspend :: proc "c" (L: ^clua.State) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	engine := engine_from_state(L)
	argv, valid := host_argv(L, 1, engine.allocator)
	if !valid {
		delete(argv)
		clua.pushboolean(L, false)
		return 1
	}
	for arg in engine.pending_suspend do delete(arg, engine.allocator)
	delete(engine.pending_suspend)
	engine.pending_suspend = argv
	clua.pushboolean(L, true)
	return 1
}

host_set_function :: proc(L: ^clua.State, name: cstring, function: clua.CFunction) {
	clua.pushcfunction(L, function)
	clua.setfield(L, -2, name)
}

engine_register_host :: proc(engine: ^Engine) {
	L := engine.state
	clua.pushlightuserdata(L, rawptr(engine))
	clua.setfield(L, clua.REGISTRYINDEX, "__trek_engine")
	clua.createtable(L, 0, 11)
	when ODIN_OS == .Linux {
		clua.pushstring(L, "linux")
	} else when ODIN_OS == .Darwin {
		clua.pushstring(L, "macos")
	} else when ODIN_OS == .Windows {
		clua.pushstring(L, "windows")
	} else {
		clua.pushstring(L, "unknown")
	}
	clua.setfield(L, -2, "platform")
	host_set_function(L, "env", host_env)
	host_set_function(L, "read", host_read)
	host_set_function(L, "scandir", host_scandir)
	host_set_function(L, "exec", host_exec)
	host_set_function(L, "cell_width", host_cell_width)
	host_set_function(L, "state_dir", host_state_dir)
	host_set_function(L, "goto_tab", host_goto_tab)
	host_set_function(L, "reveal", host_reveal)
	host_set_function(L, "stage", host_stage)
	host_set_function(L, "suspend", host_suspend)
	clua.setglobal(L, "__trek_host")
}

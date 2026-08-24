package settings

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

Root_State :: struct {
	root:     string,
	expanded: [dynamic]string,
}

Preferences :: struct {
	icons:           string,
	hidden:          bool,
	git_decorations: bool,
	start_tab:       string,
	roots:           [dynamic]Root_State,
	path:            string `json:"-"`,
	allocator:       runtime.Allocator `json:"-"`,
}

default_state_dir :: proc(allocator := context.allocator) -> string {
	state_home := os.get_env("XDG_STATE_HOME", context.temp_allocator)
	if state_home == "" {
		home := os.get_env("HOME", context.temp_allocator)
		state_home, _ = filepath.join([]string{home, ".local", "state"}, context.temp_allocator)
	}
	path, _ := filepath.join([]string{state_home, "trek"}, allocator)
	return path
}

preferences_init :: proc(preferences: ^Preferences, state_path := "", allocator := context.allocator) {
	preferences.allocator = allocator
	preferences.icons = strings.clone("", allocator)
	preferences.start_tab = strings.clone("tree", allocator)
	preferences.git_decorations = true
	preferences.roots = make([dynamic]Root_State, allocator)
	dir := state_path
	if dir == "" do dir = default_state_dir(context.temp_allocator)
	preferences.path, _ = filepath.join([]string{dir, "preferences.json"}, allocator)
}

root_state_destroy :: proc(state: ^Root_State) {
	delete(state.root)
	for path in state.expanded do delete(path)
	delete(state.expanded)
	state^ = {}
}

preferences_destroy :: proc(preferences: ^Preferences) {
	delete(preferences.icons)
	delete(preferences.start_tab)
	for &state in preferences.roots do root_state_destroy(&state)
	delete(preferences.roots)
	delete(preferences.path)
	preferences^ = {}
}

preferences_validate :: proc(preferences: ^Preferences) {
	if preferences.icons != "material" && preferences.icons != "emoji" {
		delete(preferences.icons)
		preferences.icons = strings.clone("", preferences.allocator)
	}
	if preferences.start_tab == "" {
		delete(preferences.start_tab)
		preferences.start_tab = strings.clone("tree", preferences.allocator)
	}
}

preferences_load :: proc(preferences: ^Preferences) -> bool {
	contents, err := os.read_entire_file(preferences.path, preferences.allocator)
	if err != nil do return false
	defer delete(contents, preferences.allocator)
	loaded: Preferences
	loaded.allocator = preferences.allocator
	if json.unmarshal(contents, &loaded, allocator = preferences.allocator) != nil {
		preferences_destroy(&loaded)
		return false
	}
	path := preferences.path
	preferences.path = ""
	preferences_destroy(preferences)
	preferences^ = loaded
	preferences.path = path
	preferences.allocator = loaded.allocator
	preferences_validate(preferences)
	return true
}

preferences_save :: proc(preferences: ^Preferences) -> bool {
	dir := filepath.dir(preferences.path, context.temp_allocator)
	if dir_error := os.make_directory_all(dir); dir_error != nil && dir_error != .Exist do return false
	data, marshal_error := json.marshal(preferences^, allocator = preferences.allocator)
	if marshal_error != nil do return false
	defer delete(data, preferences.allocator)
	temp := strings.concatenate({preferences.path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(temp, data) != nil do return false
	if rename_error := os.rename(temp, preferences.path); rename_error != nil {
		_ = os.remove(temp)
		return false
	}
	return true
}

preferences_root_state :: proc(preferences: ^Preferences, root: string) -> ^Root_State {
	for &state in preferences.roots {
		if state.root == root do return &state
	}
	return nil
}

preferences_expanded :: proc(preferences: ^Preferences, root: string) -> []string {
	state := preferences_root_state(preferences, root)
	if state == nil do return nil
	return state.expanded[:]
}

preferences_set_expanded :: proc(preferences: ^Preferences, root: string, paths: []string) {
	state := preferences_root_state(preferences, root)
	if state == nil {
		append(&preferences.roots, Root_State{
			root = strings.clone(root, preferences.allocator),
			expanded = make([dynamic]string, preferences.allocator),
		})
		state = &preferences.roots[len(preferences.roots) - 1]
	}
	for path in state.expanded do delete(path)
	clear(&state.expanded)
	for path in paths do append(&state.expanded, strings.clone(path, preferences.allocator))
}

preferences_set_icons :: proc(preferences: ^Preferences, value: string) {
	delete(preferences.icons)
	preferences.icons = strings.clone(value, preferences.allocator)
}

preferences_set_start_tab :: proc(preferences: ^Preferences, value: string) {
	delete(preferences.start_tab)
	preferences.start_tab = strings.clone(value, preferences.allocator)
}

nerd_font_installed :: proc() -> bool {
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{
		command = []string{"fc-match", "-f", "%{family}", "Symbols Nerd Font"},
	}, context.temp_allocator)
	delete(stderr)
	if err != nil || !state.exited || !state.success do return false
	return strings.contains(strings.to_lower(string(stdout), context.temp_allocator), "nerd")
}

resolved_icons :: proc(preferences: ^Preferences) -> string {
	env := strings.to_lower(strings.trim_space(os.get_env("TREK_ICONS", context.temp_allocator)), context.temp_allocator)
	if env == "material" || env == "emoji" do return env
	if preferences.icons == "material" || preferences.icons == "emoji" do return preferences.icons
	if nerd_font_installed() do return "material"
	return "emoji"
}

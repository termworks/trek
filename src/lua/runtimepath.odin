package lua

// Where trek looks for Lua: a path of roots, not a directory.
//
// This is neovim's model, and it is the same one hexe uses -- two tools in one family that
// each invented a layout would stop being a family, and a person who has learned either
// would learn nothing about the other.
//
// An ordered list of roots, each with the same layout inside:
//
//     <root>/plugin/**/*.lua    run at startup, alphabetically
//     <root>/lua/               modules for `require`, never run on their own
//     <root>/after/plugin/      run after everything else
//
// The list, in the order it is read:
//
//     ~/.config/trek                 yours
//     /etc/xdg/trek                  the system's
//     ~/.local/share/trek/site       where packages install
//       + site/pack/*/start/*        each one, as its own root
//     ~/.local/share/trek/runtime    trek's own
//     .../after                      the same list, reversed
//
// What the list buys that one scanned directory does not: trek can ship its own Lua the way
// you ship yours, a package is just another root so installing one is putting a directory in
// place, and order is a feature -- later roots override earlier, and `after/` exists to be
// last.
//
// `plugin/` runs and `lua/` is required. A tool that runs everything it finds leaves a plugin
// author nowhere to keep a helper, and every helper then has to defend itself against running
// twice.

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

RUN_DIR :: "plugin"
LUA_DIR :: "lua"
AFTER_DIR :: "after"

// How deep `plugin/**` is walked, and how many files may run. Bounded because the path
// reaches directories trek does not own.
MAX_DEPTH :: 8
MAX_FILES :: 512

Root :: struct {
	path:  string,
	// An `after` root: same layout, read last.
	after: bool,
}

Plugin_File :: struct {
	path: string,
	// The root, not the `plugin/` directory: a plugin's data sits beside its `plugin/` and
	// `lua/`, so the root is the only useful thing to hand it.
	root: string,
}

config_home :: proc(allocator := context.allocator) -> string {
	// TREK_C names a config FILE, so its directory is the root that file lives in. A test or
	// a one-off config gets a whole root, not just an init.lua.
	explicit := os.get_env("TREK_C", context.temp_allocator)
	if explicit != "" {
		return strings.clone(filepath.dir(explicit, context.temp_allocator), allocator)
	}
	home := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if home == "" {
		h := os.get_env("HOME", context.temp_allocator)
		home, _ = filepath.join([]string{h, ".config"}, context.temp_allocator)
	}
	path, _ := filepath.join([]string{home, "trek"}, allocator)
	return path
}

data_home :: proc(allocator := context.allocator) -> string {
	home := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if home == "" {
		h := os.get_env("HOME", context.temp_allocator)
		home, _ = filepath.join([]string{h, ".local", "share"}, context.temp_allocator)
	}
	path, _ := filepath.join([]string{home, "trek"}, allocator)
	return path
}

// Every root, in the order they are read.
//
// The `after` half is the first half reversed, so the root that comes first -- yours -- also
// gets the last word. That is what makes `after/` an override seam rather than just another
// place to put files.
roots :: proc(allocator := context.allocator) -> []Root {
	head := make([dynamic]string, context.temp_allocator)
	append(&head, config_home(context.temp_allocator))
	append(&head, "/etc/xdg/trek")

	data := data_home(context.temp_allocator)
	site, _ := filepath.join([]string{data, "site"}, context.temp_allocator)
	append(&head, site)
	append_packages(&head, site)
	runtime_dir, _ := filepath.join([]string{data, "runtime"}, context.temp_allocator)
	append(&head, runtime_dir)

	out := make([dynamic]Root, allocator)
	for path in head do append(&out, Root{path = strings.clone(path, allocator)})
	#reverse for path in head {
		joined, _ := filepath.join([]string{path, AFTER_DIR}, allocator)
		append(&out, Root{path = joined, after = true})
	}
	return out[:]
}

roots_destroy :: proc(list: []Root) {
	for root in list do delete(root.path)
	delete(list)
}

// `pack/<any>/start/<plugin>` under the site directory, each added as a root.
//
// The `<any>` level lets a person group what they installed -- by where it came from, by what
// it is for -- without trek having an opinion about the grouping. A plugin is laid out exactly
// like a config root, so one can be developed beside your `init.lua` and moved into a package
// later without being edited.
append_packages :: proc(head: ^[dynamic]string, site: string) {
	pack, _ := filepath.join([]string{site, "pack"}, context.temp_allocator)
	groups := sorted_entries(pack, .Directory, context.temp_allocator)
	for group in groups {
		start, _ := filepath.join([]string{pack, group, "start"}, context.temp_allocator)
		names := sorted_entries(start, .Directory, context.temp_allocator)
		for name in names {
			joined, _ := filepath.join([]string{start, name}, context.temp_allocator)
			append(head, joined)
		}
	}
}

// Names of one kind in a directory, sorted.
//
// Sorted because directory order is filesystem order: it differs between machines and changes
// after a reinstall, so an unsorted walk makes load order something nobody can reproduce.
//
// A symlink is resolved before its kind is judged. Symlinking a plugin -- one file, or a whole
// directory -- into a root is how people develop one, and a walk that skipped links would work
// everywhere except on the machine the plugin is being written on.
sorted_entries :: proc(dir: string, kind: os.File_Type, allocator := context.allocator) -> []string {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return {}

	names := make([dynamic]string, allocator)
	for info in infos {
		if len(info.name) > 0 && info.name[0] == '.' do continue
		actual := info.type
		if actual == .Symlink {
			path, _ := filepath.join([]string{dir, info.name}, context.temp_allocator)
			resolved, stat_err := os.stat(path, context.temp_allocator)
			if stat_err != nil do continue
			actual = resolved.type
		}
		if actual != kind do continue
		if kind == .Regular && !strings.has_suffix(info.name, ".lua") do continue
		append(&names, strings.clone(info.name, allocator))
	}
	slice.sort(names[:])
	return names[:]
}

// Every file that would run, in the order it would run.
//
// `<root>/plugin/**/*.lua` for each root in path order, sorted within a directory,
// subdirectories after the files beside them.
plugin_files :: proc(list: []Root, allocator := context.allocator) -> []Plugin_File {
	out := make([dynamic]Plugin_File, allocator)
	for root in list {
		dir, _ := filepath.join([]string{root.path, RUN_DIR}, context.temp_allocator)
		walk_plugins(dir, root.path, &out, 0, allocator)
	}
	return out[:]
}

plugin_files_destroy :: proc(files: []Plugin_File) {
	for file in files do delete(file.path)
	delete(files)
}

walk_plugins :: proc(
	dir, root: string,
	out: ^[dynamic]Plugin_File,
	depth: int,
	allocator := context.allocator,
) {
	if depth >= MAX_DEPTH || len(out) >= MAX_FILES do return

	files := sorted_entries(dir, .Regular, context.temp_allocator)
	for name in files {
		if len(out) >= MAX_FILES do return
		path, _ := filepath.join([]string{dir, name}, allocator)
		append(out, Plugin_File{path = path, root = root})
	}

	subs := sorted_entries(dir, .Directory, context.temp_allocator)
	for name in subs {
		sub, _ := filepath.join([]string{dir, name}, context.temp_allocator)
		walk_plugins(sub, root, out, depth + 1, allocator)
	}
}

// `package.path` for `require`, built from the same roots.
//
// `<root>/lua/?.lua` for every root, so a plugin's helper is `require("thing.util")` wherever
// the plugin lives. The config directory itself is also on it -- not only its `lua/` -- so a
// fragment kept beside init.lua stays `require("mine")`.
require_path :: proc(list: []Root, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	cfg := config_home(context.temp_allocator)
	strings.write_string(&b, cfg)
	strings.write_string(&b, "/?.lua;")
	strings.write_string(&b, cfg)
	strings.write_string(&b, "/?/init.lua;")
	for root in list {
		strings.write_string(&b, root.path)
		strings.write_string(&b, "/" + LUA_DIR + "/?.lua;")
		strings.write_string(&b, root.path)
		strings.write_string(&b, "/" + LUA_DIR + "/?/init.lua;")
	}
	// Trailing entry with no separator after it, so the string never ends in `;` -- which Lua
	// reads as an empty template and silently tries to load the bare name.
	strings.write_string(&b, "./.trek/lua/?.lua")
	return strings.to_string(b)
}

// Whether plugins run at all. `--noplugin`, or TREK_NOPLUGIN.
//
// The first question when a tool misbehaves is "is it me or a plugin?", and a tool with no way
// to start without them makes that unanswerable.
@(private = "file")
plugins_disabled: bool

set_plugins_enabled :: proc(on: bool) {
	plugins_disabled = !on
}

plugins_enabled :: proc() -> bool {
	if plugins_disabled do return false
	return os.get_env("TREK_NOPLUGIN", context.temp_allocator) == ""
}

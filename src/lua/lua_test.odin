package lua

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import tui "../tui"

lua_test_root :: proc(t: ^testing.T) -> string {
	root, err := os.make_directory_temp("", "trek-lua-*", context.allocator)
	testing.expect(t, err == nil)
	return root
}

@(test)
test_lua_reads_settings_tabs_and_nodes :: proc(t: ^testing.T) {
	root := lua_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	engine: Engine
	testing.expect(t, engine_init(&engine, root), engine.error)
	defer engine_destroy(&engine)
	source := `
local trek = require("trek")
trek.hidden = true
trek.start_tab = "todo"
trek.tab("todo", {
  title = "TODO",
  icon = "T",
  rows = function(ctx)
    return {
      trek.row({trek.text("item", {fg = "added"}), trek.spacer()}),
      trek.text(__trek_host.platform),
    }
  end,
})
`
	testing.expect(t, run_source(&engine, source, "@fixture.lua"), engine.error)
	testing.expect(t, engine_read_api(&engine), engine.error)
	testing.expect(t, engine.settings.hidden)
	testing.expect_value(t, engine.settings.start_tab, "todo")
	testing.expect_value(t, len(engine.tabs), 1)
	testing.expect_value(t, engine.tabs[0].name, "todo")
	nodes, message := engine_tab_rows(&engine, "todo")
	defer {
		for &node in nodes do tui.node_destroy(&node)
		delete(nodes)
		delete(message)
	}
	testing.expect_value(t, message, "")
	testing.expect_value(t, len(nodes), 2)
	testing.expect_value(t, nodes[0].kind, tui.Node_Kind.Row)
	testing.expect_value(t, nodes[1].value, "linux")
}

@(test)
test_lua_handler_errors_include_chunk_name :: proc(t: ^testing.T) {
	root := lua_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	engine: Engine
	testing.expect(t, engine_init(&engine, root), engine.error)
	defer engine_destroy(&engine)
	testing.expect(t, !run_source(&engine, "error('boom')", "@broken.lua"))
	testing.expect(t, strings.contains(engine.error, "broken.lua"))
	testing.expect(t, strings.contains(engine.error, "boom"))
}

@(test)
test_lua_exec_is_a_cached_poll :: proc(t: ^testing.T) {
	root := lua_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	engine: Engine
	testing.expect(t, engine_init(&engine, root), engine.error)
	defer engine_destroy(&engine)
	source := `
local trek = require("trek")
trek.tab("poll", {
  rows = function(ctx)
    local out = ctx.exec({"printf", "ready"})
    if out == nil then return {trek.text("pending")} end
    return {trek.text(out.stdout)}
  end,
})
`
	testing.expect(t, run_source(&engine, source, "@poll.lua"), engine.error)
	testing.expect(t, engine_read_api(&engine), engine.error)
	nodes, message := engine_tab_rows(&engine, "poll")
	testing.expect_value(t, message, "")
	testing.expect_value(t, nodes[0].value, "pending")
	for &node in nodes do tui.node_destroy(&node)
	delete(nodes)
	delete(message)
	value := ""
	for _ in 0 ..< 100 {
		time.sleep(10 * time.Millisecond)
		nodes, message = engine_tab_rows(&engine, "poll")
		if len(nodes) > 0 && nodes[0].value == "ready" {
			value = "ready"
			for &node in nodes do tui.node_destroy(&node)
			delete(nodes)
			delete(message)
			break
		}
		for &node in nodes do tui.node_destroy(&node)
		delete(nodes)
		delete(message)
	}
	testing.expect_value(t, value, "ready")
}

@(test)
test_lua_key_and_event_handlers_survive_errors :: proc(t: ^testing.T) {
	root := lua_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	engine: Engine
	testing.expect(t, engine_init(&engine, root), engine.error)
	defer engine_destroy(&engine)
	source := `
local trek = require("trek")
trek.keys.tree["?"] = function(ctx) ctx.goto_tab("graph") end
trek.keys.tree["enter"] = function(ctx) ctx.reveal("enter") end
trek.menu.tree["mark"] = {
  label = "Mark",
  when = function(ctx) return ctx.row.path ~= "" end,
  run = function(ctx) ctx.reveal(ctx.row.path) end,
}
trek.on.root(function(path) error("first") end)
trek.on.root(function(path) __trek_host.reveal(path) end)
`
	testing.expect(t, run_source(&engine, source, "@handlers.lua"), engine.error)
	testing.expect(t, engine_read_api(&engine), engine.error)
	handled, key_error := engine_handle_key(&engine, "tree", tui.Key{code = .Rune, rune = '?'})
	defer delete(key_error)
	testing.expect(t, handled)
	testing.expect_value(t, key_error, "")
	testing.expect_value(t, engine.pending_tab, "graph")
	special_error: string
	handled, special_error = engine_handle_key(&engine, "tree", tui.Key{code = .Enter})
	defer delete(special_error)
	testing.expect(t, handled)
	testing.expect_value(t, special_error, "")
	testing.expect_value(t, engine.pending_reveal, "enter")
	delete(engine.pending_reveal)
	engine.pending_reveal = ""
	entries, menu_error := engine_menu_entries(&engine, "tree", root, true)
	defer {
		for &entry in entries {
			delete(entry.id)
			delete(entry.label)
		}
		delete(entries)
		delete(menu_error)
	}
	testing.expect_value(t, menu_error, "")
	testing.expect_value(t, len(entries), 1)
	testing.expect_value(t, entries[0].id, "mark")
	run_error := engine_run_menu(&engine, "tree", "mark", root, true)
	defer delete(run_error)
	testing.expect_value(t, run_error, "")
	testing.expect_value(t, engine.pending_reveal, root)
	delete(engine.pending_reveal)
	engine.pending_reveal = ""
	event_error := engine_emit(&engine, "root", root)
	defer delete(event_error)
	testing.expect(t, strings.contains(event_error, "first"))
	testing.expect_value(t, engine.pending_reveal, root)
}

// Rule 4: a fragment registers itself and returns nothing, and the host discovers it.
// Without this a config that wants somebody else's tab has to require, shape-check and
// merge a returned table by hand, and every further fragment re-implements that.
//
// And the runtimepath's own rules, which are the parts that are easy to get wrong and
// impossible to notice when they are: `plugin/` runs while `lua/` only answers `require`,
// order is path order between roots and alphabetical within one, `after/` really is last,
// a plugin is handed its own root so it can read a file it ships, and one plugin raising
// does not stop the others.
//
// One test rather than several because TREK_C is process-global and the runner is
// threaded: two tests setting it would race, and the loser would fail for a reason that has
// nothing to do with what it was checking.
@(test)
test_plugins_are_discovered_on_the_runtimepath :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "trek-plugins-*", context.allocator)
	testing.expect(t, err == nil)
	defer { _ = os.remove_all(root); delete(root) }

	write :: proc(dir, name, body: string) {
		path, _ := filepath.join([]string{dir, name}, context.allocator)
		defer delete(path)
		_ = os.write_entire_file_from_string(path, body)
	}
	mkdir :: proc(parts: ..string) -> string {
		path, _ := filepath.join(parts, context.allocator)
		_ = os.make_directory_all(path)
		return path
	}

	plugin_dir := mkdir(root, "plugin")
	defer delete(plugin_dir)
	lua_dir := mkdir(root, "lua")
	defer delete(lua_dir)
	after_dir := mkdir(root, "after", "plugin")
	defer delete(after_dir)
	legacy_dir := mkdir(root, "plugins")
	defer delete(legacy_dir)
	write(legacy_dir, "mine.lua", `local trek = require("trek")
trek.tab("stale", {rows = function(ctx) return {} end})`)

	// A file the root ships, beside its `plugin/` rather than inside it.
	write(root, "shipped.txt", "carried along")

	// Sorted by name, so a raise in the middle must not stop the last one.
	write(plugin_dir, "10-first.lua", `local trek = require("trek")
trek.tab("first", {rows = function(ctx) return {} end})
trek.tab("shared", {title = "from the plugin", rows = function(ctx) return {} end})`)
	write(plugin_dir, "20-broken.lua", `error("deliberately broken")`)
	write(plugin_dir, "30-last.lua", `local trek = require("trek")
local helper = require("helper")
local here = ...
local f = io.open(here .. "/shipped.txt", "r")
local shipped = f and f:read("*l") or "NO-SHIPPED-FILE"
if f then f:close() end
trek.tab("last", {title = helper.title, rows = function(ctx) return {} end})
trek.tab("reader", {title = shipped, rows = function(ctx) return {} end})`)

	// Required by a plugin: its body runs because something required it, which is exactly why
	// it cannot be the file that proves `lua/` is not auto-run.
	write(lua_dir, "helper.lua", `return {title = "from a lua/ module"}`)
	// Required by nothing. If `lua/` were auto-run the way `plugin/` is, this would register
	// a tab -- the only way to tell the two directories apart.
	write(lua_dir, "never.lua", `local trek = require("trek")
trek.tab("MUSTNOTRUN", {rows = function(ctx) return {} end})`)

	// `after/` is last however it sorts: `aa` beats every other name alphabetically and must
	// still get the final word over the plugin that claimed the same tab.
	write(after_dir, "aa.lua", `local trek = require("trek")
trek.tab("shared", {title = "from after", rows = function(ctx) return {} end})`)

	// The config names no plugin, and no longer wins by ordering: it runs BEFORE them now.
	write(root, "init.lua", `local trek = require("trek")
trek.tab("shared", {title = "from the config", rows = function(ctx) return {} end})`)

	config, _ := filepath.join([]string{root, "init.lua"}, context.allocator)
	defer delete(config)
	os.set_env("TREK_C", config)
	defer os.unset_env("TREK_C")

	engine: Engine
	testing.expect(t, engine_init(&engine, root))
	defer engine_destroy(&engine)
	testing.expect(t, engine_load_config(&engine))

	names := make(map[string]string, context.allocator)
	defer delete(names)
	for tab in engine.tabs do names[tab.name] = tab.title
	// Both sides of the broken plugin loaded.
	testing.expect(t, "first" in names)
	testing.expect(t, "last" in names)
	// `lua/` answered a require, and the file nothing required never ran.
	testing.expect_value(t, names["last"], "from a lua/ module")
	testing.expect(t, !("MUSTNOTRUN" in names))
	// It was handed its own root, so it found a file it ships.
	testing.expect_value(t, names["reader"], "carried along")
	// `after/` ran last, over both the plugin and the config.
	testing.expect_value(t, names["shared"], "from after")
	// And the failure was reported rather than swallowed or made fatal.
	testing.expect(t, strings.contains(engine.plugin_error, "20-broken.lua"))

	// The directory plugins used to live in is called out rather than silently ignored: an
	// upgrade that just stops reading it looks like the plugins broke, and sends somebody
	// debugging a file that is fine. Said, not supported -- loading it too would be a second
	// mechanism for one idea.
	testing.expect(t, !("stale" in names))
	// Asserted on the notice's own words and on the legacy path: "plugin/" alone would be
	// satisfied by the broken plugin's own path in the other half of the message.
	testing.expect(t, strings.contains(engine.plugin_error, "no longer read"))
	testing.expect(t, strings.contains(engine.plugin_error, legacy_dir))
}

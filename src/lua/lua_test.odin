package lua

import "core:os"
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

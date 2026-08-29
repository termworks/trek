local trek = require("trek")


-- Settings are assigned. Anything left unmentioned keeps its default, so this file is
-- the difference from stock rather than a copy of it.

trek.hidden = false
trek.start_tab = "tree"

-- The viewport, when trek should not fill the terminal. Cells or a share of the screen:
-- `60` is sixty columns, `"50%"` is half of whatever the window is now, which is the
-- form that survives a resize.
--
-- Left unset here because the shell that opens trek usually decides — oslo's `nav` sizes
-- the float it draws trek in.
-- trek.width = "50%"
-- trek.height = "80%"
-- trek.align = "center"

-- How much of its own width the explorer gives up when `p` opens a preview beside it.
-- A list of names needs far less room than the file it is listing, and the room has to
-- come from somewhere. Only ever visible inside hexe, which is what draws the preview.
trek.preview_shrink = 40


-- Keys are registered per tab, keyed by the chord, so binding the same one twice
-- replaces rather than stacks.
--
-- `ctx` carries the row under the cursor and the ways to act on it: ctx.root, ctx.row,
-- ctx.exec, ctx.goto_tab, ctx.reveal, ctx.stage, ctx.suspend.

trek.keys.tree["ctrl+e"] = function(ctx)
  if ctx.row and not ctx.row.is_dir then
    ctx.suspend({os.getenv("EDITOR") or "vi", ctx.row.path})
  end
end

trek.keys.changes["ctrl+s"] = function(ctx)
  if ctx.row then ctx.stage(ctx.row.path) end
end


-- Handlers are registered, and registering again adds another rather than replacing the
-- first: one thing per function, several functions per event.
--
-- `on.root` is trek moving to a different directory; `on.open` is a row being opened.

trek.on.root(function(ctx)
  -- Somewhere to hang per-project behaviour. Left quiet by default.
  _ = ctx.root
end)


-- Tabs are registered the same way plugins register theirs — see plugin/tags.lua for
-- one that ships. `when` decides whether the tab belongs in the activity bar at all; it
-- runs on root changes, so it may do real work.

-- trek.tab("todo", {
--   icon = "\u{f0ae}",
--   title = "TODO",
--   when = function(ctx)
--     local result = ctx.exec({"test", "-d", ctx.root .. "/.git"})
--     return result ~= nil and result.success
--   end,
--   rows = function(ctx)
--     local result = ctx.exec({"rg", "--line-number", "TODO", ctx.root})
--     if result == nil then return {trek.text("  scanning…", {dim = true})} end
--     return {trek.text(result.stdout)}
--   end,
-- })

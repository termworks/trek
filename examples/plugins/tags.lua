-- The latest tags in this repository, as a tab of their own.
--
-- Copy to ~/.config/trek/plugins/tags.lua. It registers and returns nothing, so
-- nothing has to be required or merged by hand.

local trek = require("trek")

local LIMIT = 15

local function git(ctx, ...)
  return ctx.exec({"git", "-C", ctx.root, ...})
end

trek.tab("tags", {
  icon = "",
  title = "Tags",

  -- `when` runs on root changes, so it may ask git. The first answer is nil -- the
  -- process has not finished -- and trek asks again when it does, which is why this
  -- tests `success` rather than "did I get a result".
  when = function(ctx)
    local result = git(ctx, "rev-parse", "--git-dir")
    return result ~= nil and result.success
  end,

  rows = function(ctx)
    local result = git(ctx, "tag", "--sort=-creatordate",
      "--format=%(refname:short)\t%(creatordate:short)\t%(subject)")
    if result == nil then
      return {trek.text("  reading tags…", {dim = true})}
    end

    local rows = {}
    for line in result.stdout:gmatch("[^\n]+") do
      local name, date, subject = line:match("^([^\t]*)\t([^\t]*)\t(.*)$")
      rows[#rows + 1] = trek.row({
        trek.text("  " .. (name or line), {fg = "accent", bold = true}),
        trek.text("  " .. (date or ""), {dim = true}),
        trek.text("  " .. (subject or "")),
        trek.spacer(),
      })
      if #rows >= LIMIT then break end
    end

    if #rows == 0 then
      return {trek.text("  no tags yet", {dim = true})}
    end
    return rows
  end,
})

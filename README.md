# trek

`trek` is a standalone terminal file explorer and Git browser written in Odin.
It provides an Explorer-style tree, a changes view, a commit graph, and a Lua
configuration layer in one tabbed interface.

The tree and interface are derived from
[herdr-sidebar](https://github.com/alexarthurs/herdr-sidebar), with the herdr
multiplexer integration removed. The node vocabulary follows pixy. See
`LICENSE` for attribution.

## Build

The build recipes live in `.make.lua` and run through
[oslo](https://github.com/termworks/oslo). At an oslo prompt, use `make`;
elsewhere, prefix the same recipes with `oslo`.

```sh
make build
make test
make verify
make run
```

`make build` produces `target/trek` and rejects a dynamically linked artifact.

Focused tests can be selected without bypassing the project recipes:

```sh
make test --package git
make test --package lua --names lua.test_lua_exec_is_a_cached_poll --threads 1
```

## Usage

```sh
trek [path]
```

Core keys:

| key | action |
|---|---|
| `↑` / `↓` | move selection |
| `Enter` | expand or collapse a directory |
| `.` | toggle hidden files |
| `i` | toggle icon theme |
| `r` | refresh directory listings |
| `m` / right click | open the context menu |
| `1`…`9` | switch tabs |
| `,` | open settings |
| `q` | quit |

Mouse-wheel scrolling changes only the viewport; it never moves the selected
row. Keyboard navigation brings the selection back into view.

The Explorer menu can create, rename, delete, and copy paths, change the root,
and stage changes without crossing nested-repository boundaries. The Changes
tab supports staging, unstaging, discarding, and committing across the root and
child repositories. The Graph tab renders all local refs with bounded,
colour-stable commit lanes.

## Configuration

`trek` loads `$TREK_C` when it is set; otherwise it reads
`~/.config/trek/init.lua`. It never executes configuration from the directory
being explored.

```lua
local trek = require("trek")

trek.icons = "material"
trek.hidden = false
trek.git_decorations = true
trek.start_tab = "tree"

trek.keys.tree["ctrl+x"] = function(ctx)
  ctx.stage(ctx.row.path)
end

trek.menu.tree["edit"] = {
  label = "Open in editor",
  when = function(ctx) return not ctx.row.is_dir end,
  run = function(ctx)
    ctx.suspend({os.getenv("EDITOR"), ctx.row.path})
  end,
}

trek.tab("todo", {
  icon = "T",
  title = "TODO",
  rows = function(ctx)
    local result = ctx.exec({"rg", "--json", "TODO"})
    if result == nil then return {trek.text("scanning…", {dim = true})} end
    return {trek.text(result.stdout)}
  end,
})
```

Lua tabs use the same `text`, `row`, `column`, `pad`, `truncate`, `style`,
`spacer`, `transparent`, `priority`, and `region` nodes as built-in tabs.
`ctx.exec` is an argv-only cached poll with four workers, a five-second timeout,
and a one MiB output limit; it never blocks a redraw. Lua can add tabs, keys,
menus, and event handlers, but cannot replace a built-in row provider.

## State

Preferences and expanded directories are stored in
`$XDG_STATE_HOME/trek/preferences.json`, or
`~/.local/state/trek/preferences.json`. Icon selection resolves in this order:
`TREK_ICONS`, saved preference, then a Nerd Font probe. The settings overlay
changes the icon theme, hidden-file visibility, Git decorations, and start tab.

## License

MIT. See [LICENSE](LICENSE).

# trek

`trek` is a standalone terminal file explorer and Git browser written in Odin.
It provides an Explorer-style tree, a changes view, a commit graph, and a Lua
configuration layer in one tabbed interface.

`trek` starts in tree mode and can switch to a directory-at-a-time explorer
mode, which lets it stand in for a shell's built-in directory browser.

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
make smoke
make verify
make run
```

`make build` produces `target/trek` and rejects a dynamically linked artifact.
`make smoke` keeps that binary open in a PTY until delayed input arrives.

Focused tests can be selected without bypassing the project recipes:

```sh
make test --package git
make test --package lua --names lua.test_lua_exec_is_a_cached_poll --threads 1
```

## Usage

```sh
trek [path] [options]
```

| option | |
|---|---|
| `-e`, `--explore` | start in explorer mode |
| `--cwd-file PATH` | write the directory trek finished in to `PATH` |
| `-h`, `--help` | show help |
| `-V`, `--version` | show the version |

Core keys:

| key | action |
|---|---|
| `↑` / `↓` | move selection |
| `Enter` / `→` | open a directory |
| `←` | parent directory, or collapse |
| `a` | switch between tree and explorer mode |
| `.` | toggle hidden files |
| `r` | refresh directory listings |
| `c` | collapse every folder |
| `m` / right click | open the context menu |
| `1`…`9` | switch tabs |
| `q` | quit |

Mouse-wheel scrolling changes only the viewport; it never moves the selected
row. Keyboard navigation brings the selection back into view.

### Two ways to move

**Tree mode** is the default: a directory unfolds where it stands, with indent
guides showing the nesting, and the root never changes.

**Explorer mode** (`a`, or `--explore`) lists one directory at a time. `Enter`
walks into a folder and re-roots the view there, `←` goes back up, and the
header shows the full path rather than the folder name. Nothing is nested, so
there are no guides and no expanded state to keep.


### Sizing and placement

By default trek fills the terminal. Give it a size and it becomes a box placed
inside one, which is useful when the terminal is far larger than the tree you
are reading:

```sh
trek --width 60 --height 18                  # centred
trek --width 40 --align bottom-right         # a corner panel, full height
```

| setting | |
|---|---|
| `--width N` / `trek.width` | viewport columns; `0` or absent fills the terminal |
| `--height N` / `trek.height` | viewport rows |
| `--align WHERE` / `trek.align` | `center` (default), `top-left`, `top-right`, `bottom-left`, `bottom-right` |
| `trek.border` | frame the box when it does not fill the terminal (default `true`) |

A size larger than the terminal is clamped rather than clipped, so a config
written for a big screen still works on a small one. Command-line flags win over
the config file.

```lua
trek.width = 46
trek.height = 12
trek.align = "bottom-right"
```
### Following trek from a shell

A child process cannot change its parent's working directory, which is why
shells that ship a directory browser build it in. `--cwd-file` closes that gap:
trek writes the directory it finished in, and the caller reads it back.

```sh
trek_cd() {
  local out; out="$(mktemp)"
  trek --explore --cwd-file "$out" "$@"
  local dir; dir="$(cat "$out")"; rm -f "$out"
  [ -n "$dir" ] && cd "$dir"
}
```

In [oslo](https://github.com/termworks/oslo) the same thing is a Lua builtin,
so trek can stand in for the built-in `nav`:

```lua
oslo.register_builtin{
  name = "nav",
  run = function(argv, shell)
    local tmp <close> = oslo.fs.mktempdir()
    local out = tmp .. "/cwd"
    oslo.run{ "trek", "--explore", "--cwd-file", out, argv[2] or "." }
    local dir = oslo.fs.read(out)
    if dir and dir ~= "" then oslo.sys.cd(dir) end
    return 0
  end,
}
```

The file is written on every exit path, and is left untouched when trek cannot
start — so a caller that reads an empty or missing file should simply not move.

The Explorer menu can create, rename, delete, and copy paths, change the root,
and stage changes without crossing nested-repository boundaries. The Changes
tab lists NEW, MODIFIED, and STAGED files; `Enter` moves a file between
unstaged and staged, and the commit box commits what is staged. The Graph tab
renders all local refs with bounded, colour-stable commit lanes, laid out like
`git log --graph --all` with a `git tree`-style entry: hash, date, age, author and
refs on one line, the subject beneath it, and a blank line between commits. The age
reproduces git's own `%ar` wording, including its 90-minute and 36-hour thresholds.
## Configuration

`trek` loads `$TREK_C` when it is set; otherwise it reads
`~/.config/trek/init.lua`. It never executes configuration from the directory
being explored.

```lua
local trek = require("trek")

trek.hidden = false
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

A tab can decide whether it belongs in the activity bar at all. `when` is called
when the root changes — not per frame — so it may do real work, and a tab
without one is always shown:

```lua
trek.tab("cargo", {
  icon = "C",
  title = "Cargo",
  when = function(ctx) return ctx.exec({"test", "-f", ctx.root .. "/Cargo.toml"}) ~= nil end,
  rows = function(ctx) return { trek.text("  crate") } end,
})
```

The built-in Changes and Graph tabs use the same mechanism: both disappear the
moment you walk out of a repository and come back when you walk into one. A
hidden tab holds no slot, so the number keys always address what is on screen,
and it cannot be reached by `Tab`, by number, or by name. If the tab you are
looking at disappears, trek falls back to the first one still in the bar.

## State

Preferences and expanded directories are stored in
`$XDG_STATE_HOME/trek/preferences.json`, or
`~/.local/state/trek/preferences.json`. Hidden-file visibility, the expanded
set, and the start tab persist between runs. Icons are always the Nerd Font set;
there is no second theme and no settings overlay.

## License

MIT. See [LICENSE](LICENSE).

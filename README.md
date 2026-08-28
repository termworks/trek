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
trek [path or file] [options]
```

The argument says where to start **and**, optionally, what to start on. A directory
opens there with the cursor on its first row; a **file** opens the directory around it
with the cursor on that file. One argument rather than two, because an editor asking for
a sidebar has the file in hand, not the directory:

```sh
trek src/main.odin        # opens src/, cursor on main.odin
```

| option | |
|---|---|
| `-e`, `--explore` | start in explorer mode |
| `--cwd-file PATH` | write the directory trek finished in to `PATH` |
| `--width N`, `--height N` | cells, or a share of the terminal: `--width 50%` |
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
| `?` | shortcut list |
| `1`…`9` | switch tabs |
| `q` | quit |

The activity strip carries a `?` at its foot; it and the `?` key open the shortcut
list. Every dialog — the context menu, a rename prompt, a delete confirmation and
that list — is the same centred panel. There is no permanent hint line: the footer
appears only while trek has something to report and gives the row back otherwise.

Mouse-wheel scrolling changes only the viewport; it never moves the selected
row. Keyboard navigation brings the selection back into view.

### Two ways to move

<!-- demo:explorer -->
<!-- /demo:explorer -->

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
| `--width N` / `trek.width` | viewport columns, or a share: `50%` / `"50%"`. `0` or absent fills the terminal |
| `--height N` / `trek.height` | viewport rows, or a share: `80%` / `"80%"` |
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
<!-- demo:changes -->
<!-- /demo:changes -->

<!-- demo:graph -->
<!-- /demo:graph -->


The Explorer menu can create, rename, delete, and copy paths, change the root,
and stage changes without crossing nested-repository boundaries. The Changes
tab lists NEW, MODIFIED, and STAGED files; `Enter` moves a file between
unstaged and staged, and the commit box commits what is staged. The Graph tab
renders all local refs with bounded, colour-stable commit lanes, laid out like
`git log --graph --all` with a `git tree`-style entry: hash, date, age, author and
refs and subject reflowed as one paragraph at the pane width, exactly as `%w(80,0,0)`
does, and a blank line between commits. The age
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
  when = function(ctx)
    local result = ctx.exec({"test", "-f", ctx.root .. "/Cargo.toml"})
    return result ~= nil and result.success
  end,
  rows = function(ctx) return { trek.text("  crate") } end,
})
```

`ctx.exec` answers `nil` until the process it started finishes, so a `when` that
asks one is necessarily wrong the first time it is called. trek asks every tab
again the moment a background command completes, which is why the predicate tests
`result.success` rather than "did I get a result" — the latter is true for a
command that ran and failed.

The built-in Changes and Graph tabs use the same mechanism: both disappear the
moment you walk out of a repository and come back when you walk into one. A
hidden tab holds no slot, so the number keys always address what is on screen,
and it cannot be reached by `Tab`, by number, or by name. If the tab you are
looking at disappears, trek falls back to the first one still in the bar.


### Plugins

A file in `~/.config/trek/plugins/*.lua` is discovered and run automatically. It
registers what it wants and returns nothing, exactly like `init.lua`:

```lua
-- ~/.config/trek/plugins/todo.lua
local trek = require("trek")

trek.tab("todo", {
  icon = "T",
  title = "TODO",
  rows = function(ctx) ... end,
})
```

A worked example ships in `examples/plugins/tags.lua`: the repository's latest
tags, in a tab that is there only inside a repository.

Nothing has to be required or merged by hand — the host does the discovery, so a
config that wants somebody else's tab does not grow shape-checking for it.

Plugins run **before** `init.lua`, in name order. Since every registrar is keyed,
registering the same name again replaces the earlier one, so your own config always
wins over a plugin's — and prefixing files (`10-`, `20-`) fixes the order between
plugins rather than leaving it to the filesystem.

A plugin that raises is **reported in the footer and skipped**; the ones after it
still load. That is deliberately unlike `init.lua`, where a raise is fatal: your own
file failing means carrying on would silently apply settings you did not ask for,
while a third-party plugin failing must not take the tool down with it.

## Previewing, when hexe is drawing

Press `p` and the selected row appears in a second float beside this one: `bat` for a
file, `eza` for a directory, following the cursor as it moves. Press it again to close.

trek does not draw any of that. It knows *what is selected*; hexe knows how to put a
pane beside another one — so trek hands over a path and hexe renders it, and trek never
learns what `bat` or `eza` are. Outside hexe the key answers `preview needs hexe` and
nothing else in trek changes.

```
p ──► a float opens hard right, trek moves hard left
      cursor moves ──► the path goes down a fifo ──► bat/eza redraws
      q or p       ──► the fifo closes, the float ends
```

The order is not incidental. Opening a float puts every *other* float back at the
position it was declared with, so an explorer that stepped aside first would be moved
back underneath the preview. It opens first and trek moves second, and trek then asks
hexe where it actually ended up: if the move did not take, there is no preview rather
than one covering the thing it describes.

The two are anchored to opposite edges with their widths adding to the window, so they
are adjacent by construction. `x` in hexe is an anchor in the space a float does not
fill — 0 flush left, 100 flush right — not a centre and not a left edge; reading it as
a centre is how a pair that computes as adjacent lands twenty-four columns on top of
itself.

The channel is a fifo trek holds open for writing, and that choice does the cleanup:
the reader sees EOF the moment trek's descriptor closes, so the preview dies with trek
whether trek exited or crashed. There is no float to orphan and no pid to remember. The
descriptor is opened `O_CLOEXEC` for the same reason — without it the float trek spawns
inherits it, becomes a writer itself, and the reader waits on a pipe that can never end.

Stepping aside uses hexe's `geometry` on trek's own pane socket, which costs `read`
there because the selector cannot reach past the caller. An older hexe refuses that
verb by name; the preview still opens, beside a float that did not move.

## Answering other programs

A running trek can be asked where it is standing. This is a **socket only** — trek writes no
spawn descriptor, because its truth *is* the process: a fresh `trek` knows nothing about this
one's root, expansion or selection, so answering from a new process would succeed while being
wrong.

```sh
trek --serve            # bind a control socket; without this there is none
trek --lua-api          # print the client library
```

The socket lands at `$XDG_RUNTIME_DIR/onix/trek/<pid>.sock`, the same family directory oslo
uses, so a sibling looks in one place for every tool. The directory is `0700` and a connecting
uid that is not the owner's is refused, using the credentials the kernel reports rather than
anything the peer said.

### The surface

Small on purpose: these are facts that exist only inside a running trek. Nothing here runs a
command — that is a decision, not an omission.

| verb | |
|---|---|
| `cwd()` | the directory trek is showing |
| `selection()` | the path under the cursor, or `nil` |
| `tabs()` | the panels currently in the activity strip |
| `session()` | `{id, root, tab, socket}` |
| `verbs()` | every name this trek will answer |
| `client()` | the client library, for a host that cannot shell out |
| `subscribe(event)` | push when trek moves; returns an id |
| `unsubscribe(id)` | stop pushing |

### From oslo

```lua
local src  = io.popen("trek --lua-api"):read("a")
local trek = load(src)(oslo.stream)
local t    = trek.connect()
print(t.cwd())
t:close()
```

The wire is oslo's: four bytes of big-endian length, then JSON. A request is
`{"call":name,"args":[…]}` and a reply is `{"ok":true,"n":1,"result":[…]}` — `result` is a
*list* because a Lua function returns several things, and a family whose members disagree
about that fails silently rather than loudly. A refused verb is a reply
(`{"ok":false,"error":"no such call: x"}`), not a dropped connection. One connection serves
many calls.

### Events

trek can push when it moves, instead of being asked. Two events, both things a sibling cannot
observe any other way:

| event | fires when |
|---|---|
| `root` | trek re-roots — walking into or out of a directory |
| `selection` | the cursor moves onto a different row |

```lua
local t = trek.connect()

t:subscribe("root", function(path) oslo.sys.cd(path) end)

while working do
  t:poll()        -- delivers whatever arrived, here, at a moment you picked
end
```

**A function cannot cross a socket**, so `subscribe` hands back an opaque id and the handler
stays on your side. A push is `{"event":"root","sub":1,"args":[…]}` — it carries `event` where
a reply carries `ok`, and that one difference is the whole reentrancy contract:

> An event can arrive while a call is outstanding, because trek pushes when it moves rather
> than when it is asked. `call` therefore reads frames until it finds its *reply* and parks any
> event it passes on the way. Nothing is dispatched from inside a call — a handler running
> there could call back into the session it is suspended in, and neither side has an answer for
> that. `poll` delivers the parked events afterwards, at a moment the caller chose.

A subscriber that stops reading is dropped rather than buffered without end, and a connection
is capped at eight subscriptions, so one peer cannot grow trek's memory by ignoring it.
## State

Preferences and expanded directories are stored in
`$XDG_STATE_HOME/trek/preferences.json`, or
`~/.local/state/trek/preferences.json`. Hidden-file visibility, the expanded
set, and the start tab persist between runs. Icons are always the Nerd Font set;
there is no second theme and no settings overlay.

## License

MIT. See [LICENSE](LICENSE).

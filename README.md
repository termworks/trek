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

## License

MIT. See [LICENSE](LICENSE).

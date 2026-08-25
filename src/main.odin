package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import luaconfig "./lua"
import model "./model"
import settings "./settings"
import tabs "./tabs"
import tui "./tui"
import live "./live"
import ui "./ui"

VERSION :: "0.1.3"

Options :: struct {
	root:      string,
	cwd_file:  string,
	// A file given as the path: the row to land on once its directory is open.
	reveal:    string,
	explore:   bool,
	serve:     bool,
	width:     int,
	height:    int,
	align:     string,
	help:      bool,
	version:   bool,
	printed:   bool,
	error:     string,
}

parse_options :: proc(args: []string, default_root: string) -> Options {
	options := Options{root = default_root}
	have_root := false
	index := 0
	for index < len(args) {
		arg := args[index]
		index += 1
		switch arg {
		case "-h", "--help": options.help = true
		case "-V", "--version": options.version = true
		case "-e", "--explore": options.explore = true
		case "--serve": options.serve = true
		case "--lua-api":
			// The client library on stdout, for a host that can shell out. One that
			// cannot asks the running trek for it instead, through the `client` verb.
			fmt.print(string(live.CLIENT_SOURCE))
			options.printed = true
		case "--width", "--height", "--align":
			if index >= len(args) {
				options.error = "option needs a value"
				break
			}
			value := args[index]
			index += 1
			if arg == "--align" {
				options.align = value
				break
			}
			number, parsed := strconv.parse_int(value)
			if !parsed || number < 0 {
				options.error = "size must be a positive number"
			} else if arg == "--width" {
				options.width = number
			} else {
				options.height = number
			}
		case "--cwd-file":
			// Where trek reports the directory it finished in. A child process cannot
			// change its parent's working directory, so a shell that wants to follow
			// trek reads this file after it exits.
			if index >= len(args) {
				options.error = "--cwd-file needs a path"
			} else {
				options.cwd_file = args[index]
				index += 1
			}
		case:
			if strings.has_prefix(arg, "-") {
				options.error = "unknown option"
			} else if have_root {
				options.error = "only one root path is accepted"
			} else {
				options.root = arg
				have_root = true
			}
		}
	}
	return options
}

usage :: proc() {
	fmt.println("trek")
	fmt.println("")
	fmt.println("Usage:")
	fmt.println("  trek [path or file] [options]")
	fmt.println("")
	fmt.println("  A directory opens there. A file opens its directory with that file selected.")
	fmt.println("")
	fmt.println("Options:")
	fmt.println("  -e, --explore        start in explorer mode (walk into directories)")
	fmt.println("      --serve          bind a control socket other programs can query")
	fmt.println("      --lua-api        print the client library, then exit")
	fmt.println("      --cwd-file PATH  write the directory trek finished in to PATH")
	fmt.println("      --width N        viewport columns (default: the terminal)")
	fmt.println("      --height N       viewport rows (default: the terminal)")
	fmt.println("      --align WHERE    center, top-left, top-right, bottom-left, bottom-right")
	fmt.println("  -h, --help           show this help")
	fmt.println("  -V, --version        show the version")
	fmt.println("")
	fmt.println("Keys:")
	fmt.println("  ↑↓ move   Enter open   ← parent/collapse   a explorer mode")
	fmt.println("  . hidden  r refresh    m menu   1-9 tabs    q quit")
}

run_suspended :: proc(config: ^luaconfig.Engine, terminal: ^tui.Terminal, buffer: ^tui.Buffer) -> bool {
	if len(config.pending_suspend) == 0 do return true
	tui.terminal_restore(terminal)
	process, start_error := os.process_start(os.Process_Desc{
		working_dir = config.root,
		command = config.pending_suspend[:],
		stdin = os.stdin,
		stdout = os.stdout,
		stderr = os.stderr,
	})
	if start_error == nil do _, _ = os.process_wait(process)
	for arg in config.pending_suspend do delete(arg)
	clear(&config.pending_suspend)
	if !tui.terminal_enter(terminal) do return false
	tui.buffer_invalidate(buffer)
	return true
}

run_tui :: proc(root: string, options: Options) -> bool {
	preferences: settings.Preferences
	settings.preferences_init(&preferences)
	_ = settings.preferences_load(&preferences)
	defer settings.preferences_destroy(&preferences)
	config: luaconfig.Engine
	if !luaconfig.engine_init(&config, root) ||
	   !luaconfig.engine_apply_defaults(&config, preferences.hidden, preferences.start_tab) ||
	   !luaconfig.engine_load_config(&config) {
		fmt.eprintln("trek:", config.error)
		luaconfig.engine_destroy(&config)
		return false
	}
	defer luaconfig.engine_destroy(&config)
	preferences.hidden = config.settings.hidden
	settings.preferences_set_start_tab(&preferences, config.settings.start_tab)
	terminal: tui.Terminal
	if !tui.terminal_enter(&terminal) {
		fmt.eprintln("trek requires an interactive terminal")
		return false
	}
	defer tui.terminal_restore(&terminal)
	previous_assertion := tui.terminal_arm_panic_restore(&terminal)
	defer tui.terminal_disarm_panic_restore(previous_assertion)
	_ = tui.terminal_install_signal_handlers()

	width, height, ok := tui.terminal_size()
	if !ok {
		width, height = 80, 24
	}
	buffer: tui.Buffer
	tui.buffer_init(&buffer, width, height)
	defer tui.buffer_destroy(&buffer)
	layout: tui.Layout
	tui.layout_init(&layout)
	defer tui.layout_destroy(&layout)
	decoder: tui.Decoder
	tui.decoder_init(&decoder)
	defer tui.decoder_destroy(&decoder)
	shell: ui.Shell
	ui.shell_init(&shell)
	defer ui.shell_destroy(&shell)
	ui.shell_set_config(&shell, &config)
	ui.shell_set_preferences(&shell, &preferences)
	defer ui.shell_save_preferences(&shell)
	ui.shell_add_tab(&shell, tabs.tree_tab(root, preferences.hidden, options.explore))
	// Report where the user finished. A child process cannot change its parent's
	// working directory, so this file is the only way a shell can follow trek. It is
	// written on every exit path, which is why it is a defer rather than a line at the
	// end of the loop.
	defer if options.cwd_file != "" {
		if _, final_root, _, ok := tabs.tree_state(ui.shell_tree_tab(&shell)); ok {
			_ = os.write_entire_file_from_string(options.cwd_file, final_root)
		}
	}
	_ = tabs.tree_restore_expanded(ui.shell_active_tab(&shell), settings.preferences_expanded(&preferences, root))
	ui.shell_reload(&shell)
	ui.shell_add_tab(&shell, tabs.changes_tab(root))
	ui.shell_add_tab(&shell, tabs.graph_tab(root))
	for &definition in config.tabs do ui.shell_add_tab(&shell, tabs.lua_tab(&config, &definition))
	_ = ui.shell_switch_named(&shell, config.settings.start_tab)
	// Launch with something under the cursor. Without this the first arrow key is spent
	// selecting rather than moving, and in explorer mode -- where the selection IS what you
	// act on -- there is nothing to act on until you press one. A file given as the path
	// lands the cursor on it; anything else lands on the first row.
	ui.shell_apply_selection(&shell, tabs.Tab_Result{select_id = options.reveal, select_first = true})
	if config.plugin_error != "" do ui.shell_set_footer(&shell, config.plugin_error)
	if message := luaconfig.engine_emit(&config, "root", root); message != "" {
		ui.shell_set_footer(&shell, message)
		delete(message)
	}

	// CLI overrides config, and config overrides filling the terminal.
	width_setting := options.width if options.width > 0 else config.settings.width
	height_setting := options.height if options.height > 0 else config.settings.height
	align_name := options.align if options.align != "" else config.settings.align
	align_setting, _ := tui.align_parse(align_name)
	border_setting := config.settings.border
	// The shell always draws into a buffer of its own size starting at 0,0. When that
	// is smaller than the terminal it is blitted into place, so nothing in the shell
	// has to know it is not filling the screen.
	content: tui.Buffer
	tui.buffer_init(&content, buffer.width, buffer.height)
	defer tui.buffer_destroy(&content)
	view := tui.Rect{width = buffer.width, height = buffer.height}

	// Opt-in: a run nobody asks about has no socket at all, which is what makes the
	// feature safe to leave available by default.
	server: live.Server
	if options.serve {
		if path, ok := live.serve(&server); ok {
			ui.shell_set_footer(&shell, path)
		} else {
			ui.shell_set_footer(&shell, "could not bind the control socket")
		}
	}
	defer live.stop(&server)
	watch: live.Watch
	defer live.watch_destroy(&watch)

	input: [4096]byte
	for !shell.quit && !tui.terminal_should_exit() {
		free_all(context.temp_allocator)
		if luaconfig.engine_poll(&config) {
			ui.shell_revisit(&shell)
			ui.shell_reload(&shell)
		}
		live_state := live_snapshot(&shell)
		live.notice(&server, &watch, live_state)
		live.poll(&server, live_state)
		if tui.terminal_take_resize() {
			if new_width, new_height, resized := tui.terminal_size(); resized {
				tui.buffer_resize(&buffer, new_width, new_height)
			}
		}
		view = tui.viewport_rect(buffer.width, buffer.height, width_setting, height_setting, align_setting)
		inner := view
		framed := border_setting && (view.width < buffer.width || view.height < buffer.height)
		if framed {
			inner.x += 1
			inner.y += 1
			inner.width = max(inner.width - 2, 0)
			inner.height = max(inner.height - 2, 0)
		}
		tui.buffer_resize(&content, inner.width, inner.height)
		ui.shell_render(&shell, &content, &layout)
		tui.buffer_clear(&buffer)
		if framed do tui.draw_frame(&buffer, view, tui.Style{fg = tui.RAMP_BORDER})
		tui.buffer_blit(&buffer, &content, inner.x, inner.y)
		if !tui.buffer_flush(&buffer) do return false
		cursor_x, cursor_y, cursor_visible := ui.shell_cursor_position(&shell, content.width, content.height)
		tui.terminal_cursor(cursor_visible, cursor_x + inner.x, cursor_y + inner.y)
		count, input_state := tui.terminal_read(input[:])
		switch input_state {
		case .Timeout: continue
		case .Closed: return true
		case .Failed: return false
		case .Data:
		}
		events := tui.decoder_feed(&decoder, input[:count])
		for event in events {
			switch event.kind {
			case .Key:
				tab := ui.shell_active_tab(&shell)
				row := ui.shell_selected_row(&shell)
				tab_name, row_path := "", ""
				is_dir := false
				if tab != nil do tab_name = tab.name
				if row != nil {
					row_path = row.path
					is_dir = row.is_dir
				}
				handled, message := luaconfig.engine_handle_key(&config, tab_name, event.key, row_path, is_dir)
				if handled {
					if message != "" {
						ui.shell_set_footer(&shell, message)
						delete(message)
					}
				} else {
					ui.shell_key(&shell, event.key, ui.shell_viewport_height(&shell, content.height))
				}
				ui.shell_apply_lua_pending(&shell)
				if !run_suspended(&config, &terminal, &buffer) do return false
			case .Mouse:
				// The shell thinks in viewport coordinates, so shift the click in before
				// dispatching and drop anything outside the box entirely.
				local := event.mouse
				local.x -= inner.x
				local.y -= inner.y
				if local.x >= 0 && local.y >= 0 && local.x < content.width && local.y < content.height {
					ui.shell_mouse(&shell, local, content.width, content.height)
				}
			case .Paste: ui.shell_paste(&shell, event.text)
			}
		}
		tui.events_destroy(&events)
	}
	return true
}

main :: proc() {
	cwd, err := os.get_working_directory(context.allocator)
	if err != nil {
		fmt.eprintln("trek: could not determine the working directory")
		os.exit(1)
	}
	defer delete(cwd)
	options := parse_options(os.args[1:], cwd)
	if options.help {
		usage()
		return
	}
	if options.printed do return
	if options.version {
		fmt.println(VERSION)
		return
	}
	if options.error != "" {
		fmt.eprintln("trek:", options.error)
		os.exit(2)
	}
	target, path_err := filepath.abs(options.root, context.allocator)
	if path_err != nil {
		// abs() resolves through the filesystem, so a path that is not there fails here
		// rather than at the stat below. Name it either way.
		fmt.eprintln("trek:", options.root, "does not exist")
		os.exit(1)
	}
	defer delete(target)
	info, stat_err := os.stat(target, context.allocator)
	if stat_err != nil {
		fmt.eprintln("trek:", options.root, "does not exist")
		os.exit(1)
	}
	is_directory := info.type == .Directory
	os.file_info_delete(info, context.allocator)

		root, reveal := launch_target(target, is_directory)
	defer delete(root)
	defer delete(reveal)
	options.reveal = reveal
	if !run_tui(root, options) do os.exit(1)
}

// What the control socket may answer with. Built from the shell each poll rather than
// reached for, so the live package never depends on the ui.
live_snapshot :: proc(shell: ^ui.Shell) -> live.Snapshot {
	snapshot := live.Snapshot{}
	if tab := ui.shell_active_tab(shell); tab != nil do snapshot.tab = tab.name
	if hidden, root, _, ok := tabs.tree_state(ui.shell_tree_tab(shell)); ok {
		_ = hidden
		snapshot.root = root
	}
	if row := ui.shell_selected_row(shell); row != nil {
		snapshot.selection = row.path
		snapshot.is_dir = row.is_dir
	}
	names := make([dynamic]string, context.temp_allocator)
	for &tab in shell.tabs {
		if tabs.tab_visible(&tab) do append(&names, tab.name)
	}
	snapshot.tabs = names[:]
	return snapshot
}

// Where a path argument points: the directory to open, and the row to land on inside it.
//
// A file names both halves of the same request, which is why there is no second flag for
// it: "open here" and "open here, on this" differ only by a detail, and an editor asking
// for a sidebar has the file in hand, not the directory.
launch_target :: proc(path: string, is_directory: bool, allocator := context.allocator) -> (root, reveal: string) {
	if is_directory do return strings.clone(path, allocator), ""
	return filepath.dir(path, allocator), strings.clone(path, allocator)
}

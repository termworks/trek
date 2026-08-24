package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import luaconfig "./lua"
import model "./model"
import settings "./settings"
import tabs "./tabs"
import tui "./tui"
import ui "./ui"

VERSION :: "0.1.0"

Options :: struct {
	root:    string,
	help:    bool,
	version: bool,
	error:   string,
}

parse_options :: proc(args: []string, default_root: string) -> Options {
	options := Options{root = default_root}
	have_root := false
	for arg in args {
		switch arg {
		case "-h", "--help": options.help = true
		case "-V", "--version": options.version = true
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
	fmt.println("  trek [path] [--help] [--version]")
	fmt.println("")
	fmt.println("Keys:")
	fmt.println("  ↑↓ navigate  Enter open  m menu  1-9 tabs  q quit")
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

run_tui :: proc(root: string) -> bool {
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
	ui.shell_add_tab(&shell, tabs.tree_tab(root, preferences.hidden))
	_ = tabs.tree_restore_expanded(ui.shell_active_tab(&shell), settings.preferences_expanded(&preferences, root))
	ui.shell_reload(&shell)
	ui.shell_add_tab(&shell, tabs.changes_tab(root))
	ui.shell_add_tab(&shell, tabs.graph_tab(root))
	for &definition in config.tabs do ui.shell_add_tab(&shell, tabs.lua_tab(&config, &definition))
	_ = ui.shell_switch_named(&shell, config.settings.start_tab)
	if message := luaconfig.engine_emit(&config, "root", root); message != "" {
		ui.shell_set_footer(&shell, message)
		delete(message)
	}

	input: [4096]byte
	for !shell.quit && !tui.terminal_should_exit() {
		free_all(context.temp_allocator)
		if luaconfig.engine_poll(&config) do ui.shell_reload(&shell)
		if tui.terminal_take_resize() {
			if new_width, new_height, resized := tui.terminal_size(); resized {
				tui.buffer_resize(&buffer, new_width, new_height)
			}
		}
		ui.shell_render(&shell, &buffer, &layout)
		if !tui.buffer_flush(&buffer) do return false
		cursor_x, cursor_y, cursor_visible := ui.shell_cursor_position(&shell, buffer.width, buffer.height)
		tui.terminal_cursor(cursor_visible, cursor_x, cursor_y)
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
					ui.shell_key(&shell, event.key, ui.shell_viewport_height(buffer.height))
				}
				ui.shell_apply_lua_pending(&shell)
				if !run_suspended(&config, &terminal, &buffer) do return false
			case .Mouse: ui.shell_mouse(&shell, event.mouse, buffer.width, buffer.height)
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
	if options.version {
		fmt.println(VERSION)
		return
	}
	if options.error != "" {
		fmt.eprintln("trek:", options.error)
		os.exit(2)
	}
	root, path_err := filepath.abs(options.root, context.allocator)
	if path_err != nil {
		fmt.eprintln("trek: invalid root path")
		os.exit(1)
	}
	defer delete(root)
	info, stat_err := os.stat(root, context.allocator)
	if stat_err != nil || info.type != .Directory {
		if stat_err == nil do os.file_info_delete(info, context.allocator)
		fmt.eprintln("trek: root is not a directory")
		os.exit(1)
	}
	os.file_info_delete(info, context.allocator)
	if !run_tui(root) do os.exit(1)
}

package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
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

run_tui :: proc(root: string) -> bool {
	terminal: tui.Terminal
	if !tui.terminal_enter(&terminal) {
		fmt.eprintln("trek requires an interactive terminal")
		return false
	}
	defer tui.terminal_restore(&terminal)
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
	ui.shell_add_tab(&shell, tabs.tree_tab(root))
	ui.shell_add_tab(&shell, tabs.changes_tab())
	ui.shell_add_tab(&shell, tabs.graph_tab())

	input: [4096]byte
	for !shell.quit && !tui.terminal_should_exit() {
		if tui.terminal_take_resize() {
			if new_width, new_height, resized := tui.terminal_size(); resized {
				tui.buffer_resize(&buffer, new_width, new_height)
			}
		}
		ui.shell_render(&shell, &buffer, &layout)
		if !tui.buffer_flush(&buffer) do return false
		count, err := os.read(os.stdin, input[:])
		if err != nil do return false
		if count == 0 do continue
		events := tui.decoder_feed(&decoder, input[:count])
		for event in events {
			switch event.kind {
			case .Key: ui.shell_key(&shell, event.key, max(buffer.height - 2, 0))
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
		return
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
		fmt.eprintln("trek: ", options.error)
		return
	}
	root, path_err := filepath.abs(options.root, context.allocator)
	if path_err != nil {
		fmt.eprintln("trek: invalid root path")
		return
	}
	defer delete(root)
	info, stat_err := os.stat(root, context.allocator)
	if stat_err != nil || info.type != .Directory {
		if stat_err == nil do os.file_info_delete(info, context.allocator)
		fmt.eprintln("trek: root is not a directory")
		return
	}
	os.file_info_delete(info, context.allocator)
	_ = run_tui(root)
}

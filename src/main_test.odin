package main

import "core:testing"

@(test)
test_options_accept_root_and_flags :: proc(t: ^testing.T) {
	options := parse_options([]string{"/tmp", "--version"}, ".")
	testing.expect_value(t, options.root, "/tmp")
	testing.expect(t, options.version)
	testing.expect_value(t, options.error, "")
}

@(test)
test_options_reject_unknown_and_extra_args :: proc(t: ^testing.T) {
	unknown := parse_options([]string{"--wat"}, ".")
	extra := parse_options([]string{"one", "two"}, ".")
	testing.expect_value(t, unknown.error, "unknown option")
	testing.expect_value(t, extra.error, "only one root path is accepted")
}

// A file argument is the sidebar case: an editor knows the file it is looking at, not the
// directory around it, so trek takes the file and works the directory out.
@(test)
test_a_file_argument_opens_its_directory :: proc(t: ^testing.T) {
	root, reveal := launch_target("/home/ada/atlas", true)
	defer { delete(root); delete(reveal) }
	testing.expect_value(t, root, "/home/ada/atlas")
	// Nothing singled out: the launch falls back to the first row.
	testing.expect_value(t, reveal, "")

	nested, landing := launch_target("/home/ada/atlas/src/main.odin", false)
	defer { delete(nested); delete(landing) }
	testing.expect_value(t, nested, "/home/ada/atlas/src")
	testing.expect_value(t, landing, "/home/ada/atlas/src/main.odin")
}

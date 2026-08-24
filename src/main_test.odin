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

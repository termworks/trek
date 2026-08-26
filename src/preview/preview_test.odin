package preview

import "core:testing"

// hexe answers in the family's shape: a *list* of return values under `result`, with
// `n` saying how many. Reading the record straight out of `result` -- as though it
// were the value rather than a list holding it -- is the mistake that reads as "no
// geometry" instead of as a mismatch, so it is pinned here.
@(test)
test_geometry_is_read_out_of_the_result_list :: proc(t: ^testing.T) {
	answer := parse_geometry(`{"ok":true,"n":1,"result":[{"x":50,"y":50,"width":80,"height":70}]}`)
	testing.expect(t, answer.known)
	testing.expect_value(t, answer.x, 50)
	testing.expect_value(t, answer.width, 80)
	testing.expect_value(t, answer.height, 70)
}

// A hexe that does not serve this verb on a pane's socket refuses it by name. That is
// a reply, not a failure: the preview still opens, beside a float that did not move.
@(test)
test_a_refusal_leaves_the_geometry_unknown :: proc(t: ^testing.T) {
	refusals := [?]string {
		`{"ok":false,"error":"call ` + "`geometry`" + ` is about the whole session; this is a pane's socket"}`,
		`{"ok":true,"n":0,"result":[]}`,
		`{"ok":true,"n":1,"result":[null]}`,
		`not json at all`,
		``,
	}
	for body in refusals {
		answer := parse_geometry(body)
		testing.expectf(t, !answer.known, "accepted %q as geometry", body)
	}
}

// JSON has one number type and which Odin variant a parser hands back depends on how
// the value was written. Accepting only Integer silently loses a hexe that answers
// whole numbers as floats -- the same trap the control socket's `unsubscribe` fell
// into, where an id arrived as a Float and every removal quietly reported false.
@(test)
test_a_whole_number_is_read_whichever_way_it_arrives :: proc(t: ^testing.T) {
	answer := parse_geometry(`{"ok":true,"n":1,"result":[{"x":30.0,"width":60.0}]}`)
	testing.expect(t, answer.known)
	testing.expect_value(t, answer.x, 30)
	testing.expect_value(t, answer.width, 60)
}

// Outside hexe there is no socket to talk to, and every entry point has to be a no-op
// rather than an error: trek runs in plenty of terminals that are not hexe, and none
// of them should hear about a preview.
@(test)
test_outside_hexe_nothing_happens :: proc(t: ^testing.T) {
	state: Preview
	state.fifo = -1
	testing.expect(t, !available(&state))
	testing.expect_value(t, toggle(&state), "preview needs hexe")
	testing.expect(t, !active(&state))
	// Following a selection with nothing open must not write anywhere.
	follow(&state, "/tmp/somewhere")
	testing.expect_value(t, state.shown, "")
}

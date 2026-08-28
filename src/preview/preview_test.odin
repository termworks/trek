package preview

import "core:fmt"
import "core:testing"

// hexe answers in the family's shape: a *list* of return values under `result`, with
// `n` saying how many. Reading the record straight out of `result` -- as though it
// were the value rather than a list holding it -- is the mistake that reads as "no
// geometry" instead of as a mismatch, so it is pinned here.
@(test)
test_the_pane_record_is_read_out_of_the_result_list :: proc(t: ^testing.T) {
	answer := parse_self(`{"ok":true,"n":1,"result":[{"is_float":true,"pos_x_pct":50,"pos_y_pct":50,"width_pct":80,"height_pct":70}]}`)
	testing.expect(t, answer.known)
	testing.expect_value(t, answer.x, 50)
	testing.expect_value(t, answer.width, 80)
	testing.expect_value(t, answer.height, 70)
}

@(test)
test_a_refusal_leaves_the_position_unknown :: proc(t: ^testing.T) {
	refusals := [?]string {
		`{"ok":false,"error":"no such call"}`,
		`{"ok":true,"n":0,"result":[]}`,
		`{"ok":true,"n":1,"result":[null]}`,
		// A tiled pane has no percentages, so there is no band beside it either.
		`{"ok":true,"n":1,"result":[{"is_float":false,"pos_x_pct":50,"width_pct":80}]}`,
		`not json at all`,
		``,
	}
	for body in refusals {
		answer := parse_self(body)
		testing.expectf(t, !answer.known, "accepted %q as a position", body)
	}
}

// JSON has one number type and which Odin variant a parser hands back depends on how
// the value was written. Accepting only Integer silently loses a hexe that answers
// whole numbers as floats -- the same trap the control socket's `unsubscribe` fell
// into, where an id arrived as a Float and every removal quietly reported false.
@(test)
test_a_whole_number_is_read_whichever_way_it_arrives :: proc(t: ^testing.T) {
	answer := parse_self(`{"ok":true,"n":1,"result":[{"is_float":true,"pos_x_pct":30.0,"width_pct":60.0}]}`)
	testing.expect(t, answer.known)
	testing.expect_value(t, answer.x, 30)
	testing.expect_value(t, answer.width, 60)
}

// hexe's `x` is an anchor in the free space, not a centre. This is the measurement the
// mistake cost: on a 135-column window those two rectangles are [16,52) and [28,118),
// one drawn over the other, while centre-arithmetic calls them adjacent.
@(test)
test_an_anchor_is_not_a_centre :: proc(t: ^testing.T) {
	trek := Rect{x = 15, y = 50, width = 30, height = 70, known = true}
	preview := Rect{x = 65, y = 50, width = 70, height = 70, known = true}
	testing.expect_value(t, left_edge(trek), 10)
	testing.expect_value(t, right_edge(trek), 40)
	testing.expect_value(t, left_edge(preview), 19)
	testing.expect(t, overlaps(trek, preview))

	// The anchors the split actually uses: hard against each edge.
	testing.expect_value(t, left_edge(Rect{x = 0, width = 30}), 0)
	testing.expect_value(t, right_edge(Rect{x = 100, width = 70}), 100)
}

// The guarantee, as a property rather than one worked example: whatever the explorer
// starts as, the two boxes never share a column.
//
// Two orderings matter and both are encoded here. Opening a float puts every other
// float back where it was declared, so the explorer is moved *after* the preview
// opens; and the anchors are edges rather than positions, so no window width can round
// them into each other.
@(test)
test_the_two_boxes_never_share_a_column :: proc(t: ^testing.T) {
	starts := [?]Rect {
		{x = 50, y = 50, width = 30, height = 70, known = true}, // centred, as oslo opens it
		{x = 15, y = 50, width = 30, height = 70, known = true},
		{x = 0, y = 50, width = 30, height = 70, known = true},
		{x = 100, y = 50, width = 30, height = 70, known = true},
		{x = 50, y = 50, width = 60, height = 70, known = true},
		{x = 50, y = 50, width = 80, height = 70, known = true}, // too wide: gets narrowed
	}
	for trek in starts {
		explorer, preview, ok := split(trek)
		testing.expectf(t, ok, "no room for x=%d w=%d", trek.x, trek.width)
		if !ok do continue
		testing.expectf(
			t,
			!overlaps(explorer, preview),
			"explorer [%d,%d] overlaps preview [%d,%d]",
			left_edge(explorer),
			right_edge(explorer),
			left_edge(preview),
			right_edge(preview),
		)
		testing.expect_value(t, left_edge(explorer), 0)
		testing.expect_value(t, right_edge(explorer), left_edge(preview))
		testing.expect_value(t, right_edge(preview), 100)
		testing.expect(t, preview.width >= MIN_PREVIEW)
	}
}

// Nowhere to put it is an answer, not a reason to put it anywhere.
@(test)
test_no_room_means_no_preview :: proc(t: ^testing.T) {
	_, _, unknown := split(Rect{})
	testing.expect(t, !unknown)

	_, _, ok := split(Rect{x = 50, y = 50, width = 100, height = 70, known = true})
	testing.expect(t, ok, "a full-width explorer is narrowed rather than refused")
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
	follow(&state, "/tmp/somewhere")
	testing.expect_value(t, state.shown, "")
}

// The two ways of saying "here" have to describe the same box: hexe's `--size` takes a
// shift from centre, `geometry` takes the anchor itself.
@(test)
test_the_two_placement_apis_describe_the_same_box :: proc(t: ^testing.T) {
	trek := Rect{x = 50, y = 50, width = 30, height = 70, known = true}
	_, beside, room := split(trek)
	testing.expect(t, room)
	testing.expect_value(t, beside.x, 100)
	size := fmt.tprintf("%d,%d,%d,%d", beside.width, beside.height, beside.x - 50, beside.y - 50)
	// 70 wide, 70 tall, anchored hard right, vertically where the explorer already is.
	testing.expect_value(t, size, "70,70,50,0")
}

// The explorer gives up a share of itself so the file beside it has room. A list of
// names needs far less width than the thing it is listing.
@(test)
test_the_explorer_shrinks_for_a_preview :: proc(t: ^testing.T) {
	trek := Rect{x = 50, y = 50, width = 30, height = 70, known = true}

	kept, _, _ := split(trek, 0)
	testing.expect_value(t, kept.width, 30)

	// 40% off 30 leaves 18, and the preview takes everything else.
	narrow, beside, ok := split(trek, 40)
	testing.expect(t, ok)
	testing.expect_value(t, narrow.width, 18)
	testing.expect_value(t, beside.width, 82)
	testing.expect(t, !overlaps(narrow, beside))
	testing.expect_value(t, right_edge(narrow), left_edge(beside))
}

// A shrink that would leave nothing to read is refused rather than honoured: the
// explorer falls back to a width that still leaves room for both.
@(test)
test_an_absurd_shrink_does_not_erase_the_explorer :: proc(t: ^testing.T) {
	wide := Rect{x = 50, y = 50, width = 95, height = 70, known = true}
	kept, beside, ok := split(wide, 99)
	testing.expect(t, ok)
	testing.expect(t, kept.width > 0)
	testing.expect(t, beside.width >= MIN_PREVIEW)
	testing.expect(t, !overlaps(kept, beside))
}

// A pod inherits `HEXE_PANE_UUID` from whoever launched it rather than being given its
// own. Measured: a trek float carried the uuid of the terminal that spawned it. The
// float CLI routes on that variable, so it has to be replaced with this pane's own or
// the preview is asked for beside somebody else's pane.
@(test)
test_the_pane_record_carries_its_own_name :: proc(t: ^testing.T) {
	answer := parse_self(`{"ok":true,"n":1,"result":[{"is_float":true,"uuid":"abc123","pos_x_pct":50,"width_pct":30}]}`)
	testing.expect(t, answer.known)
	testing.expect_value(t, answer.uuid, "abc123")
}

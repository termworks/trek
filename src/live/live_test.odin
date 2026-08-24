package live

import "core:strings"
import "core:testing"

// The reply shape is the one thing a family cannot disagree about quietly. A tool answering
// {"result": value} where a sibling answers {"result":[value],"n":1} returns *nothing* to a
// client that unpacks -- and an empty answer reads as an empty session, not as a mismatch.
@(test)
test_reply_shape_matches_the_family :: proc(t: ^testing.T) {
	reply := ok_reply({`"hello"`}, context.allocator)
	defer delete(reply)
	testing.expect_value(t, reply, `{"ok":true,"n":1,"result":["hello"]}`)

	empty := ok_reply({}, context.allocator)
	defer delete(empty)
	testing.expect_value(t, empty, `{"ok":true,"n":0,"result":[]}`)
}

// A refused verb is a reply with a zero exit, so the caller sees the tool's error rather
// than a transport one.
@(test)
test_unknown_call_is_a_reply :: proc(t: ^testing.T) {
	snapshot := Snapshot{root = "/tmp"}
	reply := dispatch(`{"call":"nope","args":[]}`, snapshot, context.allocator)
	defer delete(reply)
	testing.expect(t, strings.contains(reply, `"ok":false`))
	testing.expect(t, strings.contains(reply, "no such call: nope"))
}

@(test)
test_malformed_request_is_a_reply :: proc(t: ^testing.T) {
	snapshot := Snapshot{}
	bodies := [?]string{`not json`, `[]`, `{"args":[]}`, `{"call":5}`}
	for body in bodies {
		reply := dispatch(body, snapshot, context.allocator)
		defer delete(reply)
		testing.expectf(t, strings.contains(reply, `"ok":false`), "accepted %q", body)
	}
}

TEST_TABS := [?]string{"tree", "graph"}

@(test)
test_verbs_answer_from_the_snapshot :: proc(t: ^testing.T) {
	snapshot := Snapshot{
		root = "/home/ada/atlas",
		selection = "/home/ada/atlas/src",
		tab = "tree",
		tabs = TEST_TABS[:],
	}
	cwd := dispatch(`{"call":"cwd","args":[]}`, snapshot, context.allocator)
	defer delete(cwd)
	testing.expect_value(t, cwd, `{"ok":true,"n":1,"result":["/home/ada/atlas"]}`)

	tabs := dispatch(`{"call":"tabs","args":[]}`, snapshot, context.allocator)
	defer delete(tabs)
	testing.expect_value(t, tabs, `{"ok":true,"n":1,"result":[["tree","graph"]]}`)

	// verbs() ships from the first version, or a client written against a sibling that has
	// it gets "no such call: verbs" here and the family stops being one.
	verbs := dispatch(`{"call":"verbs","args":[]}`, snapshot, context.allocator)
	defer delete(verbs)
	for verb in VERBS do testing.expect(t, strings.contains(verbs, verb))
}

// Nothing selected is a real answer, and the wire says so with null rather than "".
@(test)
test_empty_selection_is_null :: proc(t: ^testing.T) {
	reply := dispatch(`{"call":"selection","args":[]}`, Snapshot{}, context.allocator)
	defer delete(reply)
	testing.expect_value(t, reply, `{"ok":true,"n":1,"result":[null]}`)
}

// A path with a quote or a newline in it must not be able to break out of the JSON string.
@(test)
test_paths_are_escaped :: proc(t: ^testing.T) {
	snapshot := Snapshot{root = "/tmp/a\"b\nc\\d"}
	reply := dispatch(`{"call":"cwd","args":[]}`, snapshot, context.allocator)
	defer delete(reply)
	testing.expect_value(t, reply, `{"ok":true,"n":1,"result":["/tmp/a\"b\nc\\d"]}`)
}

@(test)
test_frame_length_is_big_endian :: proc(t: ^testing.T) {
	testing.expect_value(t, frame_length([]byte{0, 0, 0, 5}), 5)
	testing.expect_value(t, frame_length([]byte{0, 0, 1, 0}), 256)
	testing.expect_value(t, frame_length([]byte{1, 0, 0, 0}), 16777216)
}

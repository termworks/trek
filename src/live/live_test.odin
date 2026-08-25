package live

import "core:strings"
import "core:os"
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
	probe: Connection
	defer delete(probe.subs)
	snapshot := Snapshot{root = "/tmp"}
	reply := dispatch(&probe, `{"call":"nope","args":[]}`, snapshot, context.allocator)
	defer delete(reply)
	testing.expect(t, strings.contains(reply, `"ok":false`))
	testing.expect(t, strings.contains(reply, "no such call: nope"))
}

@(test)
test_malformed_request_is_a_reply :: proc(t: ^testing.T) {
	probe: Connection
	defer delete(probe.subs)
	snapshot := Snapshot{}
	bodies := [?]string{`not json`, `[]`, `{"args":[]}`, `{"call":5}`}
	for body in bodies {
		reply := dispatch(&probe, body, snapshot, context.allocator)
		defer delete(reply)
		testing.expectf(t, strings.contains(reply, `"ok":false`), "accepted %q", body)
	}
}

TEST_TABS := [?]string{"tree", "graph"}

@(test)
test_verbs_answer_from_the_snapshot :: proc(t: ^testing.T) {
	probe: Connection
	defer delete(probe.subs)
	snapshot := Snapshot{
		root = "/home/ada/atlas",
		selection = "/home/ada/atlas/src",
		tab = "tree",
		tabs = TEST_TABS[:],
	}
	cwd := dispatch(&probe, `{"call":"cwd","args":[]}`, snapshot, context.allocator)
	defer delete(cwd)
	testing.expect_value(t, cwd, `{"ok":true,"n":1,"result":["/home/ada/atlas"]}`)

	tabs := dispatch(&probe, `{"call":"tabs","args":[]}`, snapshot, context.allocator)
	defer delete(tabs)
	testing.expect_value(t, tabs, `{"ok":true,"n":1,"result":[["tree","graph"]]}`)

	// verbs() ships from the first version, or a client written against a sibling that has
	// it gets "no such call: verbs" here and the family stops being one.
	verbs := dispatch(&probe, `{"call":"verbs","args":[]}`, snapshot, context.allocator)
	defer delete(verbs)
	for verb in VERBS do testing.expect(t, strings.contains(verbs, verb))
}

// Nothing selected is a real answer, and the wire says so with null rather than "".
@(test)
test_empty_selection_is_null :: proc(t: ^testing.T) {
	probe: Connection
	defer delete(probe.subs)
	reply := dispatch(&probe, `{"call":"selection","args":[]}`, Snapshot{}, context.allocator)
	defer delete(reply)
	testing.expect_value(t, reply, `{"ok":true,"n":1,"result":[null]}`)
}

// A path with a quote or a newline in it must not be able to break out of the JSON string.
@(test)
test_paths_are_escaped :: proc(t: ^testing.T) {
	probe: Connection
	defer delete(probe.subs)
	snapshot := Snapshot{root = "/tmp/a\"b\nc\\d"}
	reply := dispatch(&probe, `{"call":"cwd","args":[]}`, snapshot, context.allocator)
	defer delete(reply)
	testing.expect_value(t, reply, `{"ok":true,"n":1,"result":["/tmp/a\"b\nc\\d"]}`)
}

@(test)
test_frame_length_is_big_endian :: proc(t: ^testing.T) {
	testing.expect_value(t, frame_length([]byte{0, 0, 0, 5}), 5)
	testing.expect_value(t, frame_length([]byte{0, 0, 1, 0}), 256)
	testing.expect_value(t, frame_length([]byte{1, 0, 0, 0}), 16777216)
}

// A subscription is an opaque id, because a function cannot cross a socket. What the peer
// stores is a number, and trek pushes to it.
@(test)
test_subscribe_hands_back_an_opaque_id :: proc(t: ^testing.T) {
	probe: Connection
	defer { for _, e in probe.subs do delete(e); delete(probe.subs) }
	first := dispatch(&probe, `{"call":"subscribe","args":["root"]}`, Snapshot{}, context.allocator)
	defer delete(first)
	testing.expect_value(t, first, `{"ok":true,"n":1,"result":[1]}`)
	second := dispatch(&probe, `{"call":"subscribe","args":["selection"]}`, Snapshot{}, context.allocator)
	defer delete(second)
	testing.expect_value(t, second, `{"ok":true,"n":1,"result":[2]}`)
	testing.expect_value(t, len(probe.subs), 2)
}

// An event trek does not have is refused as a reply, so the caller learns the name is wrong
// rather than subscribing successfully to nothing.
@(test)
test_unknown_event_is_refused :: proc(t: ^testing.T) {
	probe: Connection
	defer { for _, e in probe.subs do delete(e); delete(probe.subs) }
	reply := dispatch(&probe, `{"call":"subscribe","args":["bogus"]}`, Snapshot{}, context.allocator)
	defer delete(reply)
	testing.expect(t, strings.contains(reply, `"ok":false`))
	testing.expect(t, strings.contains(reply, "no such event: bogus"))
	testing.expect_value(t, len(probe.subs), 0)
}

@(test)
test_subscriptions_are_bounded_and_removable :: proc(t: ^testing.T) {
	probe: Connection
	defer { for _, e in probe.subs do delete(e); delete(probe.subs) }
	for _ in 0 ..< MAX_SUBSCRIPTIONS {
		reply := dispatch(&probe, `{"call":"subscribe","args":["root"]}`, Snapshot{}, context.allocator)
		delete(reply)
	}
	// One peer must not be able to grow trek's memory by subscribing without end.
	over := dispatch(&probe, `{"call":"subscribe","args":["root"]}`, Snapshot{}, context.allocator)
	defer delete(over)
	testing.expect(t, strings.contains(over, "too many subscriptions"))

	gone := dispatch(&probe, `{"call":"unsubscribe","args":[1]}`, Snapshot{}, context.allocator)
	defer delete(gone)
	testing.expect_value(t, gone, `{"ok":true,"n":1,"result":[true]}`)
	// Removing one that was never there is false, not an error.
	again := dispatch(&probe, `{"call":"unsubscribe","args":[1]}`, Snapshot{}, context.allocator)
	defer delete(again)
	testing.expect_value(t, again, `{"ok":true,"n":1,"result":[false]}`)
}

// A push carries `event` where a reply carries `ok`. That single difference is the whole
// reentrancy contract on the wire: a client waiting for a reply can tell them apart without
// guessing, and park the event instead of re-entering its own call.
@(test)
test_event_frame_is_distinguishable_from_a_reply :: proc(t: ^testing.T) {
	frame := event_frame(7, "root", "/home/ada", context.allocator)
	defer delete(frame)
	testing.expect_value(t, frame, `{"event":"root","sub":7,"args":["/home/ada"]}`)
	testing.expect(t, !strings.contains(frame, `"ok"`))

	empty := event_frame(1, "selection", "", context.allocator)
	defer delete(empty)
	testing.expect_value(t, empty, `{"event":"selection","sub":1,"args":[null]}`)
}

// The first snapshot primes the watch rather than firing: a subscriber must not be told the
// root "changed" to wherever trek already was.
@(test)
test_notice_primes_before_it_fires :: proc(t: ^testing.T) {
	server: Server
	server.listening = true
	watch: Watch
	defer watch_destroy(&watch)

	notice(&server, &watch, Snapshot{root = "/one", selection = "/one/a"})
	testing.expect(t, watch.primed)
	testing.expect_value(t, watch.root, "/one")

	notice(&server, &watch, Snapshot{root = "/two", selection = "/one/a"})
	testing.expect_value(t, watch.root, "/two")
	// The selection did not move, so it is left exactly as it was.
	testing.expect_value(t, watch.selection, "/one/a")
}

// **A path is not safe to paste into JSON.** A quote or a backslash in a directory name is legal on
// Linux and would end the string early — handing the shell a frame it cannot parse, or one it parses
// as something other than what was meant.
@(test)
oslo_request_escapes_what_a_path_may_contain :: proc(t: ^testing.T) {
	plain := oslo_cd_request("/tmp/project", context.temp_allocator)
	testing.expect_value(t, plain, `{"call":"cd","args":["/tmp/project"]}`)

	quoted := oslo_cd_request(`/tmp/od"d`, context.temp_allocator)
	testing.expect_value(t, quoted, `{"call":"cd","args":["/tmp/od\"d"]}`)

	slashed := oslo_cd_request(`/tmp/back\slash`, context.temp_allocator)
	testing.expect_value(t, slashed, `{"call":"cd","args":["/tmp/back\\slash"]}`)

	// The rest of the control range, which JSON requires spelled out rather than sent raw.
	controlled := oslo_cd_request("/tmp/a\x01b", context.temp_allocator)
	testing.expect_value(t, controlled, `{"call":"cd","args":["/tmp/a\u0001b"]}`)
}

// Nothing is sent outside a shell that asked for it: no `$OSLO_SOCK`, no socket, no request.
@(test)
nothing_is_sent_without_a_shell_to_send_it_to :: proc(t: ^testing.T) {
	previous, had := os.lookup_env("OSLO_SOCK", context.temp_allocator)
	os.unset_env("OSLO_SOCK")
	testing.expect(t, oslo_socket(context.temp_allocator) == "")
	testing.expect(t, !oslo_cd("/tmp"), "no socket named, nothing written")
	if had do os.set_env("OSLO_SOCK", previous)
}

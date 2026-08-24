package tui

import "core:strings"
import "core:testing"

@(test)
test_text_width_and_truncation :: proc(t: ^testing.T) {
	testing.expect_value(t, text_width("hello"), 5)
	testing.expect_value(t, text_width("界"), 2)
	value := truncate_text("abcdefgh", 5)
	defer delete(value)
	testing.expect_value(t, value, "abcd…")
}

@(test)
test_text_tail_and_wrap :: proc(t: ^testing.T) {
	tail := input_tail("a-very-long-name.txt", 10)
	defer delete(tail)
	testing.expect(t, strings.has_prefix(tail, "…"))
	testing.expect(t, strings.has_suffix(tail, ".txt"))
	testing.expect(t, text_width(tail) <= 10)
	lines := wrap_text("abcd界ef", 4)
	defer destroy_lines(&lines)
	testing.expect_value(t, len(lines), 2)
}

@(test)
test_cell_buffer_emits_only_damage :: proc(t: ^testing.T) {
	buffer: Buffer
	buffer_init(&buffer, 3, 1)
	defer buffer_destroy(&buffer)
	first := buffer_render_diff(&buffer)
	defer delete(first)
	second := buffer_render_diff(&buffer)
	defer delete(second)
	testing.expect(t, len(first) > 0)
	testing.expect_value(t, second, "")
	buffer_set(&buffer, 1, 0, Cell{rune = 'x', style = PLAIN_STYLE})
	damage := buffer_render_diff(&buffer)
	defer delete(damage)
	testing.expect(t, strings.contains(damage, "\x1b[1;2H"))
}

@(test)
test_input_decodes_keys_mouse_and_paste :: proc(t: ^testing.T) {
	decoder: Decoder
	decoder_init(&decoder)
	defer decoder_destroy(&decoder)
	input := "\x1b[A\x1b[<0;4;2M\x1b[200~hello\nworld\x1b[201~"
	events := decoder_feed(&decoder, transmute([]byte)(input))
	defer events_destroy(&events)
	testing.expect_value(t, len(events), 3)
	testing.expect_value(t, events[0].key.code, Key_Code.Up)
	testing.expect_value(t, events[1].mouse.x, 3)
	testing.expect_value(t, events[1].mouse.y, 1)
	testing.expect_value(t, events[2].text, "hello\nworld")
}

@(test)
test_node_layout_respects_priority :: proc(t: ^testing.T) {
	root := row([]Node{
		priority(truncate(text("long"), 4), 0),
		priority(text("!"), 10),
	})
	defer node_destroy(&root)
	buffer: Buffer
	buffer_init(&buffer, 4, 1)
	defer buffer_destroy(&buffer)
	layout: Layout
	layout_init(&layout)
	defer layout_destroy(&layout)
	compose(&buffer, &layout, &root, Rect{width = 4, height = 1})
	cell, ok := buffer_get(&buffer, 3, 0)
	testing.expect(t, ok)
	testing.expect_value(t, cell.rune, '!')
}

@(test)
test_node_regions_are_hit_tested :: proc(t: ^testing.T) {
	root := region(text("open"), "file:open")
	defer node_destroy(&root)
	buffer: Buffer
	buffer_init(&buffer, 8, 1)
	defer buffer_destroy(&buffer)
	layout: Layout
	layout_init(&layout)
	defer layout_destroy(&layout)
	compose(&buffer, &layout, &root, Rect{width = 4, height = 1})
	hit, ok := region_at(&layout, 2, 0)
	testing.expect(t, ok)
	testing.expect_value(t, hit.id, "file:open")
	_, outside := region_at(&layout, 5, 0)
	testing.expect(t, !outside)
}

// A terminal hands the decoder whatever arrives: truncated escapes split across
// reads, invalid UTF-8, and stray control bytes. None of it may crash, hang, or
// leave the decoder holding memory.
@(test)
test_decoder_survives_malformed_input :: proc(t: ^testing.T) {
	cases := [?]string{
		"\x1b",
		"\x1b[",
		"\x1b[<",
		"\x1b[<0;1",
		"\x1b[<999999999;999999999;999999999M",
		"\x1b[200~unterminated paste",
		"\x1bOO\x1b\x1b\x1b",
		"\xff\xfe\xfd",
		"\xc0\x80\xe0\x80\x80",
		"\x00\x01\x02\x7f",
		"\x1b[999999999999999999999m",
	}
	for value in cases {
		decoder: Decoder
		decoder_init(&decoder)
		events := decoder_feed(&decoder, transmute([]byte)value)
		events_destroy(&events)
		decoder_destroy(&decoder)
	}
}

// The same sequence delivered one byte at a time must not behave differently from
// one delivered whole: a partial escape is state the decoder has to carry.
@(test)
test_decoder_handles_split_sequences :: proc(t: ^testing.T) {
	whole: Decoder
	decoder_init(&whole)
	defer decoder_destroy(&whole)
	sequence := "\x1b[A\x1b[<0;10;5M"
	full := decoder_feed(&whole, transmute([]byte)sequence)
	defer events_destroy(&full)

	split: Decoder
	decoder_init(&split)
	defer decoder_destroy(&split)
	drip := make([dynamic]Event)
	defer events_destroy(&drip)
	for index in 0 ..< len(sequence) {
		piece := decoder_feed(&split, transmute([]byte)sequence[index:index + 1])
		append(&drip, ..piece[:])
		delete(piece)
	}
	testing.expect_value(t, len(drip), len(full))
	for event, index in drip {
		if index >= len(full) do break
		testing.expect_value(t, event.kind, full[index].kind)
	}
	testing.expect_value(t, len(split.pending), 0)
}

// A configured size that is absent, zero, or larger than the terminal all mean
// "fill it": a size setting must never shrink trek by accident.
@(test)
test_viewport_rect_places_and_clamps :: proc(t: ^testing.T) {
	full := viewport_rect(100, 30, 0, 0, .Center)
	testing.expect_value(t, full, Rect{x = 0, y = 0, width = 100, height = 30})

	oversized := viewport_rect(40, 10, 200, 200, .Center)
	testing.expect_value(t, oversized, Rect{x = 0, y = 0, width = 40, height = 10})

	centered := viewport_rect(100, 30, 60, 18, .Center)
	testing.expect_value(t, centered, Rect{x = 20, y = 6, width = 60, height = 18})

	testing.expect_value(t, viewport_rect(60, 16, 30, 8, .Top_Left), Rect{x = 0, y = 0, width = 30, height = 8})
	testing.expect_value(t, viewport_rect(60, 16, 30, 8, .Top_Right), Rect{x = 30, y = 0, width = 30, height = 8})
	testing.expect_value(t, viewport_rect(60, 16, 30, 8, .Bottom_Left), Rect{x = 0, y = 8, width = 30, height = 8})
	testing.expect_value(t, viewport_rect(60, 16, 30, 8, .Bottom_Right), Rect{x = 30, y = 8, width = 30, height = 8})
}

@(test)
test_blit_copies_and_clips :: proc(t: ^testing.T) {
	dst: Buffer
	buffer_init(&dst, 10, 4)
	defer buffer_destroy(&dst)
	src: Buffer
	buffer_init(&src, 3, 2)
	defer buffer_destroy(&src)
	for x in 0 ..< 3 do for y in 0 ..< 2 do buffer_set(&src, x, y, Cell{rune = 'x'})

	buffer_blit(&dst, &src, 2, 1)
	placed, _ := buffer_get(&dst, 2, 1)
	testing.expect_value(t, placed.rune, 'x')
	outside, _ := buffer_get(&dst, 1, 1)
	testing.expect(t, outside.rune != 'x')

	// Anything past the edge is dropped rather than wrapping onto the next row.
	buffer_blit(&dst, &src, 9, 3)
	edge, _ := buffer_get(&dst, 9, 3)
	testing.expect_value(t, edge.rune, 'x')
	wrapped, _ := buffer_get(&dst, 0, 0)
	testing.expect(t, wrapped.rune != 'x')
}

@(test)
test_shorten_path_abbreviates_from_the_root :: proc(t: ^testing.T) {
	path := "/home/bresilla/data/code/tools/trek"
	// Fits: untouched.
	full := shorten_path(path, 80)
	defer delete(full)
	testing.expect_value(t, full, path)

	// One segment short: the leading one abbreviates first.
	one := shorten_path(path, 34)
	defer delete(one)
	testing.expect_value(t, one, "/h/bresilla/data/code/tools/trek")

	two := shorten_path(path, 30)
	defer delete(two)
	testing.expect_value(t, two, "/h/b/data/code/tools/trek")

	// Squeezed hard, everything but the last segment collapses.
	tight := shorten_path(path, 16)
	defer delete(tight)
	testing.expect_value(t, tight, "/h/b/d/c/t/trek")

	// Narrower than even that: falls back to an ellipsis rather than lying.
	tiny := shorten_path(path, 10)
	defer delete(tiny)
	testing.expect(t, text_width(tiny) <= 10)

	// A single segment has nothing to abbreviate.
	single := shorten_path("/verylongdirectoryname", 10)
	defer delete(single)
	testing.expect(t, text_width(single) <= 10)

	// Multi-byte segments abbreviate to a whole rune, not a broken byte.
	unicode := shorten_path("/日本語/データ/trek", 12)
	defer delete(unicode)
	testing.expect(t, text_width(unicode) <= 12)
}

// A row that does not fit sheds its lowest-priority parts. An ordinary node gives up
// columns gradually, which is right for a subject; an atomic one disappears whole,
// because half a date reads as corruption rather than as a narrow pane.
@(test)
test_atomic_nodes_drop_whole :: proc(t: ^testing.T) {
	buffer: Buffer
	buffer_init(&buffer, 12, 1)
	defer buffer_destroy(&buffer)
	layout: Layout
	layout_init(&layout)
	defer layout_destroy(&layout)

	node := row([]Node{
		priority(text("KEEP"), 90),
		optional(text(" 2026-08-24"), 10),
	})
	defer node_destroy(&node)
	render_node(&buffer, &layout, &node, Rect{width = 12, height = 1}, PLAIN_STYLE)

	line := make([dynamic]byte, context.allocator)
	defer delete(line)
	for x in 0 ..< 12 {
		cell, _ := buffer_get(&buffer, x, 0)
		append(&line, byte(cell.rune))
	}
	text_line := strings.trim_space(string(line[:]))
	// The date does not fit alongside KEEP, so it is gone rather than clipped.
	testing.expect_value(t, text_line, "KEEP")
}

// Word wrap, the way git reflows a paragraph: break at spaces, and hard-break only a
// word that cannot fit on a line of its own.
@(test)
test_wrap_words_breaks_at_spaces :: proc(t: ^testing.T) {
	lines := wrap_words("the quick brown fox jumps", 10)
	defer destroy_lines(&lines)
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[0], "the quick")
	testing.expect_value(t, lines[1], "brown fox")
	testing.expect_value(t, lines[2], "jumps")
	for line in lines do testing.expect(t, text_width(line) <= 10)
}

@(test)
test_wrap_words_hard_breaks_long_words :: proc(t: ^testing.T) {
	lines := wrap_words("a supercalifragilistic word", 8)
	defer destroy_lines(&lines)
	for line in lines do testing.expectf(t, text_width(line) <= 8, "overflowed: %q", line)
	joined := make([dynamic]byte)
	defer delete(joined)
	for line in lines do append(&joined, ..transmute([]byte)line)
	// Nothing is dropped, only redistributed.
	testing.expect(t, strings.contains(string(joined[:]), "supercalifragilistic"))
}

@(test)
test_wrap_words_handles_degenerate_widths :: proc(t: ^testing.T) {
	zero := wrap_words("anything", 0)
	defer destroy_lines(&zero)
	testing.expect_value(t, len(zero), 1)

	empty := wrap_words("", 10)
	defer destroy_lines(&empty)
	testing.expect_value(t, len(empty), 1)
}

// A path has no spaces, so word wrap hard-breaks it mid-directory. Breaking after a
// separator keeps every segment readable.
@(test)
test_wrap_path_breaks_after_separators :: proc(t: ^testing.T) {
	lines := wrap_path("src/deeply/nested/subdirectory/structure", 20)
	defer destroy_lines(&lines)
	for line in lines do testing.expectf(t, text_width(line) <= 20, "overflowed: %q", line)
	// Every break lands after a slash, never inside a name.
	for line, index in lines {
		if index == len(lines) - 1 do break
		testing.expectf(t, strings.has_suffix(line, "/"), "broke mid-segment: %q", line)
	}
	joined := strings.concatenate(lines[:], context.allocator)
	defer delete(joined)
	testing.expect_value(t, joined, "src/deeply/nested/subdirectory/structure")
}

@(test)
test_wrap_path_handles_oversized_segments :: proc(t: ^testing.T) {
	// One segment wider than the line has to break somewhere; nothing may be lost.
	lines := wrap_path("a/reallyreallyreallylongsegment/b", 10)
	defer destroy_lines(&lines)
	for line in lines do testing.expect(t, text_width(line) <= 10)
	joined := strings.concatenate(lines[:], context.allocator)
	defer delete(joined)
	testing.expect_value(t, joined, "a/reallyreallyreallylongsegment/b")
}

// Filenames break at the separators they are actually built from.
@(test)
test_wrap_name_breaks_at_separators :: proc(t: ^testing.T) {
	lines := wrap_name("report-2026-01-summary.final.csv", 14)
	defer destroy_lines(&lines)
	for line in lines do testing.expectf(t, text_width(line) <= 14, "overflowed: %q", line)
	joined := strings.concatenate(lines[:], context.allocator)
	defer delete(joined)
	testing.expect_value(t, joined, "report-2026-01-summary.final.csv")
	for line, index in lines {
		if index == len(lines) - 1 do break
		last := line[len(line) - 1]
		testing.expectf(t, last == '-' || last == '_' || last == '.' || last == '/', "broke mid-word: %q", line)
	}
}

// A name with no separator at all still has to fit, so it hard-breaks.
@(test)
test_wrap_name_hard_breaks_when_it_must :: proc(t: ^testing.T) {
	lines := wrap_name("aaaaaaaaaaaaaaaaaaaaaaaa", 8)
	defer destroy_lines(&lines)
	for line in lines do testing.expect(t, text_width(line) <= 8)
	joined := strings.concatenate(lines[:], context.allocator)
	defer delete(joined)
	testing.expect_value(t, joined, "aaaaaaaaaaaaaaaaaaaaaaaa")
}

// Wrapping a styled paragraph has to keep the styling: a plain string wrap can only
// paint a whole line one colour, which is what made refs invisible in the graph.
@(test)
test_wrap_spans_keeps_styles :: proc(t: ^testing.T) {
	accent := Style{fg = ACCENT}
	spans := []Span{
		{text = "hash", style = Style{fg = RAMP_TEXT}},
		{text = "some subject words here", style = accent},
	}
	lines := wrap_spans(spans[:], 14)
	defer spans_destroy(&lines)
	testing.expect(t, len(lines) > 1)
	testing.expect_value(t, lines[0][0].style.fg, RAMP_TEXT)
	// The subject keeps its own colour after the break.
	last := lines[len(lines) - 1]
	testing.expect_value(t, last[len(last) - 1].style.fg, ACCENT)
	for line in lines {
		width := 0
		for span in line do width += text_width(span.text)
		testing.expectf(t, width <= 14, "overflowed: %d", width)
	}
}

// A ref chip is one object. Half a chip at a line end reads as damage, so an atomic
// span moves to the next line whole even when that leaves the current one short.
@(test)
test_wrap_spans_never_splits_atomic :: proc(t: ^testing.T) {
	spans := []Span{
		{text = "aaaa", style = PLAIN_STYLE},
		{text = " HEAD -> develop ", style = PLAIN_STYLE, atomic = true},
	}
	lines := wrap_spans(spans[:], 20)
	defer spans_destroy(&lines)
	// The chip is present exactly once, unbroken.
	found := 0
	for line in lines {
		for span in line {
			if span.text == " HEAD -> develop " do found += 1
		}
	}
	testing.expect_value(t, found, 1)
}

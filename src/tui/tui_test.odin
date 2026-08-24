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

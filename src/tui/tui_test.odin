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

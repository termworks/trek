package tui

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

text_width :: proc(value: string) -> int {
	_, _, width := utf8.grapheme_count(value)
	return width
}

truncate_text :: proc(value: string, max_width: int, mark := "…", allocator := context.allocator) -> string {
	if max_width <= 0 {
		return strings.clone("", allocator)
	}
	if text_width(value) <= max_width {
		return strings.clone(value, allocator)
	}
	mark_width := text_width(mark)
	if mark_width > max_width {
		return strings.clone("", allocator)
	}

	clusters, _, _, _ := utf8.decode_grapheme_clusters(value, allocator = context.allocator)
	defer delete(clusters)
	cut := 0
	used := 0
	for cluster, index in clusters {
		if used + cluster.width + mark_width > max_width {
			break
		}
		used += cluster.width
		if index + 1 < len(clusters) {
			cut = clusters[index + 1].byte_index
		} else {
			cut = len(value)
		}
	}

	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, value[:cut])
	strings.write_string(&builder, mark)
	return strings.clone(strings.to_string(builder), allocator)
}

input_tail :: proc(value: string, max_width: int, allocator := context.allocator) -> string {
	if max_width <= 0 {
		return strings.clone("", allocator)
	}
	if text_width(value) <= max_width {
		return strings.clone(value, allocator)
	}

	mark := "…"
	budget := max_width - text_width(mark)
	if budget <= 0 {
		return strings.clone(mark, allocator)
	}
	clusters, _, _, _ := utf8.decode_grapheme_clusters(value, allocator = context.allocator)
	defer delete(clusters)
	start := len(value)
	used := 0
	for index := len(clusters) - 1; index >= 0; index -= 1 {
		cluster := clusters[index]
		if used + cluster.width > budget {
			break
		}
		used += cluster.width
		start = cluster.byte_index
	}
	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, mark)
	strings.write_string(&builder, value[start:])
	return strings.clone(strings.to_string(builder), allocator)
}

wrap_text :: proc(value: string, max_width: int, allocator := context.allocator) -> [dynamic]string {
	lines := make([dynamic]string, allocator)
	if max_width <= 0 {
		append(&lines, strings.clone("", allocator))
		return lines
	}
	if len(value) == 0 {
		append(&lines, strings.clone("", allocator))
		return lines
	}

	line_start := 0
	line_width := 0
	clusters, _, _, _ := utf8.decode_grapheme_clusters(value, allocator = context.allocator)
	defer delete(clusters)
	for cluster, index in clusters {
		cluster_end := len(value)
		if index + 1 < len(clusters) {
			cluster_end = clusters[index + 1].byte_index
		}
		cluster_text := value[cluster.byte_index:cluster_end]
		if cluster_text == "\n" {
			append(&lines, strings.clone(value[line_start:cluster.byte_index], allocator))
			line_start = cluster_end
			line_width = 0
			continue
		}
		if line_width > 0 && line_width + cluster.width > max_width {
			append(&lines, strings.clone(value[line_start:cluster.byte_index], allocator))
			line_start = cluster.byte_index
			line_width = 0
		}
		line_width += cluster.width
	}
	append(&lines, strings.clone(value[line_start:], allocator))
	return lines
}

destroy_lines :: proc(lines: ^[dynamic]string) {
	for line in lines {
		delete(line)
	}
	delete(lines^)
	lines^ = nil
}

// Fit a path into `max_width` by abbreviating leading segments to their first
// character, one at a time from the root end: /home/bresilla/code/tools/trek
// becomes /h/bresilla/code/tools/trek, then /h/b/code/tools/trek, and so on. The
// last segment is what the reader is actually looking at, so it is never shortened
// this way; if even the fully abbreviated form does not fit, the result is
// truncated normally.
shorten_path :: proc(path: string, max_width: int, allocator := context.allocator) -> string {
	if max_width <= 0 do return strings.clone("", allocator)
	if text_width(path) <= max_width do return strings.clone(path, allocator)

	rooted := len(path) > 0 && path[0] == '/'
	trimmed := strings.trim_suffix(path, "/")
	segments := strings.split(trimmed, "/", context.temp_allocator)
	// A leading "/" splits into an empty first segment; drop it and remember it.
	start := 0
	for start < len(segments) && segments[start] == "" do start += 1
	if len(segments) - start <= 1 do return truncate_text(path, max_width, allocator = allocator)

	// Abbreviate one more leading segment per pass, never touching the last.
	shortened := 0
	limit := len(segments) - start - 1
	for {
		builder := strings.builder_make(context.temp_allocator)
		if rooted do strings.write_string(&builder, "/")
		for index in start ..< len(segments) {
			if index > start do strings.write_string(&builder, "/")
			segment := segments[index]
			if index - start < shortened && len(segment) > 0 {
				strings.write_string(&builder, first_rune_text(segment))
			} else {
				strings.write_string(&builder, segment)
			}
		}
		candidate := strings.to_string(builder)
		if text_width(candidate) <= max_width || shortened >= limit {
			if text_width(candidate) <= max_width do return strings.clone(candidate, allocator)
			return truncate_text(candidate, max_width, allocator = allocator)
		}
		shortened += 1
	}
}

// The first rune of a segment, as text. Taking one byte would split a multi-byte
// character and emit a broken glyph.
first_rune_text :: proc(value: string) -> string {
	for _, index in value {
		_ = index
		for offset in 1 ..= len(value) {
			if offset == len(value) || (value[offset] & 0xc0) != 0x80 do return value[:offset]
		}
	}
	return value
}


// Greedy word wrap, the way `git log --format=%w` reflows a paragraph: break at
// spaces, and hard-break a single word that is wider than the line so nothing is
// lost off the right edge. The existing wrap_text breaks per grapheme, which is
// right for preformatted text and wrong for prose.
wrap_words :: proc(value: string, width: int, allocator := context.allocator) -> [dynamic]string {
	lines := make([dynamic]string, allocator)
	if width <= 0 {
		append(&lines, strings.clone("", allocator))
		return lines
	}
	current := strings.builder_make(context.temp_allocator)
	used := 0
	remaining := value
	for word in strings.split_iterator(&remaining, " ") {
		if word == "" do continue
		word_width := text_width(word)
		if used > 0 && used + 1 + word_width > width {
			append(&lines, strings.clone(strings.to_string(current), allocator))
			strings.builder_reset(&current)
			used = 0
		}
		if used > 0 {
			strings.write_string(&current, " ")
			used += 1
		}
		if word_width > width {
			for r in word {
				rune_width := text_width(utf8.runes_to_string({r}, context.temp_allocator))
				if used + rune_width > width && used > 0 {
					append(&lines, strings.clone(strings.to_string(current), allocator))
					strings.builder_reset(&current)
					used = 0
				}
				strings.write_rune(&current, r)
				used += rune_width
			}
			continue
		}
		strings.write_string(&current, word)
		used += word_width
	}
	if used > 0 || len(lines) == 0 {
		append(&lines, strings.clone(strings.to_string(current), allocator))
	}
	return lines
}

// Wrap a path, breaking after a separator rather than mid-segment. Word wrap has
// nothing to work with here — a path contains no spaces — so it hard-breaks in the
// middle of a directory name, which is both ugly and ambiguous. A segment wider
// than the line still has to break somewhere.
wrap_path :: proc(value: string, width: int, allocator := context.allocator) -> [dynamic]string {
	return wrap_after(value, width, "/", allocator)
}

// Wrap after any of `breakers`, falling back to a hard break only for a run that is
// wider than the line on its own.
wrap_after :: proc(value: string, width: int, breakers: string, allocator := context.allocator) -> [dynamic]string {
	lines := make([dynamic]string, allocator)
	if width <= 0 || value == "" {
		append(&lines, strings.clone(value if width > 0 else "", allocator))
		return lines
	}
	current := strings.builder_make(context.temp_allocator)
	used := 0
	start := 0
	for index := 0; index <= len(value); index += 1 {
		// Cut after each separator, and once more at the end for the tail segment.
		if index < len(value) && !strings.contains_rune(breakers, rune(value[index])) do continue
		piece := value[start:min(index + 1, len(value))]
		start = index + 1
		piece_width := text_width(piece)
		if used > 0 && used + piece_width > width {
			append(&lines, strings.clone(strings.to_string(current), allocator))
			strings.builder_reset(&current)
			used = 0
		}
		if piece_width > width {
			for r in piece {
				rune_width := text_width(utf8.runes_to_string({r}, context.temp_allocator))
				if used + rune_width > width && used > 0 {
					append(&lines, strings.clone(strings.to_string(current), allocator))
					strings.builder_reset(&current)
					used = 0
				}
				strings.write_rune(&current, r)
				used += rune_width
			}
			continue
		}
		strings.write_string(&current, piece)
		used += piece_width
	}
	if used > 0 || len(lines) == 0 {
		append(&lines, strings.clone(strings.to_string(current), allocator))
	}
	return lines
}

// Wrap a filename. Names break at the separators people actually use in them —
// dashes, underscores and dots — so `report-2026-01.csv` splits after a dash rather
// than through the middle of a word.
wrap_name :: proc(value: string, width: int, allocator := context.allocator) -> [dynamic]string {
	return wrap_after(value, width, "-_./", allocator)
}

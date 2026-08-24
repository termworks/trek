package tui

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

package tui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

Cell :: struct {
	rune:         rune,
	style:        Style,
	continuation: bool,
}

Buffer :: struct {
	width:    int,
	height:   int,
	cells:    [dynamic]Cell,
	previous: [dynamic]Cell,
	dirty:    bool,
}

blank_cell :: proc(style := PLAIN_STYLE) -> Cell {
	return Cell{rune = ' ', style = style}
}

buffer_init :: proc(buffer: ^Buffer, width, height: int, allocator := context.allocator) {
	buffer.width = max(width, 0)
	buffer.height = max(height, 0)
	count := buffer.width * buffer.height
	buffer.cells = make([dynamic]Cell, count, allocator)
	buffer.previous = make([dynamic]Cell, count, allocator)
	for index in 0 ..< count {
		buffer.cells[index] = blank_cell()
		buffer.previous[index] = Cell{rune = 0}
	}
	buffer.dirty = true
}

buffer_destroy :: proc(buffer: ^Buffer) {
	delete(buffer.cells)
	delete(buffer.previous)
	buffer^ = {}
}

buffer_resize :: proc(buffer: ^Buffer, width, height: int) {
	if width == buffer.width && height == buffer.height {
		return
	}
	allocator := buffer.cells.allocator
	delete(buffer.cells)
	delete(buffer.previous)
	buffer_init(buffer, width, height, allocator)
}

buffer_clear :: proc(buffer: ^Buffer, style := PLAIN_STYLE) {
	cell := blank_cell(style)
	for index in 0 ..< len(buffer.cells) {
		buffer.cells[index] = cell
	}
	buffer.dirty = true
}

buffer_invalidate :: proc(buffer: ^Buffer) {
	for index in 0 ..< len(buffer.previous) do buffer.previous[index] = Cell{rune = 0}
	buffer.dirty = true
}

buffer_index :: proc(buffer: ^Buffer, x, y: int) -> (int, bool) {
	if x < 0 || y < 0 || x >= buffer.width || y >= buffer.height {
		return 0, false
	}
	return y * buffer.width + x, true
}

buffer_get :: proc(buffer: ^Buffer, x, y: int) -> (Cell, bool) {
	index, ok := buffer_index(buffer, x, y)
	if !ok {
		return {}, false
	}
	return buffer.cells[index], true
}

buffer_set :: proc(buffer: ^Buffer, x, y: int, cell: Cell) {
	index, ok := buffer_index(buffer, x, y)
	if !ok {
		return
	}
	buffer.cells[index] = cell
	buffer.dirty = true
}

buffer_fill :: proc(buffer: ^Buffer, rect: Rect, style := PLAIN_STYLE, value := ' ') {
	for y in rect.y ..< rect.y + rect.height {
		for x in rect.x ..< rect.x + rect.width {
			buffer_set(buffer, x, y, Cell{rune = value, style = style})
		}
	}
}

buffer_draw_text :: proc(buffer: ^Buffer, x, y: int, value: string, style := PLAIN_STYLE, limit := -1) -> int {
	column := x
	max_column := buffer.width
	if limit >= 0 {
		max_column = min(max_column, x + limit)
	}
	clusters, _, _, _ := utf8.decode_grapheme_clusters(value, allocator = context.allocator)
	defer delete(clusters)
	for cluster, index in clusters {
		if column + cluster.width > max_column {
			break
		}
		end := len(value)
		if index + 1 < len(clusters) {
			end = clusters[index + 1].byte_index
		}
		grapheme := value[cluster.byte_index:end]
		r, _ := utf8.decode_rune(grapheme)
		buffer_set(buffer, column, y, Cell{rune = r, style = style})
		for offset in 1 ..< cluster.width {
			buffer_set(buffer, column + offset, y, Cell{rune = ' ', style = style, continuation = true})
		}
		column += cluster.width
	}
	return column - x
}

write_color :: proc(builder: ^strings.Builder, color: Color, foreground: bool) {
	prefix := 38
	if !foreground {
		prefix = 48
	}
	switch color.kind {
	case .Default:
		if foreground {
			strings.write_string(builder, "39")
		} else {
			strings.write_string(builder, "49")
		}
	case .Indexed:
		fmt.sbprintf(builder, "%d;5;%d", prefix, color.index)
	case .RGB:
		fmt.sbprintf(builder, "%d;2;%d;%d;%d", prefix, color.r, color.g, color.b)
	}
}

write_style :: proc(builder: ^strings.Builder, style: Style) {
	strings.write_string(builder, "\x1b[0;")
	write_color(builder, style.fg, true)
	strings.write_byte(builder, ';')
	write_color(builder, style.bg, false)
	if .Bold in style.attrs do strings.write_string(builder, ";1")
	if .Dim in style.attrs do strings.write_string(builder, ";2")
	if .Italic in style.attrs do strings.write_string(builder, ";3")
	if .Underline in style.attrs do strings.write_string(builder, ";4")
	if .Reverse in style.attrs do strings.write_string(builder, ";7")
	strings.write_byte(builder, 'm')
}

buffer_render_diff :: proc(buffer: ^Buffer, allocator := context.allocator) -> string {
	if !buffer.dirty {
		return strings.clone("", allocator)
	}
	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	active_style := plain_style()
	have_style := false
	for y in 0 ..< buffer.height {
		x := 0
		for x < buffer.width {
			index := y * buffer.width + x
			if buffer.cells[index] == buffer.previous[index] {
				x += 1
				continue
			}
			fmt.sbprintf(&builder, "\x1b[%d;%dH", y + 1, x + 1)
			for x < buffer.width {
				index = y * buffer.width + x
				cell := buffer.cells[index]
				if x > 0 && cell == buffer.previous[index] {
					break
				}
				if !have_style || cell.style != active_style {
					write_style(&builder, cell.style)
					active_style = cell.style
					have_style = true
				}
				if !cell.continuation {
					strings.write_rune(&builder, cell.rune)
				}
				buffer.previous[index] = cell
				x += 1
			}
		}
	}
	if have_style {
		strings.write_string(&builder, "\x1b[0m")
	}
	buffer.dirty = false
	return strings.clone(strings.to_string(builder), allocator)
}

buffer_flush :: proc(buffer: ^Buffer) -> bool {
	output := buffer_render_diff(buffer)
	defer delete(output)
	if len(output) == 0 {
		return true
	}
	_, err := os.write_string(os.stdout, output)
	return err == nil
}

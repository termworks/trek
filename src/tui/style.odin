package tui

Color_Kind :: enum {
	Default,
	Indexed,
	RGB,
}

Color :: struct {
	kind:  Color_Kind,
	index: u8,
	r:     u8,
	g:     u8,
	b:     u8,
}

DEFAULT_COLOR :: Color{kind = .Default}

default_color :: proc() -> Color {
	return DEFAULT_COLOR
}

indexed_color :: proc(index: u8) -> Color {
	return Color{kind = .Indexed, index = index}
}

rgb :: proc(r, g, b: u8) -> Color {
	return Color{kind = .RGB, r = r, g = g, b = b}
}

// Nearest entry in the 6x6x6 colour cube (16-231). File-type icons carry brand
// colours as hex, but resolving them through the cube keeps every colour trek emits
// an index, so a themed palette stays in charge of the rest of the range.
cube :: proc(r, g, b: u8) -> Color {
	step :: proc(value: u8) -> int {
		return (int(value) * 5 + 127) / 255
	}
	return Color{kind = .Indexed, index = u8(16 + 36 * step(r) + 6 * step(g) + step(b))}
}

Attribute :: enum {
	Bold,
	Dim,
	Italic,
	Underline,
	Reverse,
}

Attributes :: bit_set[Attribute]

Style :: struct {
	fg:    Color,
	bg:    Color,
	attrs: Attributes,
}

PLAIN_STYLE :: Style{fg = DEFAULT_COLOR, bg = DEFAULT_COLOR}

plain_style :: proc() -> Style {
	return PLAIN_STYLE
}

merge_style :: proc(base, overlay: Style) -> Style {
	result := base
	if overlay.fg.kind != .Default {
		result.fg = overlay.fg
	}
	if overlay.bg.kind != .Default {
		result.bg = overlay.bg
	}
	result.attrs += overlay.attrs
	return result
}

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

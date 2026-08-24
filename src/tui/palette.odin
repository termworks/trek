package tui

HERDR_KEYCAP_BG :: Color{kind = .RGB, r = 0x32, g = 0x36, b = 0x3d}
HERDR_KEYCAP_FG :: Color{kind = .RGB, r = 0xc9, g = 0xce, b = 0xd6}
HERDR_MODIFIED :: Color{kind = .RGB, r = 0xe2, g = 0xc0, b = 0x8d}
HERDR_UNTRACKED :: Color{kind = .RGB, r = 0x73, g = 0xc9, b = 0x91}
HERDR_ADDED :: Color{kind = .RGB, r = 0x81, g = 0xb8, b = 0x8b}
HERDR_DELETED :: Color{kind = .RGB, r = 0xc7, g = 0x4e, b = 0x39}
HERDR_CONFLICT :: Color{kind = .RGB, r = 0xe4, g = 0x67, b = 0x6b}
HERDR_IGNORED :: Color{kind = .RGB, r = 0x6b, g = 0x6b, b = 0x6b}
HERDR_BUTTON_BLUE :: Color{kind = .RGB, r = 0x00, g = 0x78, b = 0xd4}
HERDR_BUTTON_BLUE_FOCUS :: Color{kind = .RGB, r = 0x02, g = 0x8a, b = 0xf0}
HERDR_HOVER_BG :: Color{kind = .RGB, r = 48, g = 52, b = 60}
HERDR_INACTIVE_BG :: Color{kind = .RGB, r = 0x2a, g = 0x2d, b = 0x2e}
HERDR_LIGHT_BLUE :: Color{kind = .Indexed, index = 12}
HERDR_DARK_GRAY :: Color{kind = .Indexed, index = 8}

herdr_status_color :: proc(letter: rune) -> Color {
	switch letter {
	case 'M': return HERDR_MODIFIED
	case 'U': return HERDR_UNTRACKED
	case 'A': return HERDR_ADDED
	case 'R', 'C': return HERDR_UNTRACKED
	case 'D': return HERDR_DELETED
	case '!': return HERDR_CONFLICT
	case 'I': return HERDR_IGNORED
	}
	return DEFAULT_COLOR
}

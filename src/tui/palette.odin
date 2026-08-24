package tui

// Everything here is an indexed colour, never RGB. lule rewrites all 256 palette
// entries from the wallpaper, so trek follows the terminal theme by naming indices
// instead of baking hex values that would fight it.
//
// 0 is the background, 1 the accent, and 232-255 the dark-to-light ramp the chrome
// is built from.

BG :: Color{kind = .Indexed, index = 0}
ACCENT :: Color{kind = .Indexed, index = 1}

// 232-235 sit at or below the terminal background, so nothing that must be SEEN as a
// surface is allowed to live there: the activity strip drawn at 234 was darker than the
// background behind it and read as no strip at all. Raised surfaces start at 236.
RAMP_SUNK :: Color{kind = .Indexed, index = 233}
RAMP_RAISED :: Color{kind = .Indexed, index = 236}
RAMP_HOVER :: Color{kind = .Indexed, index = 237}
RAMP_SELECT :: Color{kind = .Indexed, index = 238}
RAMP_BORDER :: Color{kind = .Indexed, index = 240}
RAMP_FAINT :: Color{kind = .Indexed, index = 241}
RAMP_MUTED :: Color{kind = .Indexed, index = 245}
RAMP_TEXT :: Color{kind = .Indexed, index = 250}
RAMP_BRIGHT :: Color{kind = .Indexed, index = 255}

SELECTED_BG :: RAMP_SELECT
HOVER_BG :: RAMP_HOVER
ACTIVITY_BG :: RAMP_RAISED
ACTIVITY_ACTIVE_BG :: RAMP_SELECT
BUTTON_BG :: ACCENT
BUTTON_FG :: BG

// Git status letters. Only the four the ramp cannot express keep a hue, and they
// come from the ANSI 16 so lule themes them too.
STATUS_MODIFIED :: Color{kind = .Indexed, index = 3}
STATUS_UNTRACKED :: Color{kind = .Indexed, index = 2}
STATUS_ADDED :: Color{kind = .Indexed, index = 2}
STATUS_DELETED :: Color{kind = .Indexed, index = 1}
STATUS_CONFLICT :: Color{kind = .Indexed, index = 5}
STATUS_IGNORED :: RAMP_FAINT

status_color :: proc(letter: rune) -> Color {
	switch letter {
	case 'M': return STATUS_MODIFIED
	case 'U': return STATUS_UNTRACKED
	case 'A': return STATUS_ADDED
	case 'R', 'C': return STATUS_UNTRACKED
	case 'D': return STATUS_DELETED
	case '!': return STATUS_CONFLICT
	case 'I': return STATUS_IGNORED
	}
	return DEFAULT_COLOR
}

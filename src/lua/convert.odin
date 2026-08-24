package lua

import c "core:c/libc"
import "core:strconv"
import "core:strings"
import tui "../tui"
import clua "vendor:lua/5.4"

table_int :: proc(L: ^clua.State, table: c.int, field: cstring, fallback := 0) -> int {
	clua.getfield(L, table, field)
	defer clua.pop(L, 1)
	if !clua.isinteger(L, -1) do return fallback
	return int(clua.tointeger(L, -1))
}

named_color :: proc(value: string) -> tui.Color {
	switch value {
	case "added": return tui.STATUS_ADDED
	case "modified": return tui.STATUS_MODIFIED
	case "deleted": return tui.STATUS_DELETED
	case "muted": return tui.RAMP_FAINT
	case "accent": return tui.ACCENT
	}
	if len(value) == 7 && value[0] == '#' {
		packed, ok := strconv.parse_u64(value[1:], 16)
		if ok do return tui.cube(u8(packed >> 16), u8(packed >> 8), u8(packed))
	}
	return tui.DEFAULT_COLOR
}

style_field_color :: proc(L: ^clua.State, table: c.int, field: cstring) -> tui.Color {
	clua.getfield(L, table, field)
	defer clua.pop(L, 1)
	value := lua_string(L, -1, context.temp_allocator)
	return named_color(value)
}

lua_to_style :: proc(L: ^clua.State, index: c.int) -> tui.Style {
	if !clua.istable(L, index) do return tui.PLAIN_STYLE
	table := clua.absindex(L, index)
	style := tui.Style{
		fg = style_field_color(L, table, "fg"),
		bg = style_field_color(L, table, "bg"),
	}
	if table_bool(L, table, "bold", false) do style.attrs += {.Bold}
	if table_bool(L, table, "dim", false) do style.attrs += {.Dim}
	if table_bool(L, table, "italic", false) do style.attrs += {.Italic}
	if table_bool(L, table, "underline", false) do style.attrs += {.Underline}
	if table_bool(L, table, "reverse", false) do style.attrs += {.Reverse}
	return style
}

node_field_style :: proc(L: ^clua.State, table: c.int, field: cstring) -> tui.Style {
	clua.getfield(L, table, field)
	defer clua.pop(L, 1)
	return lua_to_style(L, -1)
}

node_field :: proc(L: ^clua.State, table: c.int, field: cstring, allocator := context.allocator) -> (tui.Node, bool) {
	clua.getfield(L, table, field)
	defer clua.pop(L, 1)
	return lua_to_node(L, -1, allocator)
}

node_children :: proc(L: ^clua.State, table: c.int, allocator := context.allocator) -> [dynamic]tui.Node {
	children := make([dynamic]tui.Node, allocator)
	clua.getfield(L, table, "children")
	defer clua.pop(L, 1)
	if !clua.istable(L, -1) do return children
	child_table := clua.absindex(L, -1)
	for index in 1 ..= int(clua.rawlen(L, child_table)) {
		clua.rawgeti(L, child_table, clua.Integer(index))
		child, ok := lua_to_node(L, -1, allocator)
		clua.pop(L, 1)
		if ok do append(&children, child)
	}
	return children
}

owned_text_node :: proc(value: string, style: tui.Style) -> tui.Node {
	return tui.Node{kind = .Text, value = value, style = style, owns_values = true}
}

lua_to_node :: proc(L: ^clua.State, index: c.int, allocator := context.allocator) -> (tui.Node, bool) {
	if !clua.istable(L, index) do return {}, false
	table := clua.absindex(L, index)
	kind := table_string(L, table, "kind", context.temp_allocator)
	switch kind {
	case "text":
		value := table_string(L, table, "value", allocator)
		return owned_text_node(value, node_field_style(L, table, "style")), true
	case "row", "column":
		children := node_children(L, table, allocator)
		if kind == "row" do return tui.Node{kind = .Row, children = children}, true
		return tui.Node{kind = .Column, children = children}, true
	case "pad":
		value, ok := node_field(L, table, "value", allocator)
		if !ok do return {}, false
		padding: tui.Padding
		clua.getfield(L, table, "padding")
		if clua.istable(L, -1) {
			padding_table := clua.absindex(L, -1)
			padding.top = table_int(L, padding_table, "top")
			padding.right = table_int(L, padding_table, "right")
			padding.bottom = table_int(L, padding_table, "bottom")
			padding.left = table_int(L, padding_table, "left")
		}
		clua.pop(L, 1)
		return tui.pad(value, padding, allocator), true
	case "truncate":
		value, ok := node_field(L, table, "value", allocator)
		if !ok do return {}, false
		mark := table_string(L, table, "mark", allocator)
		if mark == "" {
			delete(mark)
			mark = strings.clone("…", allocator)
		}
		node := tui.truncate(value, table_int(L, table, "width"), mark, allocator)
		node.owns_values = true
		return node, true
	case "style":
		value, ok := node_field(L, table, "value", allocator)
		if !ok do return {}, false
		return tui.styled(value, node_field_style(L, table, "style"), allocator), true
	case "spacer":
		return tui.spacer(table_int(L, table, "weight", 1)), true
	case "transparent":
		return tui.transparent(table_int(L, table, "width")), true
	case "priority":
		value, ok := node_field(L, table, "value", allocator)
		if !ok do return {}, false
		return tui.priority(value, table_int(L, table, "importance"), allocator), true
	case "region":
		value, ok := node_field(L, table, "value", allocator)
		if !ok do return {}, false
		id := table_string(L, table, "id", allocator)
		actions := make([dynamic]string, allocator)
		clua.getfield(L, table, "actions")
		if clua.istable(L, -1) {
			action_table := clua.absindex(L, -1)
			for action_index in 1 ..= int(clua.rawlen(L, action_table)) {
				clua.rawgeti(L, action_table, clua.Integer(action_index))
				action := lua_string(L, -1, allocator)
				clua.pop(L, 1)
				if action != "" do append(&actions, action)
			}
		}
		clua.pop(L, 1)
		node := tui.region(
			value,
			id,
			actions[:],
			node_field_style(L, table, "hover_style"),
			node_field_style(L, table, "press_style"),
			allocator,
		)
		node.owns_values = true
		node.owned_actions = actions
		return node, true
	}
	return {}, false
}

package tui

import "core:strings"

Node_Kind :: enum {
	Text,
	Row,
	Column,
	Pad,
	Truncate,
	Styled,
	Spacer,
	Transparent,
	Priority,
	Region,
}

Padding :: struct {
	top:    int,
	right:  int,
	bottom: int,
	left:   int,
}

Node :: struct {
	kind:       Node_Kind,
	value:      string,
	mark:       string,
	style:      Style,
	children:   [dynamic]Node,
	padding:    Padding,
	width:      int,
	weight:     int,
	importance: int,
	region_id:  string,
	actions:    []string,
	hover:      Style,
	press:      Style,
}

nodes_copy :: proc(values: []Node, allocator := context.allocator) -> [dynamic]Node {
	result := make([dynamic]Node, 0, len(values), allocator)
	append(&result, ..values)
	return result
}

text :: proc(value: string, style := PLAIN_STYLE) -> Node {
	return Node{kind = .Text, value = value, style = style}
}

row :: proc(children: []Node, allocator := context.allocator) -> Node {
	return Node{kind = .Row, children = nodes_copy(children, allocator)}
}

column :: proc(children: []Node, allocator := context.allocator) -> Node {
	return Node{kind = .Column, children = nodes_copy(children, allocator)}
}

pad :: proc(value: Node, padding: Padding, allocator := context.allocator) -> Node {
	return Node{kind = .Pad, children = nodes_copy([]Node{value}, allocator), padding = padding}
}

truncate :: proc(value: Node, width: int, mark := "…", allocator := context.allocator) -> Node {
	return Node{kind = .Truncate, children = nodes_copy([]Node{value}, allocator), width = width, mark = mark}
}

styled :: proc(value: Node, style: Style, allocator := context.allocator) -> Node {
	return Node{kind = .Styled, children = nodes_copy([]Node{value}, allocator), style = style}
}

spacer :: proc(weight := 1) -> Node {
	return Node{kind = .Spacer, weight = max(weight, 1)}
}

transparent :: proc(width: int) -> Node {
	return Node{kind = .Transparent, width = max(width, 0)}
}

priority :: proc(value: Node, importance: int, allocator := context.allocator) -> Node {
	return Node{kind = .Priority, children = nodes_copy([]Node{value}, allocator), importance = importance}
}

region :: proc(
	value: Node,
	id: string,
	actions: []string = nil,
	hover := PLAIN_STYLE,
	press := PLAIN_STYLE,
	allocator := context.allocator,
) -> Node {
	return Node{
		kind = .Region,
		children = nodes_copy([]Node{value}, allocator),
		region_id = id,
		actions = actions,
		hover = hover,
		press = press,
	}
}

node_destroy :: proc(node: ^Node) {
	for &child in node.children {
		node_destroy(&child)
	}
	delete(node.children)
	node.children = nil
}

Rect :: struct {
	x:      int,
	y:      int,
	width:  int,
	height: int,
}

Region_Hit :: struct {
	id:      string,
	actions: []string,
	rect:    Rect,
}

Layout :: struct {
	regions: [dynamic]Region_Hit,
}

layout_init :: proc(layout: ^Layout, allocator := context.allocator) {
	layout.regions = make([dynamic]Region_Hit, allocator)
}

layout_destroy :: proc(layout: ^Layout) {
	delete(layout.regions)
	layout^ = {}
}

layout_clear :: proc(layout: ^Layout) {
	clear(&layout.regions)
}

region_at :: proc(layout: ^Layout, x, y: int) -> (Region_Hit, bool) {
	for index := len(layout.regions) - 1; index >= 0; index -= 1 {
		hit := layout.regions[index]
		if x >= hit.rect.x && x < hit.rect.x + hit.rect.width &&
		   y >= hit.rect.y && y < hit.rect.y + hit.rect.height {
			return hit, true
		}
	}
	return {}, false
}

node_width :: proc(node: ^Node) -> int {
	switch node.kind {
	case .Text:
		return text_width(node.value)
	case .Row:
		width := 0
		for &child in node.children do width += node_width(&child)
		return width
	case .Column:
		width := 0
		for &child in node.children do width = max(width, node_width(&child))
		return width
	case .Pad:
		if len(node.children) == 0 do return node.padding.left + node.padding.right
		return node.padding.left + node_width(&node.children[0]) + node.padding.right
	case .Truncate:
		if len(node.children) == 0 do return 0
		natural := node_width(&node.children[0])
		if node.width <= 0 do return natural
		return min(natural, node.width)
	case .Styled, .Priority, .Region:
		if len(node.children) == 0 do return 0
		return node_width(&node.children[0])
	case .Spacer:
		return 0
	case .Transparent:
		return node.width
	}
	return 0
}

node_height :: proc(node: ^Node) -> int {
	switch node.kind {
	case .Column:
		height := 0
		for &child in node.children do height += node_height(&child)
		return height
	case .Row:
		height := 1
		for &child in node.children do height = max(height, node_height(&child))
		return height
	case .Pad:
		child_height := 0
		if len(node.children) > 0 do child_height = node_height(&node.children[0])
		return node.padding.top + child_height + node.padding.bottom
	case .Styled, .Truncate, .Priority, .Region:
		if len(node.children) == 0 do return 0
		return node_height(&node.children[0])
	case .Text, .Spacer, .Transparent:
		return 1
	}
	return 0
}

node_priority :: proc(node: ^Node) -> int {
	if node.kind == .Priority {
		return node.importance
	}
	return 0
}

render_node :: proc(buffer: ^Buffer, layout: ^Layout, node: ^Node, rect: Rect, inherited: Style) {
	if rect.width <= 0 || rect.height <= 0 {
		return
	}
	switch node.kind {
	case .Text:
		buffer_draw_text(buffer, rect.x, rect.y, node.value, merge_style(inherited, node.style), rect.width)
	case .Transparent, .Spacer:
		return
	case .Styled:
		if len(node.children) > 0 do render_node(buffer, layout, &node.children[0], rect, merge_style(inherited, node.style))
	case .Priority:
		if len(node.children) > 0 do render_node(buffer, layout, &node.children[0], rect, inherited)
	case .Region:
		append(&layout.regions, Region_Hit{id = node.region_id, actions = node.actions, rect = rect})
		if len(node.children) > 0 do render_node(buffer, layout, &node.children[0], rect, inherited)
	case .Pad:
		if len(node.children) > 0 {
			inner := Rect{
				x = rect.x + node.padding.left,
				y = rect.y + node.padding.top,
				width = max(rect.width - node.padding.left - node.padding.right, 0),
				height = max(rect.height - node.padding.top - node.padding.bottom, 0),
			}
			render_node(buffer, layout, &node.children[0], inner, inherited)
		}
	case .Truncate:
		if len(node.children) == 0 do return
		child := &node.children[0]
		if child.kind == .Text {
			mark := node.mark
			if mark == "" do mark = "…"
			value := truncate_text(child.value, rect.width, mark, context.allocator)
			defer delete(value)
			buffer_draw_text(buffer, rect.x, rect.y, value, merge_style(inherited, child.style), rect.width)
		} else {
			render_node(buffer, layout, child, rect, inherited)
		}
	case .Column:
		y := rect.y
		for &child in node.children {
			height := min(node_height(&child), rect.y + rect.height - y)
			if height <= 0 do break
			render_node(buffer, layout, &child, Rect{x = rect.x, y = y, width = rect.width, height = height}, inherited)
			y += height
		}
	case .Row:
		count := len(node.children)
		if count == 0 do return
		widths := make([]int, count, context.allocator)
		priorities := make([]int, count, context.allocator)
		defer delete(widths)
		defer delete(priorities)
		total := 0
		spacer_weight := 0
		for &child, index in node.children {
			if child.kind == .Spacer {
				spacer_weight += child.weight
				continue
			}
			widths[index] = node_width(&child)
			priorities[index] = node_priority(&child)
			total += widths[index]
		}
		if total > rect.width {
			excess := total - rect.width
			for excess > 0 {
				chosen := -1
				for index in 0 ..< count {
					if widths[index] <= 0 do continue
					if chosen < 0 || priorities[index] < priorities[chosen] {
						chosen = index
					}
				}
				if chosen < 0 do break
				widths[chosen] -= 1
				excess -= 1
			}
		} else if spacer_weight > 0 {
			remaining := rect.width - total
			assigned := 0
			for &child, index in node.children {
				if child.kind != .Spacer do continue
				share := remaining * child.weight / spacer_weight
				widths[index] = share
				assigned += share
			}
			for index in 0 ..< count {
				if assigned >= remaining do break
				if node.children[index].kind == .Spacer {
					widths[index] += 1
					assigned += 1
				}
			}
		}
		x := rect.x
		for &child, index in node.children {
			width := min(widths[index], rect.x + rect.width - x)
			if width <= 0 do continue
			render_node(buffer, layout, &child, Rect{x = x, y = rect.y, width = width, height = rect.height}, inherited)
			x += width
		}
	}
}

compose :: proc(buffer: ^Buffer, layout: ^Layout, node: ^Node, rect: Rect) {
	render_node(buffer, layout, node, rect, PLAIN_STYLE)
}

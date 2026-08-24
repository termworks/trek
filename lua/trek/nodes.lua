package.preload["trek.nodes"] = function()
  local nodes = {}

  local function node(kind, fields)
    fields = fields or {}
    fields.kind = kind
    return fields
  end

  function nodes.text(value, style)
    return node("text", {value = tostring(value or ""), style = style})
  end

  function nodes.row(children)
    return node("row", {children = children or {}})
  end

  function nodes.column(children)
    return node("column", {children = children or {}})
  end

  function nodes.pad(value, padding)
    return node("pad", {value = value, padding = padding or {}})
  end

  function nodes.truncate(value, width, mark)
    return node("truncate", {value = value, width = width or 0, mark = mark or "…"})
  end

  function nodes.style(value, style)
    return node("style", {value = value, style = style or {}})
  end

  function nodes.spacer(weight)
    return node("spacer", {weight = weight or 1})
  end

  function nodes.transparent(width)
    return node("transparent", {width = width or 0})
  end

  function nodes.priority(value, importance)
    return node("priority", {value = value, importance = importance or 0})
  end

  function nodes.region(value, options)
    options = options or {}
    return node("region", {
      value = value,
      id = options.id or "",
      actions = options.actions or {},
      hover_style = options.hover_style,
      press_style = options.press_style,
    })
  end

  return nodes
end

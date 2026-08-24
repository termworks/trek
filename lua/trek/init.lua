package.preload["trek"] = function()
  local nodes = require("trek.nodes")
  local trek = {
    keys = {},
    menu = {},
    on = {},
    _handlers = {open = {}, root = {}},
    _tabs = {},
    _tab_order = {},
  }

  local function named_tables(table)
    return setmetatable(table, {
      __index = function(self, key)
        local value = {}
        rawset(self, key, value)
        return value
      end,
    })
  end

  trek.keys = named_tables(trek.keys)
  trek.menu = named_tables(trek.menu)

  for name, constructor in pairs(nodes) do
    trek[name] = constructor
  end

  function trek.tab(name, spec)
    assert(type(name) == "string" and name ~= "", "tab name must be a non-empty string")
    assert(type(spec) == "table", "tab specification must be a table")
    if trek._tabs[name] == nil then
      trek._tab_order[#trek._tab_order + 1] = name
    end
    trek._tabs[name] = spec
  end

  local function event(list)
    return function(handler)
      assert(type(handler) == "function", "event handler must be a function")
      list[#list + 1] = handler
    end
  end

  trek.on.open = event(trek._handlers.open)
  trek.on.root = event(trek._handlers.root)

  return trek
end

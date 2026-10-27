-- Builds the table for fb.provide("pokemon.core", tbl).
local M = {}

local METHODS = { "team", "box", "box_count", "location", "battle", "encounters", "badges", "trainer", "name",
  "species_info", "areas", "locations", "zone_info", "icon", "icon_variants", "map_candidates", "map_image", "map_selected", "diagnostics",
  "encode_pokemon", "encode_money", "encode_item", "edit_limits", "names_list" }
local FEATURE = {
  team = "team", box = "box", location = "location",
  battle = "battle", encounters = "encounters", badges = "badges", trainer = "trainer", name = "names",
  areas = "areas", locations = "locations", icon = "icons", map_candidates = "map", diagnostics = "diagnostics",
  encode_pokemon = "edit_pokemon", encode_money = "edit_money", encode_item = "edit_items", names_list = "name_lists",
}

local function has(adapter, name)
  return adapter ~= nil and type(adapter[name]) == "function"
end

-- entry: games.lua entry, detected: info from games.detect, adapter: adapter object or nil
function M.new(entry, detected, adapter)
  local api = {}

  function api.info()
    local features = { live_stats = false }
    for method, key in pairs(FEATURE) do features[key] = has(adapter, method) end
    -- An adapter may refine features that depend on runtime state (icons found, address set).
    if has(adapter, "features") then
      local over = adapter:features()
      if type(over) == "table" then
        for k, v in pairs(over) do features[k] = v == true end
      end
    end
    local language = detected and detected.language or nil
    if has(adapter, "language") then language = adapter:language() or language end
    local revision
    if has(adapter, "revision") then revision = adapter:revision() end
    local icon_rev
    if has(adapter, "icon_rev") then icon_rev = adapter:icon_rev() end
    local demo = has(adapter, "demo") and adapter:demo() == true
    return {
      demo = demo,
      icon_rev = icon_rev,
      game_id = entry.id,
      name = entry.name,
      gen = entry.gen,
      system = entry.system,
      version = entry.version,
      language = language,
      revision = revision,
      supported = adapter ~= nil,
      features = features,
    }
  end

  for _, method in ipairs(METHODS) do
    api[method] = function(...)
      if not has(adapter, method) then return nil, "unsupported" end
      return adapter[method](adapter, ...)
    end
  end

  return api
end

return M

local t = require("t")
local interface = require("core.interface")

local entry = { id = "pokemon_x", name = "Pokemon X", gen = 6, system = "3ds", version = "x" }
local detected = { language = "de" }

t.case("no adapter: unsupported everywhere", function()
  local api = interface.new(entry, detected, nil)
  local info = api.info()
  t.eq(info.supported, false)
  t.eq(info.game_id, "pokemon_x")
  t.eq(info.gen, 6)
  t.eq(info.language, "de")
  t.eq(info.revision, nil)
  t.eq(info.features, { team = false, box = false, location = false, battle = false, encounters = false, badges = false, balls = false, bag = false, abilities = false,
    icons = false, map = false, names = false, areas = false, locations = false, trainer = false, live_stats = false,
    diagnostics = false, edit_pokemon = false, edit_money = false, edit_items = false, name_lists = false })
  for _, m in ipairs({ "team", "box_count", "location", "battle", "encounters", "badges", "balls", "bag", "abilities", "icon", "map_candidates", "map_image",
    "map_selected", "trainer", "name", "species_info", "areas", "locations", "zone_info", "diagnostics",
    "encode_pokemon", "encode_money", "encode_item", "edit_limits", "names_list" }) do
    local v, err = api[m]()
    t.eq(v, nil); t.eq(err, "unsupported", m)
  end
  local v, err = api.box(1)
  t.eq(v, nil); t.eq(err, "unsupported")
end)

t.case("delegation, args, features, language and revision", function()
  local calls = {}
  local adapter = {}
  function adapter:team() calls[#calls + 1] = "team"; return { { species = 1 } } end
  function adapter:box(n) calls[#calls + 1] = "box" .. n; return { n } end
  function adapter:box_count() return 31 end
  function adapter:location() return nil, "not_ready" end
  function adapter:language() return "en" end
  function adapter:revision() return "v1.0" end
  local api = interface.new(entry, detected, adapter)
  t.eq(api.team(), { { species = 1 } })
  t.eq(api.box(3), { 3 })
  t.eq(calls, { "team", "box3" })
  t.eq(api.box_count(), 31)
  local v, err = api.location()
  t.eq(v, nil); t.eq(err, "not_ready")
  v, err = api.battle()
  t.eq(v, nil); t.eq(err, "unsupported")
  local info = api.info()
  t.eq(info.supported, true)
  t.eq(info.language, "en")
  t.eq(info.revision, "v1.0")
  t.eq(info.features.team, true)
  t.eq(info.features.box, true)
  t.eq(info.features.location, true)
  t.eq(info.features.battle, false)
end)

t.case("language falls back to detection when adapter returns nil", function()
  local adapter = { language = function() return nil end }
  t.eq(interface.new(entry, detected, adapter).info().language, "de")
end)

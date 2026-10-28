-- Demo adapter: serves synthetic data through the same adapter contract as the ORAS adapter, on a scripted
-- timeline driven by ticks. Runs only when the developer setting "Demo data" is on (see main.lua), never
-- automatically. No game memory is read.
local data = require("demo.data")

local M = {}

local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = type(v) == "table" and copy(v) or v end
  return c
end

local function find_location(zone)
  for _, l in ipairs(data.LOCATIONS) do
    for _, z in ipairs(l.zones) do
      if z == zone then return l end
    end
  end
  return nil
end

-- Synthetic square icon: a colour derived from the species id, a darker frame. nil when no PNG encoder exists.
local function make_icon(uz, species)
  if type(uz.codec) ~= "table" or type(uz.codec.png) ~= "function" then return nil end
  local w, h = 32, 32
  local r, g, b = (species * 53) % 200 + 40, (species * 97) % 200 + 40, (species * 29) % 200 + 40
  local px = {}
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local edge = x < 2 or y < 2 or x >= w - 2 or y >= h - 2
      if edge then
        px[#px + 1] = string.char(r // 3, g // 3, b // 3, 255)
      else
        px[#px + 1] = string.char(r, g, b, 255)
      end
    end
  end
  local ok, png = pcall(uz.codec.png, { width = w, height = h, rgba = table.concat(px) })
  if ok and type(png) == "string" then return png end
  return nil
end

function M.attach(ctx)
  local uz = ctx.uz
  local timeline = ctx.timeline or data.TIMELINE
  local obj = {}

  -- The host calls the tick function only while a memory snapshot exists, and a snapshot exists only while some range
  -- is registered. The demo reads no memory, so it registers one byte (no data is used) to keep its timeline running.
  if type(uz.memory) == "table" and type(uz.memory.watch) == "function" then pcall(uz.memory.watch, "demo.clock", 0, 1) end

  local ticks = 0
  local next_step = 1
  local team = data.start_team()
  local box = data.start_box()
  local zone = 101
  local badges = 0
  local battle = { active = false }
  local encounters = {}
  local seq = 0
  local icons = {}

  local function loc_table()
    local l = find_location(zone)
    return { zone = zone, location = l and l.id or nil, name = l and l.name or nil, source = "memory",
      x = 10.0, y = 20.0 }
  end

  local function with_names(rec)
    local r = copy(rec)
    r.species_name = data.name("species", r.species)
    return r
  end

  local function emit_location()
    uz.events.emit("location.changed", loc_table())
  end

  local function start_battle(kind, species, level)
    local foe = { species = species, form = 0, level = level, hp = level * 4, max_hp = level * 4, shiny = false,
      personality = 0x1A2B0100 + seq + 1 }
    battle = { active = true, kind = kind, horde = false, foes = { foe }, own = {} }
    for i, m in ipairs(team) do
      battle.own[#battle.own + 1] = { personality = m.personality, species = m.species, hp = m.hp,
        max_hp = m.max_hp, slot = i }
    end
    uz.events.emit("battle.started", { kind = kind, horde = false, foes = { species } })
    if kind == "wild" then
      seq = seq + 1
      local l = find_location(zone)
      local e = { seq = seq, species = species, form = 0, level = level, shiny = false, horde = false,
        zone = zone, location = l and l.id or nil, frame = ticks }
      encounters[#encounters + 1] = e
      uz.events.emit("encounter", with_names(e))
    end
  end

  local function end_battle()
    local kind = battle.kind
    battle = { active = false }
    if kind then uz.events.emit("battle.ended", { kind = kind }) end
  end

  local handlers = {}
  function handlers.move(s) zone = s.zone; emit_location() end
  function handlers.wild_start(s) start_battle("wild", s.species, s.level) end
  function handlers.trainer_start(s) start_battle("trainer", s.species, s.level) end
  function handlers.catch()
    if #team < 6 then
      local m = data.catch_mon()
      m.slot = #team + 1
      team[#team + 1] = m
    end
    end_battle()
  end
  function handlers.faint(s)
    local m = team[s.slot]
    if m then m.hp = 0 end
  end
  function handlers.battle_end() end_battle() end
  function handlers.badge(s)
    local old = badges
    badges = math.max(badges, s.index)
    if badges ~= old then
      local new = {}
      for i = old + 1, badges do new[#new + 1] = i end
      uz.events.emit("badges.changed", { count = badges, new = new })
    end
  end

  function obj:demo() return true end
  function obj:revision() return "demo" end
  function obj:language() return "en" end
  function obj:icon_rev() return "demo-1" end

  -- Advances the scripted timeline by one tick; due steps run in order.
  function obj:tick()
    ticks = ticks + 1
    while next_step <= #timeline and timeline[next_step].at <= ticks do
      local s = timeline[next_step]
      next_step = next_step + 1
      local h = handlers[s.step]
      if h then h(s) end
    end
  end

  function obj:ticks() return ticks end

  function obj:features()
    return { icons = type(uz.codec) == "table" and type(uz.codec.png) == "function", names = true, areas = true,
      locations = true, live_stats = true, location = true, battle = true, encounters = true }
  end

  function obj:team()
    local out = {}
    for i, m in ipairs(team) do
      local r = with_names(m)
      r.slot = i
      out[#out + 1] = r
    end
    return out
  end

  function obj:box_count() return 31 end

  function obj:box(n)
    if math.type(n) ~= "integer" or n < 1 or n > 31 then return nil, "invalid_box" end
    local out = {}
    if n == 1 then
      for i, m in ipairs(box) do
        local r = with_names(m)
        r.box, r.slot = 1, i
        out[#out + 1] = r
      end
    end
    return out
  end

  function obj:location() return loc_table() end

  function obj:battle()
    if not battle.active then return { active = false } end
    local b = copy(battle)
    for _, f in ipairs(b.foes) do f.species_name = data.name("species", f.species) end
    b.own = {}
    for i, m in ipairs(team) do
      b.own[#b.own + 1] = { personality = m.personality, species = m.species, hp = m.hp, max_hp = m.max_hp,
        slot = i, species_name = data.name("species", m.species) }
    end
    return b
  end

  function obj:encounters()
    local out = {}
    for _, e in ipairs(encounters) do out[#out + 1] = with_names(e) end
    return out
  end

  function obj:badges()
    local flags = {}
    for i = 1, 8 do flags[i] = i <= badges end
    return { count = badges, flags = flags }
  end

  function obj:trainer()
    return { name = "DEMO", tid = 4242, sid = 2424, version = "demo", language = "en", money = 3000,
      badges = badges, play_time = { h = 0, m = ticks // (60 * data.TICKS_PER_SECOND) % 60,
        s = ticks // data.TICKS_PER_SECOND % 60 } }
  end

  function obj:name(kind, id) return data.name(kind, id) end

  function obj:species_info(species, form)
    if math.type(species) ~= "integer" or species < 1 then return nil, "unknown_species" end
    if form and form ~= 0 then return nil, "no_form" end
    local t1 = species % 4 + 1
    return { types = { t1, t1 }, growth = 0 }
  end

  function obj:areas()
    local out = {}
    for _, l in ipairs(data.LOCATIONS) do
      if l.encounters then
        out[#out + 1] = { id = l.id, name = l.name, zones = copy(l.zones), encounters = copy(l.encounters) }
      end
    end
    return out
  end

  function obj:locations()
    local out = {}
    for _, l in ipairs(data.LOCATIONS) do
      out[#out + 1] = { id = l.id, name = l.name, zones = copy(l.zones), has_encounters = l.encounters ~= nil,
        source = "zones" }
    end
    return out
  end

  function obj:zone_info(z)
    local l = find_location(z)
    if not l then return nil, "unknown_zone" end
    return { zone = z, location = l.id, name = l.name }
  end

  function obj:icon(species, form)
    if math.type(species) ~= "integer" or species < 1 then return nil, "unknown_species" end
    local key = species
    if icons[key] == nil then icons[key] = make_icon(uz, species) or false end
    if not icons[key] then return nil, "unsupported" end
    return icons[key]
  end

  function obj:diagnostics()
    return { demo = 1, ticks = ticks, step = next_step - 1, zone = zone, team = #team, badges = badges }
  end

  return obj
end

return M

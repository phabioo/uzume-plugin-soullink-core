-- Synthetic demo data for the demo adapter. Everything here is invented: no real species, location or
-- move names, and no ids are looked up in a game. Names are marked "Demo" so they can never be mistaken
-- for game text.
local M = {}

M.TICKS_PER_SECOND = 30

-- Name kinds that the interface knows (`name(kind, id)`).
M.KINDS = { species = "Demomon", move = "Demo Move", item = "Demo Item", ability = "Demo Ability",
  nature = "Demo Nature", type = "Demo Type", form = "Demo Form" }

-- Locations: id -> name, zone -> location. Two routes have encounter areas.
M.LOCATIONS = {
  { id = 1001, name = "Demo Town", zones = { 101 }, encounters = nil },
  { id = 1002, name = "Demo Route 1", zones = { 102 },
    encounters = { grass = { { species = 21, form = 0, min = 2, max = 4 }, { species = 22, form = 0, min = 2, max = 4 } } } },
  { id = 1003, name = "Demo Route 2", zones = { 103 },
    encounters = { grass = { { species = 23, form = 0, min = 4, max = 6 }, { species = 24, form = 0, min = 4, max = 6 } } } },
}

local function mon(personality, species, nick, level, hp, moves)
  return {
    species = species, form = 0, nickname = nick, level = level, exp = level * level * level,
    personality = personality, shiny = false, gender = personality % 2, nature = personality % 25,
    ability = 1 + personality % 3, held_item = 0, moves = moves, ot_name = "DEMO", ot_id = 4242, ot_sid = 2424,
    language = "en", egg = false, hp = hp, max_hp = hp, status = 0,
  }
end
M.mon = mon

-- Starting team (3 creatures) and one box creature.
function M.start_team()
  return {
    mon(0x1A2B0001, 11, "Sprout", 5, 22, { 1, 2 }),
    mon(0x1A2B0002, 12, "Ember", 5, 20, { 1, 3 }),
    mon(0x1A2B0003, 13, "Drip", 5, 24, { 1, 4 }),
  }
end

function M.start_box()
  return { mon(0x1A2B0010, 14, "Boxer", 4, 18, { 1 }) }
end

-- The creature that is caught in the scripted timeline.
function M.catch_mon()
  return mon(0x1A2B0021, 21, nil, 3, 14, { 1 })
end

-- Scripted timeline: tick counts at 30 ticks per second; `do_` names the step handled by the adapter.
local S = M.TICKS_PER_SECOND
M.TIMELINE = {
  { at = 10 * S, step = "move", zone = 102 },       -- Demo Town -> Demo Route 1
  { at = 15 * S, step = "wild_start", species = 21, level = 3 },
  { at = 20 * S, step = "catch" },                  -- the wild creature joins the team, battle ends
  { at = 30 * S, step = "move", zone = 103 },       -- -> Demo Route 2
  { at = 40 * S, step = "trainer_start", species = 23, level = 6 },
  { at = 45 * S, step = "faint", slot = 4 },        -- team member 4 (the caught creature) faints
  { at = 50 * S, step = "battle_end" },
  { at = 60 * S, step = "badge", index = 1 },       -- first badge
}

function M.name(kind, id)
  if math.type(id) ~= "integer" then return nil end
  if kind == "location" then
    for _, l in ipairs(M.LOCATIONS) do
      if l.id == id then return l.name end
    end
    return nil
  end
  local base = M.KINDS[kind]
  if not base then return nil end
  return base .. " " .. id
end

return M

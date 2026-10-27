local t = require("t")
local fb_mock = require("fb_mock")
local demo = require("demo.adapter")
local data = require("demo.data")

local S = data.TICKS_PER_SECOND

local function png_codec()
  return { png = function(img) return "PNG:" .. img.width .. "x" .. img.height .. ":" .. #img.rgba end }
end

local function new_demo(opts)
  local mock = fb_mock.new(opts or { game = { system = "3ds", code = "000400000011C400" } })
  mock.fb.codec = png_codec()
  local a = demo.attach({ fb = mock.fb, game = {}, detected = {} })
  return mock, a
end
local function run(a, ticks) for _ = 1, ticks do a:tick() end end
local function names(mock)
  local out = {}
  for _, e in ipairs(mock.events) do out[#out + 1] = e.name end
  return out
end

t.case("demo registers one watch so the host keeps ticking (ticks need a memory snapshot)", function()
  local mock = new_demo()
  t.eq(mock.watches["demo.clock"], { addr = 0, len = 1 })
end)

t.case("demo start state: 3 synthetic creatures, a box, a town, no badge", function()
  local _, a = new_demo()
  local team = a:team()
  t.eq(#team, 3)
  t.eq(team[1].slot, 1)
  t.eq(team[1].species_name, "Demomon 11")
  t.ok(team[1].hp > 0 and team[1].hp == team[1].max_hp)
  t.eq(a:box_count(), 31)
  t.eq(#a:box(1), 1)
  t.eq(a:box(1)[1].box, 1)
  t.eq(#a:box(2), 0)
  t.eq(a:location().name, "Demo Town")
  t.eq(a:badges().count, 0)
  t.eq(a:battle(), { active = false })
  t.eq(a:encounters(), {})
  t.eq(a:demo(), true)
end)

t.case("demo timeline: zones, wild encounter, catch, faint, badge", function()
  local mock, a = new_demo()
  run(a, 10 * S)
  t.eq(a:location().name, "Demo Route 1")
  t.eq(a:location().location, 1002)
  run(a, 5 * S)
  local b = a:battle()
  t.eq(b.active, true); t.eq(b.kind, "wild"); t.eq(b.foes[1].species, 21)
  t.eq(#a:encounters(), 1)
  t.eq(a:encounters()[1].seq, 1)
  t.eq(a:encounters()[1].location, 1002)
  run(a, 5 * S)
  t.eq(a:battle().active, false)
  t.eq(#a:team(), 4)
  t.eq(a:team()[4].species, 21)
  run(a, 10 * S)
  t.eq(a:location().name, "Demo Route 2")
  run(a, 10 * S)
  t.eq(a:battle().kind, "trainer")
  t.eq(#a:encounters(), 1)
  run(a, 5 * S)
  t.eq(a:team()[4].hp, 0)  -- the creature caught in this run faints, so SoulLink has a death to record
  t.eq(a:team()[1].hp > 0, true)
  run(a, 5 * S)
  t.eq(a:battle().active, false)
  t.eq(a:badges().count, 0)
  run(a, 10 * S)
  t.eq(a:badges().count, 1)
  t.eq(a:badges().flags[1], true)
  t.eq(a:badges().flags[2], false)
  t.eq(a:trainer().badges, 1)
  t.eq(names(mock), { "location.changed", "battle.started", "encounter", "battle.ended", "location.changed",
    "battle.started", "battle.ended", "badges.changed" })
  local bev
  for _, e in ipairs(mock.events) do if e.name == "badges.changed" then bev = e.value end end
  t.eq(bev, { count = 1, new = { 1 } })
  run(a, 100 * S)
  t.eq(a:badges().count, 1)
  t.eq(#a:team(), 4)
end)

t.case("demo names are synthetic and marked", function()
  local _, a = new_demo()
  t.eq(a:name("species", 25), "Demomon 25")
  t.eq(a:name("location", 1002), "Demo Route 1")
  t.eq(a:name("location", 9), nil)
  t.eq(a:name("bogus", 1), nil)
  for _, l in ipairs(a:locations()) do t.ok(l.name:find("^Demo ")) end
  for _, ar in ipairs(a:areas()) do t.ok(ar.name:find("^Demo ")); t.ok(ar.encounters.grass) end
  t.eq(#a:areas(), 2)
  t.eq(a:zone_info(102).name, "Demo Route 1")
  local v, err = a:zone_info(5)
  t.eq(v, nil); t.eq(err, "unknown_zone")
end)

t.case("demo icons: synthetic PNG, nothing without an encoder", function()
  local mock, a = new_demo()
  t.ok(a:icon(21, 0):find("^PNG:32x32:"))
  t.eq(a:features().icons, true)
  mock.fb.codec = {}
  local _, b = new_demo()
  b = demo.attach({ fb = mock.fb, game = {}, detected = {} })
  local v, err = b:icon(21, 0)
  t.eq(v, nil); t.eq(err, "unsupported")
  t.eq(b:features().icons, false)
end)

-- Entry module: the developer setting decides, never the plugin.
local function run_main(store)
  local mock = fb_mock.new({ game = { system = "3ds", code = "000400000011C400" } })
  mock.fb.codec = png_codec()
  if store then
    mock.fb.store = { get = function(key) return store[key], store[key] ~= nil and 1 or 0 end }
  end
  _G.fb = mock.fb
  local ok, err = pcall(dofile, "src/main.lua")
  assert(ok, err)
  return mock
end

t.case("main: demo only with the setting on", function()
  local off = run_main(nil)
  t.eq(off.provided["pokemon.core"].info().demo, false)
  local off2 = run_main({ ["dev.demo_data"] = false })
  t.eq(off2.provided["pokemon.core"].info().demo, false)
  local on = run_main({ ["dev.demo_data"] = true })
  local info = on.provided["pokemon.core"].info()
  t.eq(info.demo, true)
  t.eq(info.supported, true)
  t.eq(info.revision, "demo")
  t.eq(info.game_id, "pokemon_omega_ruby")
  local detected
  for _, e in ipairs(on.events) do if e.name == "game.detected" then detected = e.value end end
  t.eq(detected.demo, true)
  on.tick(10 * S)
  t.eq(on.provided["pokemon.core"].location().name, "Demo Route 1")
  _G.fb = nil
end)

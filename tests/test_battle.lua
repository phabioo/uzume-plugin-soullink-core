local t = require("t")
local uz_mock = require("uz_mock")
local crypto = require("pk6_crypto")
local build = require("pk6_build")
local mem = require("oras_mem")
local addr = require("gen6.oras_addr")
local oras = require("gen6.oras")
local oras_battle = require("gen6.oras_battle")

local V10, V14 = mem.rev("v1.0").addr, mem.rev("v1.4").addr
local ZERO_FOES = string.rep("\0", 6 * 0x1E4)
local ZERO_MONS = mem.mons_blob({})

local OWN = { species = 25, ec = 0x01010101, pid = 0x11111111, exp = 100, party = { level = 30, hp = 40, max_hp = 80 } }

local function foe(species, ec, level, hp)
  return { species = species, ec = ec, pid = ec * 3 & 0xFFFFFFFF, exp = 10,
    party = { level = level or 7, hp = hp or 20, max_hp = hp or 20 } }
end

local function slots(list)
  return mem.foes_blob(list)
end

local function setup(rev, flag)
  local rv = mem.rev(rev).addr
  local m = mem.world({ rev = rev, party = { OWN }, trainer = { tid = 1, name = "Me" }, zone = 5, x = 10.0, y = 20.0, flag = flag })
  m[#m + 1] = { addr = rv.battle_wild_foes, data = ZERO_FOES }
  if rv.battle_trainer_foes then m[#m + 1] = { addr = rv.battle_trainer_foes, data = ZERO_FOES } end
  if rv.battle_wild_mons then
    m[#m + 1] = { addr = rv.battle_wild_mons, data = ZERO_MONS }
    m[#m + 1] = { addr = rv.battle_trainer_mons, data = ZERO_MONS }
  end
  local mock = uz_mock.new({ game = { system = "3ds" }, memory = m, codec = { pk6_decrypt = crypto.decrypt },
    i18n_dir = "plugin/i18n", frame = 77 })
  local a = oras.attach({ uz = mock.uz, game = {}, detected = {} })
  a:revision()
  return a, mock, rv
end

local function ticks(a, n) for _ = 1, n or 1 do a:tick() end end

local function events(mock, name)
  local out = {}
  for _, e in ipairs(mock.events) do if e.name == name then out[#out + 1] = e.value end end
  return out
end

local function wild_foe_slots(rv, mock, list) mem.poke(mock.regions, rv.battle_wild_foes, slots(list)) end

t.case("quiet memory: no battle, no encounters", function()
  local a, mock = setup("v1.0")
  ticks(a, 6)
  t.eq(a:battle(), { active = false })
  t.eq(a:encounters(), {})
  t.eq(#events(mock, "battle.started"), 0)
  t.eq(a:features().battle, true); t.eq(a:features().encounters, true)
end)

t.case("wild battle: start needs the buffer change AND the battle-mon array; HP of both sides; end on movement", function()
  local a, mock, rv = setup("v1.0")
  ticks(a, 3) -- baseline
  wild_foe_slots(rv, mock, { foe(19, 0x0A0A0A0A, 7, 20) })
  ticks(a, 3)
  t.eq(a:battle().active, false, "array not filled yet")
  mem.poke(mock.regions, rv.battle_wild_mons, mem.mons_blob({
    { species = 25, max_hp = 80, hp = 40, level = 30 }, { species = 19, max_hp = 20, hp = 20, level = 7 } }))
  ticks(a, 1)
  local b = a:battle()
  t.eq(b.active, true); t.eq(b.kind, "wild"); t.eq(b.horde, false)
  t.eq(#b.foes, 1)
  t.eq({ b.foes[1].species, b.foes[1].level, b.foes[1].hp, b.foes[1].max_hp, b.foes[1].shiny, b.foes[1].personality },
    { 19, 7, 20, 20, false, 0x0A0A0A0A * 3 & 0xFFFFFFFF })
  t.eq(#b.own, 1)
  t.eq({ b.own[1].personality, b.own[1].species, b.own[1].hp, b.own[1].max_hp }, { 0x11111111, 25, 40, 80 })
  local started = events(mock, "battle.started")
  t.eq(started, { { kind = "wild", horde = false, foes = { 19 } } })
  local enc = a:encounters()
  t.eq(#enc, 1)
  t.eq(enc[1], { seq = 1, species = 19, form = 0, level = 7, shiny = false, horde = false, zone = 5, frame = 77 })
  t.eq(events(mock, "encounter")[1].seq, 1)
  -- our Pokemon faints in battle: visible in own
  mem.poke(mock.regions, rv.battle_wild_mons + 0x10, string.pack("<I2", 0))
  t.eq(a:battle().own[1].hp, 0)
  ticks(a, 20)
  t.eq(a:battle().active, true, "stays active while nothing moves")
  t.eq(#events(mock, "battle.ended"), 0)
  -- the player walks again
  mem.poke(mock.regions, rv.player_x, string.pack("<f", 11.0))
  ticks(a, 1)
  t.eq(a:battle(), { active = false })
  t.eq(events(mock, "battle.ended"), { { kind = "wild" } })
  -- stale buffers do not start another battle
  ticks(a, 30)
  t.eq(#events(mock, "battle.started"), 1)
  t.eq(#a:encounters(), 1)
end)

t.case("a second wild battle gets the next seq; the zone change ends a battle", function()
  local a, mock, rv = setup("v1.0")
  ticks(a, 2)
  for i, spec in ipairs({ 19, 21 }) do
    wild_foe_slots(rv, mock, { foe(spec, 0x0B0B0B00 + i, 8, 22) })
    mem.poke(mock.regions, rv.battle_wild_mons, mem.mons_blob({
      { species = 25, max_hp = 80, hp = 40, level = 30 }, { species = spec, max_hp = 22, hp = 22, level = 8 } }))
    ticks(a, 2)
    t.eq(a:battle().active, true)
    mem.poke(mock.regions, rv.map_id, string.pack("<I2", 5 + i))
    ticks(a, 1)
    t.eq(a:battle().active, false)
  end
  local enc = a:encounters()
  t.eq({ #enc, enc[1].seq, enc[2].seq, enc[1].species, enc[2].species, enc[2].zone }, { 2, 1, 2, 19, 21, 6 })
  t.eq(#events(mock, "battle.ended"), 2)
end)

t.case("horde: foe slots 2..5 valid; ends when the battle-mon array is cleared", function()
  local a, mock, rv = setup("v1.0")
  ticks(a, 2)
  local list, mons = {}, { { species = 25, max_hp = 80, hp = 40, level = 30 } }
  for i = 1, 5 do
    list[i] = foe(19, 0x0C0C0C00 + i, 6, 18)
    mons[#mons + 1] = { species = 19, max_hp = 18, hp = 18, level = 6 }
  end
  wild_foe_slots(rv, mock, list)
  mem.poke(mock.regions, rv.battle_wild_mons, mem.mons_blob(mons))
  ticks(a, 2)
  local b = a:battle()
  t.eq({ b.active, b.horde, #b.foes }, { true, true, 5 })
  local enc = a:encounters()
  t.eq({ enc[1].horde, enc[1].species }, { true, 19 })
  t.eq(events(mock, "battle.started")[1], { kind = "wild", horde = true, foes = { 19, 19, 19, 19, 19 } })
  mem.poke(mock.regions, rv.battle_wild_mons, ZERO_MONS)
  ticks(a, 2)
  t.eq(a:battle().active, true, "debounced")
  ticks(a, 2)
  t.eq(a:battle().active, false)
  t.eq(events(mock, "battle.ended"), { { kind = "wild" } })
end)

t.case("stale slots of an older horde do not make a single wild battle a horde", function()
  local a, mock, rv = setup("v1.0")
  local old = {}
  for i = 1, 5 do old[i] = foe(19, 0x0D0D0D00 + i, 6, 18) end
  wild_foe_slots(rv, mock, old)
  ticks(a, 2) -- baseline contains the old horde
  old[1] = foe(129, 0x0D0D0DFF, 9, 30) -- a new single encounter only replaces slot 1
  wild_foe_slots(rv, mock, old)
  mem.poke(mock.regions, rv.battle_wild_mons, mem.mons_blob({
    { species = 25, max_hp = 80, hp = 40, level = 30 }, { species = 129, max_hp = 30, hp = 30, level = 9 } }))
  ticks(a, 2)
  local b = a:battle()
  t.eq({ b.active, b.horde, #b.foes, b.foes[1].species }, { true, false, 1, 129 })
end)

t.case("trainer battle: other buffer, only active foes, no encounter", function()
  local a, mock, rv = setup("v1.0")
  ticks(a, 2)
  local list = { foe(10, 0x0E0E0E01, 12, 30), foe(11, 0x0E0E0E02, 13, 33), foe(12, 0x0E0E0E03, 14, 36) }
  mem.poke(mock.regions, rv.battle_trainer_foes, slots(list))
  mem.poke(mock.regions, rv.battle_trainer_mons, mem.mons_blob({
    { species = 25, max_hp = 80, hp = 40, level = 30 }, { species = 10, max_hp = 30, hp = 30, level = 12 } }))
  ticks(a, 2)
  local b = a:battle()
  t.eq({ b.active, b.kind, b.horde, #b.foes, b.foes[1].species, #b.own }, { true, "trainer", false, 1, 10, 1 })
  t.eq(a:encounters(), {})
  t.eq(events(mock, "battle.started"), { { kind = "trainer", horde = false, foes = { 10 } } })
  mem.poke(mock.regions, rv.player_y, string.pack("<f", 25.0))
  ticks(a, 1)
  t.eq(events(mock, "battle.ended"), { { kind = "trainer" } })
end)

t.case("a changed buffer without a matching array times out; invalid data is ignored", function()
  local a, mock, rv = setup("v1.0")
  ticks(a, 2)
  wild_foe_slots(rv, mock, { foe(19, 0x0F0F0F0F, 7, 20) })
  mem.poke(mock.regions, rv.battle_wild_mons, mem.mons_blob({ { species = 99, max_hp = 5, hp = 5, level = 5 } }))
  ticks(a, oras_battle.PENDING_POLLS + 5)
  t.eq(a:battle().active, false)
  -- now the array fits, but the pending request is gone until the buffer changes again
  mem.poke(mock.regions, rv.battle_wild_mons, mem.mons_blob({ { species = 19, max_hp = 20, hp = 20, level = 7 } }))
  ticks(a, 3)
  t.eq(a:battle().active, false)
  -- corrupted checksum: never pending
  local bad = build.ram_slot(foe(19, 0x01020304))
  bad = bad:sub(1, 40) .. string.char(bad:byte(41) ~ 0xFF) .. bad:sub(42)
  mem.poke(mock.regions, rv.battle_wild_foes, bad)
  ticks(a, 3)
  t.eq(a:battle().active, false)
  t.eq(#events(mock, "battle.started"), 0)
end)

t.case("v1.4: the in-battle flag confirms the start and ends the battle; no array needed", function()
  local a, mock, rv = setup("v1.4", 0)
  t.eq(rv.battle_trainer_foes, nil)
  ticks(a, 2)
  local list = {}
  for i = 1, 5 do list[i] = foe(19, 0x20000 + i, 6, 18) end
  mem.poke(mock.regions, rv.battle_wild_foes, slots(list))
  ticks(a, 3)
  t.eq(a:battle().active, false, "flag not raised yet")
  mem.poke(mock.regions, rv.battle_flag, string.pack("<I4", addr.FLAG_BATTLE))
  ticks(a, 1)
  local b = a:battle()
  t.eq({ b.active, b.kind, b.horde, #b.foes }, { true, "wild", true, 5 })
  t.eq(b.own, {})
  mem.poke(mock.regions, rv.battle_flag, string.pack("<I4", 0))
  ticks(a, 1)
  t.eq(a:battle().active, false)
  t.eq(#events(mock, "battle.ended"), 1)
end)

t.case("battle addresses can be overridden", function()
  local m = mem.world({ party = { OWN }, zone = 5, x = 1.0, y = 2.0 })
  m[#m + 1] = { addr = 0x08700000, data = ZERO_FOES }
  m[#m + 1] = { addr = 0x08710000, data = ZERO_MONS }
  local mock = uz_mock.new({ memory = m, codec = { pk6_decrypt = crypto.decrypt }, i18n_dir = "plugin/i18n",
    cache = { ["config/addresses.txt"] = "v1.0.battle_wild_foes=0x08700000\nv1.0.battle_wild_mons=0x08710000\n" } })
  local a = oras.attach({ uz = mock.uz })
  a:revision()
  t.eq(mock.watches["oras.v1.0.battle_wild_foes"].addr, 0x08700000)
  ticks(a, 2)
  mem.poke(mock.regions, 0x08700000, slots({ foe(19, 0x31313131, 7, 20) }))
  mem.poke(mock.regions, 0x08710000, mem.mons_blob({ { species = 19, max_hp = 20, hp = 20, level = 7 } }))
  ticks(a, 2)
  t.eq(a:battle().active, true)
end)

t.case("battle() and encounters() before detection and without addresses", function()
  local a = oras.attach({ uz = uz_mock.new({ codec = { pk6_decrypt = crypto.decrypt }, i18n_dir = "plugin/i18n" }).uz })
  t.eq({ a:battle() }, { nil, "not_ready" })
  t.eq({ a:encounters() }, { nil, "not_ready" })
  ticks(a, 10) -- tracking must not raise without memory
end)

t.case("encounters keep the last 64 entries", function()
  local a, mock, rv = setup("v1.0")
  ticks(a, 2)
  for i = 1, 70 do
    wild_foe_slots(rv, mock, { foe(19, 0x40000000 + i, 7, 20) })
    mem.poke(mock.regions, rv.battle_wild_mons, mem.mons_blob({ { species = 19, max_hp = 20, hp = 20, level = 7 } }))
    ticks(a, 2)
    mem.poke(mock.regions, rv.player_x, string.pack("<f", 10.0 + i)) -- the battle ends by movement
    ticks(a, 1)
    mem.poke(mock.regions, rv.battle_wild_mons, ZERO_MONS)
  end
  local enc = a:encounters()
  t.eq({ #enc, enc[1].seq, enc[64].seq }, { 64, 7, 70 })
end)

t.case("v0.3.1: the encounter record and event carry the species name once the text is loaded", function()
  local tb = require("text_build")
  local formats = require("formats")
  local rv = mem.rev("v1.0").addr
  local m = mem.world({ rev = "v1.0", party = { OWN }, trainer = { tid = 1, name = "Me" }, zone = 5, x = 1.0, y = 2.0 })
  m[#m + 1] = { addr = rv.battle_wild_foes, data = ZERO_FOES }
  m[#m + 1] = { addr = rv.battle_trainer_foes, data = ZERO_FOES }
  m[#m + 1] = { addr = rv.battle_wild_mons, data = ZERO_MONS }
  m[#m + 1] = { addr = rv.battle_trainer_mons, data = ZERO_MONS }
  local names = {}
  for i = 0, 29 do names[#names + 1] = "Sp" .. i end
  local gt = tb.garc({ [98] = tb.build(names), [14] = tb.build({ "a", "b" }) })
  local c = formats.fake_codec(); c.pk6_decrypt = crypto.decrypt
  local mock = uz_mock.new({ game = { system = "3ds" }, memory = m, codec = c, i18n_dir = "plugin/i18n", frame = 77,
    romfs = { ["/a/0/7/3"] = gt } })
  local a = oras.attach({ uz = mock.uz, game = {}, detected = {} })
  ticks(a, 200)
  t.eq(a:name("species", 19), "Sp19")
  wild_foe_slots(rv, mock, { foe(19, 0x0A0A0A0A, 7, 20) })
  mem.poke(mock.regions, rv.battle_wild_mons, mem.mons_blob({
    { species = 25, max_hp = 80, hp = 40, level = 30 }, { species = 19, max_hp = 20, hp = 20, level = 7 } }))
  ticks(a, 4)
  t.eq(events(mock, "encounter")[1].species_name, "Sp19")
  t.eq(a:encounters()[1].species_name, "Sp19")
  t.eq(a:battle().foes[1].species_name, "Sp19")
end)

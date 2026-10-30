local t = require("t")
local uz_mock = require("uz_mock")
local crypto = require("pk6_crypto")
local build = require("pk6_build")
local oras = require("gen6.oras")

local mem = require("oras_mem")
local addr = require("gen6.oras_addr")

local V10, V14 = mem.rev("v1.0").addr, mem.rev("v1.4").addr
-- party + box in a revision (used by the older tests, same shape as before)
local REV2 = { rev = "v1.0", party = V10.party, box = V10.box }
local REV01 = { rev = "v1.4", party = V14.party, box = V14.box }

local function codec()
  return { pk6_decrypt = crypto.decrypt }
end

local function make(set, slots, boxes, extra)
  local memory = {}
  if set then memory = mem.world({ rev = set.rev, party = slots or {}, boxes = boxes or {} }) end
  local opts = { game = { system = "3ds", code = "000400000011C400" }, memory = memory, codec = codec(),
    i18n_dir = "plugin/i18n" }
  for k, v in pairs(extra or {}) do opts[k] = v end
  local mock = uz_mock.new(opts)
  local a = oras.attach({ uz = mock.uz, game = {}, detected = {} })
  return a, mock
end

t.case("watches both revision tables, the other one is released after detection", function()
  local a, mock = make(REV2, { { species = 255, exp = 5 } })
  t.eq(mock.watches["oras.v1.0.party"], { addr = V10.party, len = 6 * 0x1E4 })
  t.eq(mock.watches["oras.v1.4.box"], { addr = V14.box, len = 31 * 30 * 232 })
  t.eq(mock.watches["oras.v1.0.mystatus"].addr, V10.mystatus)
  local total = 0
  for _, w in pairs(mock.watches) do t.ok(w.len <= 4 * 1024 * 1024); total = total + w.len end
  t.ok(total <= 16 * 1024 * 1024)
  t.eq(a:revision(), "v1.0")
  t.eq(mock.watches["oras.v1.4.party"], nil)
  t.ok(mock.watches["oras.v1.0.party"] ~= nil)
end)

t.case("v1.0 chosen", function()
  local a = make(REV2, { { species = 255, exp = 5, nickname = "Colonel" } })
  t.eq(a:revision(), "v1.0")
  local team = a:team()
  t.eq(#team, 1)
  t.eq(team[1].species, 255); t.eq(team[1].slot, 1); t.eq(team[1].nickname, "Colonel")
  t.eq(team[1].level, nil)
end)

t.case("v1.4 chosen", function()
  local a = make(REV01, { { species = 7, exp = 5 } })
  t.eq(a:revision(), "v1.4")
  t.eq(a:team()[1].species, 7)
  t.eq(a:box_count(), 31)
end)

t.case("nothing valid -> not_ready", function()
  local a = make(nil)
  t.eq({ a:revision() }, { nil, "not_ready" })
  t.eq({ a:team() }, { nil, "not_ready" })
  t.eq({ a:box(1) }, { nil, "not_ready" })
  t.eq({ a:box_count() }, { nil, "not_ready" })
  -- invalid checksum / species 0 / species out of range in slot 1
  local bad = build.build({ species = 255 })
  local enc = crypto.encrypt(bad)
  enc = enc:sub(1, 30) .. string.char(enc:byte(31) ~ 0xFF) .. enc:sub(32)
  local mock = uz_mock.new({ memory = { { addr = REV2.party, data = enc .. string.rep("\0", 1000) } },
    codec = codec(), i18n_dir = "plugin/i18n" })
  t.eq({ oras.attach({ uz = mock.uz }):revision() }, { nil, "not_ready" })
  local a2 = make(REV2, { { species = 800 } })
  t.eq({ a2:revision() }, { nil, "not_ready" })
  t.eq(a:language(), nil)
end)

t.case("party with gaps", function()
  local a = make(REV2, {
    { species = 1, exp = 1 }, nil, { species = 4, exp = 2 }, nil, nil, { species = 7, exp = 3 },
  })
  local team = a:team()
  t.eq(#team, 3)
  t.eq({ team[1].slot, team[2].slot, team[3].slot }, { 1, 3, 6 })
  t.eq(team[3].species, 7)
end)

t.case("box 1 and box 31", function()
  local a = make(REV2, { { species = 1 } }, {
    [1] = { [1] = { species = 265 }, [30] = { species = 10 } },
    [31] = { [2] = { species = 721 } },
  })
  local b1 = a:box(1)
  t.eq(#b1, 2)
  t.eq({ b1[1].species, b1[1].slot, b1[1].box }, { 265, 1, 1 })
  t.eq({ b1[2].species, b1[2].slot }, { 10, 30 })
  local b31 = a:box(31)
  t.eq(#b31, 1)
  t.eq({ b31[1].species, b31[1].slot, b31[1].box }, { 721, 2, 31 })
  t.eq(#a:box(2), 0)
  t.eq({ a:box(0) }, { nil, "out_of_range" })
  t.eq({ a:box(32) }, { nil, "out_of_range" })
end)

-- synthetic personal GARC: growth rate of species s = s % 6; entry size 0x50, byte 0x15
local function personal_stubs(layout, romfs_valid)
  local entries = {}
  for s = 0, 721 do
    local e = {}
    for i = 1, 0x50 do e[i] = "\0" end
    e[0x15 + 1] = string.char(s % 6)
    entries[s] = table.concat(e)
  end
  local whole = {}
  for s = 0, 721 do whole[#whole + 1] = entries[s] end
  whole = table.concat(whole)
  -- data strings are markers: "valid" parses as a table, anything else as garbage
  return {
    pk6_decrypt = crypto.decrypt,
    garc = function(d)
      if d ~= "valid" then return { count = 3, data_offset = 0, files = {} } end
      return { count = layout == "single" and 1 or 722, data_offset = 0, files = {} }
    end,
    garc_file = function(d, i, sub)
      if d ~= "valid" then return string.rep("\9", 5) end
      if layout == "single" then return whole end
      return entries[i - 1]
    end,
  }
end

local function level_case(name, layout, romfs, expect_path)
  t.case(name, function()
    local g = require("gen6.growth")
    -- species 255: 255 % 6 = 3 medium slow; species 12: rate 0
    local a, mock = make(REV2, { { species = 255, exp = g.exp_for_level(3, 8) + 1 }, { species = 12, exp = 1000 } }, nil, {
      codec = personal_stubs(layout), romfs = romfs,
    })
    local team = a:team()
    t.eq(team[1].level, expect_path and 8 or nil)
    t.eq(team[2].level, expect_path and 10 or nil)
    local logged = 0
    for _, l in ipairs(mock.logs) do
      if l.level == "info" and l.text:find(expect_path or "\0", 1, true) then logged = logged + 1 end
    end
    t.eq(logged, expect_path and 1 or 0)
  end)
end

for _, layout in ipairs({ "single", "per_entry" }) do
  level_case("personal valid at 1/9/6 only (" .. layout .. ")", layout, { ["/a/1/9/6"] = "valid" }, "/a/1/9/6")
  level_case("personal valid at 1/9/5 only (" .. layout .. ")", layout, { ["/a/1/9/5"] = "valid" }, "/a/1/9/5")
  level_case("garbage at 1/9/5, valid at 1/9/6 (" .. layout .. ")", layout,
    { ["/a/1/9/5"] = "junk", ["/a/1/9/6"] = "valid" }, "/a/1/9/6")
  level_case("nothing valid (" .. layout .. ")", layout, { ["/a/1/9/5"] = "junk", ["/a/1/9/6"] = "junk" }, nil)
end

t.case("level nil without romfs files or without garc codec", function()
  local a = make(REV2, { { species = 255, exp = 100 } }, nil, { codec = personal_stubs("single") })
  t.eq(a:team()[1].level, nil)
  local b = make(REV2, { { species = 255, exp = 100 } }, nil, { romfs = { ["/a/1/9/6"] = "valid" } })
  t.eq(b:team()[1].level, nil)
end)

t.case("growth byte out of range rejects the table", function()
  local c = personal_stubs("single")
  local good = c.garc_file("valid", 1, 1)
  local bad = good:sub(1, 5 * 0x50 + 0x15) .. "\7" .. good:sub(5 * 0x50 + 0x17)
  c.garc_file = function() return bad end
  local a = make(REV2, { { species = 255, exp = 100 } }, nil, { codec = c, romfs = { ["/a/1/9/6"] = "valid" } })
  t.eq(a:team()[1].level, nil)
end)

t.case("language heuristic", function()
  local own = { tid = 11, sid = 22, origin_game = 27, language_id = 5 } -- de
  local a = make(REV2, { own, { species = 4, tid = 11, sid = 22, origin_game = 27, language_id = 5 } })
  t.eq(a:language(), "de")
  -- traded-in en Pokemon in slot 1 is outvoted by two own de catches
  local b = make(REV2, {
    { tid = 99, sid = 98, origin_game = 26, language_id = 2 },
    { species = 4, tid = 11, sid = 22, origin_game = 27, language_id = 5 },
    { species = 7, tid = 11, sid = 22, origin_game = 27, language_id = 5 },
  })
  t.eq(b:language(), "de")
  -- only foreign-origin Pokemon (e.g. XY, default origin 0x2C) -> nil
  local c = make(REV2, { { origin_game = 24, language_id = 5 }, { species = 4, origin_game = 44, language_id = 2 } })
  t.eq(c:language(), nil)
  t.eq(make(nil):language(), nil)
end)

-- ---------------------------------------------------------------------------------------------
-- live party stats, trainer, badges, overrides, location, names (v0.3)

local tb = require("text_build")
local formats = require("formats")

local function world_make(o, extra)
  local opts = { game = { system = "3ds", code = "000400000011C400" }, memory = mem.world(o), codec = codec(),
    i18n_dir = "plugin/i18n" }
  for k, v in pairs(extra or {}) do opts[k] = v end
  local mock = uz_mock.new(opts)
  local a = oras.attach({ uz = mock.uz, game = { id = "pokemon_omega_ruby" }, detected = {} })
  return a, mock
end

local function ticks(a, n) for _ = 1, n do a:tick() end end

t.case("live stats are decoded from the second stream at +0x158", function()
  local a = world_make({ party = {
    { species = 25, exp = 100, party = { level = 37, hp = 55, max_hp = 102, status = 0x0A, stats = { atk = 60 } } },
    { species = 4, exp = 100, ec = 0x00ABCDEF, party = { level = 5, hp = 1, max_hp = 1 } },
  } })
  local team = a:team()
  t.eq({ team[1].level, team[1].hp, team[1].max_hp, team[1].status }, { 37, 55, 102, 0x0A })
  t.eq({ team[2].level, team[2].hp, team[2].max_hp }, { 5, 1, 1 })
  t.eq(team[1].party_ext, nil)
  t.eq(a:features().live_stats, true)
end)

t.case("insane or missing live stats fall back to the level from EXP", function()
  local g = require("gen6.growth")
  local c = personal_stubs("single")
  local a = world_make({ party = {
    { species = 255, exp = g.exp_for_level(3, 8) + 1, party = { level = 50, hp = 200, max_hp = 100 } }, -- hp > max
    { species = 255, exp = g.exp_for_level(3, 8) + 1, party = { level = 101, hp = 1, max_hp = 1 } },
    { species = 255, exp = g.exp_for_level(3, 8) + 1, party = { level = 5, hp = 0, max_hp = 0 } },
    { species = 255, exp = g.exp_for_level(3, 8) + 1, party = { level = 5, hp = 5, max_hp = 5, stats = { spd = 0 } } },
  } }, { codec = c, romfs = { ["/a/1/9/5"] = "valid" } })
  local team = a:team()
  t.eq(#team, 4)
  for i = 1, 4 do
    t.eq(team[i].level, 8, "slot " .. i)
    t.eq(team[i].hp, nil); t.eq(team[i].max_hp, nil); t.eq(team[i].status, nil)
  end
  t.eq(a:features().live_stats, false)
  -- an all-zero stats area decrypts to garbage and must not pass
  local mockmem = mem.world({ party = { { species = 255, exp = 1 } } })
  mem.poke(mockmem, V10.party + 0x158, string.rep("\0", 22))
  local b = oras.attach({ uz = uz_mock.new({ memory = mockmem, codec = codec(), i18n_dir = "plugin/i18n" }).uz })
  t.eq(b:team()[1].level, nil)
end)

local TRAINER = { tid = 1111, sid = 2222, version = 27, language_id = 5, name = "Rubin" }

t.case("trainer, badges, money, play time and language from MyStatus (v1.0 and v1.4)", function()
  for _, rev in ipairs({ "v1.0", "v1.4" }) do
    local a = world_make({ rev = rev, party = { { species = 25 } }, trainer = TRAINER,
      misc = { money = 12345, badges = 0x15 }, play_time = { h = 123, m = 34, s = 56 } })
    t.eq(a:trainer(), { name = "Rubin", tid = 1111, sid = 2222, version = 27, language = "de", money = 12345, badges = 3,
      play_time = { h = 123, m = 34, s = 56 } }, rev)
    local b = a:badges()
    t.eq(b.count, 3)
    t.eq(b.flags, { true, false, true, false, true, false, false, false })
    t.eq(a:language(), "de")
  end
end)

t.case("trainer needs a readable MyStatus; implausible money and play time are left out", function()
  local a = world_make({ party = { { species = 25 } } })
  t.eq({ a:trainer() }, { nil, "not_ready" })
  t.eq({ a:badges() }, { nil, "not_ready" })
  local b = world_make({ party = { { species = 25 } }, trainer = TRAINER, misc = { money = 5000000, badges = 255 },
    play_time = { h = 1, m = 61, s = 1 } })
  local tr = b:trainer()
  t.eq(tr.money, nil); t.eq(tr.play_time, nil); t.eq(tr.badges, 8)
  local c = world_make({ trainer = TRAINER })
  t.eq({ c:trainer() }, { nil, "not_ready" }, "no revision yet")
  t.eq({ c:badges() }, { nil, "not_ready" })
end)

t.case("balls(): sums every ball type in the Items pouch, ignores other items (v1.0 and v1.4)", function()
  for _, rev in ipairs({ "v1.0", "v1.4" }) do
    local a = world_make({ rev = rev, party = { { species = 25 } },
      bag = { { 17, 5 }, { 4, 10 }, { 3, 4 }, { 13, 2 }, { 576, 1 }, { 492, 3 }, { 500, 1 }, { 25, 99 }, { 16, 1 } } })
    t.eq(a:balls(), { count = 22 }, rev)
  end
end)

t.case("balls(): no balls and an empty pouch give 0", function()
  local a = world_make({ party = { { species = 25 } }, bag = { { 17, 5 }, { 18, 2 } } })
  t.eq(a:balls(), { count = 0 })
  local b = world_make({ party = { { species = 25 } }, bag = {} })
  t.eq(b:balls(), { count = 0 })
  -- a ball behind the first empty slot is not read
  local c = world_make({ party = { { species = 25 } }, bag = { { 17, 1 }, { 0, 0 }, { 4, 9 } } })
  t.eq(c:balls(), { count = 0 })
end)

t.case("balls(): implausible slots are skipped, garbage is unsupported", function()
  local ok = world_make({ party = { { species = 25 } }, bag = { { 4, 3 }, { 900, 5 }, { 3, 2 }, { 2, 1000 }, { 1, 1 } } })
  t.eq(ok:balls(), { count = 6 }) -- 3 valid, 2 invalid
  local junk = world_make({ party = { { species = 25 } }, bag = { { 900, 5 }, { 4, 2000 }, { 60000, 1 } } })
  t.eq({ junk:balls() }, { nil, "unsupported" })
  local noise = {}
  for i = 1, 400 do noise[i] = string.pack("<I2I2", 0xFFFF - i, 0xABCD) end
  local n = world_make({ party = { { species = 25 } }, bag = table.concat(noise) })
  t.eq({ n:balls() }, { nil, "unsupported" })
end)

t.case("balls(): not_ready before the revision is found or while the pouch is unreadable", function()
  local a = world_make({ trainer = TRAINER })
  t.eq({ a:balls() }, { nil, "not_ready" })
  local b = world_make({ party = { { species = 25 } } }) -- party found, no bag memory mapped
  t.eq({ b:balls() }, { nil, "not_ready" })
end)

t.case("balls(): a revision without a bag address is unsupported, the bag override fills it", function()
  local rev = addr.REVISIONS[1]
  local saved = rev.addr.bag
  rev.addr.bag = nil
  local a = world_make({ party = { { species = 25 } } })
  t.eq({ a:balls() }, { nil, "unsupported" })
  local extra = { { addr = 0x08123450, data = mem.bag_blob({ { 4, 7 } }) } }
  local b = world_make({ party = { { species = 25 } }, extra = extra },
    { cache = { ["config/addresses.txt"] = "bag=0x08123450" } })
  t.eq(b:balls(), { count = 7 })
  rev.addr.bag = saved
  local c = world_make({ party = { { species = 25 } }, bag = { { 4, 2 } }, extra = extra },
    { cache = { ["config/addresses.txt"] = "v1.0.bag=0x08123450" } })
  t.eq(c:balls(), { count = 7 })
end)

t.case("badges.changed: baseline emits nothing, a new badge emits count and new indexes", function()
  local a, mock = world_make({ party = { { species = 25 } }, trainer = TRAINER, misc = { money = 1, badges = 0x01 } })
  local function evs()
    local out = {}
    for _, e in ipairs(mock.events) do if e.name == "badges.changed" then out[#out + 1] = e.value end end
    return out
  end
  ticks(a, 40)
  t.eq(#evs(), 0, "first snapshot is the baseline")
  mem.poke(mock.regions, V10.misc + 0xC, string.char(0x05))
  ticks(a, 40)
  t.eq(#evs(), 1)
  t.eq(evs()[1].count, 2); t.eq(evs()[1].new, { 3 })
  ticks(a, 40)
  t.eq(#evs(), 1, "no repeat while unchanged")
end)

t.case("language falls back to the party heuristic without MyStatus", function()
  local a = world_make({ party = { { tid = 11, sid = 22, origin_game = 27, language_id = 5 } } })
  t.eq(a:language(), "de")
end)

local function warnings(mock, pat)
  local n = 0
  for _, l in ipairs(mock.logs) do if l.level == "warn" and l.text:find(pat, 1, true) then n = n + 1 end end
  return n
end

t.case("cross-check: MyStatus TID against own-origin party members", function()
  local a, mock = world_make({ party = { { tid = 1111, sid = 2222, origin_game = 27 } }, trainer = TRAINER })
  a:team(); a:team()
  t.eq(warnings(mock, "cross-check"), 0)
  local b, mock2 = world_make({ party = { { tid = 4, sid = 2222, origin_game = 27 }, { tid = 1111, origin_game = 44 } },
    trainer = TRAINER })
  b:team(); b:team()
  t.eq(warnings(mock2, "cross-check"), 1)
  -- nothing to compare yet (only foreign-origin members): no verdict, no warning
  local c, mock3 = world_make({ party = { { tid = 4, origin_game = 44 } }, trainer = TRAINER })
  c:team()
  t.eq(warnings(mock3, "cross-check"), 0)
end)

t.case("address overrides: generic, per revision, bad lines, zone_addr.txt", function()
  local ov = addr.parse_overrides("party=0x08000000\nv1.4.misc = 08111110\n# comment\nbogus=1\nmystatus=zzz\nv9.9.party=0x1\nmap_id=0x08222220 # c\n\nbox")
  t.eq(ov.generic, { party = 0x08000000, map_id = 0x08222220 })
  t.eq(ov.rev, { ["v1.4"] = { misc = 0x08111110 } })
  t.eq(#ov.bad, 4)
  local good = addr.resolve(mem.rev("v1.4"), ov)
  t.eq(good.party, 0x08000000); t.eq(good.misc, 0x08111110); t.eq(good.box, V14.box)
  t.eq(addr.resolve(mem.rev("v1.0"), ov).misc, V10.misc)

  -- the party is found at the overridden address; watches follow
  local m = mem.world({ party = { { species = 25 } } })
  m[1].addr = 0x08000000
  local mock = uz_mock.new({ memory = m, codec = codec(), i18n_dir = "plugin/i18n",
    cache = { ["config/addresses.txt"] = "party=0x08000000\nnonsense\n", ["config/zone_addr.txt"] = "0x08123450" } })
  local a = oras.attach({ uz = mock.uz })
  t.eq(a:revision(), "v1.0")
  t.eq(mock.watches["oras.v1.0.party"].addr, 0x08000000)
  t.eq(mock.watches["oras.v1.4.party"], nil) -- released after detection
  t.eq(mock.watches["oras.v1.0.map_id"].addr, 0x08123450)
  t.eq(warnings(mock, "nonsense"), 1)
  -- zone_addr.txt wins over map_id= in addresses.txt
  local both = addr.load_overrides(uz_mock.new({ i18n_dir = "plugin/i18n", cache = {
    ["config/addresses.txt"] = "map_id=0x08222220", ["config/zone_addr.txt"] = "0x08123450" } }).uz)
  t.eq(both.generic.map_id, 0x08123450)
  t.eq(addr.parse_addr("0x10"), 16)
  t.eq(addr.parse_addr("0"), nil)
  t.eq(addr.parse_addr("123456789"), nil)
  t.eq(addr.parse_addr(nil), nil)
end)

t.case("every address key has a length and the v1.4 save range is v1.0 + 0x3FF0", function()
  for _, key in ipairs({ "party", "box", "mystatus", "misc", "bag", "play_time", "map_id", "player_x", "player_y", "event_flags" }) do
    t.eq(V14[key] - V10[key], addr.SHIFT, key)
  end
  for _, key in ipairs(addr.KEYS) do t.ok(addr.LENGTHS[key] > 0) end
  t.eq(V10.battle_flag, nil) -- no known v1.0 in-battle flag
end)

-- zone world: zone 0 = route (loc 10), zone 1 = town (loc 20)
local function zr(loc) return string.rep("\0", 0x1C) .. string.pack("<I2", loc) .. string.rep("\0", 0x38 - 0x1E) end
local function mini(magic, subs)
  local n = #subs
  local off, offs, body = 4 + (n + 1) * 4, {}, {}
  for i = 1, n do offs[i] = string.pack("<I4", off); body[i] = subs[i]; off = off + #subs[i] end
  return magic .. string.pack("<I2", n) .. table.concat(offs) .. string.pack("<I4", off) .. table.concat(body)
end
local function zo(loc)
  local slots = string.pack("<I2I1I1", 25, 3, 5) .. string.rep("\0", 0xF4 - 4)
  return mini("ZO", { zr(loc), "e", "s", string.rep("\1", 0x0E) .. slots .. "\0\0", "u" })
end

local function text_world()
  local function lines(prefix, n) local l = {} for i = 0, n - 1 do l[#l + 1] = prefix .. i end return l end
  local gt = tb.garc({ [98] = tb.build(lines("Sp", 30)), [14] = tb.build(lines("Mv", 10)), [90] = tb.build(lines("Loc", 40)) })
  return {
    ["/a/0/7/6"] = gt, -- German
    ["/a/0/1/3"] = formats.garc({ zo(10), mini("ZO", { zr(20), "a", "b" }), mini("EN", { "x" }) }),
  }
end

t.case("location with names: zone, location id, name, position, event on change", function()
  local a, mock = world_make({ party = { { species = 25 } }, trainer = TRAINER, zone = 0, x = 1.5, y = -2.25 },
    { romfs = text_world(), codec = (function() local c = formats.fake_codec(); c.pk6_decrypt = crypto.decrypt; return c end)() })
  local l = a:location()
  t.eq(l, { zone = 0, source = "memory", x = 1.5, y = -2.25 }, "before the zone scan")
  ticks(a, 400)
  l = a:location()
  t.eq(l, { zone = 0, location = 10, name = "Loc10", x = 1.5, y = -2.25, source = "memory" })
  t.eq(a:zone_info(1), { zone = 1, location = 20, name = "Loc20" })
  t.eq(a:name("species", 7), "Sp7")
  t.eq(a:features().names, true); t.eq(a:features().areas, true); t.eq(a:features().location, true)
  local areas = a:areas()
  t.eq(#areas, 1); t.eq(areas[1].id, 10); t.eq(areas[1].name, "Loc10"); t.eq(areas[1].zones, { 0 })
  t.eq(a:team()[1].species_name, "Sp25")
  local events = {}
  for _, e in ipairs(mock.events) do if e.name == "location.changed" then events[#events + 1] = e.value end end
  t.eq(#events, 3) -- first sight (zone only), then with the location id, then with the name
  t.eq(events[1].location, nil); t.eq(events[2].location, 10); t.eq(events[2].name, nil)
  t.eq(events[3].name, "Loc10")
  mem.poke(mock.regions, V10.map_id, string.pack("<I2", 1))
  ticks(a, 3)
  events = {}
  for _, e in ipairs(mock.events) do if e.name == "location.changed" then events[#events + 1] = e.value end end
  t.eq(#events, 4)
  t.eq(events[4].zone, 1); t.eq(events[4].location, 20); t.eq(events[4].name, "Loc20")
end)

t.case("location: unsupported/not_ready cases", function()
  local a = world_make({})
  t.eq({ a:location() }, { nil, "not_ready" })
  local c = formats.fake_codec(); c.pk6_decrypt = crypto.decrypt
  local b = world_make({ party = { { species = 25 } } }, { codec = c })
  t.eq({ b:location() }, { nil, "not_ready" }, "map id not readable")
  t.eq({ b:name("species", 1) }, { nil, "not_ready" })
  t.eq({ b:areas() }, { nil, "not_ready" })
  t.eq({ b:zone_info(1) }, { nil, "not_ready" }, "the archive is retried a few times")
  for _ = 1, 25 do b:zone_info(1) end
  t.eq({ b:zone_info(1) }, { nil, "not_ready" }, "then it keeps retrying slowly (state failed), not final")
  t.eq(b:diagnostics().zones_state, "failed")
end)

-- personal GARC with types: entry s has types (s % 18, s * 7 % 18), growth s % 6; the last file is the
-- whole table; species 25 has 3 forms at table indices 722..724
local function personal_with_types()
  local function entry(s, t1, t2, gr, fidx, fcount)
    local e = {}
    for i = 1, 0x50 do e[i] = "\0" end
    e[0x06 + 1], e[0x07 + 1], e[0x15 + 1] = string.char(t1), string.char(t2), string.char(gr)
    if fidx then
      e[0x1C + 1], e[0x1C + 2] = string.char(fidx & 255), string.char(fidx >> 8)
      e[0x20 + 1] = string.char(fcount)
    end
    return table.concat(e)
  end
  local list = {}
  for s = 0, 721 do list[s + 1] = entry(s, s % 18, (s * 7) % 18, s % 6, s == 25 and 722 or nil, s == 25 and 3 or nil) end
  list[723] = entry(722, 5, 5, 0); list[724] = entry(723, 6, 6, 0); list[725] = entry(724, 7, 8, 0)
  local files = {}
  for i = 1, #list do files[i] = list[i] end
  files[#files + 1] = table.concat(list)
  return formats.garc(files)
end

t.case("species_info from the personal table (last file holds everything)", function()
  local c = formats.fake_codec(); c.pk6_decrypt = crypto.decrypt
  local a = world_make({ party = { { species = 25 } } }, { romfs = { ["/a/1/9/5"] = personal_with_types() }, codec = c })
  t.eq(a:species_info(25, 0), { types = { 7, 13 }, growth = 1 })
  t.eq(a:species_info(25), { types = { 7, 13 }, growth = 1 })
  t.eq(a:species_info(25, 1), { types = { 5, 5 }, growth = 0 })
  t.eq(a:species_info(25, 3), nil, "form beyond FormeCount")
  t.eq({ a:species_info(800, 0) }, { nil, "unknown_species" })
  t.eq({ a:species_info(25, 3) }, { nil, "no_form" })
  local b = world_make({ party = { { species = 25 } } })
  t.eq({ b:species_info(25, 0) }, { nil, "not_ready" })
end)

t.case("event flags are bits of the flag block", function()
  local a, mock = world_make({ party = { { species = 25 } }, extra = nil })
  t.eq(a:event_flag(0), nil)
  local b = oras.attach({ uz = uz_mock.new({ memory = (function()
    local m = mem.world({ party = { { species = 25 } } })
    m[#m + 1] = { addr = V10.event_flags, data = "\5" .. string.rep("\0", 0x19F) }
    return m
  end)(), codec = codec(), i18n_dir = "plugin/i18n" }).uz })
  t.eq(b:event_flag(0), true); t.eq(b:event_flag(1), false); t.eq(b:event_flag(2), true)
  t.eq(b:event_flag(0xD00), nil)
end)

t.case("v0.3.1: species names in team and encounter records, locations() through the adapter", function()
  local a, mock = world_make({ party = { { species = 25 } }, trainer = TRAINER, zone = 0 },
    { romfs = text_world(), codec = (function() local c = formats.fake_codec(); c.pk6_decrypt = crypto.decrypt; return c end)() })
  t.eq({ a:locations() }, { nil, "not_ready" })
  ticks(a, 400)
  t.eq(a:team()[1].species_name, "Sp25")
  local locs = a:locations()
  t.eq(#locs, 2); t.eq(locs[1].id, 10); t.eq(locs[1].has_encounters, true); t.eq(locs[2].id, 20); t.eq(locs[2].has_encounters, false)
  t.eq(locs[2].name, "Loc20")
  t.eq(a:features().locations, true)
end)

-- v0.3.2: places never stay empty
local function loc_text_world(zone_archive)
  local function lines(prefix, n) local l = {} for i = 0, n - 1 do l[#l + 1] = prefix .. i end return l end
  local gt = tb.garc({ [98] = tb.build(lines("Sp", 30)), [14] = tb.build(lines("Mv", 10)),
    [90] = tb.build({ "Loc0", "", "Loc2", "Loc0", "Loc4", "" }) })
  local w = { ["/a/0/7/6"] = gt }
  if zone_archive then w["/a/0/1/3"] = zone_archive end
  return w
end
local function text_codec() local c = formats.fake_codec(); c.pk6_decrypt = crypto.decrypt; return c end

t.case("v0.3.2: no zone archive -> locations() from the location text (dedup by name, id order)", function()
  local a = world_make({ party = { { species = 25 } }, trainer = TRAINER, zone = 0 },
    { romfs = loc_text_world(nil), codec = text_codec() })
  t.eq({ a:locations() }, { nil, "not_ready" })
  ticks(a, 600)
  local locs = a:locations()
  t.eq(locs.source, "text")
  t.eq(#locs, 3)
  t.eq(locs[1], { id = 0, name = "Loc0", zones = {}, has_encounters = false, source = "text" })
  t.eq({ locs[2].id, locs[2].name, locs[3].id, locs[3].name }, { 2, "Loc2", 4, "Loc4" })
  t.eq(a:features().locations, true)
  t.eq({ a:areas() }, { nil, "not_ready" }, "areas stay as they are")
  local d = a:diagnostics()
  t.eq(d.zones_state, "failed"); t.eq(d.first_rejection, "archive_missing"); t.eq(d.locations_source, "text")
end)

t.case("v0.3.2: zone scan finished with zero locations -> locations() from the text", function()
  local a = world_make({ party = { { species = 25 } }, trainer = TRAINER, zone = 0 },
    { romfs = loc_text_world(formats.garc({ "junk junk", "more junk" })), codec = text_codec() })
  ticks(a, 600)
  local locs = a:locations()
  t.eq(locs.source, "text"); t.eq(#locs, 3)
  t.eq(a:diagnostics().zones_state, "done")
end)

t.case("v0.3.2: zones with a location use the zone list (source zones)", function()
  local a = world_make({ party = { { species = 25 } }, trainer = TRAINER, zone = 0 },
    { romfs = text_world(), codec = text_codec() })
  ticks(a, 600)
  local locs = a:locations()
  t.eq(locs.source, "zones"); t.eq(locs[1].source, "zones"); t.eq(locs[1].name, "Loc10")
end)

t.case("v0.3.2: diagnostics() holds plain numbers and strings only", function()
  local a = world_make({ party = { { species = 25 } }, trainer = TRAINER, zone = 0 },
    { romfs = text_world(), codec = text_codec() })
  ticks(a, 600)
  local d = a:diagnostics()
  for k, v in pairs(d) do t.ok(type(v) == "number" or type(v) == "string", k) end
  for _, k in ipairs({ "zones_state", "zone_files", "zo_packs", "zones_with_encounters", "areas", "locations",
    "zone_id_assignment", "first_rejection", "text_state", "lines_location", "lines_species", "species_file_index",
    "revision", "language", "locations_source" }) do t.ok(d[k] ~= nil, k) end
  t.eq(d.zones_state, "done"); t.eq(d.zo_packs, 2); t.eq(d.locations, 2); t.eq(d.areas, 1)
  t.eq(d.text_state, "done"); t.eq(d.lines_location, 40); t.eq(d.species_file_index, 98)
  t.eq(d.revision, "v1.0"); t.eq(d.language, "de")
  local text = {}
  for _, v in pairs(d) do if type(v) == "string" then text[#text + 1] = v end end
  t.ok(not table.concat(text, " "):find("Loc", 1, true), "no names")
end)

t.case("v0.3.2 regression: no list without names while the text is still loading", function()
  local a = world_make({ party = { { species = 25 } }, trainer = TRAINER, zone = 0 },
    { romfs = text_world(), codec = text_codec() })
  for _ = 1, 600 do
    a:tick()
    local locs, why = a:locations()
    if locs then
      for _, l in ipairs(locs) do t.ok(l.name ~= nil, "every handed-out place has its name") end
    else
      t.eq(why, "not_ready")
    end
  end
  t.ok(a:locations() ~= nil)
end)

t.case("v0.3.3: personal table in an LZ11-compressed GARC entry is read", function()
  local personal = require("gen6.personal")
  local whole = {}
  for s = 0, 721 do
    local e = {}
    for i = 1, 0x50 do e[i] = "\0" end
    e[0x15 + 1] = string.char(s % 6)
    whole[#whole + 1] = table.concat(e)
  end
  local garc = formats.garc({ formats.lz11_literal(table.concat(whole)) })
  local mock = uz_mock.new({ game = { system = "3ds" }, codec = formats.fake_codec(), i18n_dir = "plugin/i18n",
    romfs = { ["/a/1/9/5"] = garc } })
  local p = personal.new(mock.uz, { paths = { "/a/1/9/5" } })
  t.eq(p.growth_rate(25), 25 % 6)
  t.eq(p.diagnostics().personal_ok, 1)
  local q = personal.new(uz_mock.new({ game = { system = "3ds" }, codec = formats.fake_codec(), i18n_dir = "plugin/i18n",
    romfs = { ["/a/1/9/5"] = "GARC" .. string.rep("\0", 40) } }).uz, { paths = { "/a/1/9/5" } })
  t.eq(q.growth_rate(25), nil)
  t.ok(q.diagnostics().personal_first_rejection:find("garc_rejected", 1, true))
end)

-- v0.7.2: game language robustness (issue #42) --------------------------------------------------------

local function lang_world()
  local function lines(prefix, n) local l = {} for i = 0, n - 1 do l[#l + 1] = prefix .. i end return l end
  local function gt(tag)
    return tb.garc({ [98] = tb.build(lines(tag .. "S", 30)), [14] = tb.build(lines(tag .. "M", 10)),
      [90] = tb.build(lines(tag .. "L", 40)) })
  end
  return { ["/a/0/7/6"] = gt("de"), ["/a/0/7/3"] = gt("en") }
end

t.case("v0.7.2: MyStatus language byte 5 -> de, text index 5, language_source mystatus", function()
  local a = world_make({ party = { { species = 25 } }, trainer = TRAINER },
    { romfs = lang_world(), codec = text_codec() })
  ticks(a, 400)
  local d = a:diagnostics()
  t.eq(d.language, "de"); t.eq(d.language_source, "mystatus"); t.eq(d.mystatus_language_id, 5)
  t.eq(d.text_language_index, 5); t.eq(a:name("species", 3), "deS3")
end)

t.case("v0.7.2: language known only after the fallback -> text reloads to the right index", function()
  local tr = { tid = 1, sid = 2, version = 27, language_id = 0, name = "Rubin" } -- 0: not set yet
  local a, mock = world_make({ party = { { species = 25, origin_game = 24 } }, trainer = tr },
    { romfs = lang_world(), codec = text_codec() })
  ticks(a, 3000)
  local d = a:diagnostics()
  t.eq(d.language, "unknown"); t.eq(d.language_source, "fallback"); t.eq(d.mystatus_language_id, 0)
  t.eq(d.text_language_index, 2); t.eq(d.text_fallback_used, 1)
  t.eq(a:name("species", 3), "enS3")
  mem.poke(mock.regions, V10.mystatus + 0x2D, string.char(5))
  ticks(a, 400)
  d = a:diagnostics()
  t.eq(d.language, "de"); t.eq(d.language_source, "mystatus")
  t.eq(d.text_language_index, 5); t.eq(d.text_fallback_used, 0)
  t.eq(a:name("species", 3), "deS3")
end)

t.case("v0.7.2: language from the party when MyStatus has none (language_source party)", function()
  local tr = { tid = 11, sid = 22, version = 27, language_id = 0, name = "Rubin" }
  local a = world_make({ party = { { species = 25, tid = 11, sid = 22, origin_game = 27, language_id = 5 } }, trainer = tr })
  local d = a:diagnostics()
  t.eq(d.language, "de"); t.eq(d.language_source, "party")
end)

t.case("v0.7.2: language never known -> EN fallback, language_source fallback", function()
  local a = world_make({ party = { { species = 25, origin_game = 24 } } },
    { romfs = lang_world(), codec = text_codec() })
  ticks(a, 3000)
  local d = a:diagnostics()
  t.eq(d.language, "unknown"); t.eq(d.language_source, "fallback"); t.eq(d.mystatus_language_id, -1)
  t.eq(d.text_language_index, 2); t.eq(a:name("species", 3), "enS3")
end)

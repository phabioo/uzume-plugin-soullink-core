local t = require("t")
local uz_mock = require("uz_mock")
local formats = require("formats")
local zones = require("gen6.zones")

local function u16(v) return string.pack("<I2", v) end

-- zone record 0x38 with the location name index in the low 10 bits of u16 @0x1C
local function record(loc, hi)
  return string.rep("\0", 0x1C) .. u16((hi or 0) << 10 | loc) .. string.rep("\0", 0x38 - 0x1E)
end

-- 61 slots from { {group, index(1-based inside group), species, form, min, max}, ... }
local function slots(list)
  local starts, pos = {}, 0
  local order = { "grass", "tall_grass", "swarm", "surf", "rock_smash", "old_rod", "good_rod", "super_rod", "hordeA", "hordeB", "hordeC" }
  local sizes = { 12, 12, 3, 5, 5, 3, 3, 3, 5, 5, 5 }
  for i, g in ipairs(order) do starts[g] = pos; pos = pos + sizes[i] end
  local b = {}
  for i = 1, 61 do b[i] = string.pack("<I2I1I1", 0, 0, 0) end
  for _, s in ipairs(list) do
    b[starts[s[1]] + s[2]] = string.pack("<I2I1I1", s[3] | ((s[4] or 0) << 11), s[5], s[6])
  end
  return table.concat(b)
end

local function pack(magic, subs)
  local n = #subs
  local head = magic .. u16(n)
  local off = 4 + (n + 1) * 4
  local offs, body = {}, {}
  for i = 1, n do offs[i] = string.pack("<I4", off); body[i] = subs[i]; off = off + #subs[i] end
  offs[n + 1] = string.pack("<I4", off)
  return head .. table.concat(offs) .. table.concat(body)
end

-- ORAS ZO pack: [0] zone record, [1] entities, [2] script, [3] encounters, [4] unknown
local function zo(loc, enc)
  local e
  if enc then e = string.rep("\1", 0x0E) .. slots(enc) .. "\0\0" else e = string.rep("\2", 0x10) end
  return pack("ZO", { record(loc), string.rep("e", 8), string.rep("s", 4), e, string.rep("u", 4) })
end

local function world(opts)
  opts = opts or {}
  local z = {
    zo(10, { { "grass", 1, 25, 0, 3, 5 }, { "grass", 2, 25, 0, 3, 5 }, { "grass", 3, 16, 0, 2, 3 } }), -- zone 0
    zo(10, { { "surf", 1, 7, 0, 20, 30 } }),                                    -- zone 1, same location
    zo(20),                                                                     -- zone 2, town
    zo(30, { { "hordeA", 1, 19, 0, 10, 12 }, { "hordeB", 1, 19, 0, 10, 12 }, { "hordeC", 2, 19, 1, 10, 12 } }), -- zone 3
    pack("ZO", { record(12), "a", "b" }),                                       -- zone 4: too few sub-files
    zo(30, { { "old_rod", 1, 129, 0, 5, 10 }, { "tall_grass", 3, 722, 0, 1, 1 }, { "super_rod", 1, 0, 0, 9, 9 } }), -- zone 5
  }
  local table_data = {}
  local locs = { 10, 10, 20, 30, 12, 30 }
  for i, l in ipairs(locs) do table_data[i] = record(l) end
  local entries = {}
  for i, d in ipairs(z) do entries[i] = (i % 2 == 1) and formats.lz11_literal(d) or d end
  local tbl, en = table.concat(table_data), pack("EN", { "copy", "copy2" })
  if opts.table_first then
    table.insert(entries, 1, en); table.insert(entries, 1, tbl)
  else
    entries[#entries + 1] = tbl; entries[#entries + 1] = en
  end
  return { ["/a/0/1/3"] = formats.garc(entries) }
end

local function make(romfs, names)
  local mock = uz_mock.new({ game = { system = "3ds" }, codec = formats.fake_codec(), i18n_dir = "plugin/i18n", romfs = romfs })
  local reads, fileCalls = 0, 0
  local ro, gf = mock.uz.rom.romfs, mock.uz.codec.garc_file
  mock.uz.rom.romfs = function(p) reads = reads + 1; return ro(p) end
  local store = zones.new(mock.uz, { name = function(kind, id) return names and names[id] end })
  local peak = 0
  mock.uz.codec.garc_file = function(...) fileCalls = fileCalls + 1; return gf(...) end
  local function run()
    for _ = 1, 100 do
      if store.state() == "done" or store.state() == "unsupported" then return end
      fileCalls = 0
      store.step()
      peak = math.max(peak, fileCalls)
    end
  end
  return store, mock, run, function() return reads, peak end
end

t.case("slot decoding: groups, form bits, dedup, species range", function()
  local out, n = zones.decode_slots(slots({
    { "grass", 1, 25, 0, 3, 5 }, { "grass", 2, 25, 0, 3, 5 }, { "grass", 3, 25, 0, 3, 6 },
    { "surf", 5, 7, 2, 1, 2 }, { "hordeA", 1, 19, 0, 10, 12 }, { "hordeC", 5, 19, 0, 10, 12 },
    { "grass", 4, 722, 0, 1, 1 },
  }))
  t.eq(n, 6)
  t.eq(out.grass, { { species = 25, form = 0, min = 3, max = 5 }, { species = 25, form = 0, min = 3, max = 6 } })
  t.eq(out.surf, { { species = 7, form = 2, min = 1, max = 2 } })
  t.eq(out.horde, { { species = 19, form = 0, min = 10, max = 12 } })
  t.eq(out.swarm, {})
end)

t.case("classify by content: ZO, EN, table, no encounters, junk", function()
  local kind, rec0, enc = zones.classify(zo(33, { { "grass", 1, 25, 0, 3, 5 } }))
  t.eq(kind, "zo"); t.eq(#rec0, 0x38); t.eq(#enc, 0xF4)
  kind, rec0, enc = zones.classify(zo(33))
  t.eq(kind, "zo"); t.eq(enc, nil)
  t.eq((zones.classify(pack("EN", { "x" }))), "en")
  t.eq((zones.classify(string.rep("\0", 0x38 * 3))), "table")
  t.eq(zones.classify(string.rep("j", 55)), nil)
  t.eq(zones.classify("ZO"), nil)
  t.eq(zones.classify("ZO" .. u16(9) .. string.rep("\255", 8)), nil)
end)

t.case("scan builds zones and areas grouped by location in zone order", function()
  local store, _, run, stats = make(world())
  t.eq({ store.areas() }, { nil, "not_ready" })
  run()
  t.eq(store.state(), "done")
  t.ok(store.found())
  local areas = store.areas()
  t.eq(#areas, 2)
  t.eq(areas[1].id, 10); t.eq(areas[1].zones, { 0, 1 })
  t.eq(areas[1].encounters.grass, { { species = 25, form = 0, min = 3, max = 5 }, { species = 16, form = 0, min = 2, max = 3 } })
  t.eq(areas[1].encounters.surf, { { species = 7, form = 0, min = 20, max = 30 } })
  t.eq(areas[2].id, 30); t.eq(areas[2].zones, { 3, 5 })
  t.eq(areas[2].encounters.horde, { { species = 19, form = 0, min = 10, max = 12 }, { species = 19, form = 1, min = 10, max = 12 } })
  t.eq(areas[2].encounters.old_rod, { { species = 129, form = 0, min = 5, max = 10 } })
  t.eq(areas[2].encounters.tall_grass, nil, "species 722 is not a slot")
  local reads, peak = stats()
  t.eq(reads, 1)
  t.ok(peak <= zones.ENTRIES_PER_STEP)
end)

t.case("zone_info covers towns and unknown zones; names come from the text", function()
  local store, _, run = make(world(), { [10] = "Route A", [20] = "Town B" })
  t.eq({ store.zone_info(2) }, { nil, "not_ready" })
  run()
  t.eq(store.zone_info(2), { zone = 2, location = 20, name = "Town B" })
  t.eq(store.zone_info(4), { zone = 4, location = 12 })
  t.eq(store.zone_info(0).name, "Route A")
  t.eq({ store.zone_info(99) }, { nil, "unknown_zone" })
  t.eq({ store.zone_info("x") }, { nil, "unknown_zone" })
  t.eq(store.areas()[1].name, "Route A")
  t.eq(store.areas()[2].name, nil)
end)

t.case("zonedata table in front shifts the GARC index: the ordinal is used", function()
  local store, _, run = make(world({ table_first = true }))
  run()
  t.eq(store.zone_info(2).location, 20)
  t.eq(store.zone_info(5).location, 30)
  t.eq(store.areas()[1].zones, { 0, 1 })
end)

t.case("missing or broken archives never raise", function()
  local store, _, run = make({})
  run()
  t.eq(store.state(), "failed", "a missing archive is retried, not final")
  t.eq({ store.areas() }, { nil, "not_ready" })
  for _ = 1, (zones.MAX_RETRIES + 2) * (zones.RETRY_EVERY + 2) do store.step() end
  t.eq(store.state(), "unsupported")
  t.eq({ store.areas() }, { nil, "unsupported" })
  local junk, _, run2 = make({ ["/a/0/1/3"] = formats.garc({ "junk", "more junk" }) })
  run2()
  t.eq(junk.state(), "done")
  t.eq(junk.found(), false)
  t.eq(junk.areas(), {})
  local mock = uz_mock.new({ i18n_dir = "plugin/i18n" })
  t.eq(zones.new(mock.uz, {}).state(), "unsupported")
end)

-- v0.3.1 ---------------------------------------------------------------------------------------------

-- a ZO pack whose last offset points past the end of the pack (padding) and whose encounter
-- sub-file is the last real one: the v0.3.0 reader rejected the whole pack
local function zo_padded(loc, enc)
  local d = zo(loc, enc)
  local count = string.unpack("<I2", d, 3)
  local last = 5 + count * 4
  return d:sub(1, last - 1) .. string.pack("<I4", #d + 8) .. d:sub(last + 4) .. string.rep("\0", 8)
end

-- ZO pack with an empty trailing sub-file whose offset is 0 (out of order)
local function zo_zero_tail(loc, enc)
  local d = zo(loc, enc)
  local count = string.unpack("<I2", d, 3)
  local last = 5 + count * 4
  return d:sub(1, last - 1) .. string.pack("<I4", 0) .. d:sub(last + 4)
end

t.case("lenient packs: padded or out-of-order offsets still give the encounter table", function()
  local kind, rec0, enc = zones.classify(zo_padded(33, { { "grass", 1, 25, 0, 3, 5 } }))
  t.eq(kind, "zo"); t.eq(#rec0, 0x38); t.eq(#enc, 0xF4)
  kind, _, enc = zones.classify(zo_zero_tail(33, { { "surf", 1, 7, 0, 3, 5 } }))
  t.eq(kind, "zo"); t.eq(#enc, 0xF4)
  -- the encounter sub-file is the last sub-file (4 sub-files only)
  local four = pack("ZO", { record(5), "e", "s", string.rep("\1", 0x0E) .. slots({ { "grass", 1, 25, 0, 3, 5 } }) })
  kind, _, enc = zones.classify(four)
  t.eq(kind, "zo"); t.eq(#enc, 0xF4)
  local k2, _, e2, why = zones.classify(zo(33))
  t.eq(k2, "zo"); t.eq(e2, nil); t.eq(why, "enc_too_short")
  local k3, why3 = zones.classify("ZO" .. u16(9) .. string.rep("\255", 8))
  t.eq(k3, nil); t.eq(why3, "zo_bad_header")
end)

local function world2()
  local z = {
    zo_padded(10, { { "grass", 1, 25, 0, 3, 5 } }),                 -- zone 0, route
    zo_zero_tail(10, { { "surf", 1, 7, 0, 20, 30 } }),              -- zone 1, same location
    zo(20),                                                         -- zone 2, town
    zo(30, { { "grass", 1, 19, 0, 10, 12 } }),                      -- zone 3
  }
  local recs = { record(10), record(10), record(20), record(30), record(40), string.rep("\0", 0x38), record(50) }
  local entries = {}
  for i, d in ipairs(z) do entries[i] = (i % 2 == 1) and formats.lz11_literal(d) or d end
  entries[#entries + 1] = table.concat(recs)
  entries[#entries + 1] = pack("EN", { "copy" })
  return { ["/a/0/1/3"] = formats.garc(entries) }
end

t.case("areas from packs the old reader rejected; locations include towns and table-only zones", function()
  local store, mock, run = make(world2(), { [10] = "Route A", [20] = "Town B" })
  t.eq({ store.locations() }, { nil, "not_ready" })
  run()
  t.eq(store.state(), "done")
  local areas = store.areas()
  t.eq(#areas, 2)
  t.eq(areas[1].id, 10); t.eq(areas[1].zones, { 0, 1 })
  t.eq(areas[1].encounters.surf, { { species = 7, form = 0, min = 20, max = 30 } })
  t.eq(areas[2].id, 30)
  local locs = store.locations()
  t.eq(#locs, 5)
  t.eq(locs[1], { id = 10, name = "Route A", zones = { 0, 1 }, has_encounters = true })
  t.eq(locs[2], { id = 20, name = "Town B", zones = { 2 }, has_encounters = false })
  t.eq(locs[3], { id = 30, name = nil, zones = { 3 }, has_encounters = true })
  t.eq(locs[4], { id = 40, zones = { 4 }, has_encounters = false }, "zone only in the table")
  t.eq(locs[5], { id = 50, zones = { 6 }, has_encounters = false }, "empty record 5 is skipped")
  t.eq(store.zone_info(4).location, 40)
  t.ok(store.has_locations())
  local line
  for _, l in ipairs(mock.logs) do if l.level == "info" and l.text:find("zones scanned", 1, true) then line = l.text end end
  t.ok(line and line:find("4 ZO packs", 1, true) and line:find("2 areas", 1, true) and line:find("5 locations", 1, true), line)
  t.ok(not line:find("Route", 1, true), "no names in the log")
end)

t.case("empty areas although ZO packs exist: one warning with the first reason", function()
  local entries = {}
  for i = 1, 3 do entries[i] = zo(10 + i) end -- encounter sub-files too short
  entries[4] = pack("ZO", { record(3), "x", "y", "z" }) -- 4 sub-files, no room for slots
  local store, mock, run = make({ ["/a/0/1/3"] = formats.garc(entries) })
  run()
  t.eq(store.state(), "done"); t.eq(store.found(), false)
  t.eq(#store.locations(), 4)
  local n, text = 0, nil
  for _, l in ipairs(mock.logs) do if l.level == "warn" and l.text:find("no encounter areas", 1, true) then n = n + 1; text = l.text end end
  t.eq(n, 1); t.ok(text:find("enc_too_short", 1, true), text)
end)

t.case("the archive is retried when it is not readable yet; a failing entry does not stop the scan", function()
  local good = world2()["/a/0/1/3"]
  local calls = 0
  local mock = uz_mock.new({ game = { system = "3ds" }, codec = formats.fake_codec(), i18n_dir = "plugin/i18n", romfs = {} })
  mock.uz.rom.romfs = function() calls = calls + 1; if calls <= 3 then return nil end return good end
  local gf = mock.uz.codec.garc_file
  mock.uz.codec.garc_file = function(d, i, sub) if i == 2 then error("boom") end return gf(d, i, sub) end
  local store = zones.new(mock.uz, {})
  for _ = 1, 100 do store.step() end
  t.eq(store.state(), "done")
  t.eq(#store.areas() >= 1, true)
  local mock2 = uz_mock.new({ game = { system = "3ds" }, codec = formats.fake_codec(), i18n_dir = "plugin/i18n", romfs = {} })
  local s2 = zones.new(mock2.uz, {})
  for _ = 1, zones.OPEN_RETRIES + 1 do s2.step() end
  t.eq(s2.state(), "failed")
end)

-- v0.3.2
t.case("v0.3.2: no list is handed out while the game text is still loading", function()
  local text_state = "open"
  local mock = uz_mock.new({ game = { system = "3ds" }, codec = formats.fake_codec(), i18n_dir = "plugin/i18n", romfs = world2() })
  local store = zones.new(mock.uz, { name = function(_, id) return "N" .. id end, names_state = function() return text_state end })
  for _ = 1, 100 do store.step() end
  t.eq(store.state(), "done")
  t.eq({ store.locations() }, { nil, "not_ready" })
  t.eq({ store.areas() }, { nil, "not_ready" })
  text_state = "done"
  t.eq(store.locations()[1].name, "N10"); t.eq(store.areas()[1].name, "N10")
  text_state = "unsupported"
  t.ok(store.locations() ~= nil, "without any text the zone list is still returned")
end)

t.case("v0.3.2: an archive that becomes readable late is still scanned (no final unsupported)", function()
  local good = world2()["/a/0/1/3"]
  local steps = 0
  local mock = uz_mock.new({ game = { system = "3ds" }, codec = formats.fake_codec(), i18n_dir = "plugin/i18n", romfs = {} })
  mock.uz.rom.romfs = function() if steps < 60 then return nil end return good end
  local store = zones.new(mock.uz, {})
  while steps < 400 and store.state() ~= "done" do steps = steps + 1; store.step() end
  t.eq(store.state(), "done"); t.eq(#store.locations(), 5)
  t.ok(store.diagnostics().zone_retries >= 1)
end)

t.case("v0.3.2: an unreadable GARC and a failing scan are retried, not final", function()
  local good = world2()["/a/0/1/3"]
  local mock = uz_mock.new({ game = { system = "3ds" }, codec = formats.fake_codec(), i18n_dir = "plugin/i18n", romfs = { ["/a/0/1/3"] = good } })
  local garc, broken = mock.uz.codec.garc, true
  mock.uz.codec.garc = function(d) if broken then error("not yet") end return garc(d) end
  local store = zones.new(mock.uz, {})
  store.step()
  t.eq(store.state(), "failed"); t.eq(store.diagnostics().first_rejection, "archive_unreadable")
  t.eq({ store.locations() }, { nil, "failed" })
  broken = false
  for _ = 1, 100 do store.step() end
  t.eq(store.state(), "done"); t.eq(#store.locations(), 5)
end)

t.case("v0.3.2: diagnostics() counts and the first rejection reason", function()
  local store, _, run = make(world2())
  t.eq(store.diagnostics().zones_state, "idle")
  run()
  local d = store.diagnostics()
  t.eq({ d.zones_state, d.zone_files, d.zo_packs, d.zones_with_encounters, d.areas, d.locations },
    { "done", 6, 4, 3, 2, 5 })
  t.eq(d.zone_id_assignment, "garc index"); t.eq(d.table_zones, 2); t.ok(type(d.first_rejection) == "string")
  for k, v in pairs(d) do t.ok(type(v) == "number" or type(v) == "string", k) end
end)

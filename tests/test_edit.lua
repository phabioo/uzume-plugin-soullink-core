-- Write helpers: PK6 crypto, pk6_edit, and the ORAS adapter's encode_* (synthetic data only).
local t = require("t")
local uz_mock = require("uz_mock")
local crypto = require("pk6_crypto")
local build = require("pk6_build")
local formats = require("formats")
local pk6 = require("gen6.pk6")
local edit = require("gen6.pk6_edit")
local growth = require("gen6.growth")
local oras = require("gen6.oras")
local mem = require("oras_mem")
local interface = require("core.interface")

-- ---- crypto ----

t.case("pk6.encrypt matches the independent test crypto, decrypt round-trips", function()
  for _, ec in ipairs({ 0, 1, 0x2000, 0x4000, 0xBADF00D, 0xFFFFFFFF, 0x1234ABCD, 0x31A000, 0x7FFFE000 }) do
    for _, party in ipairs({ false, true }) do
      local plain = build.build({ ec = ec, species = 255, exp = 77, nickname = "Abc",
        party = party and { level = 9, hp = 30, max_hp = 31 } or nil })
      local enc = pk6.encrypt(plain)
      t.eq(enc, crypto.encrypt(plain))
      local back, ok = pk6.decrypt(enc)
      t.eq(back, plain); t.eq(ok, true)
      t.eq(select(1, pk6.decrypt(crypto.encrypt(plain))), plain)
    end
  end
  t.eq({ pk6.encrypt("short") }, { nil, "bad_length" })
  t.eq({ pk6.decrypt(5) }, { nil, "bad_length" })
end)

t.case("checksum recompute and seal", function()
  local plain = build.build({ species = 25, exp = 100 })
  local changed = plain:sub(1, 0x0F) .. "\x55" .. plain:sub(0x11)
  local _, ok = pk6.decrypt(pk6.encrypt(changed))
  t.eq(ok, false, "stale checksum is detected")
  local back, ok2 = pk6.decrypt(pk6.seal(changed))
  t.eq(ok2, true)
  t.eq(string.unpack("<I2", back, 7), pk6.checksum(back))
  t.eq(back:sub(9), changed:sub(9))
  t.eq(pk6.checksum(plain), crypto.checksum(plain))
end)

t.case("utf8 to utf16le", function()
  t.eq(pk6.utf8_to_utf16le("Ab", 4), "A\0b\0\0\0\0\0")
  t.eq(#pk6.utf8_to_utf16le(string.rep("x", 20), 13), 26)
  t.eq(pk6.utf16le_to_utf8(pk6.utf8_to_utf16le("Zebra", 13), 12), "Zebra")
end)

-- ---- pk6_edit ----

local function base_plain(extra)
  local f = { species = 25, exp = 1000, tid = 100, sid = 200, pid = 0x0000ABCD, nature = 3, nickname = "Zap",
    nicknamed = true, held_item = 5, moves = { 33, 45, 0, 0 }, ivs = { hp = 1, atk = 2, def = 3, spe = 4, spa = 5, spd = 6 },
    evs = { hp = 10, atk = 20, def = 0, spe = 0, spa = 0, spd = 0 } }
  for k, v in pairs(extra or {}) do f[k] = v end
  return build.build(f)
end

local CTX = {
  growth_rate = function() return growth.MEDIUM_FAST end,
  base_stats = function() return { hp = 50, atk = 60, def = 70, spe = 80, spa = 90, spd = 100 } end,
  species_name = function(id) return "Sp" .. id end,
  current_level = 10,
}

t.case("apply sets every simple field", function()
  local out, w = edit.apply(base_plain(), {
    species = 7, level = 30, nature = 12, held_item = 77, ability = 9, nickname = "Pika",
    ivs = { atk = 31 }, evs = { spa = 100 }, moves = { 1, 2, 3, 4 }, pp = { 10, 20, 30, 40 },
  }, CTX)
  t.ok(out, tostring(w))
  local r = pk6.parse(out)
  t.eq(r.species, 7); t.eq(r.exp, 30 * 30 * 30); t.eq(r.nature, 12); t.eq(r.held_item, 77); t.eq(r.ability, 9)
  t.eq(r.nickname, "Pika"); t.eq(r.nicknamed, true)
  t.eq(r.ivs, { hp = 1, atk = 31, def = 3, spe = 4, spa = 5, spd = 6 })
  t.eq(r.evs, { hp = 10, atk = 20, def = 0, spe = 0, spa = 100, spd = 0 })
  t.eq(r.moves, { 1, 2, 3, 4 })
  t.eq({ out:byte(0x62 + 1, 0x62 + 4) }, { 10, 20, 30, 40 })
  t.eq(r.ot_id, 100) -- untouched
  t.eq(w, { "ability_unchanged" })
end)

t.case("species change renames an unnicknamed mon and resets the form", function()
  local out = edit.apply(base_plain({ nicknamed = false, nickname = "Old", form = 2 }), { species = 9 }, CTX)
  local r = pk6.parse(out)
  t.eq(r.nickname, "Sp9"); t.eq(r.nicknamed, false); t.eq(r.form, 0)
  local out2 = edit.apply(base_plain({ form = 2 }), { form = 1 }, CTX)
  t.eq(pk6.parse(out2).form, 1)
end)

t.case("level to EXP for each growth rate; unchanged level keeps EXP", function()
  for rate = 0, 5 do
    local ctx = { growth_rate = function() return rate end, current_level = 10 }
    local out = edit.apply(base_plain(), { level = 55 }, ctx)
    t.eq(pk6.parse(out).exp, growth.exp_for_level(rate, 55), "rate " .. rate)
  end
  local same = edit.apply(base_plain(), { level = 10 }, CTX)
  t.eq(pk6.parse(same).exp, 1000)
  t.eq({ edit.apply(base_plain(), { level = 40 }, { current_level = 10 }) }, { nil, "growth_unavailable" })
  local out, w = edit.apply(base_plain(), { species = 9 }, { current_level = 10 })
  t.eq(pk6.parse(out).exp, 1000); t.eq(w, { "ability_unchanged", "exp_unchanged" })
end)

t.case("shiny on and off keeps gender byte of the PID and is idempotent", function()
  local plain = base_plain()
  t.eq(pk6.parse(plain).shiny, false)
  local on = edit.apply(plain, { shiny = true }, CTX)
  local r = pk6.parse(on)
  t.eq(r.shiny, true)
  t.eq(r.personality & 0xFFFF, 0xABCD)
  t.eq(edit.apply(on, { shiny = true }, CTX), on)
  local off = pk6.parse(edit.apply(on, { shiny = false }, CTX))
  t.eq(off.shiny, false); t.eq(off.personality & 0xFFFF, 0xABCD)
  t.eq(edit.apply(plain, { shiny = false }, CTX), plain)
end)

t.case("moves keep PP of unchanged moves and warn about unknown PP", function()
  local plain = base_plain()
  plain = plain:sub(1, 0x62) .. string.char(7, 8, 0, 0) .. plain:sub(0x67)
  local out, w = edit.apply(plain, { moves = { 33, 99 } }, CTX)
  t.eq({ out:byte(0x62 + 1, 0x62 + 4) }, { 7, edit.DEFAULT_PP, 0, 0 })
  t.eq(pk6.parse(out).moves, { 33, 99 })
  t.eq(w, { "pp_unknown" })
  local out2, w2 = edit.apply(plain, { moves = { 33, 45 }, pp = { nil, 12 } }, CTX)
  t.eq({ out2:byte(0x62 + 1, 0x62 + 2) }, { 7, 12 }); t.eq(w2, {})
end)

t.case("validation", function()
  local p = base_plain()
  local function bad(fields, why)
    t.eq({ edit.apply(p, fields, CTX) }, { nil, why }, why)
  end
  bad({ species = 0 }, "invalid_species")
  bad({ species = 722 }, "invalid_species")
  bad({ species = 1.5 }, "invalid_species")
  bad({ level = 101 }, "invalid_level")
  bad({ level = 0 }, "invalid_level")
  bad({ nature = 25 }, "invalid_nature")
  bad({ ivs = { atk = 32 } }, "invalid_ivs")
  bad({ ivs = { foo = 1 } }, "invalid_ivs")
  bad({ evs = { atk = 256 } }, "invalid_evs")
  bad({ evs = { hp = 255, atk = 255, def = 1 } }, "ev_total")
  bad({ evs = { hp = 250 }, held_item = 1, moves = {} }, "invalid_moves")
  bad({ moves = { 1, 2, 3, 4, 5 } }, "invalid_moves")
  bad({ moves = { 618 } }, "invalid_moves")
  bad({ moves = { 5, 5 } }, "invalid_moves")
  bad({ moves = { 0 } }, "invalid_moves")
  bad({ held_item = 776 }, "invalid_item")
  bad({ ability = 192 }, "invalid_ability")
  bad({ shiny = 1 }, "invalid_shiny")
  bad({ nickname = string.rep("x", 13) }, "invalid_nickname")
  bad({ pp = { 65 } }, "invalid_pp")
  bad({ cheese = 1 }, "unknown_field:cheese")
  -- EV total counts the existing EVs of untouched stats (10 + 20 already there)
  bad({ evs = { spa = 200, spd = 200, spe = 81 } }, "ev_total")
  t.ok(edit.apply(p, { evs = { spa = 252, spd = 252, def = 0, hp = 0, atk = 6 } }, CTX))
  t.eq({ edit.apply("short", {}, CTX) }, { nil, "bad_structure" })
end)

t.case("stats formula (known values: base 50 hp at level 100, no EV/IV = 210 hp)", function()
  local s = edit.compute_stats({ hp = 50, atk = 50, def = 50, spe = 50, spa = 50, spd = 50 },
    { hp = 0, atk = 0, def = 0, spe = 0, spa = 0, spd = 0 }, { hp = 0, atk = 0, def = 0, spe = 0, spa = 0, spd = 0 }, 100, 0)
  t.eq(s, { hp = 210, atk = 105, def = 105, spe = 105, spa = 105, spd = 105 })
  local n = edit.compute_stats({ hp = 50, atk = 50, def = 50, spe = 50, spa = 50, spd = 50 },
    { hp = 31, atk = 31, def = 31, spe = 31, spa = 31, spd = 31 }, { hp = 0, atk = 0, def = 0, spe = 0, spa = 0, spd = 0 }, 100, 3)
  t.eq(n.atk, 136 * 11 // 10); t.eq(n.spa, 136 * 9 // 10) -- Adamant: +Atk -SpA
end)

-- ---- adapter ----

local function personal_garc()
  local list = {}
  for s = 0, 721 do
    local e = {}
    for i = 1, 0x50 do e[i] = "\0" end
    e[1], e[2], e[3], e[4], e[5], e[6] = "\45", "\49", "\49", "\45", "\65", "\65"
    e[0x15 + 1] = string.char(s % 6)
    list[s + 1] = table.concat(e)
  end
  local files = {}
  for i = 1, #list do files[i] = list[i] end
  files[#files + 1] = table.concat(list)
  return formats.garc(files)
end

local function make(world, extra)
  local c = formats.fake_codec(); c.pk6_decrypt = crypto.decrypt
  local opts = { game = { system = "3ds", code = "000400000011C400" }, memory = world and mem.world(world) or {}, codec = c,
    romfs = { ["/a/1/9/5"] = personal_garc() }, i18n_dir = "plugin/i18n" }
  for k, v in pairs(extra or {}) do opts[k] = v end
  local mock = uz_mock.new(opts)
  local a = oras.attach({ uz = mock.uz, game = { id = "pokemon_omega_ruby" }, detected = {} })
  for _ = 1, 70 do a:tick() end
  return a, mock
end

local V10 = mem.rev("v1.0").addr
local LIVE = { level = 20, hp = 40, max_hp = 60, stats = { atk = 50, def = 50, spe = 50, spa = 50, spd = 50 } }

local function apply_ops(mock, res)
  for _, op in ipairs(res.ops) do assert(mem.poke(mock.regions, op.addr, op.bytes)) end
end

t.case("encode_pokemon team slot: main block, live stats extension, round trip", function()
  local a, mock = make({ rev = "v1.0", party = { { species = 25, exp = 8000, nature = 1, moves = { 33 }, party = LIVE },
    { species = 4, exp = 100, party = LIVE } }, misc = { money = 5, badges = 0 } })
  local res, why = a:encode_pokemon({ kind = "team", slot = 2 }, { species = 7, level = 35, nature = 3, shiny = true,
    ivs = { hp = 31 }, evs = { atk = 252 }, moves = { 55, 56 }, pp = { 15, 10 }, held_item = 17 })
  t.eq(why, nil)
  t.ok(res, "encode failed")
  t.eq(#res.ops, 2)
  t.eq(res.ops[1].addr, V10.party + 0x1E4); t.eq(#res.ops[1].bytes, 0xE8)
  t.eq(res.ops[2].addr, V10.party + 0x1E4 + 0x158); t.eq(#res.ops[2].bytes, 22)
  t.eq(res.addr, res.ops[1].addr); t.eq(res.bytes, res.ops[1].bytes)
  t.eq(res.record.species, 7)
  apply_ops(mock, res)
  local team = a:team()
  t.eq(#team, 2)
  local m = team[2]
  t.eq(m.species, 7); t.eq(m.level, 35); t.eq(m.nature, 3); t.eq(m.shiny, true); t.eq(m.held_item, 17)
  t.eq(m.moves, { 55, 56 }); t.eq(m.ivs.hp, 31); t.eq(m.evs.atk, 252)
  t.eq(m.exp, growth.exp_for_level(7 % 6, 35))
  t.eq(team[1].species, 25) -- slot 1 untouched
  -- live extension recomputed from the personal base stats
  local st = edit.compute_stats({ hp = 45, atk = 49, def = 49, spe = 45, spa = 65, spd = 65 }, m.ivs, m.evs, 35, 3)
  local ext = pk6.parse(select(1, pk6.decrypt(mock.uz.memory.bytes(V10.party + 0x1E4, 0xE8) ..
    mock.uz.memory.bytes(V10.party + 0x1E4 + 0x158, 22) .. string.rep("\0", 6))))
  t.eq(ext.party_ext.level, 35); t.eq(ext.party_ext.max_hp, st.hp); t.eq(ext.party_ext.stats.atk, st.atk)
  t.eq(ext.party_ext.hp, st.hp) -- a species change fills HP
end)

t.case("HP stays when only the level changes and HP is below the new maximum", function()
  local a, mock = make({ rev = "v1.0", party = { { species = 25, exp = 8000, party = LIVE } } })
  local res = a:encode_pokemon({ kind = "team", slot = 1 }, { level = 40 })
  t.eq(res.record.party_ext.hp, 40); t.ok(res.record.party_ext.max_hp > 60)
  t.eq(res.record.party_ext.level, 40)
end)

t.case("encode_pokemon box slot and untouched neighbours", function()
  local a, mock = make({ rev = "v1.0", party = { { species = 1 } },
    boxes = { [2] = { [3] = { species = 25, exp = 500, nickname = "Box" }, [4] = { species = 26 } } } })
  local res = a:encode_pokemon({ kind = "box", box = 2, slot = 3 }, { level = 50, moves = { 10, 20, 30, 40 } })
  t.eq(res.ops[1].addr, V10.box + ((2 - 1) * 30 + 2) * 232); t.eq(#res.ops, 1); t.eq(#res.ops[1].bytes, 232)
  apply_ops(mock, res)
  local box = a:box(2)
  t.eq(box[1].level, 50); t.eq(box[1].moves, { 10, 20, 30, 40 }); t.eq(box[1].nickname, "Box")
  t.eq(box[2].species, 26)
end)

t.case("encode_pokemon errors", function()
  local a = make({ rev = "v1.0", party = { { species = 25, party = LIVE } }, boxes = {} })
  t.eq({ a:encode_pokemon({ kind = "team", slot = 3 }, { level = 5 }) }, { nil, "empty_slot" })
  t.eq({ a:encode_pokemon({ kind = "team", slot = 0 }, { level = 5 }) }, { nil, "invalid_location" })
  t.eq({ a:encode_pokemon({ kind = "box", box = 32, slot = 1 }, {}) }, { nil, "invalid_location" })
  t.eq({ a:encode_pokemon({ kind = "shelf" }, {}) }, { nil, "invalid_location" })
  t.eq({ a:encode_pokemon(nil, {}) }, { nil, "invalid_location" })
  t.eq({ a:encode_pokemon({ kind = "team", slot = 1 }, { level = 101 }) }, { nil, "invalid_level" })
  t.eq({ a:encode_pokemon({ kind = "team", slot = 1 }, { evs = { hp = 255, atk = 255, def = 255 } }) }, { nil, "ev_total" })
  local b = make(nil)
  t.eq({ b:encode_pokemon({ kind = "team", slot = 1 }, {}) }, { nil, "not_ready" })
  t.eq({ b:encode_money(5) }, { nil, "not_ready" })
end)

t.case("encode_pokemon without readable personal data refuses a level change only", function()
  local a = make({ rev = "v1.0", party = { { species = 25, exp = 500, party = LIVE } } }, { romfs = {} })
  t.eq({ a:encode_pokemon({ kind = "team", slot = 1 }, { level = 21 }) }, { nil, "growth_unavailable" })
  local res = a:encode_pokemon({ kind = "team", slot = 1 }, { held_item = 3 })
  t.ok(res); t.eq(res.record.held_item, 3); t.eq(res.warnings, {})
end)

t.case("encode_pokemon on a team slot without live stats writes the main block only", function()
  local a = make({ rev = "v1.0", party = { { species = 25, exp = 500 } } })
  local res = a:encode_pokemon({ kind = "team", slot = 1 }, { held_item = 3 })
  t.eq(#res.ops, 1); t.eq(#res.ops[1].bytes, 0xE8)
end)

t.case("encode_money, encode_item, limits and names", function()
  local a = make({ rev = "v1.0", party = { { species = 25 } }, misc = { money = 5, badges = 2 } })
  local r = a:encode_money(123456)
  t.eq(r.addr, V10.misc + 8); t.eq(r.bytes, string.pack("<I4", 123456)); t.eq(r.ops, { { addr = r.addr, bytes = r.bytes } })
  t.eq({ a:encode_money(1000000) }, { nil, "invalid_money" })
  t.eq({ a:encode_money(-1) }, { nil, "invalid_money" })
  t.eq({ a:encode_money(1.5) }, { nil, "invalid_money" })
  local L = a:edit_limits()
  t.eq(L.species, 721); t.eq(L.move, 617); t.eq(L.ev_total, 510); t.eq(L.money, 999999)
  t.eq({ a:names_list("species") }, { nil, "not_ready" })
end)

t.case("interface exposes the write helpers and their feature flags", function()
  local a = make({ rev = "v1.0", party = { { species = 25 } }, bag = { { 4, 1 } },
    bag_more = { medicine = { { 18, 3 } } } })
  local api = interface.new({ id = "pokemon_omega_ruby", name = "OR", gen = 6, system = "3ds", version = "or" }, {}, a)
  local f = api.info().features
  t.eq(f.edit_pokemon, true); t.eq(f.edit_money, true); t.eq(f.edit_items, true); t.eq(f.name_lists, true); t.eq(f.bag, true)
  t.eq({ api.encode_item("nope", 17, 5) }, { nil, "unknown_pouch" })
  t.ok(api.encode_item("medicine", 17, 5))
  t.ok(api.bag())
  t.ok(api.encode_money(10))
  t.ok(api.encode_pokemon({ kind = "team", slot = 1 }, { held_item = 1 }))
  t.eq(api.edit_limits().team_slots, 6)
end)

-- ---- bag: bag() and encode_item ----

local function sl(...) local o = {} for i, v in ipairs({ ... }) do o[i] = string.pack("<I2I2", v[1], v[2]) end return table.concat(o) end

t.case("bag(): reads every pouch from a synthetic bag, limits list the pouches", function()
  local a = make({ rev = "v1.0", party = { { species = 25 } }, bag = { { 17, 5 }, { 4, 10 } },
    bag_more = { key_items = { { 70, 1 } }, tms = { { 328, 1 }, { 330, 1 } }, medicine = { { 18, 3 } }, berries = { { 149, 7 } } } })
  local b = a:bag()
  t.eq(b.items, { { slot = 1, item = 17, count = 5 }, { slot = 2, item = 4, count = 10 } })
  t.eq(b.key_items, { { slot = 1, item = 70, count = 1 } })
  t.eq(#b.tms, 2); t.eq(b.tms[2].item, 330)
  t.eq(b.medicine[1].count, 3); t.eq(b.berries[1], { slot = 1, item = 149, count = 7 })
  local L = a:edit_limits()
  t.eq(L.item_count, 999); t.eq(L.pouches.items, { slots = 400, max_count = 999 })
  t.eq(L.pouches.key_items, { slots = 96, max_count = 1 }); t.eq(L.pouches.tms.slots, 108)
  t.eq(L.pouches.medicine.slots, 64); t.eq(L.pouches.berries.slots, 72)
  -- only the Items pouch mapped: the others are left out
  local c = make({ rev = "v1.4", party = { { species = 25 } }, bag = { { 4, 1 } } })
  local cb = c:bag()
  t.eq(#cb.items, 1); t.eq(cb.key_items, nil)
  t.eq({ make({ rev = "v1.0", party = { { species = 25 } }, bag = { { 900, 5 }, { 4, 2000 } } }):bag() }, { nil, "unsupported" })
  t.eq({ make({ rev = "v1.0", party = { { species = 25 } } }):bag() }, { nil, "not_ready" })
end)

t.case("encode_item: change, append and remove a slot, v1.0 and v1.4 addresses", function()
  for _, rev in ipairs({ "v1.0", "v1.4" }) do
    local base = mem.rev(rev).addr.bag
    local a = make({ rev = rev, party = { { species = 25 } }, bag = { { 17, 5 }, { 4, 10 }, { 3, 2 } } })
    local r = a:encode_item("items", 4, 99)
    t.eq(r.addr, base + 4); t.eq(r.bytes, sl({ 4, 99 })); t.eq(r.ops, { { addr = r.addr, bytes = r.bytes } }); t.eq(r.slot, 2)
    local n = a:encode_item("items", 20, 7) -- appended behind the three used slots
    t.eq(n.addr, base + 12); t.eq(n.bytes, sl({ 20, 7 })); t.eq(n.slot, 4)
    local rm = a:encode_item("items", 17, 0) -- removal compacts: slots 1..3 rewritten
    t.eq(rm.addr, base); t.eq(rm.bytes, sl({ 4, 10 }, { 3, 2 }, { 0, 0 }))
    t.eq(a:encode_item("items", 99, 0).warnings, { "unchanged" }) -- absent item, nothing to remove
    local same = a:encode_item("items", 3, 2)
    t.eq(same.warnings, { "unchanged" }); t.eq(same.bytes, sl({ 3, 2 })); t.eq(same.addr, base + 8)
  end
end)

t.case("encode_item: explicit slot, other pouch offsets", function()
  local a = make({ rev = "v1.0", party = { { species = 25 } }, bag = { { 17, 5 } },
    bag_more = { medicine = { { 18, 3 }, { 19, 4 } }, tms = { { 328, 1 } }, key_items = {}, berries = {} } })
  local r = a:encode_item("items", 4, 10, 2) -- first free slot
  t.eq(r.addr, V10.bag + 4); t.eq(r.bytes, sl({ 4, 10 }))
  local rep = a:encode_item("items", 3, 1, 1) -- replace slot 1
  t.eq(rep.addr, V10.bag); t.eq(rep.bytes, sl({ 3, 1 }))
  local m = a:encode_item("medicine", 19, 50)
  t.eq(m.addr, V10.bag + 0x970 + 4); t.eq(m.bytes, sl({ 19, 50 }))
  local k = a:encode_item("key_items", 70, 1)
  t.eq(k.addr, V10.bag + 0x640); t.eq(k.pouch, "key_items")
  t.eq(a:encode_item("tms", 329, 1).addr, V10.bag + 0x7C0 + 4)
  t.eq(a:encode_item("berries", 149, 999).addr, V10.bag + 0xA70)
  local rm = a:encode_item("medicine", 18, 0, 1)
  t.eq(rm.addr, V10.bag + 0x970); t.eq(rm.bytes, sl({ 19, 4 }, { 0, 0 }))
end)

t.case("encode_item: bounds answer nil plus a reason, nothing is guessed", function()
  local a = make({ rev = "v1.0", party = { { species = 25 } }, bag = { { 17, 5 } } })
  t.eq({ a:encode_item("pockets", 17, 1) }, { nil, "unknown_pouch" })
  t.eq({ a:encode_item(nil, 17, 1) }, { nil, "unknown_pouch" })
  t.eq({ a:encode_item("items", 0, 1) }, { nil, "invalid_item" })
  t.eq({ a:encode_item("items", 776, 1) }, { nil, "invalid_item" })
  t.eq({ a:encode_item("items", 1.5, 1) }, { nil, "invalid_item" })
  t.eq({ a:encode_item("items", 17, 1000) }, { nil, "invalid_count" })
  t.eq({ a:encode_item("items", 17, -1) }, { nil, "invalid_count" })
  t.eq({ a:encode_item("items", 17, "5") }, { nil, "invalid_count" })
  t.eq({ a:encode_item("key_items", 70, 2) }, { nil, "invalid_count" })
  t.eq({ a:encode_item("tms", 328, 2) }, { nil, "invalid_count" })
  t.eq({ a:encode_item("items", 17, 1, 0) }, { nil, "invalid_slot" })
  t.eq({ a:encode_item("items", 17, 1, 401) }, { nil, "invalid_slot" })
  t.eq({ a:encode_item("key_items", 70, 1, 97) }, { nil, "invalid_slot" })
  t.eq({ a:encode_item("items", 17, 1, 3) }, { nil, "invalid_slot" }) -- would leave a gap
  t.eq({ a:encode_item("items", 17, 0, 2) }, { nil, "invalid_slot" }) -- nothing to remove there
  -- full pouch
  local full = {}
  for i = 1, 400 do full[i] = { (i % 700) + 1, 1 } end
  local f = make({ rev = "v1.0", party = { { species = 25 } }, bag = full })
  t.eq({ f:encode_item("items", 775, 1) }, { nil, "pouch_full" })
  t.ok(f:encode_item("items", 5, 9)) -- existing item still changes
  -- garbage, unreadable
  t.eq({ make({ rev = "v1.0", party = { { species = 25 } }, bag = { { 900, 5 }, { 4, 2000 } } }):encode_item("items", 4, 1) },
    { nil, "unsupported" })
  t.eq({ make({ rev = "v1.0", party = { { species = 25 } } }):encode_item("items", 4, 1) }, { nil, "not_ready" })
  local e = make({ rev = "v1.0", party = { { species = 25 } }, bag = {} }):encode_item("items", 4, 1) -- empty pouch: append
  t.eq(e.addr, V10.bag); t.eq(e.bytes, sl({ 4, 1 }))
end)

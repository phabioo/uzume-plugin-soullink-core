-- Adapter for Pokemon Omega Ruby / Alpha Sapphire (3DS, Gen 6).
-- Addresses and formats with sources: docs/games/omega-ruby-alpha-sapphire.md.
-- Backs team (with live stats), boxes, trainer, badges, location, battle, encounters, names
-- (game text), zones/areas/locations (encdata), species_info (personal), icons and the region map.
local pk6 = require("gen6.pk6")
local growth = require("gen6.growth")
local personal = require("gen6.personal")
local icons = require("gen6.icons")
local maps = require("gen6.maps")
local addr = require("gen6.oras_addr")
local text = require("gen6.text")
local zones = require("gen6.zones")
local oras_battle = require("gen6.oras_battle")
local pk6_edit = require("gen6.pk6_edit")

local M = {}

M.PARTY_SLOTS = addr.PARTY_SLOTS
M.PARTY_STRIDE = addr.PARTY_STRIDE -- 0x1E4: encrypted PK6 (0xE8) at +0, encrypted party stats (22 bytes) at +0x158
M.STATS_OFFSET, M.STATS_LEN = 0x158, 22
M.PARTY_SIZE = pk6.SIZE_PARTY
M.BOX_COUNT = addr.BOX_COUNT
M.BOX_SLOTS = addr.BOX_SLOTS
M.BOX_SIZE = addr.BOX_SIZE
M.REVISIONS = addr.REVISIONS
M.NAME_START_TICK, M.NAME_STEP_EVERY = 20, 4   -- game text loading (ticks % 4 == 2)
M.ZONE_START_TICK, M.ZONE_STEP_EVERY = 30, 4   -- zone scan (ticks % 4 == 1)
M.ICON_START_TICK = 90 -- ticks before icon discovery starts
M.ICON_STEP_EVERY = 8  -- ticks between discovery steps
M.MAP_START_TICK = 120 -- map scan starts later; steps are offset from the other loaders
M.MAP_STEP_EVERY = 4 -- ticks % 4 == 3 (names 2, zones 1, icons 0 mod 8); a step is time-budgeted (maps.STEP_BUDGET_MS)
M.PERSONAL_START_TICK, M.PERSONAL_STEP_EVERY = 60, 30 -- personal table (growth, types) is loaded in the background
M.DETECT_EVERY = 5
M.CROSSCHECK_EVERY = 30
M.BADGE_POLL_EVERY = 15
M.ORIGIN_AS, M.ORIGIN_OR = 26, 27 -- PKHeX GameVersion (X 24, Y 25)
M.MAX_MONEY = 999999
M.MAX_STAT = 1500 -- upper bound for a stat or HP value (Blissey at level 100: 714)

-- MyStatus block offsets (PKHeX MyStatus6)
local MS_TID, MS_VERSION, MS_LANGUAGE, MS_OT = 0, 4, 0x2D, 0x48
-- Misc block offsets (PKHeX Misc6AO)
local MISC_MONEY, MISC_BADGES = 8, 0xC

-- Items pouch: Poke Ball item ids (PKHeX Legal ball items, recalled, not re-fetched): 1..16 (Master
-- to Cherish), 492..500 (Fast to Park), 576 (Dream). Sanity limits: PKHeX max item id 775, count 999.
M.BALL_IDS = { [576] = true }
for i = 1, 16 do M.BALL_IDS[i] = true end
for i = 492, 500 do M.BALL_IDS[i] = true end
M.MAX_ITEM_ID, M.MAX_ITEM_COUNT = 775, 999

-- Sanity of decrypted party stats (garbage decrypts almost never pass; an all-zero area decrypts to
-- garbage): level 1..100, 0 < max HP, HP <= max HP, every battle stat plausible.
function M.live_sane(x)
  if x.level < 1 or x.level > 100 or x.max_hp < 1 or x.max_hp > M.MAX_STAT or x.hp > x.max_hp then return false end
  for _, v in pairs(x.stats) do
    if v < 1 or v > M.MAX_STAT then return false end
  end
  return true
end

local function popcount(v)
  local n = 0
  while v ~= 0 do n = n + (v & 1); v = v >> 1 end
  return n
end

function M.attach(ctx)
  local uz = ctx.uz
  local pers = personal.new(uz)
  local icon_store = icons.new(uz, pers)
  local ticks = 0
  local map_store, names, zone_store, battle_mod
  local chosen
  local live_seen, checked = false, false
  local last_loc_key
  local last_badges
  local warned = {}

  local overrides = addr.load_overrides(uz)
  for _, line in ipairs(overrides.bad) do
    if uz.log and uz.log.warn then uz.log.warn("ignored address override line: " .. line) end
  end

  local sets = {}
  for i, rev in ipairs(addr.REVISIONS) do
    sets[i] = { name = rev.name, a = addr.resolve(rev, overrides), state = rev.state }
    for _, key in ipairs(addr.KEYS) do
      local a = sets[i].a[key]
      if a then uz.memory.watch("oras." .. rev.name .. "." .. key, a, addr.LENGTHS[key]) end
    end
  end

  local function warn_once(key, msg)
    if warned[key] then return end
    warned[key] = true
    if uz.log and uz.log.warn then uz.log.warn(msg) end
  end

  local function A(key) return chosen and chosen.a[key] or nil end

  -- Plain PK6 -> record, nil when invalid (checksum, species 1..721).
  local function decode(buf)
    if not (uz.codec and uz.codec.pk6_decrypt) then return nil end
    local plain, ok = uz.codec.pk6_decrypt(buf)
    if not plain or not ok then return nil end
    local rec = pk6.parse(plain)
    if not rec or rec.species < 1 or rec.species > pk6.MAX_SPECIES then return nil end
    return rec
  end

  local function read_record(base, size)
    local raw = uz.memory.bytes(base, size)
    if not raw or #raw < size then return nil end
    return decode(raw)
  end

  -- Live party slot: 0xE8 encrypted bytes at +0 and 22 encrypted party-stat bytes at +0x158 (a fresh
  -- stream seeded with the EC) are joined into the 260-byte save layout. Level, HP, max HP and
  -- status are taken only when they pass a sanity check. Returns record, live (bool).
  local function read_party_slot(base)
    local raw = uz.memory.bytes(base, 0xE8)
    if not raw or #raw < 0xE8 then return nil end
    local stats = uz.memory.bytes(base + M.STATS_OFFSET, M.STATS_LEN) or string.rep("\0", M.STATS_LEN)
    local buf = raw .. stats .. string.rep("\0", pk6.SIZE_PARTY - 0xE8 - M.STATS_LEN)
    local rec = decode(buf)
    if not rec then return nil end
    local x = rec.party_ext
    rec.party_ext = nil
    if x and M.live_sane(x) then
      rec.level, rec.hp, rec.max_hp, rec.status = x.level, x.hp, x.max_hp, x.status
      return rec, true
    end
    return rec, false
  end

  local function peek_name(kind, id)
    if names then
      local n = names.peek(kind, id)
      if type(n) == "string" then return n end
    end
    return nil
  end

  local function finish(rec)
    if rec.level == nil then
      local rate = pers.growth_rate(rec.species)
      if rate then rec.level = growth.level_from_exp(rate, rec.exp) end
    end
    rec.species_name = peek_name("species", rec.species)
    return rec
  end

  local function detect()
    if chosen then return chosen end
    for _, set in ipairs(sets) do
      if set.a.party and read_party_slot(set.a.party) then
        chosen = set
        for _, other in ipairs(sets) do
          if other ~= set then
            for _, key in ipairs(addr.KEYS) do
              if other.a[key] then uz.memory.unwatch("oras." .. other.name .. "." .. key) end
            end
          end
        end
        if uz.log and uz.log.info then uz.log.info("game revision " .. set.name) end
        return chosen
      end
    end
    return nil
  end

  local function u16(a) return a and uz.memory.u16(a) or nil end

  local function f32(a)
    local b = a and uz.memory.bytes(a, 4)
    if not b or #b < 4 then return nil end
    local v = string.unpack("<f", b)
    if v ~= v or v > 1e7 or v < -1e7 then return nil end
    return v
  end

  -- MyStatus block: { name, tid, sid, version, language_id, language } or nil.
  local function mystatus()
    local base = A("mystatus")
    local raw = base and uz.memory.bytes(base, 0x70)
    if not raw or #raw < 0x70 then return nil end
    local tid, sid = string.unpack("<I2I2", raw, MS_TID + 1)
    local lang_id = raw:byte(MS_LANGUAGE + 1)
    return {
      name = pk6.utf16le_to_utf8(raw:sub(MS_OT + 1, MS_OT + 0x1A), 12),
      tid = tid, sid = sid, version = raw:byte(MS_VERSION + 1),
      language_id = lang_id, language = pk6.LANGUAGES[lang_id],
    }
  end

  -- Own-origin party members must carry the trainer's TID, otherwise the revision (or the MyStatus
  -- address) is wrong. Runs until it had something to compare, logs a warning on a mismatch.
  local function crosscheck(team)
    if checked or not chosen then return end
    local ms = mystatus()
    if not ms or ms.name == "" then return end
    local cands, match = 0, false
    for _, r in ipairs(team) do
      if r.origin_game == M.ORIGIN_AS or r.origin_game == M.ORIGIN_OR then
        cands = cands + 1
        if r.ot_id == ms.tid then match = true end
      end
    end
    if cands == 0 then return end
    checked = true
    if not match then
      warn_once("crosscheck", "revision cross-check failed: MyStatus TID " .. ms.tid ..
        " matches no own party member; revision " .. chosen.name .. " or the mystatus address may be wrong")
    end
  end

  local function read_team()
    local set = detect()
    if not set then return nil end
    local out = {}
    for i = 1, M.PARTY_SLOTS do
      local rec, live = read_party_slot(set.a.party + (i - 1) * M.PARTY_STRIDE)
      if rec then
        rec.slot = i
        if live then live_seen = true end
        out[#out + 1] = finish(rec)
      end
    end
    return out
  end

  local obj = {}

  -- Language of the game: MyStatus language byte; heuristic fallback (party members of own origin).
  function obj:language()
    local ms = mystatus()
    if ms and ms.language then return ms.language end
    local team = read_team()
    if not team then return nil end
    local groups, order = {}, {}
    for _, r in ipairs(team) do
      if (r.origin_game == M.ORIGIN_AS or r.origin_game == M.ORIGIN_OR) and r.language then
        local key = r.ot_id .. ":" .. r.ot_sid
        if not groups[key] then groups[key] = { n = 0, first = r }; order[#order + 1] = key end
        groups[key].n = groups[key].n + 1
      end
    end
    local best
    for _, key in ipairs(order) do
      if not best or groups[key].n > best.n then best = groups[key] end
    end
    return best and best.first.language or nil
  end

  names = text.new(uz, { language_fn = function() return obj:language() end })
  zone_store = zones.new(uz, {
    name = function(kind, id) return names.peek(kind, id) end,
    names_state = function() return names.state() end,
  })
  map_store = maps.new(uz, ctx.game and ctx.game.id, function() return chosen and chosen.name end)

  function obj:revision()
    local set = detect()
    if not set then return nil, "not_ready" end
    return set.name
  end

  local function location_info(quiet)
    local set = detect()
    if not set then return nil, "not_ready" end
    local a = A("map_id")
    if not a then return nil, "unsupported" end
    local zone = u16(a)
    if zone == nil then return nil, "not_ready" end
    local out = { zone = zone, source = "memory", x = f32(A("player_x")), y = f32(A("player_y")) }
    local zi = zone_store.zone_info(zone, quiet)
    if zi then out.location, out.name = zi.location, zi.name end
    return out
  end

  local function poll()
    if not chosen then return end
    local loc = location_info(true)
    if loc then
      local key = loc.zone .. ":" .. tostring(loc.location) .. ":" .. tostring(loc.name)
      if key ~= last_loc_key then
        last_loc_key = key
        uz.events.emit("location.changed", loc)
      end
    end
    if ticks % M.BADGE_POLL_EVERY == 0 then
      local misc = A("misc")
      local b = misc and uz.memory.u8(misc + MISC_BADGES)
      if b then
        if last_badges ~= nil and b ~= last_badges then
          local new = {}
          for i = 1, 8 do
            if (b >> (i - 1)) & 1 == 1 and (last_badges >> (i - 1)) & 1 == 0 then new[#new + 1] = i end
          end
          uz.events.emit("badges.changed", { count = popcount(b), new = new })
        end
        last_badges = b
      end
    end
    if battle_mod then battle_mod.poll() end
    if not checked and ticks % M.CROSSCHECK_EVERY == 0 then
      local team = read_team()
      if team then crosscheck(team) end
    end
  end

  local function position()
    return u16(A("map_id")), f32(A("player_x")), f32(A("player_y"))
  end

  battle_mod = oras_battle.new(uz, {
    addr = A,
    read_slot = function(base)
      local rec = read_party_slot(base)
      if rec then rec = finish(rec) end
      return rec
    end,
    position = position,
    species_name = function(species) return peek_name("species", species) end,
    team = read_team,
    location_id = function(zone)
      local zi = zone_store.zone_info(zone, true)
      return zi and zi.location or nil
    end,
  })

  -- Called every tick by main.lua: bounded background work and the state tracking.
  function obj:tick()
    ticks = ticks + 1
    if not chosen and ticks % M.DETECT_EVERY == 0 then detect() end
    if ticks >= M.NAME_START_TICK and ticks % M.NAME_STEP_EVERY == 2 then names.step() end
    if ticks >= M.ZONE_START_TICK and ticks % M.ZONE_STEP_EVERY == 1 then zone_store.step() end
    if ticks >= M.PERSONAL_START_TICK and ticks % M.PERSONAL_STEP_EVERY == 0 then pers.growth_rate(1) end
    if ticks >= M.MAP_START_TICK and ticks % M.MAP_STEP_EVERY == 3 then
      map_store.step()
    end
    if ticks >= M.ICON_START_TICK and ticks % M.ICON_STEP_EVERY == 0 and icon_store.state() ~= "done" then
      icon_store.step()
    end
    if icon_store.state() ~= "idle" and icon_store.state() ~= "scan" and not icon_store.export_done() then
      icon_store.export_step(function()
        local team = chosen and read_team()
        local out = {}
        for _, r in ipairs(team or {}) do out[#out + 1] = r.species end
        return out
      end)
    end
    local ok, err = pcall(poll)
    if not ok then warn_once("poll", "tracking failed: " .. tostring(err)) end
  end

  -- Feature overrides: depend on runtime state (icons found, names loaded, ...).
  function obj:features()
    local any_map, any_battle = false, false
    for _, set in ipairs(sets) do
      if set.a.map_id then any_map = true end
      if set.a.battle_wild_foes or set.a.battle_trainer_foes then any_battle = true end
    end
    return {
      icons = icon_store.found(), map = map_store.found(), names = names.ready(), areas = zone_store.found(),
      locations = zone_store.has_locations() or (zone_store.state() ~= "idle" and zone_store.state() ~= "scan" and
        names.count("location") > 0),
      live_stats = live_seen, location = chosen and A("map_id") ~= nil or (not chosen and any_map),
      battle = chosen and battle_mod.available() or (not chosen and any_battle),
      encounters = chosen and battle_mod.available() or (not chosen and any_battle),
    }
  end

  function obj:icon_rev() return icon_store.icon_rev() end
  function obj:icon(species, form) return icon_store.icon(species, form) end
  function obj:icon_variants(species, form) return icon_store.icon_variants(species, form) end
  function obj:map_candidates() return map_store.candidates() end
  function obj:map_image(id) return map_store.image(id) end
  function obj:map_selected() return map_store.selected() end

  function obj:name(kind, id) return names.name(kind, id) end
  function obj:areas() return zone_store.areas() end

  -- Places for a picker. The zone scan is the source; when it is unsupported, failed or found no
  -- location, every non-empty entry of the game's location text is listed instead (source = "text",
  -- no zones, no encounter flag). A list is only returned together with its names.
  function obj:locations()
    local list, why = zone_store.locations()
    if list and #list > 0 then
      for _, l in ipairs(list) do l.source = "zones" end
      list.source = "zones"
      return list
    end
    if why == "not_ready" then return nil, why end
    -- the zone scan is over (done empty, unsupported) or failing (retrying): use the text
    local tl, twhy = names.list("location")
    if not tl then return nil, twhy == "no_lines" and "unsupported" or twhy end
    local out = { source = "text" }
    for i, e in ipairs(tl) do
      out[i] = { id = e.id, name = e.name, zones = {}, has_encounters = false, source = "text" }
    end
    return out
  end

  function obj:diagnostics()
    local d = zone_store.diagnostics()
    for k, v in pairs(names.diagnostics()) do d[k] = v end
    for k, v in pairs(pers.diagnostics()) do d[k] = v end
    for k, v in pairs(icon_store.diagnostics()) do d[k] = v end
    for k, v in pairs(map_store.diagnostics()) do d[k] = v end
    d.locations_source = d.locations > 0 and "zones" or (names.count("location") > 0 and "text" or "none")
    d.revision = chosen and chosen.name or "none"
    local ok, lang = pcall(obj.language, obj)
    d.language = ok and lang or "unknown"
    return d
  end
  function obj:zone_info(zone) return zone_store.zone_info(zone) end

  function obj:species_info(species, form)
    if not pers.growth_rate(1) then return nil, "not_ready" end
    return pers.info(species, form or 0)
  end

  function obj:location() return location_info(false) end

  function obj:team()
    local team = read_team()
    if not team then return nil, "not_ready" end
    crosscheck(team)
    return team
  end

  function obj:trainer()
    local set = detect()
    if not set then return nil, "not_ready" end
    local ms = mystatus()
    if not ms or ms.name == "" then return nil, "not_ready" end
    local out = {
      name = ms.name, tid = ms.tid, sid = ms.sid, version = ms.version, language = ms.language,
    }
    local misc = A("misc")
    if misc then
      local money = uz.memory.u32(misc + MISC_MONEY)
      if money and money <= M.MAX_MONEY then out.money = money end
      local b = uz.memory.u8(misc + MISC_BADGES)
      if b then out.badges = popcount(b) end
    end
    local pt = A("play_time")
    local raw = pt and uz.memory.bytes(pt, 4)
    if raw and #raw == 4 then
      local h, m, s = string.unpack("<I2I1I1", raw)
      if m < 60 and s < 60 then out.play_time = { h = h, m = m, s = s } end
    end
    return out
  end

  function obj:badges()
    local set = detect()
    if not set then return nil, "not_ready" end
    local misc = A("misc")
    if not misc then return nil, "unsupported" end
    local b = uz.memory.u8(misc + MISC_BADGES)
    if b == nil then return nil, "not_ready" end
    local flags = {}
    for i = 1, 8 do flags[i] = (b >> (i - 1)) & 1 == 1 end
    return { count = popcount(b), flags = flags }
  end

  -- Poke Ball count in the Items pouch (400 slots of u16 id, u16 count, packed from slot 0).
  function obj:balls()
    if not detect() then return nil, "not_ready" end
    local bag = A("bag")
    if not bag then return nil, "unsupported" end
    local raw = uz.memory.bytes(bag, addr.BAG_SLOTS * 4)
    if not raw or #raw < addr.BAG_SLOTS * 4 then return nil, "not_ready" end
    local valid, invalid, balls = 0, 0, 0
    for i = 0, addr.BAG_SLOTS - 1 do
      local id, ct = string.unpack("<I2I2", raw, i * 4 + 1)
      if id == 0 then break end -- the pouch is packed, the first empty slot ends it
      if id > M.MAX_ITEM_ID or ct == 0 or ct > M.MAX_ITEM_COUNT then
        invalid = invalid + 1
      else
        valid = valid + 1
        if M.BALL_IDS[id] then balls = balls + ct end
      end
    end
    -- Mostly implausible slots: wrong address or stale memory, better no answer than a wrong number.
    if invalid > 0 and invalid >= valid then return nil, "unsupported" end
    return { count = balls }
  end

  -- Event flag n (0..0xCFF) of the save, or nil. Not part of the interface yet.
  function obj:event_flag(n)
    if not detect() then return nil end
    local base = A("event_flags")
    if not base or math.type(n) ~= "integer" or n < 0 or n >= 0xD00 then return nil end
    local b = uz.memory.u8(base + (n >> 3))
    if b == nil then return nil end
    return (b >> (n & 7)) & 1 == 1
  end

  function obj:battle()
    if not detect() then return nil, "not_ready" end
    if not battle_mod.available() then return nil, "unsupported" end
    local b = battle_mod.battle()
    if b.active then
      for _, f in ipairs(b.foes) do f.species_name = peek_name("species", f.species) end
      for _, o in ipairs(b.own) do o.species_name = peek_name("species", o.species) end
    end
    return b
  end

  function obj:encounters()
    if not detect() then return nil, "not_ready" end
    if not battle_mod.available() then return nil, "unsupported" end
    local list = battle_mod.encounters()
    for _, e in ipairs(list) do e.species_name = peek_name("species", e.species) end
    return list
  end

  -- ---- write helpers (build write operations only, nothing is written here) ----

  function obj:edit_limits()
    local L = pk6_edit.LIMITS
    local out = {}
    for k, v in pairs(L) do out[k] = v end
    out.money = M.MAX_MONEY
    out.team_slots, out.boxes, out.box_slots = M.PARTY_SLOTS, M.BOX_COUNT, M.BOX_SLOTS
    return out
  end

  function obj:names_list(kind)
    return names.list(kind)
  end

  -- Location: { kind = "team", slot = 1..6 } or { kind = "box", box = 1..31, slot = 1..30 }.
  -- Returns { addr, bytes, ops = { {addr, bytes}, ... }, warnings = { ... }, record = <new record> }:
  -- apply every op of `ops` in order with uz.memory.write. `addr`/`bytes` are the first op. Errors:
  -- nil, "not_ready" | "invalid_location" | "empty_slot" | "growth_unavailable" | "invalid_<field>" |
  -- "ev_total" | "unknown_field:<name>".
  function obj:encode_pokemon(location, fields)
    local set = detect()
    if not set then return nil, "not_ready" end
    if type(location) ~= "table" or type(fields) ~= "table" then return nil, "invalid_location" end
    local base, size, live_ext, ext_raw
    local plain, ok
    if location.kind == "team" then
      local slot = location.slot
      if not (math.type(slot) == "integer" and slot >= 1 and slot <= M.PARTY_SLOTS) then return nil, "invalid_location" end
      base = set.a.party + (slot - 1) * M.PARTY_STRIDE
      local raw = uz.memory.bytes(base, 0xE8)
      if not raw or #raw < 0xE8 then return nil, "not_ready" end
      ext_raw = uz.memory.bytes(base + M.STATS_OFFSET, M.STATS_LEN)
      if ext_raw and #ext_raw == M.STATS_LEN then
        local p2, ok2 = pk6.decrypt(raw .. ext_raw .. string.rep("\0", pk6.SIZE_PARTY - 0xE8 - M.STATS_LEN))
        local r2 = ok2 and pk6.parse(p2)
        if r2 and r2.party_ext and M.live_sane(r2.party_ext) then plain, ok, live_ext = p2, ok2, true end
      end
      if not plain then plain, ok = pk6.decrypt(raw .. string.rep("\0", 232 - 0xE8)) end
      size = 0xE8
    elseif location.kind == "box" then
      local b, s = location.box, location.slot
      if not (math.type(b) == "integer" and b >= 1 and b <= M.BOX_COUNT and math.type(s) == "integer" and s >= 1 and
        s <= M.BOX_SLOTS) then
        return nil, "invalid_location"
      end
      base = set.a.box + ((b - 1) * M.BOX_SLOTS + (s - 1)) * M.BOX_SIZE
      local raw = uz.memory.bytes(base, M.BOX_SIZE)
      if not raw or #raw < M.BOX_SIZE then return nil, "not_ready" end
      plain, ok = pk6.decrypt(raw)
      size = M.BOX_SIZE
    else
      return nil, "invalid_location"
    end
    local rec = ok and pk6.parse(plain)
    if not rec or rec.species < 1 or rec.species > pk6.MAX_SPECIES then return nil, "empty_slot" end
    local level
    if live_ext then level = rec.party_ext.level else
      local rate = pers.growth_rate(rec.species)
      level = rate and growth.level_from_exp(rate, rec.exp) or nil
    end
    local new, warnings = pk6_edit.apply(plain, fields, {
      growth_rate = pers.growth_rate,
      base_stats = function(sp, form)
        return (pers.base_stats(sp, form))
      end,
      species_name = function(id) return peek_name("species", id) end,
      current_level = level,
    })
    if not new then return nil, warnings end
    local enc = pk6.seal(new)
    local ops = { { addr = base, bytes = enc:sub(1, size) } }
    if live_ext then ops[2] = { addr = base + M.STATS_OFFSET, bytes = enc:sub(0xE9, 0xE8 + M.STATS_LEN) } end
    local record = pk6.parse(new)
    if record and not live_ext then record.party_ext = nil end
    return { addr = ops[1].addr, bytes = ops[1].bytes, ops = ops, warnings = warnings, record = record }
  end

  -- Money (0..999999) at misc + 8.
  function obj:encode_money(value)
    local set = detect()
    if not set then return nil, "not_ready" end
    if not (math.type(value) == "integer" and value >= 0 and value <= M.MAX_MONEY) then return nil, "invalid_money" end
    local misc = A("misc")
    if not misc then return nil, "unsupported" end
    local bytes = string.pack("<I4", value)
    return { addr = misc + MISC_MONEY, bytes = bytes, ops = { { addr = misc + MISC_MONEY, bytes = bytes } }, warnings = {} }
  end

  function obj:box_count()
    if not detect() then return nil, "not_ready" end
    return M.BOX_COUNT
  end

  function obj:box(n)
    local set = detect()
    if not set then return nil, "not_ready" end
    if math.type(n) ~= "integer" or n < 1 or n > M.BOX_COUNT then return nil, "out_of_range" end
    local base = set.a.box + (n - 1) * M.BOX_SLOTS * M.BOX_SIZE
    if not uz.memory.bytes(base, M.BOX_SLOTS * M.BOX_SIZE) then return nil, "not_ready" end
    local out = {}
    for s = 1, M.BOX_SLOTS do
      local rec = read_record(base + (s - 1) * M.BOX_SIZE, M.BOX_SIZE)
      if rec then rec.slot = s; rec.box = n; out[#out + 1] = finish(rec) end
    end
    return out
  end

  return obj
end

return M

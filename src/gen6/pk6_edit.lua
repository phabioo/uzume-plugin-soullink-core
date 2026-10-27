-- Pure editing of a decrypted PK6 (232/260 bytes): validation, field writes, EXP from level, PID shiny
-- adjustment, party-extension stats. No memory access. Offsets: gen6.pk6 (PKHeX PK6.cs).
-- Moves PP 0x62 (4 x u8), PP ups 0x66 (4 x u8), nickname 0x40 (13 UTF-16 units) are from the same file.
local pk6 = require("gen6.pk6")
local growth = require("gen6.growth")

local M = {}

-- ORAS maxima (PKHeX Legal.cs: MaxSpeciesID_6 721, MaxMoveID_6_AO 617, MaxItemID_6_AO 775,
-- MaxAbilityID_6_AO 191), recalled, not re-fetched.
M.LIMITS = {
  species = 721, move = 617, item = 775, ability = 191, nature = 24, form = 31, level = 100,
  iv = 31, ev = 255, ev_total = 510, moves = 4, pp = 64, nickname = 12,
}
M.DEFAULT_PP = 5 -- placeholder for a new move when the caller gives no PP (lowest base PP in Gen 6)

local STATS = { "hp", "atk", "def", "spe", "spa", "spd" }
M.STATS = STATS
local KNOWN = { species = true, form = true, level = true, nature = true, ivs = true, evs = true, moves = true,
  pp = true, shiny = true, held_item = true, nickname = true, ability = true }

local function isint(v, lo, hi) return math.type(v) == "integer" and v >= lo and v <= hi end

local OFF = pk6.OFF
local OFF_PP, OFF_PPUPS = 0x62, 0x66

-- Validates `fields` against `rec` (the parsed current record). Returns nil or an error string
-- ("invalid_<field>", "ev_total", "unknown_field:<name>").
function M.validate(fields, rec)
  local L = M.LIMITS
  if type(fields) ~= "table" then return "invalid_fields" end
  for k in pairs(fields) do
    if not KNOWN[k] then return "unknown_field:" .. tostring(k) end
  end
  if fields.species ~= nil and not isint(fields.species, 1, L.species) then return "invalid_species" end
  if fields.form ~= nil and not isint(fields.form, 0, L.form) then return "invalid_form" end
  if fields.level ~= nil and not isint(fields.level, 1, L.level) then return "invalid_level" end
  if fields.nature ~= nil and not isint(fields.nature, 0, L.nature) then return "invalid_nature" end
  if fields.held_item ~= nil and not isint(fields.held_item, 0, L.item) then return "invalid_item" end
  if fields.ability ~= nil and not isint(fields.ability, 1, L.ability) then return "invalid_ability" end
  if fields.shiny ~= nil and type(fields.shiny) ~= "boolean" then return "invalid_shiny" end
  if fields.nickname ~= nil then
    if type(fields.nickname) ~= "string" or not utf8.len(fields.nickname) or utf8.len(fields.nickname) > L.nickname then
      return "invalid_nickname"
    end
  end
  for _, key in ipairs({ "ivs", "evs" }) do
    local t = fields[key]
    if t ~= nil then
      if type(t) ~= "table" then return "invalid_" .. key end
      local hi = key == "ivs" and L.iv or L.ev
      for k, v in pairs(t) do
        local known = false
        for _, s in ipairs(STATS) do if s == k then known = true end end
        if not known or not isint(v, 0, hi) then return "invalid_" .. key end
      end
    end
  end
  if fields.evs ~= nil then
    local total = 0
    for _, s in ipairs(STATS) do total = total + (fields.evs[s] or (rec and rec.evs[s]) or 0) end
    if total > L.ev_total then return "ev_total" end
  end
  if fields.moves ~= nil then
    local m = fields.moves
    if type(m) ~= "table" or #m < 1 or #m > L.moves then return "invalid_moves" end
    local seen = {}
    for i = 1, #m do
      if not isint(m[i], 1, L.move) or seen[m[i]] then return "invalid_moves" end
      seen[m[i]] = true
    end
    for k in pairs(m) do
      if math.type(k) ~= "integer" or k < 1 or k > #m then return "invalid_moves" end
    end
  end
  if fields.pp ~= nil then
    if type(fields.pp) ~= "table" then return "invalid_pp" end
    for i = 1, L.moves do
      local v = fields.pp[i]
      if v ~= nil and not isint(v, 0, L.pp) then return "invalid_pp" end
    end
  end
  return nil
end

-- Battle stats from base stats, IVs, EVs, level and nature (Bulbapedia "Stat"; integer division).
function M.compute_stats(base, ivs, evs, level, nature)
  local out = {}
  for _, s in ipairs(STATS) do
    local core = (2 * base[s] + ivs[s] + evs[s] // 4) * level // 100
    if s == "hp" then
      out.hp = core + level + 10
    else
      out[s] = core + 5
    end
  end
  -- nature n: +stat n // 5, -stat n % 5 over atk def spe spa spd
  local order = { "atk", "def", "spe", "spa", "spd" }
  local up, down = order[nature // 5 + 1], order[nature % 5 + 1]
  if up ~= down then
    out[up] = out[up] * 11 // 10
    out[down] = out[down] * 9 // 10
  end
  return out
end

local function patch(s, off, bytes) return s:sub(1, off) .. bytes .. s:sub(off + #bytes + 1) end

-- Applies `fields` to the decrypted structure `plain` (checksum is NOT recomputed here).
-- ctx (all optional): growth_rate(species) -> 0..5, base_stats(species, form) -> {hp,atk,def,spe,spa,spd},
-- species_name(id) -> string, current_level (the level the structure shows now).
-- Returns new_plain, warnings (list of strings) or nil, error.
function M.apply(plain, fields, ctx)
  ctx = ctx or {}
  local rec = pk6.parse(plain)
  if not rec then return nil, "bad_structure" end
  local err = M.validate(fields, rec)
  if err then return nil, err end
  local warnings = {}
  local function warn(w) warnings[#warnings + 1] = w end
  local out = plain

  local species = fields.species or rec.species
  local species_changed = species ~= rec.species
  local form = fields.form or (species_changed and 0 or rec.form)

  -- species / form
  if species_changed then out = patch(out, OFF.species, string.pack("<I2", species)) end
  if species_changed or fields.form ~= nil then
    local flags = out:byte(OFF.flags + 1)
    out = patch(out, OFF.flags, string.char((flags & 0x07) | (form << 3)))
  end
  if species_changed then
    warn("ability_unchanged")
    if not rec.nicknamed and fields.nickname == nil and ctx.species_name then
      local n = ctx.species_name(species)
      if type(n) == "string" and n ~= "" and utf8.len(n) then
        out = patch(out, OFF.nickname, pk6.utf8_to_utf16le(n, 13))
      end
    end
  end

  -- level -> EXP (rate of the final species)
  local target_level = fields.level
  if target_level == nil and species_changed then target_level = ctx.current_level end
  local current_level = ctx.current_level
  if target_level and (target_level ~= current_level or species_changed) then
    local rate = ctx.growth_rate and ctx.growth_rate(species)
    if rate then
      out = patch(out, OFF.exp, string.pack("<I4", growth.exp_for_level(rate, target_level)))
    elseif fields.level ~= nil and fields.level ~= current_level then
      return nil, "growth_unavailable"
    else
      warn("exp_unchanged")
    end
  end

  if fields.nature ~= nil then out = patch(out, OFF.nature, string.char(fields.nature)) end
  if fields.ability ~= nil then out = patch(out, OFF.ability, string.char(fields.ability)) end
  if fields.held_item ~= nil then out = patch(out, OFF.held_item, string.pack("<I2", fields.held_item)) end

  if fields.nickname ~= nil then
    out = patch(out, OFF.nickname, pk6.utf8_to_utf16le(fields.nickname, 13))
    local iv32 = string.unpack("<I4", out, OFF.iv32 + 1)
    iv32 = fields.nickname ~= "" and (iv32 | (1 << 31)) or (iv32 & ~(1 << 31) & 0xFFFFFFFF)
    out = patch(out, OFF.iv32, string.pack("<I4", iv32))
  end

  if fields.evs then
    local b = {}
    for i, s in ipairs(STATS) do b[i] = string.char(fields.evs[s] or rec.evs[s]) end
    out = patch(out, OFF.evs, table.concat(b))
  end
  if fields.ivs then
    local iv32 = string.unpack("<I4", out, OFF.iv32 + 1)
    for i, s in ipairs(STATS) do
      if fields.ivs[s] ~= nil then
        iv32 = (iv32 & ~(0x1F << (5 * (i - 1))) & 0xFFFFFFFF) | (fields.ivs[s] << (5 * (i - 1)))
      end
    end
    out = patch(out, OFF.iv32, string.pack("<I4", iv32))
  end

  -- moves + PP
  if fields.moves then
    local old_ids, old_pp, old_up = {}, {}, {}
    for i = 0, 3 do
      old_ids[i + 1] = string.unpack("<I2", plain, OFF.moves + i * 2 + 1)
      old_pp[i + 1] = plain:byte(OFF_PP + i + 1)
      old_up[i + 1] = plain:byte(OFF_PPUPS + i + 1)
    end
    local ids, pps, ups = {}, {}, {}
    local unknown_pp = false
    for i = 1, 4 do
      local id = fields.moves[i] or 0
      ids[i] = string.pack("<I2", id)
      if id == 0 then
        pps[i], ups[i] = "\0", "\0"
      elseif id == old_ids[i] and (fields.pp == nil or fields.pp[i] == nil) then
        pps[i], ups[i] = string.char(old_pp[i]), string.char(old_up[i])
      else
        local pp = fields.pp and fields.pp[i]
        if pp == nil then pp = M.DEFAULT_PP; unknown_pp = true end
        pps[i] = string.char(pp)
        ups[i] = (id == old_ids[i]) and string.char(old_up[i]) or "\0"
      end
    end
    out = patch(out, OFF.moves, table.concat(ids))
    out = patch(out, OFF_PP, table.concat(pps))
    out = patch(out, OFF_PPUPS, table.concat(ups))
    if unknown_pp then warn("pp_unknown") end
  elseif fields.pp then
    local pps = {}
    for i = 1, 4 do
      local id = string.unpack("<I2", out, OFF.moves + (i - 1) * 2 + 1)
      local v = fields.pp[i]
      pps[i] = string.char(v ~= nil and id ~= 0 and v or out:byte(OFF_PP + i))
    end
    out = patch(out, OFF_PP, table.concat(pps))
  end

  -- shiny: only the high PID half changes (gender, which uses the low byte, stays)
  if fields.shiny ~= nil then
    local tid, sid = string.unpack("<I2I2", out, OFF.tid + 1)
    local pid = string.unpack("<I4", out, OFF.pid + 1)
    local lo, hi = pid & 0xFFFF, pid >> 16
    local is_shiny = (tid ~ sid ~ hi ~ lo) < 16
    if fields.shiny and not is_shiny then
      hi = tid ~ sid ~ lo ~ ((hi ~ lo) & 7) -- star shiny, xor 0..7 (keeps some variety of the old PID)
    elseif not fields.shiny and is_shiny then
      hi = tid ~ sid ~ lo ~ 0x10 -- xor 16: not shiny
    end
    out = patch(out, OFF.pid, string.pack("<I4", (hi << 16) | lo))
  end

  -- party extension (live level and stats), only for a 260 byte structure
  if #out == pk6.SIZE_PARTY then
    local new = pk6.parse(out)
    local ext = rec.party_ext
    local level = fields.level or ctx.current_level
    local relevant = fields.level ~= nil or fields.species ~= nil or fields.form ~= nil or fields.nature ~= nil or
      fields.ivs ~= nil or fields.evs ~= nil
    if level and ext and relevant then
      out = patch(out, OFF.level, string.char(level))
      local base = ctx.base_stats and ctx.base_stats(new.species, new.form)
      if base then
        local st = M.compute_stats(base, new.ivs, new.evs, level, new.nature)
        local hp = ext.hp or st.hp
        if hp > st.hp or species_changed then hp = st.hp end
        out = patch(out, OFF.hp, string.pack("<I2I2", hp, st.hp))
        out = patch(out, OFF.stats, string.pack("<I2I2I2I2I2", st.atk, st.def, st.spe, st.spa, st.spd))
      else
        warn("stats_stale")
      end
    end
  end
  return out, warnings
end

return M

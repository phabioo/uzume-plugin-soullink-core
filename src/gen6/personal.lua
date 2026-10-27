-- Growth rate per species, read at runtime from the user's own game files
-- (RomFS personal GARC). Nothing from the game is shipped or persisted; the
-- values live in a Lua table cache only.
--
-- ORAS personal data (community-documented, all to verify locally):
--   path  : candidates "/a/1/9/5" and "/a/1/9/6", tried in order; the first one
--           whose data validates as a personal table is used (see validate)
--   entry : 0x50 bytes per species (PKHeX PersonalInfoORAS), index = Dex number
--   growth: byte 0x15 of the entry (PersonalInfoORAS.EXPGrowth), values 0..5
--   types : bytes 0x06 / 0x07 (Type1 / Type2, same value = single type)
-- /a/1/9/5 is the confirmed ORAS path (pk3DS GARCReference); the LAST GARC file holds the whole
-- table concatenated (pk3DS GameConfig). Accepted shapes: the last file (or the only one) with
-- length % 0x50 == 0 and >= 722 entries, or >= 722 files of 0x50 bytes (file species + 1 is the
-- entry of that species).
local garc_entry = require("gen6.garc_entry")
local M = {}

M.CANDIDATE_PATHS = { "/a/1/9/5", "/a/1/9/6" }
M.TYPE_OFFSET = 0x06 -- Type1, Type2 follows
M.ENTRY_SIZE = 0x50
M.GROWTH_OFFSET = 0x15
M.BASE_STATS_OFFSET = 0x00 -- 6 bytes HP, Atk, Def, Spe, SpA, SpD (PKHeX PersonalInfo, recalled, not verified on a device)
M.FORM_INDEX_OFFSET = 0x1C -- u16 FormStatsIndex (PKHeX PersonalInfoXY/ORAS), 0 = no extra forms
M.FORM_COUNT_OFFSET = 0x20 -- u8 FormeCount
M.MIN_ENTRIES = 722 -- species 0..721
M.MAX_ATTEMPTS = 3

function M.new(fb, opts)
  opts = opts or {}
  local paths = opts.paths or M.CANDIDATE_PATHS
  local esize = opts.entry_size or M.ENTRY_SIZE
  local goff = opts.growth_offset or M.GROWTH_OFFSET
  local self = {}
  local rates, forms, attempts = nil, nil, 0
  local whole_data, garc_data -- entry source: concatenated table, or the GARC itself
  local first_reject = nil
  local function reject(why) if not first_reject then first_reject = why end end

  local function form_info(e, out_forms, s)
    local idx = string.unpack("<I2", e, M.FORM_INDEX_OFFSET + 1)
    local cnt = e:byte(M.FORM_COUNT_OFFSET + 1)
    out_forms[s] = { index = idx, count = cnt }
  end

  -- Returns a table species -> rate (1..721), a table species -> {index, count} and the source of
  -- the entries ("whole", string | "files"), or nil when data is not a personal table.
  local function validate(data)
    local g, gerr = fb.codec.garc(data)
    if type(g) ~= "table" or type(g.count) ~= "number" then
      reject("garc_rejected: " .. (tostring(gerr):gsub("[^%w _%.:%-]", "?"):sub(1, 40)))
      return nil
    end
    local out, fo = {}, {}
    local whole
    local last = garc_entry.entry(fb.codec, data, g.count)
    if type(last) == "string" and #last % esize == 0 and #last // esize >= M.MIN_ENTRIES then whole = last end
    if whole then
      for s = 1, M.MIN_ENTRIES - 1 do
        local r = whole:byte(s * esize + goff + 1)
        if not r or r > 5 then reject("growth_invalid"); return nil end
        out[s] = r
        form_info(whole:sub(s * esize + 1, s * esize + esize), fo, s)
      end
      return out, fo, whole
    elseif g.count >= M.MIN_ENTRIES then
      for s = 1, M.MIN_ENTRIES - 1 do
        local e = garc_entry.entry(fb.codec, data, s + 1)
        if type(e) ~= "string" or #e ~= esize then reject("entry_size"); return nil end
        local r = e:byte(goff + 1)
        if r > 5 then return nil end
        out[s] = r
        form_info(e, fo, s)
      end
      return out, fo, nil
    end
    reject("table_shape")
    return nil
  end

  local function load()
    if rates then return true end
    if attempts >= M.MAX_ATTEMPTS then return false end
    attempts = attempts + 1
    if not (fb and fb.rom and fb.rom.romfs and fb.codec and fb.codec.garc and fb.codec.garc_file) then
      return false
    end
    for _, path in ipairs(paths) do
      local data = fb.rom.romfs(path)
      if type(data) ~= "string" then reject("romfs_unreadable") end
      if type(data) == "string" then
        local r, fo, whole = validate(data)
        if r then
          rates, forms, whole_data, garc_data = r, fo, whole, data
          self.path = path
          if fb.log and fb.log.info then fb.log.info("personal data accepted at " .. path) end
          return true
        end
      end
    end
    return false
  end

  -- Growth rate 0..5 for a species (Dex number 1..721), or nil.
  function self.growth_rate(species)
    if math.type(species) ~= "integer" or species < 1 then return nil end
    if not load() then return nil end
    return rates[species]
  end

  -- Personal-table index of a species form (assumption, see docs): form 0 is the
  -- species itself; form f > 0 is FormStatsIndex + f - 1 when 0 < f < FormeCount.
  -- Returns the index, or nil, "not_ready" (table not readable) / "no_form".
  function self.form_index(species, form)
    if math.type(species) ~= "integer" or species < 1 or species >= M.MIN_ENTRIES then
      return nil, "no_form"
    end
    form = form or 0
    if form == 0 then return species end
    if not load() then return nil, "not_ready" end
    local f = forms[species]
    if not f or f.index == 0 or form < 0 or form >= f.count then return nil, "no_form" end
    return f.index + form - 1
  end

  -- Raw personal entry of a table index, or nil.
  local function raw_entry(idx)
    if whole_data then
      local e = whole_data:sub(idx * esize + 1, idx * esize + esize)
      return #e == esize and e or nil
    end
    local e = garc_entry.entry(fb.codec, garc_data, idx + 1)
    return (type(e) == "string" and #e == esize) and e or nil
  end

  -- { types = { t1, t2 }, growth } of a species form, or nil, "not_ready" | "unknown_species" | "no_form".
  function self.info(species, form)
    if math.type(species) ~= "integer" or species < 1 or species >= M.MIN_ENTRIES then
      return nil, "unknown_species"
    end
    local idx, err = self.form_index(species, form)
    if not idx then return nil, err end
    local e = raw_entry(idx)
    if not e then return nil, "no_form" end
    return { types = { e:byte(M.TYPE_OFFSET + 1), e:byte(M.TYPE_OFFSET + 2) }, growth = e:byte(goff + 1) }
  end

  -- { hp, atk, def, spe, spa, spd } base stats of a species form, or nil, "not_ready" | "unknown_species" | "no_form".
  function self.base_stats(species, form)
    if math.type(species) ~= "integer" or species < 1 or species >= M.MIN_ENTRIES then
      return nil, "unknown_species"
    end
    local idx, err = self.form_index(species, form)
    if not idx then return nil, err end
    local e = raw_entry(idx)
    if not e then return nil, "no_form" end
    local base = {}
    for i, k in ipairs({ "hp", "atk", "def", "spe", "spa", "spd" }) do base[k] = e:byte(M.BASE_STATS_OFFSET + i) end
    return base
  end

  -- Plain strings and numbers only.
  function self.diagnostics()
    return { personal_ok = rates and 1 or 0, personal_attempts = attempts, personal_first_rejection = first_reject or "none" }
  end

  -- Forget failures and cached values (e.g. after a game change).
  function self.reset()
    rates, forms, whole_data, garc_data, attempts, self.path = nil, nil, nil, nil, 0, nil
  end

  return self
end

return M

-- Game text of Omega Ruby / Alpha Sapphire, read at runtime from the player's own
-- RomFS (gametext GARC) and kept in memory only. Nothing is shipped or cached.
--
-- Format (pk3DS TextFile.cs, see docs/games/omega-ruby-alpha-sapphire.md):
--   header   : u16 sections, u16 line count, u32 total length, u32 initial key, u32 section data offset (SDO)
--   at SDO   : u32 section length (== total length; SDO + total == file length)
--   line tab : at SDO+4, 8 bytes per line: i32 offset (relative to SDO), i16 length (UTF-16 units), 2 pad
--   line i   : UTF-16LE words, each xor key, key = rotl16(key, 3); key(i) = 0x7C89 + i * 0x2983 (16 bit)
--   markup   : 0x0010 = variable (count, code, count-1 args); 0x0000 ends the line
local garc_entry = require("gen6.garc_entry")
local M = {}

M.GARC_BASE = 1 -- ORAS gametext of language index 0 is /a/0/7/1
M.GARC_DIR = "/a/0/7/"
M.KEY_BASE, M.KEY_ADVANCE, M.KEY_VARIABLE = 0x7C89, 0x2983, 0x0010

-- gametext file index per name kind (ORAS, pk3DS TextReference.cs)
M.FILES = { form = 5, move = 14, type = 18, ability = 37, nature = 51, location = 90, species = 98, item = 114 }
M.KIND_ORDER = { "species", "move", "type", "ability", "nature", "location", "item", "form" }
M.REQUIRED = { "species", "move" }
M.MIN_ENTRIES = 115 -- the highest file index used is 114

-- language code -> language indices to try (0 JA kana, 1 JA kanji, 2 EN, 3 FR, 4 IT, 5 DE, 6 ES, 7 KO)
M.LANG_INDEX = { ja = { 1, 0 }, en = { 2 }, fr = { 3 }, it = { 4 }, de = { 5 }, es = { 6 }, ko = { 7 } }
M.SEARCH_PER_STEP = 8 -- files examined per step while looking for the species list
M.SPECIES_PROBES = { 1, 25, 150, 300, 500, 721 }
M.FALLBACK_STEPS = 300 -- steps to wait for the game language before falling back to EN
M.RETRY_EVERY = 25     -- steps to wait before going through the archive candidates again
M.MAX_RETRIES = 40     -- rounds through the candidates before the state becomes "unsupported" for good

local SPECIAL = { [0xE07F] = 0x202F, [0xE08D] = 0x2026, [0xE08E] = 0x2642, [0xE08F] = 0x2640 }

-- Parses a text file. Returns { count = n, line = function(i) -> string|nil } (i is 0-based), or nil, reason.
function M.parse(data)
  if type(data) ~= "string" or #data < 0x14 then return nil, "too_short" end
  local sections, count, total, _, sdo = string.unpack("<I2I2I4I4I4", data)
  if sections < 1 or sdo < 0x10 or sdo + 4 > #data then return nil, "bad_header" end
  -- trailing bytes (GARC alignment padding) are tolerated; a file shorter than declared is not
  if sdo + total > #data then return nil, "bad_length" end
  if string.unpack("<I4", data, sdo + 1) ~= total then return nil, "bad_section" end
  if sdo + 4 + count * 8 > #data then return nil, "bad_table" end
  local file = { count = count }

  function file.line(i)
    if math.type(i) ~= "integer" or i < 0 or i >= count then return nil end
    local off, len = string.unpack("<i4i2", data, sdo + 4 + i * 8 + 1)
    if off < 0 or len < 0 then return nil end
    local first = sdo + off + 1
    if first + len * 2 - 1 > #data then return nil end
    local key = (M.KEY_BASE + i * M.KEY_ADVANCE) & 0xFFFF
    local out, n, p = {}, 0, first
    local stop = first + len * 2
    local function word()
      if p + 1 > stop - 1 then return nil end
      local w = string.unpack("<I2", data, p) ~ key
      key = ((key << 3) | (key >> 13)) & 0xFFFF
      p = p + 2
      return w
    end
    while p < stop do
      local w = word()
      if w == nil or w == 0 then break end
      if w == M.KEY_VARIABLE then
        local cnt, code = word(), word()
        if cnt == nil or code == nil then break end
        local args = {}
        for _ = 2, cnt do
          local a = word()
          if a == nil then break end
          args[#args + 1] = a
        end
        if code == 0xBE00 then n = n + 1; out[n] = "\r"
        elseif code == 0xBE01 then n = n + 1; out[n] = "\\c"
        elseif code == 0xBE02 then n = n + 1; out[n] = "[WAIT]"
        elseif code == 0xBDFF then -- empty-line marker, nothing to show
        else n = n + 1; out[n] = string.format("[VAR %04X]", code) end
      else
        w = SPECIAL[w] or w
        if w >= 0xD800 and w <= 0xDBFF and p < stop then
          local lo = word()
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            w = 0x10000 + ((w - 0xD800) << 10) + (lo - 0xDC00)
          else
            w = 0xFFFD
          end
        elseif w >= 0xD800 and w <= 0xDFFF then
          w = 0xFFFD
        end
        n = n + 1
        out[n] = utf8.char(w)
      end
    end
    return table.concat(out)
  end

  return file
end

-- A species list holds one short non-empty name per national dex number. Files with 100 to 721
-- lines cannot be the national dex list (tiny synthetic files are not judged by size).
-- strict (discovery of another file): additionally no spaces, no markup, at most 16 characters.
function M.species_plausible(f, strict)
  if not f or math.type(f.count) ~= "integer" then return false end
  if f.count > 100 and f.count < 722 then return false end
  if strict and f.count < 722 then return false end
  if f.count > 4000 then return false end
  local seen = 0
  for _, id in ipairs(M.SPECIES_PROBES) do
    if id < f.count then
      local ok, s = pcall(f.line, id)
      if not ok or type(s) ~= "string" or s == "" then return false end
      if strict and (s:find(" ", 1, true) or s:find("[", 1, true) or utf8.len(s) == nil or utf8.len(s) > 16) then
        return false
      end
      seen = seen + 1
    end
  end
  return seen > 0
end

-- Store: finds the gametext GARC for the game language and loads the name files in bounded steps
-- (one archive read or one file per step). Decoded lines are kept in memory only.
-- opts.language_fn() -> language code or nil.
function M.new(uz, opts)
  opts = opts or {}
  local self = {}
  local codec = uz.codec
  local can = uz.rom and uz.rom.romfs and codec and codec.garc and codec.garc_file and true or false
  local state = can and "idle" or "unsupported" -- idle | open | fetch | search | done | unsupported
  local files, lines = {}, {}
  local cands, cand, data, kinds_left, garc_count, search_list, search_pos
  local found_species_file = nil
  local waited, fallback_used = 0, false
  local rounds, pause = 0, 0
  local first_reject = nil

  local function short(v) return (tostring(v):gsub("[^%w _%.:%-]", "?"):sub(1, 40)) end
  local function reject(why) if not first_reject then first_reject = why end end

  local function candidates(lang)
    local out, seen = {}, {}
    local function add(i) if not seen[i] then seen[i] = true; out[#out + 1] = i end end
    for _, i in ipairs(M.LANG_INDEX[lang or ""] or {}) do add(i) end
    add(2)
    for i = 0, 7 do add(i) end
    return out
  end

  local function begin(lang)
    cands, cand, data = candidates(lang), 0, nil
    files, lines = {}, {}
    state = "open"
  end

  local function open_next()
    if pause > 0 then pause = pause - 1; return end
    cand = cand + 1
    if cand > #cands then
      -- the ROM may only be mounted later: go through the candidates again, slowly, before giving up
      rounds = rounds + 1
      if rounds > M.MAX_RETRIES then
        state = "unsupported"
        if uz.log and uz.log.warn then uz.log.warn("no readable game text archive found; giving up") end
      else
        cand, pause = 0, M.RETRY_EVERY
        if rounds == 1 and uz.log and uz.log.warn then uz.log.warn("no readable game text archive found; retrying") end
      end
      return
    end
    local idx = cands[cand]
    local d = uz.rom.romfs(M.GARC_DIR .. (M.GARC_BASE + idx))
    if type(d) ~= "string" then reject("romfs_unreadable"); return end
    local ok, g, gerr = pcall(codec.garc, d)
    if not ok or type(g) ~= "table" or type(g.count) ~= "number" then
      reject("garc_rejected: " .. short(ok and gerr or g))
      return
    end
    if g.count < M.MIN_ENTRIES then reject("garc_entries_" .. g.count); return end
    data, garc_count, found_species_file = d, g.count, nil
    kinds_left = {}
    for i, k in ipairs(M.KIND_ORDER) do kinds_left[i] = k end
    files = {}
    state = "fetch"
    cands.current = idx
  end

  local function finalize()
    for _, k in ipairs(M.REQUIRED) do
      if not files[k] then -- not this language: try the next archive
        data, files, state = nil, {}, "open"
        return
      end
    end
    data = nil
    state = "done"
    if uz.log and uz.log.info then
      local parts = {}
      for _, k in ipairs(M.KIND_ORDER) do parts[#parts + 1] = k .. "=" .. (files[k] and files[k].count or 0) end
      uz.log.info("game text loaded, language index " .. tostring(cands.current) .. ", lines: " ..
        table.concat(parts, " ") .. (found_species_file and (", species list found at file " .. found_species_file) or ""))
    end
  end

  local function fetch_next()
    local kind = table.remove(kinds_left, 1)
    if kind then
      local raw = garc_entry.entry(codec, data, M.FILES[kind] + 1)
      if type(raw) == "string" then
        local f = M.parse(raw)
        if f then files[kind] = f end
      end
    end
    if #kinds_left > 0 then return end
    if files.species and M.species_plausible(files.species) then return finalize() end
    -- the fixed species file is missing or implausible: look for the list by content, nearest first
    search_list = {}
    for i = 0, garc_count - 1 do
      if i ~= M.FILES.species then search_list[#search_list + 1] = i end
    end
    table.sort(search_list, function(a, b)
      local da, db = math.abs(a - M.FILES.species), math.abs(b - M.FILES.species)
      if da ~= db then return da < db end
      return a < b
    end)
    search_pos = 1
    state = "search"
  end

  local function search_next()
    local last = math.min(search_pos + M.SEARCH_PER_STEP - 1, #search_list)
    for p = search_pos, last do
      local i = search_list[p]
      local raw = garc_entry.entry(codec, data, i + 1)
      if type(raw) == "string" then
        local f = M.parse(raw)
        if f and M.species_plausible(f, true) then
          files.species, found_species_file = f, i
          return finalize()
        end
      end
    end
    search_pos = last + 1
    if search_pos > #search_list then finalize() end
  end

  local function advance()
    if state == "idle" then
      local lang = opts.language_fn and opts.language_fn() or nil
      if lang == nil then
        waited = waited + 1
        if waited < M.FALLBACK_STEPS then return end
        fallback_used = true
      end
      begin(lang)
    elseif state == "open" then
      open_next()
    elseif state == "fetch" then
      fetch_next()
    elseif state == "search" then
      search_next()
    elseif state == "done" and fallback_used then
      -- loaded without knowing the language: reload once the real one is known
      local lang = opts.language_fn and opts.language_fn() or nil
      if lang ~= nil then
        fallback_used = false
        local want = (M.LANG_INDEX[lang] or {})[1]
        -- the fallback archive is already the right one (EN): keep it
        if want == nil or want ~= cands.current then begin(lang) end
      end
    end
  end

  -- One bounded step. Never raises.
  function self.step()
    if state == "unsupported" then return end
    if state == "done" and not fallback_used then return end
    local ok, err = pcall(advance)
    if not ok then
      state = "unsupported"
      if uz.log and uz.log.error then uz.log.error("game text failed: " .. tostring(err)) end
    end
  end

  function self.state() return state end
  function self.ready() return state == "done" end
  function self.language_index() return cands and cands.current end

  -- Plain numbers and strings only: state, language index, lines per kind, species file index.
  function self.diagnostics()
    local d = { text_state = state, text_language_index = cands and cands.current or -1, text_retries = rounds, text_fallback_used = fallback_used and 1 or 0,
      text_first_rejection = first_reject or "none" }
    for _, k in ipairs(M.KIND_ORDER) do d["lines_" .. k] = files[k] and files[k].count or 0 end
    d.species_file_index = files.species and (found_species_file or M.FILES.species) or -1
    return d
  end

  function self.count(kind) return state == "done" and files[kind] and files[kind].count or 0 end

  -- Every id of `kind` with a non-empty name, deduplicated by name (first id kept), in id order:
  -- { { id, name }, ... }; nil, "not_ready" | "unsupported" | "unknown_kind" | "no_lines".
  function self.list(kind)
    if not M.FILES[kind] then return nil, "unknown_kind" end
    if state == "unsupported" then return nil, "unsupported" end
    if state ~= "done" then self.step(); return nil, "not_ready" end
    local f = files[kind]
    if not f or f.count < 1 then return nil, "no_lines" end
    local out, seen = {}, {}
    for id = 0, f.count - 1 do
      local n = self.name(kind, id)
      if n and not seen[n] then seen[n] = true; out[#out + 1] = { id = id, name = n } end
    end
    if #out == 0 then return nil, "no_lines" end
    return out
  end

  -- Like name() but never advances the loading: the string, or nil when not loaded / unknown.
  function self.peek(kind, id)
    if state ~= "done" then return nil end
    return (self.name(kind, id))
  end

  -- Name from the game text: string, or nil, "not_ready" | "unsupported" | "unknown_kind".
  function self.name(kind, id)
    if not M.FILES[kind] then return nil, "unknown_kind" end
    if state == "unsupported" then return nil, "unsupported" end
    if state ~= "done" then self.step(); return nil, "not_ready" end
    if math.type(id) == "float" then id = math.tointeger(id) end -- integral floats from other plugins
    if math.type(id) ~= "integer" then return nil end
    local f = files[kind]
    if not f then return nil end
    local lk = lines[kind]
    if not lk then lk = {}; lines[kind] = lk end
    local v = lk[id]
    if v == nil then
      local ok, s = pcall(f.line, id)
      v = (ok and type(s) == "string" and s ~= "") and s or false
      lk[id] = v
    end
    return v or nil
  end

  return self
end

return M

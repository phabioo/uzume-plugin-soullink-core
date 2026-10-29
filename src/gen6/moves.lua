-- Base PP per move, read at runtime from the user's own game files (RomFS move GARC). Nothing from the
-- game is shipped or persisted; the values live in a Lua table cache only.
--
-- ORAS move data (community-documented, all to verify locally, NOT yet checked on a real game):
--   path  : candidates "/a/1/8/9" (pk3DS GARCReference "move", recalled) and "/a/1/9/4", tried in order;
--           the first one whose data validates as a move table is used (see validate)
--   entry : 0x24 bytes per move (PKHeX Move6), index = move id; byte 0 type, 3 power, 4 accuracy,
--           0x05 base PP (recalled), 0x06 priority
--   shape : a "WD" mini container (u16 count, count + 1 u32 offsets) inside the single GARC file, or the
--           concatenated table (length % 0x24 == 0), or one GARC file per move
local garc_entry = require("gen6.garc_entry")
local M = {}

M.CANDIDATE_PATHS = { "/a/1/8/9", "/a/1/9/4" }
M.ENTRY_SIZE = 0x24
M.PP_OFFSET = 0x05
M.MIN_ENTRIES = 622 -- moves 0..621 (ORAS)
M.MAX_BASE_PP = 64
M.MAX_ATTEMPTS = 3

function M.new(uz, opts)
  opts = opts or {}
  local paths = opts.paths or M.CANDIDATE_PATHS
  local esize = opts.entry_size or M.ENTRY_SIZE
  local poff = opts.pp_offset or M.PP_OFFSET
  local self = {}
  local pps, attempts = nil, 0
  local first_reject
  local function reject(why) if not first_reject then first_reject = why end end

  -- entries: list (1-based, entry i = move i - 1) of strings -> table move id -> base PP, or nil
  local function from_entries(list)
    if #list < M.MIN_ENTRIES then return nil end
    local out, filled = {}, 0
    for id = 1, M.MIN_ENTRIES - 1 do
      local e = list[id + 1]
      if type(e) ~= "string" or #e ~= esize then reject("entry_size"); return nil end
      local pp = e:byte(poff + 1)
      if pp > M.MAX_BASE_PP then reject("pp_invalid"); return nil end
      if pp > 0 then filled = filled + 1 end
      out[id] = pp
    end
    if filled < (M.MIN_ENTRIES - 1) * 9 // 10 then reject("pp_mostly_zero"); return nil end
    return out
  end

  local function split(blob)
    local list = {}
    if blob:sub(1, 2) == "WD" and #blob >= 8 then -- mini container
      local count = string.unpack("<I2", blob, 3)
      if 4 + 4 * (count + 1) > #blob then return nil end
      local offs = {}
      for i = 0, count do offs[i] = string.unpack("<I4", blob, 5 + 4 * i) end
      for i = 0, count - 1 do
        if offs[i] > offs[i + 1] or offs[i + 1] > #blob then return nil end
        list[i + 1] = blob:sub(offs[i] + 1, offs[i + 1])
      end
      return list
    end
    if #blob % esize == 0 then
      for i = 0, #blob // esize - 1 do list[i + 1] = blob:sub(i * esize + 1, i * esize + esize) end
      return list
    end
    return nil
  end

  local function validate(data)
    local g, gerr = uz.codec.garc(data)
    if type(g) ~= "table" or type(g.count) ~= "number" then
      reject("garc_rejected: " .. (tostring(gerr):gsub("[^%w _%.:%-]", "?"):sub(1, 40)))
      return nil
    end
    local last = garc_entry.entry(uz.codec, data, g.count)
    if type(last) == "string" then
      local list = split(last)
      local r = list and from_entries(list)
      if r then return r end
    end
    if g.count >= M.MIN_ENTRIES then
      local list = {}
      for i = 1, M.MIN_ENTRIES do list[i] = garc_entry.entry(uz.codec, data, i) end
      return from_entries(list)
    end
    reject("table_shape")
    return nil
  end

  local function load()
    if pps then return true end
    if attempts >= M.MAX_ATTEMPTS then return false end
    attempts = attempts + 1
    if not (uz and uz.rom and uz.rom.romfs and uz.codec and uz.codec.garc and uz.codec.garc_file) then return false end
    for _, path in ipairs(paths) do
      local data = uz.rom.romfs(path)
      if type(data) ~= "string" then reject("romfs_unreadable") else
        local r = validate(data)
        if r then
          pps = r
          self.path = path
          if uz.log and uz.log.info then uz.log.info("move data accepted at " .. path) end
          return true
        end
      end
    end
    return false
  end

  -- Base PP (1..64) of a move id (1..621), or nil when unknown or the table is not readable.
  function self.base_pp(move)
    if math.type(move) ~= "integer" or move < 1 or move >= M.MIN_ENTRIES then return nil end
    if not load() then return nil end
    local pp = pps[move]
    return (pp and pp > 0) and pp or nil
  end

  function self.diagnostics()
    return { moves_ok = pps and 1 or 0, moves_attempts = attempts, moves_first_rejection = first_reject or "none" }
  end

  function self.reset() pps, attempts, self.path = nil, 0, nil end

  return self
end

return M

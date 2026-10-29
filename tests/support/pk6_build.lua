-- Builds synthetic plain PK6 bytes from a field table (all values invented).
local crypto = require("pk6_crypto")
local M = {}

local function utf16(s, chars)
  local out = {}
  for _, c in utf8.codes(s) do
    if c >= 0x10000 then
      c = c - 0x10000
      out[#out + 1] = string.pack("<I2", 0xD800 + (c >> 10))
      out[#out + 1] = string.pack("<I2", 0xDC00 + (c & 0x3FF))
    else
      out[#out + 1] = string.pack("<I2", c)
    end
  end
  local b = table.concat(out)
  return b .. string.rep("\0", chars * 2 - #b)
end

-- f: species, ec, pid, tid, sid, exp, held_item, ability, nature, gender (0..2), form,
-- fateful, moves {..}, ivs {hp,atk,def,spe,spa,spd}, evs {...}, egg, nicknamed,
-- nickname, ot_name, language_id, origin_game, party {status, level, hp, max_hp}
function M.build(f)
  local b = {}
  for i = 0, 259 do b[i] = 0 end
  local function put(off, fmt, v)
    local s = string.pack(fmt, v)
    for i = 1, #s do b[off + i - 1] = s:byte(i) end
  end
  local function puts(off, s) for i = 1, #s do b[off + i - 1] = s:byte(i) end end
  local pid = f.pid or 0x12345678
  put(0x00, "<I4", f.ec or 0x0BADF00D)
  put(0x08, "<I2", f.species or 1)
  put(0x0A, "<I2", f.held_item or 0)
  put(0x0C, "<I2", f.tid or 1000)
  put(0x0E, "<I2", f.sid or 2000)
  put(0x10, "<I4", f.exp or 0)
  b[0x14] = f.ability or 0
  b[0x15] = f.ability_num or 0
  put(0x18, "<I4", pid)
  b[0x1C] = f.nature or 0
  b[0x1D] = (f.fateful and 1 or 0) | ((f.gender or 0) << 1) | ((f.form or 0) << 3)
  local evs = f.evs or {}
  for i, k in ipairs({ "hp", "atk", "def", "spe", "spa", "spd" }) do b[0x1E + i - 1] = evs[k] or 0 end
  puts(0x40, utf16(f.nickname or "", 13))
  for i = 0, 3 do put(0x5A + i * 2, "<I2", (f.moves or {})[i + 1] or 0) end
  local iv = 0
  local ivs = f.ivs or {}
  for i, k in ipairs({ "hp", "atk", "def", "spe", "spa", "spd" }) do iv = iv | ((ivs[k] or 0) << (5 * (i - 1))) end
  if f.egg then iv = iv | (1 << 30) end
  if f.nicknamed then iv = iv | (1 << 31) end
  put(0x74, "<I4", iv)
  puts(0xB0, utf16(f.ot_name or "", 13))
  b[0xDF] = f.origin_game or 0x2C
  b[0xE3] = f.language_id or 2
  local size = 232
  if f.party then
    size = 260
    put(0xE8, "<I4", f.party.status or 0)
    b[0xEC] = f.party.level or 0
    put(0xF0, "<I2", f.party.hp or 0)
    put(0xF2, "<I2", f.party.max_hp or 0)
    local st = f.party.stats or {}
    for i, k in ipairs({ "atk", "def", "spe", "spa", "spd" }) do put(0xF4 + (i - 1) * 2, "<I2", st[k] or 50) end
  end
  local parts = {}
  for i = 0, size - 1 do parts[#parts + 1] = string.char(b[i]) end
  local plain = table.concat(parts)
  put(0x06, "<I2", crypto.checksum(plain))
  parts = {}
  for i = 0, size - 1 do parts[#parts + 1] = string.char(b[i]) end
  return table.concat(parts)
end

function M.encrypted(f) return crypto.encrypt(M.build(f)) end

-- A party slot as laid out in RAM (0x1E4 bytes): the encrypted 0xE8 bytes at +0, the 22 encrypted
-- party-stat bytes at +0x158 (invented layout position copied from the documented RAM layout).
function M.ram_slot(f)
  local g = {}
  for k, v in pairs(f) do g[k] = v end
  g.party = g.party or {}
  local enc = crypto.encrypt(M.build(g))
  return enc:sub(1, 232) .. string.rep("\0", 0x158 - 232) .. enc:sub(233, 254) .. string.rep("\0", 0x1E4 - 0x16E)
end

return M

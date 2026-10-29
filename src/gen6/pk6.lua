-- Gen 6 PK6 parser for decrypted data (232 stored / 260 party bytes).
-- Layout: PKHeX PK6.cs (kwsch/PKHeX, PKHeX.Core/PKM/PK6.cs), offsets below are
-- from that file; cross-check: Project Pokemon "Pokemon X/Y save structure".
-- Strings are UTF-16LE, 12 characters + terminator (0x1A bytes).
local M = {}

M.SIZE_STORED = 232
M.SIZE_PARTY = 260
M.MAX_SPECIES = 721 -- ORAS National Dex

local OFF = {
  ec = 0x00, checksum = 0x06, species = 0x08, held_item = 0x0A, tid = 0x0C, sid = 0x0E,
  exp = 0x10, ability = 0x14, ability_num = 0x15, pid = 0x18, nature = 0x1C, flags = 0x1D, evs = 0x1E,
  nickname = 0x40, moves = 0x5A, iv32 = 0x74, ot_name = 0xB0, version = 0xDF, language = 0xE3,
  -- party extension (not trusted for live party memory, see parse)
  status = 0xE8, level = 0xEC, hp = 0xF0, max_hp = 0xF2, stats = 0xF4,
}
M.OFF = OFF

-- Language byte (PKHeX LanguageID; 6 is unused, 7 = Spanish) -> language code
local LANG = { [1] = "ja", [2] = "en", [3] = "fr", [4] = "it", [5] = "de", [7] = "es",
  [8] = "ko", [9] = "zh-Hans", [10] = "zh-Hant" }
M.LANGUAGES = LANG

local GENDER = { [0] = "male", [1] = "female", [2] = "genderless" }

-- UTF-16LE (up to max_chars code units, stops at 0x0000) -> UTF-8
function M.utf16le_to_utf8(s, max_chars)
  local out, i, n = {}, 1, 0
  max_chars = max_chars or (#s // 2)
  while n < max_chars and i + 1 <= #s do
    local u = string.unpack("<I2", s, i)
    i = i + 2
    n = n + 1
    if u == 0 then break end
    if u >= 0xD800 and u <= 0xDBFF and n < max_chars and i + 1 <= #s then
      local lo = string.unpack("<I2", s, i)
      if lo >= 0xDC00 and lo <= 0xDFFF then
        i = i + 2
        n = n + 1
        out[#out + 1] = utf8.char(0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00))
      else
        out[#out + 1] = utf8.char(0xFFFD)
      end
    elseif u >= 0xD800 and u <= 0xDFFF then
      out[#out + 1] = utf8.char(0xFFFD)
    else
      out[#out + 1] = utf8.char(u)
    end
  end
  return table.concat(out)
end

-- plain: decrypted PK6 (232 or 260 bytes). Returns record or nil, reason.
-- Level/HP/status of the live party are NOT filled from 0xE8+ (unreliable in
-- running ORAS memory); they are exposed as record.party_ext only.
function M.parse(plain)
  if type(plain) ~= "string" then return nil, "bad_type" end
  if #plain ~= M.SIZE_STORED and #plain ~= M.SIZE_PARTY then return nil, "bad_length" end
  local function u8(o) return (string.unpack("<I1", plain, o + 1)) end
  local function u16(o) return (string.unpack("<I2", plain, o + 1)) end
  local function u32(o) return (string.unpack("<I4", plain, o + 1)) end

  local pid, tid, sid = u32(OFF.pid), u16(OFF.tid), u16(OFF.sid)
  local flags = u8(OFF.flags)
  local iv32 = u32(OFF.iv32)
  local moves = {}
  for i = 0, 3 do
    local m = u16(OFF.moves + i * 2)
    if m ~= 0 then moves[#moves + 1] = m end
  end
  local evs, ivs = {}, {}
  for i, k in ipairs({ "hp", "atk", "def", "spe", "spa", "spd" }) do
    evs[k] = u8(OFF.evs + i - 1)
    ivs[k] = (iv32 >> (5 * (i - 1))) & 0x1F
  end
  local lang_id = u8(OFF.language)

  local rec = {
    species = u16(OFF.species),
    form = flags >> 3,
    nickname = M.utf16le_to_utf8(plain:sub(OFF.nickname + 1, OFF.nickname + 0x1A), 12),
    nicknamed = (iv32 >> 31) & 1 == 1,
    exp = u32(OFF.exp),
    personality = pid,
    encryption_constant = u32(OFF.ec),
    shiny = ((tid ~ sid ~ (pid >> 16) ~ (pid & 0xFFFF)) < 16),
    gender = GENDER[(flags >> 1) & 3],
    fateful = flags & 1 == 1,
    nature = u8(OFF.nature),
    ability = u8(OFF.ability),
    ability_num = u8(OFF.ability_num), -- bit 0 = ability 1, bit 1 = ability 2, bit 2 = hidden (PKHeX AbilityNumber)
    held_item = u16(OFF.held_item),
    moves = moves,
    ot_name = M.utf16le_to_utf8(plain:sub(OFF.ot_name + 1, OFF.ot_name + 0x1A), 12),
    ot_id = tid,
    ot_sid = sid,
    language = LANG[lang_id],
    language_id = lang_id,
    origin_game = u8(OFF.version),
    egg = (iv32 >> 30) & 1 == 1,
    ivs = ivs,
    evs = evs,
    -- level, hp, max_hp, status: nil here; level comes from growth
  }
  if #plain == M.SIZE_PARTY then
    local stats = {}
    for i, k in ipairs({ "atk", "def", "spe", "spa", "spd" }) do
      stats[k] = u16(OFF.stats + (i - 1) * 2)
    end
    rec.party_ext = {
      status = u32(OFF.status), level = u8(OFF.level),
      hp = u16(OFF.hp), max_hp = u16(OFF.max_hp), stats = stats,
    }
  end
  return rec
end

-- Crypto (PKHeX PokeCrypto.cs, same algorithm as the host helpers uz.codec.pk6_decrypt / pk6_encrypt,
-- kept here so write helpers do not depend on the host). seed = encryption constant (first u32);
-- seed = seed * 0x41C64E6D + 0x6073 (32 bit); each u16 is xored with seed >> 16. Bytes 0x08..0xE7 are
-- crypted and their four 56-byte blocks shuffled by (EC >> 13) & 31 modulo 24; the party extension
-- 0xE8.. is crypted with a fresh stream seeded by the same constant.
local ORDER = {
  {0,1,2,3},{0,1,3,2},{0,2,1,3},{0,3,1,2},{0,2,3,1},{0,3,2,1},
  {1,0,2,3},{1,0,3,2},{2,0,1,3},{3,0,1,2},{2,0,3,1},{3,0,2,1},
  {1,2,0,3},{1,3,0,2},{2,1,0,3},{3,1,0,2},{2,3,0,1},{3,2,0,1},
  {1,2,3,0},{1,3,2,0},{2,1,3,0},{3,1,2,0},{2,3,1,0},{3,2,1,0},
}
local BLOCK = 56

-- u16 sum over 0x08..0xE7 of a decrypted structure.
function M.checksum(plain)
  local sum = 0
  for o = 0x08, 0xE6, 2 do sum = sum + string.unpack("<I2", plain, o + 1) end
  return sum & 0xFFFF
end

local function crypt(s, seed)
  local out = {}
  for i = 1, #s - 1, 2 do
    seed = (seed * 0x41C64E6D + 0x6073) & 0xFFFFFFFF
    out[#out + 1] = string.pack("<I2", string.unpack("<I2", s, i) ~ (seed >> 16))
  end
  if #s % 2 == 1 then out[#out + 1] = s:sub(-1) end
  return table.concat(out)
end

-- decrypted block i (0-based) = encrypted block ORDER[sv][i]
local function shuffle(body, sv, inverse)
  local order = ORDER[sv % 24 + 1]
  local out = {}
  for i = 1, 4 do
    local from = order[i]
    if inverse then
      out[from + 1] = body:sub((i - 1) * BLOCK + 1, i * BLOCK)
    else
      out[i] = body:sub(from * BLOCK + 1, (from + 1) * BLOCK)
    end
  end
  return table.concat(out)
end

local function good_len(s)
  return type(s) == "string" and (#s == M.SIZE_STORED or #s == M.SIZE_PARTY)
end

-- enc -> plain, checksum_ok; nil, "bad_length" for other input.
function M.decrypt(enc)
  if not good_len(enc) then return nil, "bad_length" end
  local ec = string.unpack("<I4", enc)
  local body = shuffle(crypt(enc:sub(9, 232), ec), (ec >> 13) & 31, false)
  local plain = enc:sub(1, 8) .. body
  if #enc == M.SIZE_PARTY then plain = plain .. crypt(enc:sub(233), ec) end
  return plain, string.unpack("<I2", plain, 7) == M.checksum(plain)
end

-- Encrypts without touching the checksum.
function M.encrypt(plain)
  if not good_len(plain) then return nil, "bad_length" end
  local ec = string.unpack("<I4", plain)
  local body = crypt(shuffle(plain:sub(9, 232), (ec >> 13) & 31, true), ec)
  local enc = plain:sub(1, 8) .. body
  if #plain == M.SIZE_PARTY then enc = enc .. crypt(plain:sub(233), ec) end
  return enc
end

-- plain with a recomputed checksum at 0x06.
function M.with_checksum(plain)
  if not good_len(plain) then return nil, "bad_length" end
  return plain:sub(1, 6) .. string.pack("<I2", M.checksum(plain)) .. plain:sub(9)
end

-- Recomputes the checksum, then encrypts.
function M.seal(plain)
  local p, err = M.with_checksum(plain)
  if not p then return nil, err end
  return M.encrypt(p)
end

-- UTF-8 -> UTF-16LE with exactly `chars` code units (cut or zero padded; no terminator is forced
-- when the text fills all units, as in the game's 12 character + terminator field when chars = 13).
function M.utf8_to_utf16le(s, chars)
  local out, n = {}, 0
  for _, c in utf8.codes(s) do
    if c >= 0x10000 then
      if n + 2 > chars then break end
      c = c - 0x10000
      out[#out + 1] = string.pack("<I2I2", 0xD800 + (c >> 10), 0xDC00 + (c & 0x3FF))
      n = n + 2
    else
      if n + 1 > chars then break end
      out[#out + 1] = string.pack("<I2", c)
      n = n + 1
    end
  end
  return table.concat(out) .. string.rep("\0", (chars - n) * 2)
end

return M

-- Pure-Lua PK6 crypto from the documented algorithm (PKHeX PokeCrypto.cs):
-- seed = encryption constant (first u32); seed = seed*0x41C64E6D + 0x6073;
-- each u16 xor (seed >> 16). Bytes 0x08..0xE7 are crypted and their four 56-byte
-- blocks shuffled by (EC >> 13) & 31 mod 24; the party extension 0xE8.. is crypted
-- with a fresh stream seeded by the same constant. Checksum = u16 sum over 0x08..0xE7.
local M = {}

local ORDER = {
  {0,1,2,3},{0,1,3,2},{0,2,1,3},{0,3,1,2},{0,2,3,1},{0,3,2,1},
  {1,0,2,3},{1,0,3,2},{2,0,1,3},{3,0,1,2},{2,0,3,1},{3,0,2,1},
  {1,2,0,3},{1,3,0,2},{2,1,0,3},{3,1,0,2},{2,3,0,1},{3,2,0,1},
  {1,2,3,0},{1,3,2,0},{2,1,3,0},{3,1,2,0},{2,3,1,0},{3,2,1,0},
}
local BLOCK = 56

function M.checksum(plain)
  local sum = 0
  for o = 0x08, 0xE6, 2 do sum = sum + string.unpack("<I2", plain, o + 1) end
  return sum & 0xFFFF
end

local function crypt(s, seed)
  local out = {}
  for i = 1, #s, 2 do
    seed = (seed * 0x41C64E6D + 0x6073) & 0xFFFFFFFF
    local v = string.unpack("<I2", s, i) ~ (seed >> 16)
    out[#out + 1] = string.pack("<I2", v)
  end
  return table.concat(out)
end

-- plain[i-th block] = enc[ORDER[sv][i]]
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

local function check_len(s)
  assert(#s == 232 or #s == 260, "PK6 must be 232 or 260 bytes")
end

function M.decrypt(enc)
  if type(enc) ~= "string" or (#enc ~= 232 and #enc ~= 260) then return nil, "bad length" end
  local ec = string.unpack("<I4", enc)
  local sv = (ec >> 13) & 31
  local body = shuffle(crypt(enc:sub(9, 232), ec), sv, false)
  local plain = enc:sub(1, 8) .. body
  if #enc == 260 then plain = plain .. crypt(enc:sub(233), ec) end
  return plain, string.unpack("<I2", plain, 7) == M.checksum(plain)
end

-- Encrypts without touching the checksum (like uz.codec.pk6_encrypt).
function M.encrypt(plain)
  check_len(plain)
  local ec = string.unpack("<I4", plain)
  local sv = (ec >> 13) & 31
  local body = crypt(shuffle(plain:sub(9, 232), sv, true), ec)
  local enc = plain:sub(1, 8) .. body
  if #plain == 260 then enc = enc .. crypt(plain:sub(233), ec) end
  return enc
end

return M

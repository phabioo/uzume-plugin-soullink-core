-- Gen 6 palette BCLIM decoder in Lua (box icons). The Player's fb.codec.bclim decodes this variant
-- too, but with one fixed set of choices (RGBA5551 colours, low nibble first) that did not give a
-- usable picture on a real Omega Ruby (v0.3.3 field report). The choices are parameters here so
-- variants can be compared (icon_variants); the field report on a real Omega Ruby EU confirmed
-- variant D, which is the default (DEFAULT_VARIANT).
--
-- Layout (pk3DS pk3DS.Core/CTR/Images/BCLIM.cs, GetPixelsViaPalette; Player texture.cpp), pixel data
-- of a BCLIM whose footer format is 7 and whose data starts with u16 2:
--   u16 2, u16 colour count, count x u16 colours, then the indices in 8x8 Morton tiles, tile rows
--   BaseSize/8 tiles wide (BaseSize = next power of two of max(w, h), 64 for 40x30). Indices are
--   4 bit (two per byte) when the count is at most 16, else 8 bit.
-- pk3DS reads the colours as RGB565 with low nibble first; its writer (BCLIM.cs) writes RGBA5551,
-- forces transparent pixels to index 0 and puts the FIRST pixel in the HIGH nibble. The game files
-- follow the writer (RGBA5551, index 0 not forced transparent, high nibble first: variant D); the
-- other variants stay for diagnostics. Nothing is shipped.
local M = {}

M.FOOTER = 0x28
M.FMT_OFFSET = 0x20          -- format byte inside the footer
M.MAX_DIM = 1024

-- Variant table. color: "565" | "5551"; index0: index 0 is transparent (565 has no alpha bit);
-- high_first: the first (even) pixel of a byte sits in the high nibble.
M.VARIANTS = {
  A = { color = "565", index0 = true, high_first = false, desc = "RGB565, index 0 transparent, low nibble first" },
  B = { color = "5551", index0 = false, high_first = false, desc = "RGBA5551, low nibble first" },
  C = { color = "565", index0 = true, high_first = true, desc = "RGB565, index 0 transparent, high nibble first" },
  D = { color = "5551", index0 = false, high_first = true, desc = "RGBA5551, high nibble first" },
}
-- E: no palette at all; the data is a plain tiled 16-bit texture (RGBA5551, the footer format 7).
-- The Player treats every format 7 image whose first u16 is 2 as a palette image, which also
-- catches a plain texture whose first pixel happens to be 0x0002 (transparent). Plain texture data
-- is exactly pow2(w) x pow2(h) x 2 bytes (64 x 32 x 2 = 4096 for a 40x30 icon).
M.VARIANTS.E = { plain = true, color = "5551", desc = "plain tiled RGBA5551, no palette" }
M.ORDER = { "A", "B", "C", "D", "E" }
-- The variant icon() uses: D, confirmed on a real Omega Ruby EU (clean, correctly coloured icons).
M.DEFAULT_VARIANT = "D"

local function pow2_at_least_8(v)
  local p = 8
  while p < v do p = p << 1 end
  return p
end

-- width, height, format byte of the BCLIM footer, or nil.
local function footer(s)
  if type(s) ~= "string" or #s < M.FOOTER then return nil end
  local f = #s - M.FOOTER + 1
  if s:sub(f, f + 3) ~= "CLIM" or s:sub(f + 0x14, f + 0x17) ~= "imag" then return nil end
  local w, h = string.unpack("<I2I2", s, f + 0x1C)
  return w, h, s:byte(f + M.FMT_OFFSET)
end

-- True for a format 7 BCLIM whose data starts with u16 2 and a nonzero colour count.
function M.is_palette(s)
  local w, h, fmt = footer(s)
  if not w or fmt ~= 7 or #s < M.FOOTER + 4 then return false end
  local a, count = string.unpack("<I2I2", s, 1)
  return a == 2 and count >= 1
end

-- True when the data (without footer) is a palette image whose index bytes needed for the image
-- fit behind the palette and everything after them up to the end of the data is zero padding.
-- Needed indices: all tiles up to the last tile row of the image (stride = BaseSize as in decode).
local function padded_palette(s)
  if not M.is_palette(s) then return false end
  local w, h = footer(s)
  local size = #s - M.FOOTER
  local count = string.unpack("<I2", s, 3)
  if count > 256 then return false end
  local stride = pow2_at_least_8(math.max(w, h))
  local pixels = ((h + 7) // 8) * (stride // 8) * 64
  local nbytes = (count <= 16) and ((pixels + 1) // 2) or pixels
  local last = 4 + 2 * count + nbytes
  if last > size then return false end
  for i = last + 1, size do
    if s:byte(i) ~= 0 then return false end
  end
  return true
end

-- "plain16" when the data size is exactly that of a plain tiled 16-bit texture of the footer size
-- (format 7 RGBA5551 or 5 RGB565), unless the palette signature holds and the data is a palette
-- image zero-padded to that size (real Omega Ruby icons: 40x30, 12 colours, 4096 data bytes), then
-- "palette". Without the plain size, the palette signature means "palette", else nil.
function M.layout(s)
  local w, h, fmt = footer(s)
  if not w or w < 1 or h < 1 or w > M.MAX_DIM or h > M.MAX_DIM then return nil end
  if fmt == 7 or fmt == 5 then
    if #s - M.FOOTER == pow2_at_least_8(w) * pow2_at_least_8(h) * 2 then
      if padded_palette(s) then return "palette" end
      return "plain16"
    end
  end
  if M.is_palette(s) then return "palette" end
  return nil
end

-- Plain facts for diagnostics: { count, pal = { u16... (first 8) }, idx = { bytes... (first 8) },
-- idx_bytes = bytes left for the indices } or nil when the data is no palette BCLIM.
function M.inspect(s)
  if not M.is_palette(s) then return nil end
  local size = #s - M.FOOTER
  local count = string.unpack("<I2", s, 3)
  local out = { count = count, pal = {}, idx = {}, idx_bytes = size - 4 - 2 * count }
  for i = 1, math.min(8, count) do
    local o = 4 + (i - 1) * 2 + 1
    if o + 1 <= size then out.pal[#out.pal + 1] = string.unpack("<I2", s, o) end
  end
  local base = 4 + 2 * count
  for i = 1, 8 do
    if base + i <= size then out.idx[#out.idx + 1] = s:byte(base + i) end
  end
  return out
end

local function expand(v, bits)
  if bits == 5 then return (v << 3) | (v >> 2) end
  return (v << 2) | (v >> 4)
end

-- Colour u16 -> r, g, b, a (0..255).
function M.color(v, mode)
  if mode == "565" then
    return expand((v >> 11) & 31, 5), expand((v >> 5) & 63, 6), expand(v & 31, 5), 255
  end
  return expand((v >> 11) & 31, 5), expand((v >> 6) & 31, 5), expand((v >> 1) & 31, 5), (v & 1) == 1 and 255 or 0
end

-- Morton position inside an 8x8 tile: MORTON[(y % 8) * 8 + x % 8] = index 0..63
local MORTON = {}
for y = 0, 7 do
  for x = 0, 7 do
    MORTON[y * 8 + x] = (x & 1) | ((y & 1) << 1) | ((x & 2) << 1) | ((y & 2) << 2) | ((x & 4) << 2) | ((y & 4) << 3)
  end
end

-- Decodes a palette BCLIM. opts: color "565"|"5551" (default "565"), index0 (index 0 transparent,
-- default true), high_first (default false), bits 4|8 (default: 4 when the count is at most 16),
-- stride (tile layout width in pixels, multiple of 8; default BaseSize = next power of two of
-- max(w, h)). Returns { width, height, rgba } or nil, reason.
function M.decode(s, opts)
  opts = opts or {}
  if not M.is_palette(s) then return nil, "not_palette" end
  local w, h = footer(s)
  if w < 1 or h < 1 or w > M.MAX_DIM or h > M.MAX_DIM then return nil, "size" end
  local mode = opts.color or "565"
  local index0 = opts.index0
  if index0 == nil then index0 = true end
  local size = #s - M.FOOTER
  local count = string.unpack("<I2", s, 3)
  if 4 + 2 * count > size then return nil, "palette_truncated" end
  local bits = opts.bits or (count <= 16 and 4 or 8)
  local stride = opts.stride or pow2_at_least_8(math.max(w, h))
  if stride % 8 ~= 0 or stride < w then return nil, "stride" end
  local tiles_x = stride // 8
  local base = 4 + 2 * count -- 0-based offset of the indices
  local pal = {}
  for c = 0, count - 1 do
    local r, g, b, a = M.color(string.unpack("<I2", s, 5 + c * 2), mode)
    if index0 and c == 0 then a = 0 end
    if index0 and c ~= 0 and mode == "565" then a = 255 end
    pal[c] = string.char(r, g, b, a)
  end
  local clear = "\0\0\0\0"
  local rows = {}
  for y = 0, h - 1 do
    local row = {}
    for x = 0, w - 1 do
      local n = ((y >> 3) * tiles_x + (x >> 3)) * 64 + MORTON[(y & 7) * 8 + (x & 7)]
      local idx
      if bits == 4 then
        local o = base + (n >> 1) + 1
        if o > size then return nil, "indices_truncated" end
        local b = s:byte(o)
        local first = (n & 1) == 0
        if opts.high_first then idx = first and (b >> 4) or (b & 15) else idx = first and (b & 15) or (b >> 4) end
      else
        local o = base + n + 1
        if o > size then return nil, "indices_truncated" end
        idx = s:byte(o)
      end
      row[x + 1] = pal[idx] or clear
    end
    rows[y + 1] = table.concat(row)
  end
  return { width = w, height = h, rgba = table.concat(rows) }
end

-- Decodes a plain tiled 16-bit texture ("plain16" layout), cropped to the footer size.
-- opts.color: "5551" (default for format 7) or "565" (default for format 5).
function M.decode_plain(s, opts)
  opts = opts or {}
  local w, h, fmt = footer(s)
  if M.layout(s) ~= "plain16" then return nil, "not_plain16" end
  local mode = opts.color or (fmt == 5 and "565" or "5551")
  local tiles_x = pow2_at_least_8(w) // 8
  local rows = {}
  for y = 0, h - 1 do
    local row = {}
    for x = 0, w - 1 do
      local n = ((y >> 3) * tiles_x + (x >> 3)) * 64 + MORTON[(y & 7) * 8 + (x & 7)]
      local r, g, b, a = M.color(string.unpack("<I2", s, n * 2 + 1), mode)
      row[x + 1] = string.char(r, g, b, a)
    end
    rows[y + 1] = table.concat(row)
  end
  return { width = w, height = h, rgba = table.concat(rows) }
end

-- Decodes `s` as named variant A..E, or nil, reason.
function M.decode_variant(s, label)
  local v = M.VARIANTS[label]
  if not v then return nil, "unknown_variant" end
  if v.plain then return M.decode_plain(s, { color = v.color }) end
  return M.decode(s, M.variant_opts(label))
end

-- Decodes an icon the way icon() does: plain 16-bit layout as a plain texture, palette layout with
-- the default variant; nil when the data is neither (the caller uses fb.codec.bclim).
function M.decode_auto(s)
  local layout = M.layout(s)
  if layout == "plain16" then return M.decode_plain(s) end
  if layout == "palette" then return M.decode(s, M.variant_opts(M.DEFAULT_VARIANT)) end
  return nil, "not_palette"
end

-- Options of a named variant (A..D), or nil.
function M.variant_opts(label)
  local v = M.VARIANTS[label]
  if not v then return nil end
  return { color = v.color, index0 = v.index0, high_first = v.high_first }
end

return M

-- Test-only builders for Gen 6 style 16-bit textures: palette BCLIM and plain tiled 16-bit BCLIM.
-- Synthetic data generated from the documented layout; the tiling here goes from the tile position
-- to (x, y) (the decoder goes the other way), so both directions are checked against each other.
local M = {}
local pack = string.pack

function M.footer(w, h, fmt, data_len)
  local total = data_len + 40
  return "CLIM" .. pack("<I2I2I4I4I2I2", 0xFEFF, 0x14, 0x02020000, total, 1, 0)
    .. "imag" .. pack("<I4I2I2I1I1I2I4", 0x10, w, h, fmt, 0, 0, data_len)
end

local function pow2(v) local p = 8; while p < v do p = p << 1 end; return p end

-- (x, y) of Morton position j (0..63) inside a tile
local function pos(j)
  return (j & 1) | ((j >> 1) & 2) | ((j >> 2) & 4), ((j >> 1) & 1) | ((j >> 2) & 2) | ((j >> 3) & 4)
end

-- Palette BCLIM. index(x, y) -> palette index; palette = list of u16; opts: high_first (first pixel
-- in the high nibble), bits (4 or 8, default 4 for <= 16 colours), base (tile layout width, default
-- pow2(max(w, h))), rows (stored tile rows, default base / 8), pad_to (zero-pad the data to this total size).
function M.palette(w, h, index, palette, opts)
  opts = opts or {}
  local count = #palette
  local bits = opts.bits or (count <= 16 and 4 or 8)
  local base = opts.base or pow2(math.max(w, h))
  local tiles_x, tiles_y = base // 8, opts.rows or base // 8
  local n = tiles_x * tiles_y * 64
  local idx = {}
  for tile = 0, tiles_x * tiles_y - 1 do
    for j = 0, 63 do
      local px, py = pos(j)
      local x, y = (tile % tiles_x) * 8 + px, (tile // tiles_x) * 8 + py
      idx[tile * 64 + j] = (x < w and y < h) and index(x, y) or 0
    end
  end
  local out = {}
  if bits == 4 then
    for i = 0, n - 1, 2 do
      local a, b = idx[i], idx[i + 1]
      if opts.high_first then out[#out + 1] = string.char((a << 4) | b) else out[#out + 1] = string.char((b << 4) | a) end
    end
  else
    for i = 0, n - 1 do out[#out + 1] = string.char(idx[i]) end
  end
  local head = pack("<I2I2", 2, count)
  for _, c in ipairs(palette) do head = head .. pack("<I2", c) end
  local data = head .. table.concat(out)
  if opts.pad_to and #data < opts.pad_to then data = data .. string.rep("\0", opts.pad_to - #data) end
  return data .. M.footer(w, h, 7, #data)
end

-- Plain tiled 16-bit BCLIM (format 7 = RGBA5551 unless fmt given), stored pow2(w) x pow2(h).
function M.plain16(w, h, colour, fmt)
  local sw, sh = pow2(w), pow2(h)
  local tiles_x, tiles_y = sw // 8, sh // 8
  local out = {}
  for tile = 0, tiles_x * tiles_y - 1 do
    for j = 0, 63 do
      local px, py = pos(j)
      local x, y = (tile % tiles_x) * 8 + px, (tile // tiles_x) * 8 + py
      out[#out + 1] = pack("<I2", (x < w and y < h) and colour(x, y) or 0)
    end
  end
  local data = table.concat(out)
  return data .. M.footer(w, h, fmt or 7, #data)
end

return M

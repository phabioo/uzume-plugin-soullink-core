-- Synthetic builders and a fake codec for documented container formats.
-- Test-only: the fake decoder reads linear RGBA8888 BCLIM (format 9) and a fake PNG;
-- the real tiling/format decoding is the host's uz.codec job.
local M = {}
local pack, unpack = string.pack, string.unpack

-- BCLIM: pixel data followed by the 40-byte footer ("CLIM" header 20 + "imag" block 20).
function M.bclim(w, h, rgba)
  rgba = rgba or string.rep("\0\0\0\255", w * h)
  assert(#rgba == w * h * 4)
  local total = #rgba + 40
  return rgba .. "CLIM" .. pack("<I2I2I4I4I2I2", 0xFEFF, 0x14, 0x02020000, total, 1, 0)
    .. "imag" .. pack("<I4I2I2I4I4", 0x10, w, h, 9, #rgba)
end

-- GARC version 0x0400, one sub-file per entry (nil entries are skipped as empty files).
function M.garc(files)
  local n = #files
  local fato = {}
  local fatb = {}
  local data = {}
  local pos = 0
  for i = 1, n do
    fato[i] = pack("<I4", (i - 1) * 16)
    local f = files[i]
    local len = #f
    local padded = (len + 3) & ~3
    fatb[i] = pack("<I4I4I4I4", 1, pos, pos + len, len)
    data[i] = f .. string.rep("\0", padded - len)
    pos = pos + padded
  end
  local fato_s = "OTAF" .. pack("<I4I2I2", 12 + 4 * n, n, 0xFFFF) .. table.concat(fato)
  local fatb_s = "BTAF" .. pack("<I4I4", 12 + 16 * n, n) .. table.concat(fatb)
  local body = table.concat(data)
  local fimb = "BMIF" .. pack("<I4I4", 12, #body)
  local head_len = 0x1C
  local data_offset = head_len + #fato_s + #fatb_s + 12
  local total = data_offset + #body
  local head = "CRAG" .. pack("<I4I2I2I4I4I4I4", head_len, 0xFEFF, 0x0400, 4, data_offset, total, pos)
  return head .. fato_s .. fatb_s .. fimb .. body
end

-- DARC: root + optional directory; files = { { path = "timg/a.bclim", data = ... }, ... }
-- (paths have at most one directory level).
function M.darc(files)
  local entries, names = {}, {}
  local function name(s)
    local off = #table.concat(names)
    local u = {}
    for i = 1, #s do u[#u + 1] = pack("<I2", s:byte(i)) end
    names[#names + 1] = table.concat(u) .. "\0\0"
    return off
  end
  local dirs, order = {}, {}
  for _, f in ipairs(files) do
    local d, base = f.path:match("^(.-)/?([^/]+)$")
    if not dirs[d] then dirs[d] = {}; order[#order + 1] = d end
    table.insert(dirs[d], { name = base, data = f.data })
  end
  -- entry 0: root, then per directory: dir entry + its files
  local ents = { { root = true } }
  for _, d in ipairs(order) do
    if d == "" then
      for _, f in ipairs(dirs[d]) do ents[#ents + 1] = { file = f } end
    else
      ents[#ents + 1] = { dir = d, files = dirs[d] }
      for _, f in ipairs(dirs[d]) do ents[#ents + 1] = { file = f, parent = #ents } end
    end
  end
  local count = #ents
  local table_off = 0x1C
  local names_off_start = table_off + count * 12
  local tmp = {}
  local name_offs = {}
  for i, e in ipairs(ents) do
    name_offs[i] = name(e.root and "" or (e.dir or e.file.name))
  end
  local names_s = table.concat(names)
  local data_off = (names_off_start + #names_s + 0x7F) & ~0x7F
  local blob, cursor = {}, data_off
  local rows = {}
  for i, e in ipairs(ents) do
    if e.root then
      rows[i] = pack("<I4I4I4", (1 << 24) | name_offs[i], 0, count)
    elseif e.dir then
      rows[i] = pack("<I4I4I4", (1 << 24) | name_offs[i], 0, i - 1 + 1 + #e.files)
    else
      local pad = (cursor + 3) & ~3
      if pad > cursor then blob[#blob + 1] = string.rep("\0", pad - cursor); cursor = pad end
      rows[i] = pack("<I4I4I4", name_offs[i], cursor, #e.file.data)
      blob[#blob + 1] = e.file.data
      cursor = cursor + #e.file.data
    end
  end
  local tbl = table.concat(rows) .. names_s
  local pad = string.rep("\0", data_off - table_off - #tbl)
  local total = cursor
  local head = "darc" .. pack("<I2I2I4I4I4I4I4", 0xFEFF, 0x1C, 0x11000000, total, table_off, #tbl + #pad, data_off)
  return head .. tbl .. pad .. table.concat(blob)
end

-- LZ11 stream made of literals only (valid: flag byte 0, then 8 literal bytes per block).
function M.lz11_literal(s)
  local out = { pack("<I1I3", 0x11, #s) }
  for i = 1, #s, 8 do
    local chunk = s:sub(i, i + 7)
    out[#out + 1] = "\0" .. chunk
  end
  return table.concat(out)
end

function M.fake_codec(extra)
  local c = {}
  local function parse(d)
    if type(d) ~= "string" or d:sub(1, 4) ~= "CRAG" then return nil end
    local data_offset = unpack("<I4", d, 0x11)
    local n = unpack("<I2", d, 0x1C + 8 + 1)
    local files = {}
    local fatb = 0x1C + (12 + 4 * n) + 12
    for i = 1, n do
      local _, s, e, len = unpack("<I4I4I4I4", d, fatb + (i - 1) * 16 + 1)
      files[i] = { { offset = s, length = len } }
    end
    return { count = n, data_offset = data_offset, files = files }
  end
  c.garc = function(d)
    local g = parse(d)
    if not g then return nil, "not a garc" end
    return g
  end
  c.garc_file = function(d, i, sub)
    local g = parse(d)
    local f = g and g.files[i] and g.files[i][sub or 1]
    if not f then return nil, "no entry" end
    return d:sub(g.data_offset + f.offset + 1, g.data_offset + f.offset + f.length)
  end
  c.bclim = function(s)
    if #s < 40 or s:sub(-40, -37) ~= "CLIM" then return nil, "not a bclim" end
    local w, h, fmt = unpack("<I2I2I4", s, #s - 39 + 28)
    if fmt ~= 9 or #s ~= w * h * 4 + 40 then return nil, "unsupported format" end
    return { width = w, height = h, rgba = s:sub(1, w * h * 4) }
  end
  c.png = function(img) return "\137PNG\r\n\26\n" .. pack("<I2I2", img.width, img.height) .. img.rgba end
  c.lz_decompress = function(s)
    local kind = s:byte(1)
    if kind ~= 0x11 then return nil, "unsupported" end
    local size = unpack("<I3", s, 2)
    local out, pos = {}, 5
    local got = 0
    while got < size do
      local flags = s:byte(pos); pos = pos + 1
      if flags ~= 0 then return nil, "fake codec: literals only" end
      local chunk = s:sub(pos, pos + math.min(8, size - got) - 1)
      out[#out + 1] = chunk; pos = pos + #chunk; got = got + #chunk
    end
    return table.concat(out)
  end
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

return M

-- Shared GARC entry reading. pk3DS reads every GARC entry through GARCEntry, which LZ11-decompresses
-- any entry whose first byte is 0x11 and keeps the raw bytes when that fails (pk3DS.Core/CTR/GARC.cs).
-- Plain readers (text, personal, icons) use `entry`; zones and maps use `decompress` directly.
local M = {}

M.MAX_LZ_OUTPUT = 8 * 1024 * 1024 -- output size limit of a decompressed entry

-- Decompresses `e` when its first byte is 0x11 (also 0x10 with allow_lz10) via codec.lz_decompress.
-- Returns data, status: "lz" (decompressed), "raw" (not compressed or no codec) or
-- "lz_failed" (data = the raw entry; decompression raised, returned a non-string or exceeded the limit).
function M.decompress(codec, e, allow_lz10)
  if type(e) ~= "string" then return e, "raw" end
  local b = e:byte(1)
  if (b == 0x11 or (allow_lz10 and b == 0x10)) and codec and codec.lz_decompress then
    local ok, out = pcall(codec.lz_decompress, e)
    if ok and type(out) == "string" and #out <= M.MAX_LZ_OUTPUT then return out, "lz" end
    return e, "lz_failed"
  end
  return e, "raw"
end

-- GARC file `index` (1-based, first sub-file), decompressed if needed. Returns data, status
-- (see decompress); nil, "garc_error" | "no_entry" when the entry cannot be read.
function M.entry(codec, d, index)
  local ok, e = pcall(codec.garc_file, d, index, 1)
  if not ok then return nil, "garc_error" end
  if type(e) ~= "string" or #e == 0 then return nil, "no_entry" end
  return M.decompress(codec, e)
end

return M

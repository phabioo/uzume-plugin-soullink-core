-- Box icons of Gen 6 games, read at runtime from the player's own RomFS and
-- converted to PNG with fb.codec.bclim + fb.codec.png. Nothing is shipped; the
-- PNGs are derived data in the plugin cache (fb.cache), never in the repository.
--
-- The icon GARC is not hardcoded: it is discovered by walking the RomFS and
-- validated by content (see docs/games/omega-ruby-alpha-sapphire.md, "Icons").
-- Discovery runs one small step per call (one directory listing or one
-- candidate validation) so no entry call comes near the 500 ms / 20M budget.
local garc_entry = require("gen6.garc_entry")
local pal_bclim = require("gen6.pal_bclim")
local icon_order = require("gen6.icon_order")
local M = {}

M.CANDIDATE_PATHS = {}      -- known paths are not sourced; discovery finds the file
M.ROOT = "/a"
M.MIN_FILE_SIZE = 256 * 1024       -- assumption: >= ~700 icons of >= 0.4 KiB
M.MAX_FILE_SIZE = 16 * 1024 * 1024
M.MIN_ENTRIES, M.MAX_ENTRIES = 700, 1100
M.SAMPLES = { 1, 25, 150, 300, 500, 700 } -- species whose entries are decoded to validate
M.SIZES = { ["40x30"] = true, ["32x32"] = true, ["64x32"] = true } -- accepted BCLIM sizes
M.MAX_STEPS = 4000
M.INDEX_FILE = "icons/index.txt"      -- first line: RomFS path of the icon GARC
M.OVERRIDE_FILE = "config/icon_garc.txt" -- optional: RomFS path to try first
M.MAX_SPECIES = 721
M.EXPORT_ENTRIES = { 0, 1, 25, 201, 255, 258, 261 } -- 0-based GARC entries of the one-time debug export
M.EXPORT_RAW = { 1, 255 }        -- entries that are also exported undecompressed
M.EXPORT_MAX_BINS = 12           -- cap of exported .bin files
M.EXPORT_BUDGET_MS = 25          -- wall-clock budget of one export step (fb.clock)
M.CACHE_REV = "r3-o1"  -- part of the PNG cache key: bump when decoding or the entry mapping changes (r3 = variant D palette decoder, o1 = measured icon order)
M.REV = M.CACHE_REV    -- icon decoder revision exposed as info().icon_rev so consumers can key their own caches
M.PROBE_PATH = "/a/0/9/1"   -- Project Pokemon ORAS file system: "971 box sprites" (diagnostics probe only)
M.PROBE_ENTRIES = { 1, 25, 700 } -- 0-based GARC entries inspected by diagnostics()

local function first_line(s)
  if type(s) ~= "string" then return nil end
  local l = s:match("^%s*([^\r\n]-)%s*[\r\n]") or s:match("^%s*(.-)%s*$")
  if l and l:match("^/[%w%._%-/]+$") then return l end
  return nil
end

function M.new(fb, personal)
  local self = {}
  local codec = fb.codec
  local can = fb.rom and fb.rom.romfs and fb.rom.romfs_list and codec and codec.garc
    and codec.garc_file and codec.bclim and codec.png and fb.cache and true or false

  local state = can and "idle" or "unsupported" -- idle | scan | done | failed | unsupported
  local data, path, icon_count
  local forced, dirs, cands, steps = {}, {}, {}, 0
  local exp_status = "pending" -- diagnostics key icon_export

  local function read_cache(name)
    local ok, v = pcall(fb.cache.read, name)
    if ok and type(v) == "string" then return v end
    return nil
  end

  -- Accepts the GARC when sampled entries decode to BCLIM images of an accepted size.
  local first_reject = nil
  local function reject(why) if not first_reject then first_reject = why end; return false end
  local function short(v) return (tostring(v):gsub("[^%w _%.:%-]", "?"):sub(1, 40)) end

  local function validate(d)
    local ok, g, gerr = pcall(codec.garc, d)
    if not ok or type(g) ~= "table" or type(g.count) ~= "number" then
      return reject("garc_rejected: " .. short(ok and gerr or g))
    end
    if g.count < M.MIN_ENTRIES or g.count > M.MAX_ENTRIES then return reject("garc_entries_" .. g.count) end
    for _, s in ipairs(M.SAMPLES) do
      local e = garc_entry.entry(codec, d, s + 1)
      if type(e) ~= "string" then return reject("entry_unreadable_" .. s) end
      local img = codec.bclim(e)
      if type(img) ~= "table" then return reject("bclim_failed_" .. s) end
      local size = tostring(img.width) .. "x" .. tostring(img.height)
      if not M.SIZES[size] then return reject("size_" .. size) end
    end
    return true
  end

  local function try_path(p)
    local d = fb.rom.romfs(p)
    if type(d) ~= "string" or not validate(d) then return false end
    data, path, state = d, p, "done"
    local okc, gg = pcall(codec.garc, d)
    icon_count = okc and type(gg) == "table" and gg.count or nil
    pcall(fb.cache.write, M.INDEX_FILE, p .. "\n")
    if fb.log and fb.log.info then fb.log.info("icon archive accepted at " .. p) end
    return true
  end

  local function start()
    state = "scan"
    local seen = {}
    local function add(p)
      if p and not seen[p] then seen[p] = true; forced[#forced + 1] = p end
    end
    add(first_line(read_cache(M.OVERRIDE_FILE)))
    add(first_line(read_cache(M.INDEX_FILE)))
    for _, p in ipairs(M.CANDIDATE_PATHS) do add(p) end
    dirs = { M.ROOT }
  end

  local function scan_dir(dir)
    local list = fb.rom.romfs_list(dir)
    if type(list) ~= "table" then return end
    for _, e in ipairs(list) do
      local full = dir .. "/" .. tostring(e.name)
      if e.dir then
        dirs[#dirs + 1] = full
      elseif type(e.size) == "number" and e.size >= M.MIN_FILE_SIZE and e.size <= M.MAX_FILE_SIZE then
        cands[#cands + 1] = full
      end
    end
  end

  local function advance()
    if state == "idle" then start() end
    if state ~= "scan" then return end
    steps = steps + 1
    if steps > M.MAX_STEPS then state = "failed"; return end
    if #forced > 0 then
      try_path(table.remove(forced, 1))
    elseif #cands > 0 then
      try_path(table.remove(cands, 1))
    elseif #dirs > 0 then
      scan_dir(table.remove(dirs, 1))
    else
      state = "failed"
      if fb.log and fb.log.warn then fb.log.warn("no box icon archive found in the RomFS") end
    end
  end

  -- One bounded discovery step. Never raises.
  function self.step()
    local ok, err = pcall(advance)
    if not ok then
      state = "failed"
      if fb.log and fb.log.error then fb.log.error("icon discovery failed: " .. tostring(err)) end
    end
  end

  -- Probe of the icon archive for diagnostics(): numbers and short strings only, no pixels, no names.
  -- Read once and cached; the archive is the accepted one or, if none was accepted, M.PROBE_PATH.
  local probe, probe_key
  local function hex(b) return b and string.format("0x%02X", b) or "none" end
  local function probe_entry(out, tag, d, n)
    local ok, raw = pcall(codec.garc_file, d, n + 1, 1)
    if not ok or type(raw) ~= "string" or #raw == 0 then out[tag .. "_first"] = "unreadable"; return end
    out[tag .. "_first"] = hex(raw:byte(1))
    local e, status = garc_entry.decompress(codec, raw)
    out[tag .. "_lz11"] = status == "lz" and 1 or 0
    if status == "lz_failed" then out[tag .. "_lz_failed"] = 1 end
    out[tag .. "_size"] = #e
    local fmt, w, h = -1, -1, -1
    if #e >= 0x28 and e:sub(#e - 0x27, #e - 0x24) == "CLIM" then
      w, h = string.unpack("<I2I2", e, #e - 0x28 + 0x1C + 1)
      fmt = e:byte(#e - 0x28 + 0x20 + 1)
    end
    out[tag .. "_fmt"], out[tag .. "_w"], out[tag .. "_h"] = fmt, w, h
    out[tag .. "_px0"] = #e >= 2 and string.format("0x%04X", string.unpack("<I2", e, 1)) or "none"
    out[tag .. "_layout"] = pal_bclim.layout(e) or "none"
    local info = pal_bclim.inspect(e)
    if info then
      local pal, idx = {}, {}
      for _, v in ipairs(info.pal) do pal[#pal + 1] = string.format("%04X", v) end
      for _, v in ipairs(info.idx) do idx[#idx + 1] = string.format("%02X", v) end
      out[tag .. "_count"] = info.count
      out[tag .. "_pal"] = table.concat(pal, ",")
      out[tag .. "_idx"] = table.concat(idx, ",")
      out[tag .. "_idxbytes"] = info.idx_bytes
    end
    local head = {}
    for i = 1, math.min(16, #e) do head[i] = string.format("%02X", e:byte(i)) end
    out[tag .. "_head"] = table.concat(head, " ")
  end

  local function run_probe()
    local out = { icons_state = state, icons_path = path or "none", icons_count = -1, icons_garc_ok = 0 }
    if not can then return out end
    local d = data
    if not d then
      local okr, r = pcall(fb.rom.romfs, M.PROBE_PATH)
      d = okr and type(r) == "string" and r or nil
      out.icons_path = M.PROBE_PATH .. (d and "" or " (unreadable)")
    end
    if d then
      local ok, g, gerr = pcall(codec.garc, d)
      if ok and type(g) == "table" and type(g.count) == "number" then
        out.icons_garc_ok, out.icons_count = 1, g.count
        for _, n in ipairs(M.PROBE_ENTRIES) do probe_entry(out, "icon_e" .. n, d, n) end
      else
        out.icons_garc_error = short(ok and gerr or g)
      end
    end
    return out
  end

  function self.diagnostics()
    if not can then return { icons_state = state, icon_export = "unsupported" } end
    -- one probe per archive: the fixed probe path until discovery accepts another archive
    local key = path or M.PROBE_PATH
    if not probe or probe_key ~= key then probe, probe_key = run_probe(), key end
    local out = {}
    for k, v in pairs(probe) do out[k] = v end
    out.icons_state = state
    out.icons_first_rejection = first_reject or "none"
    out.icon_export = exp_status
    return out
  end

  -- One-time debug export (0.4.1): the DECOMPRESSED bytes of a few icon GARC entries (exactly what
  -- the decoder gets) go to the plugin's own cache as diag/icon-<entry0>.bin, plus diag/icon-index.txt.
  -- Local to the player's PC, never logged. Runs one time-budgeted step per call once discovery is done.
  local exp = { state = "idle", queue = nil, lines = {}, files = 0, bins = 0, g = nil, err = nil }
  local function exp_clock() local ok, v = pcall(fb.clock or function() end); return ok and v or nil end

  local function exp_fail(why)
    exp.state = "failed"
    exp_status = short(why)
  end

  local function exp_write(name, bytes)
    local ok, r = pcall(fb.cache.write, name, bytes)
    if not ok or r == false then return false end
    exp.files = exp.files + 1
    return true
  end

  local function exp_queue(team_fn)
    local q, seen = {}, {}
    local function add(n)
      if math.type(n) == "integer" and n >= 0 and not seen[n] and #q < M.EXPORT_MAX_BINS then
        seen[n] = true; q[#q + 1] = n
      end
    end
    for _, n in ipairs(M.EXPORT_ENTRIES) do add(n) end
    if type(team_fn) == "function" then
      local ok, list = pcall(team_fn)
      if ok and type(list) == "table" then
        for _, sp in ipairs(list) do if math.type(sp) == "integer" and sp >= 1 then add(sp) end end
      end
    end
    -- raw (undecompressed) copies count against the cap too: they are extra .bin files
    return q
  end

  local function exp_header(count, g)
    local subs = {}
    for i = 1, 8 do
      local f = type(g.files) == "table" and g.files[i]
      subs[i] = type(f) == "table" and tostring(#f) or "n/a"
    end
    return string.format("# garc=%s entries=%s version=%s data_offset=%s fatb_subfiles_first8=%s",
      tostring(path), tostring(count), tostring(g.version or "n/a"), tostring(g.data_offset or "n/a"),
      table.concat(subs, ","))
  end

  local function exp_one(n)
    local ok, raw = pcall(codec.garc_file, data, n + 1, 1)
    if not ok or type(raw) ~= "string" or #raw == 0 then
      exp.lines[#exp.lines + 1] = string.format("%d unreadable", n)
      return
    end
    local e = garc_entry.decompress(codec, raw)
    local head = {}
    for i = 1, math.min(16, #e) do head[i] = string.format("%02X", e:byte(i)) end
    local foot = "w=-1 h=-1 fmt=-1"
    if #e >= 0x28 and e:sub(#e - 0x27, #e - 0x24) == "CLIM" then
      local w, h = string.unpack("<I2I2", e, #e - 0x28 + 0x1C + 1)
      foot = string.format("w=%d h=%d fmt=%d", w, h, e:byte(#e - 0x28 + 0x20 + 1))
    end
    exp.lines[#exp.lines + 1] = string.format("%d comp=%d decomp=%d head=%s footer=%s",
      n, #raw, #e, table.concat(head, " "), foot)
    if not exp_write(string.format("diag/icon-%d.bin", n), e) then error("write_failed", 0) end
    exp.bins = exp.bins + 1
    for _, rn in ipairs(M.EXPORT_RAW) do
      if rn == n and exp.bins < M.EXPORT_MAX_BINS then
        if not exp_write(string.format("diag/icon-%d-raw.bin", n), raw) then error("write_failed", 0) end
        exp.bins = exp.bins + 1
      end
    end
  end

  local function exp_advance(team_fn)
    if exp.state == "idle" then
      local okg, g = pcall(codec.garc, data)
      if not okg or type(g) ~= "table" then return exp_fail("garc_unreadable") end
      exp.g, exp.queue, exp.state = g, exp_queue(team_fn), "run"
      exp.header = exp_header(g.count, g)
    end
    local t0 = exp_clock()
    while #exp.queue > 0 do
      local n = table.remove(exp.queue, 1)
      local ok, err = pcall(exp_one, n)
      if not ok then return exp_fail(tostring(err)) end
      local now = exp_clock()
      if t0 and now and now - t0 >= M.EXPORT_BUDGET_MS then return end
    end
    local text = exp.header .. "\n" .. table.concat(exp.lines, "\n") .. "\n"
    if not exp_write("diag/icon-index.txt", text) then return exp_fail("write_failed") end
    exp.state = "done"
    exp_status = string.format("done:%d files", exp.files)
  end

  -- One bounded export step (only after discovery accepted the archive); team_fn returns species
  -- numbers of the current team or nil. Never raises.
  function self.export_step(team_fn)
    if exp.state == "done" or exp.state == "failed" then return end
    if not can then exp_status = "unsupported"; exp.state = "failed"; return end
    if state == "failed" then exp_status = "no_icon_archive"; exp.state = "failed"; return end
    if state ~= "done" or not data then return end
    local ok, err = pcall(exp_advance, team_fn)
    if not ok then exp_fail(tostring(err)) end
  end

  function self.export_done() return exp.state == "done" or exp.state == "failed" end

  function self.found() return state == "done" end
  function self.state() return state end
  function self.path() return path end
  function self.icon_rev() return M.REV end

  -- Restart discovery (e.g. after a game change).
  function self.reset()
    if can then state = "idle" end
    data, path, icon_count, forced, dirs, cands, steps = nil, nil, nil, {}, {}, {}, 0
    probe, probe_key, first_reject = nil, nil, nil
    exp.state, exp.queue, exp.lines, exp.files, exp.bins, exp.g = "idle", nil, {}, 0, 0, nil
    exp_status = "pending"
  end

  local function entry_for(species, form)
    -- the ORAS icon GARC (974 entries) is ordered by the measured table, not by species
    if icon_count == icon_order.COUNT then
      local e, exact = icon_order.entry(species, form)
      if e then return e, exact end
    end
    local idx = personal and personal.form_index(species, form)
    if idx then return idx, true end
    -- no such form or personal table unreadable: base icon, not cached under the form key
    return species, false
  end

  -- Blob of a species form, or nil, reason.
  local function blob_for(species, form)
    if state == "unsupported" then return nil, "unsupported" end
    if state ~= "done" then
      self.step()
      if state == "failed" then return nil, "unsupported" end
      if state ~= "done" then return nil, "not_ready" end
    end
    local idx, exact = entry_for(species, form)
    local blob = garc_entry.entry(codec, data, idx + 1)
    if type(blob) ~= "string" then return nil, "unknown_species" end
    return blob, exact
  end

  local function valid_args(species, form)
    if math.type(species) ~= "integer" or species < 1 or species > M.MAX_SPECIES then return false end
    if form == nil then form = 0 end
    if math.type(form) ~= "integer" or form < 0 then return false end
    return true, form
  end

  -- PNG string, or nil, "not_ready" | "unsupported" | "unknown_species".
  -- Palette / plain 16-bit data of the Gen 6 icons is decoded in Lua (gen6.pal_bclim, default
  -- variant pal_bclim.DEFAULT_VARIANT); every other BCLIM goes through fb.codec.bclim.
  function self.icon(species, form)
    local ok, f = valid_args(species, form)
    if not ok then return nil, "unknown_species" end
    form = f
    local key = string.format("icons/%d-%d-%s.png", species, form, M.CACHE_REV)
    if state == "unsupported" then return nil, "unsupported" end
    local hit = read_cache(key)
    if hit then return hit end
    local blob, exact = blob_for(species, form)
    if not blob then return nil, exact end
    local img = pal_bclim.decode_auto(blob)
    if type(img) ~= "table" then img = codec.bclim(blob) end
    if type(img) ~= "table" then return nil, "unknown_species" end
    local png = codec.png(img)
    if type(png) ~= "string" then return nil, "unknown_species" end
    if exact then pcall(fb.cache.write, key, png) end
    return png
  end

  -- Up to 5 decodings of the species icon to compare: { label, desc, png } for the labels A..D
  -- (palette readings, see pal_bclim.VARIANTS) and E (plain tiled RGBA5551). Variants that cannot
  -- be decoded for this data are left out. nil, "not_ready" | "unsupported" | "unknown_species".
  function self.icon_variants(species, form)
    local ok, f = valid_args(species, form)
    if not ok then return nil, "unknown_species" end
    local blob, err = blob_for(species, f)
    if not blob then return nil, err end
    local layout = pal_bclim.layout(blob)
    if layout == nil then return nil, "unsupported" end
    -- consumers may show only the first 4 entries: for plain 16-bit data E goes first, else the default variant
    local order = { pal_bclim.DEFAULT_VARIANT }
    for _, label in ipairs(pal_bclim.ORDER) do
      if label ~= pal_bclim.DEFAULT_VARIANT then order[#order + 1] = label end
    end
    if layout == "plain16" then order = { "E", "A", "B", "C", "D" } end
    local out = {}
    for _, label in ipairs(order) do
      local img = pal_bclim.decode_variant(blob, label)
      local png = type(img) == "table" and codec.png(img)
      if type(png) == "string" then
        out[#out + 1] = { label = label, desc = pal_bclim.VARIANTS[label].desc, png = png }
      end
    end
    if #out == 0 then return nil, "unsupported" end
    return out
  end

  return self
end

return M

-- Region map discovery: finds large BCLIM images in the player's own RomFS at
-- runtime (plain files, GARC entries, LZ10/LZ11-wrapped entries, DARC archives)
-- and converts a chosen one to PNG. No image is shipped; the index and PNGs are
-- derived data in the plugin cache (uz.cache). Scanning is a resumable state
-- machine. One unit = one directory listing, one archive open, or a bounded batch of entries;
-- one step() runs units until a wall-clock budget (STEP_BUDGET_MS, uz.clock) is used up, so no
-- entry call nears the 500 ms / 20M instruction budget. The scan always ends in `done` (a list,
-- possibly empty) or `failed` (with a reason): a throwing entry or archive is skipped and counted
-- (never retried), and MAX_SCAN_MS bounds the whole scan.
local darc = require("gen6.darc")
local garc_entry = require("gen6.garc_entry")

local M = {}

M.ROOT = "/a"
M.MAX_FILE_SIZE = 32 * 1024 * 1024  -- larger files are skipped
M.MIN_FILE_SIZE = 64
M.MIN_W, M.MIN_H = 256, 128         -- candidate threshold (decoded size = BCLIM header size)
M.ENTRIES_PER_STEP = 16             -- entries per unit
M.STEP_BUDGET_MS = 25               -- wall-clock budget of one step() (units run until it is used)
M.MAX_UNITS_PER_STEP = 200          -- hard cap when uz.clock is missing or stands still
M.MAX_SCAN_MS = 30 * 60 * 1000      -- scan time limit (uz.clock): then `failed` with the partial list
-- Entries whose decoded size is below this cannot hold a candidate (4-bit texture of MIN_W x MIN_H
-- plus the footer): they are skipped without decompressing (LZ header) or decoding.
M.MIN_DECODED = (256 * 128) // 2 + 40
M.INDEX_REV = "3"                   -- cache format revision; other revisions are rescanned
M.MAX_ENTRIES_PER_FILE = 5000
M.MAX_LZ_INPUT = 2 * 1024 * 1024
M.MAX_LZ_OUTPUT = 4 * 1024 * 1024
M.MAX_ERRORS = 500                  -- scan errors tolerated before `failed`
M.MAX_CANDIDATES = 2000             -- kept in the index
M.LIST_CAP = 40                     -- returned by map_candidates
M.MAX_PNG = 1024 * 1024             -- interface value limit
M.SAVE_EVERY = 10                   -- files between progress writes
M.INDEX = "map/index.txt"           -- "complete" or "partial", then id TAB w TAB h lines
M.FILES = "map/files.txt"           -- sorted list of scanned file paths
M.PROGRESS = "map/progress.txt"     -- number of files fully scanned
-- Archives named in the Project Pokemon ORAS file list as town map UI / PokeNav screens: scanned first.
M.PRIORITY = { "/a/0/6/7", "/a/0/6/8", "/a/2/4/8", "/a/2/7/6" }
-- Noise filter: a decoded candidate is dropped when more than NOISE_RATIO of the sampled
-- neighbouring pixel pairs differ by more than NOISE_DIFF (sum of the RGB differences, max 765).
M.NOISE_DIFF, M.NOISE_RATIO, M.NOISE_MIN_PAIRS = 96, 0.5, 200
M.NOISE_ROWS, M.NOISE_COLS = 64, 128 -- sample grid (bounds the work per candidate)

-- Map id per game id, optionally per revision: MAP_ID[game_id] = "<id>" or { ["v1.0"] = "<id>" }.
-- Fill after the maintainer confirms the region map image.
M.MAP_ID = {}

-- Width, height of a BCLIM from its 40-byte footer ("CLIM" header + "imag" block), or nil.
function M.bclim_size(s)
  if #s < 40 then return nil end
  local f = #s - 39 -- 1-based start of the footer
  if s:sub(f, f + 3) ~= "CLIM" or s:sub(f + 20, f + 23) ~= "imag" then return nil end
  local w, h = string.unpack("<I2I2", s, f + 28)
  return w, h
end

local function hash(id)
  local h = 5381
  for i = 1, #id do h = (h * 33 + id:byte(i)) & 0xFFFFFFFF end
  return string.format("%08x", h)
end

-- True when the decoded image { width, height, rgba } looks like noise (garbage decode of a wrong
-- candidate): real maps and UI textures have large smooth areas, noise differs at almost every pixel.
function M.noisy(img)
  if type(img) ~= "table" or type(img.rgba) ~= "string" then return false end
  local w, h, px = img.width, img.height, img.rgba
  if type(w) ~= "number" or type(h) ~= "number" or w < 2 or h < 1 or #px < w * h * 4 then return false end
  local ystep = math.max(1, h // M.NOISE_ROWS)
  local xstep = math.max(1, (w - 1) // M.NOISE_COLS)
  local pairs_n, strong = 0, 0
  for y = 0, h - 1, ystep do
    for x = 0, w - 2, xstep do
      local o = (y * w + x) * 4 + 1
      local r1, g1, b1, a1, r2, g2, b2, a2 = px:byte(o, o + 7)
      if a1 ~= 0 or a2 ~= 0 then
        pairs_n = pairs_n + 1
        if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > M.NOISE_DIFF then strong = strong + 1 end
      end
    end
  end
  return pairs_n >= M.NOISE_MIN_PAIRS and strong / pairs_n > M.NOISE_RATIO
end

-- "<path>#<entry>[/<darc path>]" -> path, entry, sub
function M.parse_id(id)
  if type(id) ~= "string" then return nil end
  local path, entry, sub = id:match("^(/[^#]+)#(%d+)/(.+)$")
  if not path then path, entry = id:match("^(/[^#]+)#(%d+)$") end
  if not path then return nil end
  return path, tonumber(entry), sub
end

-- Short, log-safe text.
local function short(v) return (tostring(v):gsub("[^%w _%.:#/%-]", "?"):sub(1, 60)) end

function M.new(uz, game_id, revision_fn)
  local self = {}
  local codec = uz.codec
  local missing
  if not (uz.rom and uz.rom.romfs) then missing = "uz.rom.romfs"
  elseif not uz.rom.romfs_list then missing = "uz.rom.romfs_list"
  elseif not codec then missing = "uz.codec"
  elseif not codec.png then missing = "codec.png"
  elseif not codec.bclim then missing = "codec.bclim"
  elseif not uz.cache then missing = "uz.cache" end
  -- idle | dirs | files | done | failed | unsupported
  local state = missing and "unsupported" or "idle"
  local dirs, files, fidx, cands, cur = {}, {}, 0, {}, nil
  local first_reject = missing and ("missing_" .. missing) or nil
  local fail_reason
  local stat = { entries = 0, errors = 0, steps = 0, started = nil, elapsed = 0, archives_skipped = 0 }

  local function reject(why) if not first_reject then first_reject = short(why) end end
  local function clock()
    if type(uz.clock) ~= "function" then return nil end
    local ok, v = pcall(uz.clock)
    if ok and type(v) == "number" then return v end
  end

  local function cread(name)
    local ok, v = pcall(uz.cache.read, name)
    if ok and type(v) == "string" then return v end
  end
  local function cwrite(name, data) pcall(uz.cache.write, name, data) end

  local function save_index(complete)
    local lines = { (complete and "complete " or "partial ") .. M.INDEX_REV }
    for _, c in ipairs(cands) do lines[#lines + 1] = c.id .. "\t" .. c.w .. "\t" .. c.h end
    cwrite(M.INDEX, table.concat(lines, "\n") .. "\n")
  end

  local function load_state()
    local idx = cread(M.INDEX)
    local usable = false
    if idx then
      local first = true
      local loaded = {}
      for line in idx:gmatch("[^\n]+") do
        if first then
          first = false
          local kind, rev = line:match("^(%a+) (%w+)$")
          if rev == M.INDEX_REV and (kind == "complete" or kind == "partial") then
            usable = true
            if kind == "complete" then state = "done" end
          else
            break -- index of an older revision (or unknown): rescan
          end
        else
          local id, w, h = line:match("^(.-)\t(%d+)\t(%d+)$")
          if id then loaded[#loaded + 1] = { id = id, w = tonumber(w), h = tonumber(h) } end
        end
      end
      if usable then cands = loaded end
      if state == "done" then return end
    end
    local list = usable and cread(M.FILES)
    if list then
      for line in list:gmatch("[^\n]+") do files[#files + 1] = line end
      fidx = math.min(tonumber(cread(M.PROGRESS) or "0") or 0, #files)
      if #files > 0 then state = "files"; return end
      files = {}
    end
    cands = {}
    dirs = { M.ROOT }
    state = "dirs"
  end

  -- bclim: the BCLIM bytes; the candidate is decoded once and dropped when the image is mostly noise
  -- (a failed decode keeps it: only proven garbage is dropped).
  local function add(id, w, h, bclim)
    if w >= M.MIN_W and h >= M.MIN_H and #cands < M.MAX_CANDIDATES then
      if bclim and codec.bclim then
        local ok, img = pcall(codec.bclim, bclim)
        if ok and type(img) == "table" and M.noisy(img) then return end
      end
      cands[#cands + 1] = { id = id, w = w, h = h }
    end
  end

  -- Looks into plain data (no further LZ): BCLIM or DARC with BCLIM files.
  local function examine_plain(s, id)
    -- DARC first: its last member may end in a BCLIM footer that would pass for the archive's own
    if s:sub(1, 4) ~= "darc" then
      local w, h = M.bclim_size(s)
      if w then add(id, w, h, s) end
    else
      local list = darc.parse(s)
      if list then
        for _, f in ipairs(list) do
          if f.length >= 40 then
            local sub = s:sub(f.offset + 1, f.offset + f.length)
            local fw, fh = M.bclim_size(sub)
            if fw then add(id .. "/" .. f.path, fw, fh, sub) end
          end
        end
      end
    end
  end

  -- Decoded size announced by an LZ10/LZ11 header, or nil.
  local function lz_size(e)
    if #e < 8 then return nil end
    local n = string.unpack("<I3", e, 2)
    if n == 0 then n = string.unpack("<I4", e, 5) end
    return n
  end

  local function examine(e, id)
    local b = e:byte(1)
    if (b == 0x10 or b == 0x11) and #e > 4 and codec.lz_decompress then
      -- the header tells the decoded size: entries that cannot hold a candidate are not decompressed
      local n = lz_size(e)
      if #e <= M.MAX_LZ_INPUT and n and n >= M.MIN_DECODED and n <= M.MAX_LZ_OUTPUT then
        local out, status = garc_entry.decompress(codec, e, true)
        if status == "lz" then examine_plain(out, id) else reject("lz_failed " .. id) end
      end
      return
    end
    if #e >= M.MIN_DECODED then examine_plain(e, id) end
  end

  local function open_file(path)
    local d = uz.rom.romfs(path)
    if type(d) ~= "string" then reject("romfs_unreadable " .. path); return nil end
    local okg, g = false, nil
    if codec.garc and codec.garc_file then okg, g = pcall(codec.garc, d) end
    if okg and type(g) == "table" and type(g.count) == "number" and g.count >= 1 then
      return { path = path, data = d, garc = true, count = math.min(g.count, M.MAX_ENTRIES_PER_FILE), next = 1, g = g }
    end
    return { path = path, data = d, garc = false, count = 1, next = 1 }
  end

  -- One bounded batch of entries; `next` moves first, so a throwing entry is never retried.
  local function process(c)
    local last = math.min(c.next + M.ENTRIES_PER_STEP - 1, c.count)
    for i = c.next, last do
      c.next = i + 1
      stat.entries = stat.entries + 1
      local ok, err = pcall(function()
        local e = c.data
        if c.garc then
          local f = c.g.files and c.g.files[i] and c.g.files[i][1]
          if type(f) == "table" and type(f.length) == "number" and f.length < 40 then return end
          e = codec.garc_file(c.data, i, 1)
        end
        if type(e) == "string" and #e >= 40 then examine(e, c.path .. "#" .. i) end
      end)
      if not ok then
        stat.errors = stat.errors + 1
        reject("entry_error " .. c.path .. "#" .. i .. ": " .. tostring(err))
      end
    end
    return c.next > c.count
  end

  local function scan_dir(dir)
    local list = uz.rom.romfs_list(dir)
    if type(list) ~= "table" then reject("list_failed " .. dir); return end
    for _, e in ipairs(list) do
      local full = dir .. "/" .. tostring(e.name)
      if e.dir then
        dirs[#dirs + 1] = full
      elseif type(e.size) == "number" and e.size >= M.MIN_FILE_SIZE and e.size <= M.MAX_FILE_SIZE then
        files[#files + 1] = full
      end
    end
  end

  local function finish()
    table.sort(cands, function(a, b)
      local aa, ba = a.w * a.h, b.w * b.h
      if aa ~= ba then return aa > ba end
      return a.id < b.id
    end)
    state = "done"
    cur = nil
    save_index(true)
    if uz.log and uz.log.info then uz.log.info("map scan finished, " .. #cands .. " candidates") end
  end

  local function fail(why)
    state, cur, fail_reason = "failed", nil, short(why)
    save_index(false)
    if uz.log and uz.log.error then uz.log.error("map scan failed: " .. tostring(why)) end
  end

  -- One unit of work.
  local function advance()
    if state == "idle" then load_state() end
    if state == "idle" then return end
    if state == "dirs" then
      if #dirs > 0 then
        scan_dir(table.remove(dirs, 1))
      else
        table.sort(files)
        -- the forum-listed town map archives first, then the rest in path order
        local first, rest, is_prio = {}, {}, {}
        for _, p in ipairs(M.PRIORITY) do is_prio[p] = true end
        for _, p in ipairs(M.PRIORITY) do
          for _, f in ipairs(files) do if f == p then first[#first + 1] = f; break end end
        end
        for _, f in ipairs(files) do if not is_prio[f] then rest[#rest + 1] = f end end
        files = first
        for _, f in ipairs(rest) do files[#files + 1] = f end
        cwrite(M.FILES, table.concat(files, "\n") .. "\n")
        cwrite(M.PROGRESS, "0")
        fidx, state = 0, "files"
      end
    elseif state == "files" then
      if cur then
        if process(cur) then
          cur = nil
          fidx = fidx + 1
          if fidx % M.SAVE_EVERY == 0 then cwrite(M.PROGRESS, tostring(fidx)); save_index(false) end
        end
      elseif fidx >= #files then
        finish()
      else
        local path = files[fidx + 1]
        local ok, c = pcall(open_file, path)
        if not ok then
          reject("archive_error " .. path .. ": " .. tostring(c))
          stat.errors = stat.errors + 1
          c = nil
        end
        if c then cur = c else fidx = fidx + 1; stat.archives_skipped = stat.archives_skipped + 1 end
      end
    end
  end

  -- Restore the saved index/progress at once (cheap cache reads only).
  if state == "idle" then pcall(load_state) end

  local function terminal() return state == "done" or state == "failed" or state == "unsupported" end

  -- One bounded scan step: units until STEP_BUDGET_MS (uz.clock) is used. Never raises.
  function self.step()
    if terminal() then return end
    stat.steps = stat.steps + 1
    local t0 = clock()
    if t0 and not stat.started then stat.started = t0 end
    for _ = 1, M.MAX_UNITS_PER_STEP do
      local ok, err = pcall(advance)
      if not ok then
        -- advance() itself raised outside the per-entry/per-archive guards (directory listing, cache,
        -- sort): skip the work item that raised, never loop on it
        stat.errors = stat.errors + 1
        reject("scan_error: " .. tostring(err))
        if state == "dirs" then
          -- the directory was already taken from the queue
        elseif state == "files" then
          if cur then cur = nil end
          fidx = fidx + 1
          stat.archives_skipped = stat.archives_skipped + 1
        else
          fail("scan_error: " .. tostring(err))
        end
        if stat.errors > M.MAX_ERRORS then fail("too_many_errors") end
      end
      if terminal() then return end
      local now = clock()
      if now then
        stat.elapsed = now - (stat.started or now)
        if stat.elapsed > M.MAX_SCAN_MS then fail("time_limit"); return end
        if t0 and now - t0 >= M.STEP_BUDGET_MS then return end
      end
    end
  end

  function self.state() return state end
  function self.found() return (state == "done" or state == "failed") and #cands > 0 end

  function self.diagnostics()
    return {
      map_state = state,
      map_archives_scanned = fidx,
      map_archives_total = #files,
      map_archives_skipped = stat.archives_skipped,
      map_dirs_pending = #dirs,
      map_entries_scanned = stat.entries,
      map_errors = stat.errors,
      map_candidates = #cands,
      map_current = cur and cur.path or "none",
      map_first_rejection = first_reject or "none",
      map_fail_reason = fail_reason or "none",
      map_steps = stat.steps,
      map_elapsed_ms = stat.elapsed,
    }
  end

  function self.candidates()
    if state == "unsupported" then return nil, "unsupported" end
    if not terminal() then self.step() end
    if state == "failed" and #cands == 0 then return nil, "unsupported" end
    if state ~= "done" and state ~= "failed" then return nil, "not_ready" end
    local out = {}
    for i = 1, math.min(#cands, M.LIST_CAP) do
      local c = cands[i]
      out[i] = { id = c.id, w = c.w, h = c.h }
    end
    return out
  end

  function self.image(id)
    if state == "unsupported" then return nil, "unsupported" end
    local path, entry, sub = M.parse_id(id)
    if not path then return nil, "unknown_map" end
    local key = "map/" .. hash(id) .. ".png"
    local hit = cread(key)
    if hit then
      if #hit > M.MAX_PNG then return nil, "too_large" end
      return hit
    end
    if state ~= "done" and state ~= "failed" then self.step(); return nil, "not_ready" end
    local known = false
    for _, c in ipairs(cands) do if c.id == id then known = true; break end end
    if not known then return nil, "unknown_map" end
    local d = uz.rom.romfs(path)
    if type(d) ~= "string" then return nil, "unknown_map" end
    local e = d
    local okg, g = false, nil
    if codec.garc then okg, g = pcall(codec.garc, d) end
    if okg and type(g) == "table" and type(g.count) == "number" and g.count >= 1 then
      e = codec.garc_file(d, entry, 1)
    end
    if type(e) ~= "string" then return nil, "unknown_map" end
    if not M.bclim_size(e) then
      local out, status = garc_entry.decompress(codec, e, true)
      if status == "lz_failed" then return nil, "unknown_map" end
      e = out
    end
    if sub then
      local list = darc.parse(e)
      local found
      for _, f in ipairs(list or {}) do if f.path == sub then found = f; break end end
      if not found then return nil, "unknown_map" end
      e = e:sub(found.offset + 1, found.offset + found.length)
    end
    local img = codec.bclim(e)
    if type(img) ~= "table" then return nil, "unknown_map" end
    local png = codec.png(img)
    if type(png) ~= "string" then return nil, "unknown_map" end
    if #png > M.MAX_PNG then return nil, "too_large" end
    cwrite(key, png)
    return png
  end

  function self.selected()
    local v = M.MAP_ID[game_id]
    if type(v) == "table" then v = v[revision_fn and revision_fn() or ""] end
    if type(v) == "string" then return v end
    return nil
  end

  return self
end

return M

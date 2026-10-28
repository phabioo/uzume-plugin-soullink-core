local t = require("t")
local uz_mock = require("uz_mock")
local formats = require("formats")
local crypto = require("pk6_crypto")
local oras = require("gen6.oras")
local icons = require("gen6.icons")

-- icon GARC: entry i+1 holds the icon with index i; first pixel red byte = i % 256
local function icon_garc(count, w, h)
  local files = { formats.bclim(w, h) }
  for i = 1, count - 1 do
    local px = string.char(i % 256, 0, 0, 255) .. string.rep("\0\0\0\255", w * h - 1)
    files[#files + 1] = formats.bclim(w, h, px)
  end
  return formats.garc(files)
end

-- personal GARC (722 entries of 0x50): species 25 has form index 722 and 3 forms
local function personal_garc()
  local files = {}
  for s = 0, 721 do
    local e = {}
    for i = 1, 0x50 do e[i] = "\0" end
    if s == 25 then
      e[0x1C + 1] = string.char(722 & 255); e[0x1C + 2] = string.char(722 >> 8)
      e[0x20 + 1] = string.char(3)
    end
    files[#files + 1] = table.concat(e)
  end
  return formats.garc(files)
end

local REAL = "/a/0/9/4"

local function romfs(extra)
  local r = {
    ["/a/0/0/1"] = string.rep("x", 1000),
    ["/a/1/9/6"] = personal_garc(),
    ["/a/2/4/7"] = icon_garc(800, 16, 16),                -- decoy: wrong image size
    [REAL] = icon_garc(800, 40, 30),
    ["/a/3/0/0"] = formats.garc({ string.rep("j", 400000) }), -- decoy: too few entries
  }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

local function make(opts)
  opts = opts or {}
  local codec = formats.fake_codec()
  codec.pk6_decrypt = crypto.decrypt
  if opts.codec then for k, v in pairs(opts.codec) do codec[k] = v end end
  local mock = uz_mock.new({ game = { system = "3ds" }, codec = codec, i18n_dir = "plugin/i18n",
    romfs = opts.romfs or romfs(), cache = opts.cache, memory = opts.memory })
  local reads = {}
  local orig = mock.uz.rom.romfs
  mock.uz.rom.romfs = function(p) reads[#reads + 1] = p; return orig(p) end
  if opts.no_list then mock.uz.rom.romfs_list = nil end
  local a = oras.attach({ uz = mock.uz, game = {}, detected = {} })
  return a, mock, reads
end

local function run_until(a, pred, limit)
  for _ = 1, limit or 20000 do
    if pred() then return true end
    a:tick()
  end
  return pred()
end


t.case("discovery finds the icon archive by content and flips the feature", function()
  local a, mock = make()
  t.eq(a:features().icons, false)
  t.eq({ a:icon(25, 0) }, { nil, "not_ready" })
  t.ok(run_until(a, function() return a:features().icons end), "found")
  t.eq(mock.cache_files["icons/index.txt"], REAL .. "\n")
end)

t.case("icon maps species to entry, encodes PNG and caches it", function()
  local a, mock, reads = make()
  run_until(a, function() return a:features().icons end)
  local png = a:icon(25, 0)
  t.eq(png:sub(1, 8), "\137PNG\r\n\26\n")
  t.eq({ string.unpack("<I2I2", png, 9) }, { 40, 30, 13 })
  t.eq(png:byte(13), 25)
  t.eq(mock.cache_files["icons/25-0-" .. icons.CACHE_REV .. ".png"], png)
  local n = #reads
  t.eq(a:icon(25, 0), png)
  t.eq(#reads, n, "second call served from cache")
  t.eq(a:icon(1):byte(13), 1) -- form defaults to 0
  t.eq(a:icon(721):byte(13), 721 % 256)
end)

t.case("forms use the personal form index, otherwise the base icon", function()
  local a, mock = make()
  run_until(a, function() return a:features().icons end)
  t.eq(a:icon(25, 1):byte(13), 722 % 256)
  t.ok(mock.cache_files["icons/25-1-" .. icons.CACHE_REV .. ".png"])
  t.eq(a:icon(25, 2):byte(13), 723 % 256)
  local base = a:icon(25, 3) -- FormeCount is 3: form 3 does not exist
  t.eq(base:byte(13), 25)
  t.eq(mock.cache_files["icons/25-3-" .. icons.CACHE_REV .. ".png"], nil, "fallback is not cached under the form key")
  t.eq(a:icon(4, 1):byte(13), 4) -- species without extra forms
end)

t.case("invalid arguments", function()
  local a = make()
  for _, args in ipairs({ { 0 }, { 722 }, { "x" }, { 1.5 }, { 25, -1 }, { 25, "a" } }) do
    t.eq({ a:icon(table.unpack(args)) }, { nil, "unknown_species" })
  end
end)

t.case("later starts use the stored index and skip the scan", function()
  local a, _, reads = make({ cache = { ["icons/index.txt"] = REAL .. "\n" } })
  a:icon(25, 0) -- one step
  t.eq(reads[1], REAL)
  t.ok(a:features().icons)
end)

t.case("a stale index is revalidated and discovery continues", function()
  local a = make({ cache = { ["icons/index.txt"] = "/a/2/4/7\n" } })
  t.ok(run_until(a, function() return a:features().icons end))
end)

t.case("config override path is tried first", function()
  local a, _, reads = make({ cache = { ["config/icon_garc.txt"] = REAL } })
  a:icon(1)
  t.eq(reads[1], REAL)
end)

t.case("no archive: unsupported after the scan", function()
  local r = romfs(); r[REAL] = nil
  local a = make({ romfs = r })
  t.ok(run_until(a, function() return select(2, a:icon(25)) == "unsupported" end))
  t.eq(a:features().icons, false)
end)

t.case("missing codec or romfs_list: unsupported at once", function()
  local a = make({ no_list = true })
  t.eq({ a:icon(25) }, { nil, "unsupported" })
  local b = make({ codec = { bclim = false } })
  t.eq({ b:icon(25) }, { nil, "unsupported" })
end)

t.case("a single tick does at most one directory listing or candidate read", function()
  local a, mock, reads = make()
  local lists = 0
  local orig = mock.uz.rom.romfs_list
  mock.uz.rom.romfs_list = function(d) lists = lists + 1; return orig(d) end
  for _ = 1, icons.MAX_STEPS do
    local l0, r0 = lists, #reads
    a:icon(25)
    t.ok((lists - l0) + (#reads - r0) <= 2, "bounded work per call") -- icon() + personal never both heavy
    if a:features().icons then break end
  end
end)

t.case("interface info reports icons only once found", function()
  local interface = require("core.interface")
  local a = make()
  local api = interface.new({ id = "x", name = "x", gen = 6, system = "3ds", version = "v" }, {}, a)
  t.eq(api.info().features.icons, false)
  run_until(a, function() return a:features().icons end)
  t.eq(api.info().features.icons, true)
  t.eq(api.icon(0), nil)
end)

local function lz_icon_garc(count, w, h)
  local files = {}
  for i = 0, count - 1 do
    local px = string.char(i % 256, 0, 0, 255) .. string.rep("\0\0\0\255", w * h - 1)
    files[#files + 1] = formats.lz11_literal(formats.bclim(w, h, px))
  end
  return formats.garc(files)
end

t.case("v0.3.3: LZ11-compressed icon entries are found and decoded", function()
  local a = make({ romfs = { ["/a/0/9/1"] = lz_icon_garc(800, 40, 30) } })
  t.ok(run_until(a, function() return a:features().icons end), "found")
  local png = a:icon(25, 0)
  t.ok(png and png:sub(1, 4) == "\137PNG")
  local d = a:diagnostics()
  t.eq({ d.icon_e25_lz11, d.icon_e25_first }, { 1, "0x11" })
end)

t.case("v0.3.3: diagnostics() probe of the icon archive: flat keys, no pixels", function()
  local a = make({ romfs = { ["/a/0/9/1"] = icon_garc(800, 40, 30) } })
  local d = a:diagnostics()
  t.eq({ d.icons_state, d.icons_path, d.icons_count, d.icons_garc_ok }, { "idle", "/a/0/9/1", 800, 1 })
  for _, n in ipairs({ 1, 25, 700 }) do
    local p = "icon_e" .. n
    t.eq({ d[p .. "_first"], d[p .. "_lz11"], d[p .. "_fmt"], d[p .. "_w"], d[p .. "_h"] },
      { "0x" .. string.format("%02X", n % 256), 0, 9, 40, 30 }, p)
    t.eq(type(d[p .. "_px0"]), "string")
  end
  t.eq(d.icons_first_rejection, "none")
  for k, v in pairs(d) do t.ok(type(v) == "number" or type(v) == "string", k) end
end)

t.case("v0.3.3: diagnostics() names where icon reading stops", function()
  local a = make({ romfs = { ["/a/0/9/1"] = "GARC" .. string.rep("\0", 64) } })
  local d = a:diagnostics()
  t.eq(d.icons_garc_ok, 0); t.eq(d.icons_count, -1)
  t.ok(d.icons_garc_error ~= nil)
  local b = make({ romfs = { ["/a/0/9/2"] = icon_garc(5, 40, 30) } })
  t.eq(b:diagnostics().icons_path, "/a/0/9/1 (unreadable)")
end)

-- v0.4.1: one-time debug export of raw icon entries into the plugin cache (uz.cache), synthetic data only
t.case("v0.4.1: debug export writes diag files once discovery is done", function()
  local a, mock = make({ romfs = { ["/a/0/9/1"] = lz_icon_garc(800, 40, 30) } })
  t.eq(a:diagnostics().icon_export, "pending")
  t.ok(run_until(a, function() return (a:diagnostics().icon_export or ""):match("^done") ~= nil end), "export done")
  local c = mock.cache_files
  for _, n in ipairs({ 0, 1, 25, 201, 255, 258, 261 }) do
    local f = c["diag/icon-" .. n .. ".bin"]
    t.ok(f and #f == 40 + 40 * 30 * 4 or false, "entry " .. n)
    t.eq(f:byte(1), n % 256)
  end
  t.eq(c["diag/icon-1-raw.bin"]:byte(1), 0x11)
  t.eq(c["diag/icon-255-raw.bin"]:byte(1), 0x11)
  t.eq(c["diag/icon-25-raw.bin"], nil)
  local idx = c["diag/icon-index.txt"]
  t.ok(idx:match("^# garc=/a/0/9/1 entries=800 version=n/a data_offset=%d+ fatb_subfiles_first8=1,1,1,1,1,1,1,1\n"), idx)
  t.ok(idx:match("\n25 comp=%d+ decomp=4840 head=19 00 00 FF .- footer=w=40 h=30 fmt=9\n"), idx)
  t.eq(a:diagnostics().icon_export, "done:10 files")
  local before = 0
  for _ in pairs(c) do before = before + 1 end
  c["diag/icon-25.bin"] = nil
  for _ = 1, 200 do a:tick() end
  t.eq(c["diag/icon-25.bin"], nil) -- once per session
end)

t.case("v0.4.1: debug export caps files and adds team species", function()
  local a, mock = make({ romfs = { ["/a/0/9/1"] = icon_garc(800, 40, 30) } })
  local ex = require("gen6.icons")
  t.eq(ex.EXPORT_MAX_BINS, 12)
  t.ok(run_until(a, function() return (a:diagnostics().icon_export or ""):match("^done") ~= nil end), "done")
  local n = 0
  for k in pairs(mock.cache_files) do if k:match("^diag/icon%-[%d%-raw]+%.bin$") then n = n + 1 end end
  t.ok(n <= 12 and n >= 9, "bins " .. n)
end)

t.case("v0.4.1: debug export never throws and reports the reason", function()
  local a, mock = make({ romfs = { ["/a/0/9/1"] = icon_garc(800, 40, 30) } })
  mock.uz.cache.write = function(name) if name:match("^diag/") then error("disk full") end return true end
  t.ok(run_until(a, function() return (a:diagnostics().icon_export or "") ~= "pending" end), "reported")
  t.eq(a:diagnostics().icon_export, "write_failed")
  local b = make({ romfs = { ["/a/0/0/1"] = string.rep("x", 1000) } })
  t.ok(run_until(b, function() return b:diagnostics().icon_export ~= "pending" end), "no archive")
  t.eq(b:diagnostics().icon_export, "no_icon_archive")
end)

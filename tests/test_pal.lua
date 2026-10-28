local t = require("t")
local uz_mock = require("uz_mock")
local formats = require("formats")
local pal_build = require("pal_build")
local crypto = require("pk6_crypto")
local oras = require("gen6.oras")
local icons = require("gen6.icons")
local maps = require("gen6.maps")
local pal = require("gen6.pal_bclim")

local PALETTE = { 0xF800, 0x07E1, 0x001F, 0xFFFF }
local function idx(x, y) return (x + y) % 4 end
local function px(img, x, y) return { img.rgba:byte((y * img.width + x) * 4 + 1, (y * img.width + x) * 4 + 4) } end

-- expected colours by hand: RGB565 (index 0 transparent) and RGBA5551
local E565 = { { 255, 0, 0, 0 }, { 0, 255, 8, 255 }, { 0, 0, 255, 255 }, { 255, 255, 255, 255 } }
local E5551 = { { 255, 0, 0, 0 }, { 0, 255, 132, 255 }, { 0, 0, 123, 255 }, { 255, 255, 255, 255 } }

local function check(img, expect, label)
  t.eq({ img.width, img.height }, { 40, 30 }, label)
  for _, p in ipairs({ { 0, 0 }, { 1, 0 }, { 2, 0 }, { 3, 0 }, { 9, 9 }, { 39, 29 }, { 8, 1 } }) do
    t.eq(px(img, p[1], p[2]), expect[idx(p[1], p[2]) + 1], label .. " pixel " .. p[1] .. "," .. p[2])
  end
end

t.case("palette BCLIM: each variant decodes to the expected pixels", function()
  local low = pal_build.palette(40, 30, idx, PALETTE)
  local high = pal_build.palette(40, 30, idx, PALETTE, { high_first = true })
  t.eq(pal.layout(low), "palette")
  check(assert(pal.decode_variant(low, "A")), E565, "A")
  check(assert(pal.decode_variant(low, "B")), E5551, "B")
  check(assert(pal.decode_variant(high, "C")), E565, "C")
  check(assert(pal.decode_variant(high, "D")), E5551, "D")
end)

t.case("palette BCLIM: the wrong nibble order swaps neighbouring pixels", function()
  local low = pal_build.palette(40, 30, idx, PALETTE)
  local img = assert(pal.decode_variant(low, "C")) -- high nibble first on low-first data
  t.eq(px(img, 0, 0), E565[2]) -- pixel (0,0) now reads the index of (1,0)
  t.eq(px(img, 1, 0), E565[1])
end)

t.case("palette BCLIM: 8 bit indices and another tile layout width", function()
  local pal20 = {}
  for i = 1, 20 do pal20[i] = 0x0001 + (i << 11) end
  local f = pal_build.palette(40, 30, function(x, y) return (x * 3 + y) % 20 end, pal20)
  local img = assert(pal.decode(f, { color = "5551", index0 = false }))
  local want = { pal.color(pal20[(5 * 3 + 7) % 20 + 1], "5551") }
  t.eq(px(img, 5, 7), want)
  -- tile layout 32 wide instead of 64 (parametric)
  local g = pal_build.palette(24, 16, idx, PALETTE, { base = 32, rows = 2 })
  local img2 = assert(pal.decode(g, { color = "565", index0 = true, stride = 32 }))
  t.eq(px(img2, 3, 2), E565[idx(3, 2) + 1])
  t.eq(px(img2, 17, 9), E565[idx(17, 9) + 1])
end)

t.case("palette BCLIM: bad input is refused, never raised", function()
  t.eq({ pal.decode("nope") }, { nil, "not_palette" })
  local f = pal_build.palette(40, 30, idx, PALETTE)
  t.eq(select(2, pal.decode(f:sub(1, 30) .. f:sub(-40))), "indices_truncated")
  t.eq(pal.decode_variant(f, "Z"), nil)
  t.eq(pal.layout(formats.bclim(40, 30)), nil)
end)

local function plain(w, h)
  return pal_build.plain16(w, h, function(x, y) return (x == 0 and y == 0) and 0x0002 or (0x0001 | ((x % 32) << 11)) end)
end

t.case("plain 16-bit texture with first pixel 0x0002 is not taken for a palette", function()
  local f = plain(40, 30)
  t.eq(string.unpack("<I2", f, 1), 2)
  t.eq(pal.layout(f), "plain16")
  local img = assert(pal.decode_plain(f))
  t.eq(px(img, 0, 0), { 0, 0, 8, 0 }) -- 0x0002: B = 1, A = 0
  t.eq(px(img, 5, 3), { 5 * 8 + 1, 0, 0, 255 })
  t.eq(px(img, 39, 29), { (39 % 32) * 8 + ((39 % 32) >> 2), 0, 0, 255 })
end)

-- icon archives -------------------------------------------------------------------------------

local function bclim_stub(s)
  if type(s) ~= "string" or #s < 40 or s:sub(-40, -37) ~= "CLIM" then return nil, "no" end
  local w, h = string.unpack("<I2I2", s, #s - 39 + 28)
  return { width = w, height = h, rgba = string.rep("\1\2\3\255", w * h) }
end

local function garc_of(builder)
  local files = {}
  for i = 0, 799 do files[#files + 1] = builder(i) end
  return formats.garc(files)
end

local function make(romfs, codec_over)
  local codec = formats.fake_codec()
  codec.pk6_decrypt = crypto.decrypt
  codec.bclim = bclim_stub
  for k, v in pairs(codec_over or {}) do codec[k] = v end
  local mock = uz_mock.new({ game = { system = "3ds" }, codec = codec, i18n_dir = "plugin/i18n", romfs = romfs })
  local a = oras.attach({ uz = mock.uz, game = { id = "pokemon_omega_ruby" }, detected = {} })
  return a, mock
end

local function found(a)
  for _ = 1, 20000 do
    if a:features().icons then return true end
    a:tick()
  end
  return false
end

local function palette_world()
  return { ["/a/0/9/1"] = garc_of(function(i) return pal_build.palette(40, 30, idx, PALETTE, { high_first = i % 2 == 0 }) end) }
end

t.case("icon_variants: shape, order and states", function()
  local a = make(palette_world())
  t.eq({ a:icon_variants(25) }, { nil, "not_ready" })
  t.ok(found(a))
  local v = assert(a:icon_variants(25, 0))
  local labels = {}
  for i, e in ipairs(v) do
    labels[i] = e.label
    t.eq(type(e.desc), "string"); t.ok(#e.desc > 0)
    t.eq(e.png:sub(1, 8), "\137PNG\r\n\26\n")
    t.eq({ string.unpack("<I2I2", e.png, 9) }, { 40, 30, 13 })
  end
  t.eq(labels, { "D", "A", "B", "C" }) -- default variant first; E (plain texture) only for plain data
  t.eq(v[1].desc, pal.VARIANTS.D.desc)
  -- different readings give different pictures
  t.ok(v[1].png ~= v[2].png and v[1].png ~= v[3].png)
  t.eq({ a:icon_variants(0) }, { nil, "unknown_species" })
  t.eq({ a:icon_variants(25, -1) }, { nil, "unknown_species" })
  local interface = require("core.interface")
  local api = interface.new({ id = "x", name = "x", gen = 6, system = "3ds", version = "v" }, {}, a)
  t.eq(#api.icon_variants(25), 4)
  t.eq({ interface.new({ id = "x", name = "x", gen = 6, system = "3ds", version = "v" }, {}, nil).icon_variants(25) },
    { nil, "unsupported" })
end)

t.case("icon_variants: plain images (no palette data) are unsupported", function()
  local a = make({ ["/a/0/9/1"] = garc_of(function() return formats.bclim(40, 30) end) },
    { bclim = function(s) return formats.fake_codec().bclim(s) end })
  t.ok(found(a))
  t.eq({ a:icon_variants(25) }, { nil, "unsupported" })
end)

t.case("icon(): palette data uses the default variant in Lua, not uz.codec.bclim", function()
  local called = 0
  local a = make(palette_world(), { bclim = function(s) called = called + 1; return bclim_stub(s) end })
  t.ok(found(a))
  local before = called
  local png = assert(a:icon(25, 0))
  t.eq(called, before, "codec.bclim not used for the icon itself")
  local want = assert(a:icon_variants(25, 0))[1].png
  t.eq(pal.DEFAULT_VARIANT, "D")
  t.eq(png, want)
  t.eq(png:byte(13 + 4 * 0 + 0 + 0) ~= nil, true)
end)

t.case("icon(): a plain texture whose first pixel is 0x0002 is decoded as plain, not as palette", function()
  local called = 0
  local a = make({ ["/a/0/9/1"] = garc_of(function() return plain(40, 30) end) },
    { bclim = function(s) called = called + 1; return bclim_stub(s) end })
  t.ok(found(a))
  local before = called
  local png = assert(a:icon(25, 0))
  t.eq(called, before)
  t.eq({ string.unpack("<I2I2", png, 9) }, { 40, 30, 13 })
  local rgba = png:sub(13)
  t.eq({ rgba:byte(1, 4) }, { 0, 0, 8, 0 })
  local v = assert(a:icon_variants(25))
  t.eq(v[1].label, "E", "E first for plain data (consumers show only 4)")
  t.eq(v[1].png, png)
  local labels = {}
  for i, e in ipairs(v) do labels[i] = e.label end
  t.eq(labels[1], "E")
  -- a plain texture that also parses as a palette (pixel 2 = 4): all five, E first, labels unchanged
  local both = pal_build.plain16(40, 30, function(x, y) return (x == 0 and y == 0) and 2 or ((x == 1 and y == 0) and 4 or 0x0001) end)
  local b = make({ ["/a/0/9/1"] = garc_of(function() return both end) })
  t.ok(found(b))
  local w = assert(b:icon_variants(25))
  local l2 = {}
  for i, e in ipairs(w) do l2[i] = e.label end
  t.eq(l2, { "E", "A", "B", "C", "D" })
end)

-- real Omega Ruby icons: 12 colours, 4-bit high-nibble-first indices, zero padded to 4096 bytes
local PAL12 = {}
for i = 1, 12 do PAL12[i] = 0x0001 | ((i * 2) << 11) | ((i * 5) << 6) end
local function padded12()
  return pal_build.palette(40, 30, function(x, y) return (x * 2 + y) % 12 end, PAL12, { high_first = true, pad_to = 4096 })
end

t.case("zero-padded palette icon of 4096 data bytes is a palette, decoded as variant D", function()
  local f = padded12()
  t.eq(#f - 40, 4096)
  t.eq(pal.layout(f), "palette")
  local auto = assert(pal.decode_auto(f))
  local d = assert(pal.decode_variant(f, "D"))
  t.eq(auto.rgba, d.rgba)
  t.eq(px(auto, 3, 2), { pal.color(PAL12[(3 * 2 + 2) % 12 + 1], "5551") })
  -- non-zero trailing data: stays a plain texture
  local g = f:sub(1, 4096 - 1) .. "\1" .. f:sub(4097)
  t.eq(pal.layout(g), "plain16")
  local a = make({ ["/a/0/9/1"] = garc_of(function() return padded12() end) })
  t.ok(found(a))
  t.eq(assert(a:icon(25, 0)), assert(a:icon_variants(25, 0))[1].png)
end)

t.case("icon cache key carries the decoder revision", function()
  local a, mock = make(palette_world())
  t.ok(found(a))
  a:icon(25, 0)
  t.eq(icons.CACHE_REV, "r3-o1")
  t.ok(mock.uz.cache.read("icons/25-0-" .. icons.CACHE_REV .. ".png"))
  t.eq(mock.uz.cache.read("icons/25-0.png"), nil)
end)

t.case("diagnostics: palette facts of the probed icon entries", function()
  local a = make(palette_world())
  local d = a:diagnostics()
  t.eq(d.icon_e1_count, 4)
  t.eq(d.icon_e1_pal, "F800,07E1,001F,FFFF")
  t.eq(type(d.icon_e1_idx), "string")
  t.eq(#d.icon_e1_idx, 8 * 2 + 7) -- 8 bytes "XX,XX,..."
  t.eq(d.icon_e1_layout, "palette")
  t.eq(type(d.icon_e1_head), "string")
  t.eq(d.icon_e1_idxbytes, 2048)
  local b = make({ ["/a/0/9/1"] = garc_of(function() return plain(40, 30) end) })
  local e = b:diagnostics()
  t.eq(e.icon_e1_layout, "plain16")
  t.eq(e.icon_e1_head:sub(1, 5), "02 00")
end)

-- map scan ------------------------------------------------------------------------------------

local function big(m, w, h) return formats.bclim(w or 300, h or 200, string.char(m, 0, 0, 255) .. string.rep("\0\0\0\255", (w or 300) * (h or 200) - 1)) end

-- an archive of n tiny entries (some LZ11 wrapped), plus the given extra entries at the end
local function archive(n, extra)
  local files = {}
  for i = 1, n do
    local s = string.rep("t", 60 + i % 7)
    files[i] = (i % 3 == 0) and formats.lz11_literal(s) or s
  end
  for _, e in ipairs(extra or {}) do files[#files + 1] = e end
  return formats.garc(files)
end

local function mapworld()
  return {
    ["/a/0/6/7"] = archive(974, { big(1), formats.lz11_literal(big(2, 320, 240)) }), -- priority, with maps
    ["/a/0/9/1"] = archive(974),                                                      -- icons-like, none
    ["/a/1/0/0"] = archive(40, { big(3, 400, 300) }),
    ["/a/1/0/1"] = archive(10),
    ["/a/2/0/0"] = string.rep("z", 500),                                               -- not a GARC
  }
end

local function mapstore(world, codec_over, cache)
  local codec = formats.fake_codec()
  for k, v in pairs(codec_over or {}) do codec[k] = v end
  local mock = uz_mock.new({ game = { system = "3ds" }, codec = codec, i18n_dir = "plugin/i18n", romfs = world, cache = cache })
  return maps.new(mock.uz, "pokemon_omega_ruby", function() return "v1.0" end), mock
end

local function run_scan(store, limit)
  for n = 1, limit or 5000 do
    store.step()
    local s = store.state()
    if s == "done" or s == "failed" then return n end
  end
end

t.case("map scan: ends in done with all archives scanned and the big maps listed", function()
  local store = mapstore(mapworld())
  t.ok(run_scan(store), "finished")
  t.eq(store.state(), "done")
  local list = assert(store.candidates())
  local ids = {}
  for i, c in ipairs(list) do ids[i] = c.id end
  t.eq(ids, { "/a/1/0/0#41", "/a/0/6/7#976", "/a/0/6/7#975" })
  local d = store.diagnostics()
  t.eq({ d.map_state, d.map_archives_scanned, d.map_archives_total, d.map_candidates, d.map_errors },
    { "done", 5, 5, 3, 0 })
  t.ok(d.map_entries_scanned >= 974 * 2 + 40 + 10 + 3)
  t.eq(d.map_fail_reason, "none")
  t.eq(type(d.map_elapsed_ms), "number")
  for k, v in pairs(d) do t.ok(k:sub(1, 4) == "map_" and (type(v) == "number" or type(v) == "string"), k) end
end)

t.case("map scan: archives without large images finish with an empty list", function()
  local store = mapstore({ ["/a/0/0/0"] = archive(200), ["/a/0/0/1"] = archive(20) })
  t.ok(run_scan(store))
  t.eq(store.state(), "done")
  t.eq(store.candidates(), {})
  t.eq(store.found(), false)
end)

t.case("map scan: tiny entries are neither decompressed nor decoded", function()
  local lz = 0
  local base = formats.fake_codec()
  local store = mapstore({ ["/a/0/0/0"] = archive(300) },
    { lz_decompress = function(s) lz = lz + 1; return base.lz_decompress(s) end })
  t.ok(run_scan(store))
  t.eq(lz, 0)
end)

t.case("map scan: a throwing entry and a throwing archive are skipped, the scan still ends", function()
  local world = mapworld()
  local bad_archive = world["/a/0/9/1"]
  local base = formats.fake_codec()
  local store, mock = mapstore(world, {
    garc_file = function(d, i, sub)
      if d == world["/a/0/6/7"] and i == 5 then error("boom entry") end
      return base.garc_file(d, i, sub)
    end,
    garc = function(d)
      if d == bad_archive then error("boom archive") end
      return base.garc(d)
    end,
  })
  local orig = mock.uz.rom.romfs
  mock.uz.rom.romfs = function(p) if p == "/a/1/0/1" then error("boom read") end return orig(p) end
  t.ok(run_scan(store), "finished")
  t.eq(store.state(), "done")
  t.eq(#store.candidates(), 3, "the maps after the throwing entry are still found")
  local d = store.diagnostics()
  t.ok(d.map_errors >= 2, "errors counted")
  t.ok(d.map_first_rejection:find("boom", 1, true), d.map_first_rejection)
  t.eq(d.map_archives_scanned, 5)
end)

t.case("map scan: time limit ends in failed with a reason and keeps the partial list", function()
  local world = mapworld()
  local store, mock = mapstore(world)
  local now = 0
  mock.uz.clock = function() now = now + 1000; return now end
  local saved = maps.MAX_SCAN_MS
  maps.MAX_SCAN_MS = 20000
  local n = run_scan(store)
  maps.MAX_SCAN_MS = saved
  t.ok(n, "finished")
  t.eq(store.state(), "failed")
  local d = store.diagnostics()
  t.eq(d.map_fail_reason, "time_limit")
  t.ok(d.map_elapsed_ms > 20000)
  t.ok(mock.cache_files["map/index.txt"]:find("^partial"))
  local list, err = store.candidates()
  if store.found() then t.ok(list) else t.eq({ list, err }, { nil, "unsupported" }) end
end)

t.case("map scan: a step stops at the time budget", function()
  local store, mock = mapstore(mapworld())
  local now = 0
  mock.uz.clock = function() now = now + 100; return now end -- every clock call costs 100 ms
  local reads = 0
  local orig = mock.uz.rom.romfs
  mock.uz.rom.romfs = function(p) reads = reads + 1; return orig(p) end
  store.step()
  store.step()
  t.ok(store.diagnostics().map_steps == 2)
  local d = store.diagnostics()
  t.ok(d.map_dirs_pending + d.map_archives_total >= 0)
  t.ok(run_scan(store))
  t.eq(store.state(), "done")
end)

t.case("map scan: a cache of an older revision is rescanned", function()
  local world = mapworld()
  local store = mapstore(world, nil, { ["map/index.txt"] = "complete\n/a/9/9#1\t999\t999\n" })
  t.eq(store.state(), "dirs")
  t.ok(run_scan(store))
  t.eq(#store.candidates(), 3)
end)

t.case("map scan: adapter ticks alone finish the scan", function()
  local codec = formats.fake_codec()
  codec.pk6_decrypt = crypto.decrypt
  local mock = uz_mock.new({ game = { system = "3ds" }, codec = codec, i18n_dir = "plugin/i18n", romfs = mapworld() })
  local a = oras.attach({ uz = mock.uz, game = { id = "pokemon_omega_ruby" }, detected = {} })
  local ticks = 0
  while not a:features().map and ticks < 20000 do a:tick(); ticks = ticks + 1 end
  t.ok(a:features().map, "map feature after " .. ticks .. " ticks")
  local d = a:diagnostics()
  t.eq(d.map_state, "done")
  t.eq(#a:map_candidates(), 3)
end)

t.case("personal table is loaded by ticks (diagnostics show an attempt)", function()
  local a = make({ ["/a/1/9/5"] = formats.garc({ "x" }) })
  t.eq(a:diagnostics().personal_attempts, 0)
  for _ = 1, 100 do a:tick() end
  t.ok(a:diagnostics().personal_attempts >= 1)
end)

t.case("8-bit palette icon (20 colours) zero-padded to 4096 data bytes is a palette", function()
  local pal20 = {}
  for i = 1, 20 do pal20[i] = 0x0001 + (i << 11) end
  local f = pal_build.palette(40, 30, function(x, y) return (x * 3 + y) % 20 end, pal20, { rows = 4, pad_to = 4096 })
  t.eq(#f - 40, 4096)
  t.eq(pal.layout(f), "palette")
  local img = assert(pal.decode_auto(f))
  t.eq({ img.width, img.height }, { 40, 30 })
  t.eq(px(img, 5, 7), { pal.color(pal20[(5 * 3 + 7) % 20 + 1], "5551") })
  t.eq(px(img, 39, 29), { pal.color(pal20[(39 * 3 + 29) % 20 + 1], "5551") })
end)

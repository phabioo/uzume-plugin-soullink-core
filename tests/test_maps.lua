local t = require("t")
local uz_mock = require("uz_mock")
local formats = require("formats")
local darc = require("gen6.darc")
local maps = require("gen6.maps")
local oras = require("gen6.oras")
local crypto = require("pk6_crypto")

local function marker(w, h, m) -- bclim whose first pixel red byte is m
  return formats.bclim(w, h, string.char(m, 0, 0, 255) .. string.rep("\0\0\0\255", w * h - 1))
end

local DARC_BIG = marker(300, 200, 7)

local function world()
  local r = {
    ["/a/0/0/0"] = formats.garc({
      marker(256, 128, 1),                                   -- 1: plain, exactly at threshold
      marker(64, 64, 2),                                     -- 2: too small
      formats.lz11_literal(marker(512, 256, 3)),             -- 3: LZ11 wrapped
      formats.darc({ { path = "timg/map.bclim", data = DARC_BIG },
        { path = "timg/icon.bclim", data = marker(16, 16, 4) } }), -- 4: DARC
      string.rep("junk", 50),                                -- 5: junk
      marker(255, 128, 5),                                   -- 6: one pixel too narrow
    }),
    ["/a/0/0/1"] = marker(400, 300, 9),                      -- plain BCLIM file, no GARC
    ["/a/0/1/2"] = string.rep("z", 300),
  }
  for i = 1, 12 do r[string.format("/a/5/%02d", i)] = string.rep("q", 100 + i) end
  return r
end

local function make(opts)
  opts = opts or {}
  local mock = uz_mock.new({ game = { system = "3ds" }, codec = opts.codec or formats.fake_codec(),
    i18n_dir = "plugin/i18n", romfs = opts.romfs or world(), cache = opts.cache })
  local reads, lists = {}, 0
  local ro, lo = mock.uz.rom.romfs, mock.uz.rom.romfs_list
  mock.uz.rom.romfs = function(p) reads[#reads + 1] = p; return ro(p) end
  mock.uz.rom.romfs_list = function(d) lists = lists + 1; return lo(d) end
  local store = maps.new(mock.uz, "pokemon_omega_ruby", function() return "rev2" end)
  return store, mock, reads, function() return lists end
end

local function finish(store)
  for _ = 1, 5000 do
    if store.state() == "done" then return true end
    store.step()
  end
  return false
end

t.case("darc parser lists files with directory paths", function()
  local d = formats.darc({ { path = "top.bin", data = "AAAA" }, { path = "timg/a.bclim", data = "BBBBBB" },
    { path = "timg/b.bclim", data = "C" } })
  local list = assert(darc.parse(d))
  local got = {}
  for _, f in ipairs(list) do got[f.path] = d:sub(f.offset + 1, f.offset + f.length) end
  t.eq(got, { ["top.bin"] = "AAAA", ["timg/a.bclim"] = "BBBBBB", ["timg/b.bclim"] = "C" })
end)

t.case("darc parser rejects garbage without raising", function()
  t.eq(darc.parse("nope"), nil)
  t.eq(darc.parse("darc" .. string.rep("\255", 40)), nil)
  local d = formats.darc({ { path = "a.bin", data = "AAAA" } })
  t.eq(darc.parse(d:sub(1, 30)), nil)
end)

t.case("bclim_size reads the footer", function()
  t.eq({ maps.bclim_size(formats.bclim(40, 30)) }, { 40, 30 })
  t.eq(maps.bclim_size("short"), nil)
  t.eq(maps.bclim_size(string.rep("x", 100)), nil)
end)

t.case("scan finds plain, LZ11, DARC and loose candidates sorted by area", function()
  local store, mock = make()
  t.eq({ store.candidates() }, { nil, "not_ready" })
  t.ok(finish(store))
  local list = store.candidates()
  local ids = {}
  for i, c in ipairs(list) do ids[i] = c.id end
  t.eq(ids, { "/a/0/0/0#3", "/a/0/0/1#1", "/a/0/0/0#4/timg/map.bclim", "/a/0/0/0#1" })
  t.eq(list[1], { id = "/a/0/0/0#3", w = 512, h = 256 })
  t.eq(store.found(), true)
  t.eq(mock.cache_files["map/index.txt"]:match("^[^\n]+"), "complete " .. maps.CACHE_REV)
end)

t.case("files over 32 MiB are skipped and nothing found means no feature", function()
  local r = { ["/a/0/big"] = string.rep("\0", maps.MAX_FILE_SIZE + 1), ["/a/0/small"] = string.rep("s", 100) }
  local store, _, reads = make({ romfs = r })
  t.ok(finish(store))
  t.eq(reads, { "/a/0/small" })
  t.eq(store.found(), false)
  t.eq(store.candidates(), {})
end)

t.case("each scan step reads at most one file", function()
  local saved = maps.STEP_BUDGET_MS
  maps.STEP_BUDGET_MS = 0 -- one unit per step
  local store, _, reads = make()
  for _ = 1, 5000 do
    local n = #reads
    store.step()
    t.ok(#reads - n <= 1)
    if store.state() == "done" then break end
  end
  maps.STEP_BUDGET_MS = saved
end)

t.case("scan resumes from saved progress without rereading finished files", function()
  local store, mock = make()
  for _ = 1, 5000 do
    store.step()
    if mock.cache_files["map/progress.txt"] == "10" then break end
  end
  t.eq(mock.cache_files["map/progress.txt"], "10")
  local first10 = {}
  local sorted = {}
  for l in mock.cache_files["map/files.txt"]:gmatch("[^\n]+") do sorted[#sorted + 1] = l end
  for i = 1, 10 do first10[sorted[i]] = true end
  local s2, _, reads, lists = make({ cache = mock.cache_files })
  t.ok(finish(s2))
  for _, p in ipairs(reads) do t.ok(not first10[p], "reread " .. p) end
  t.eq(lists(), 0, "directories not listed again")
  t.eq(#s2.candidates(), 4)
end)

t.case("a complete index skips the scan entirely", function()
  local store, mock = make()
  finish(store)
  local s2, _, reads, lists = make({ cache = mock.cache_files })
  t.ok(s2.candidates())
  t.eq(#reads, 0); t.eq(lists(), 0)
  t.eq(#s2.candidates(), 4)
end)

t.case("map_image converts and caches; unknown and bad ids rejected", function()
  local store, mock, reads = make()
  finish(store)
  local id = "/a/0/0/0#4/timg/map.bclim"
  local png = assert(store.image(id))
  t.eq({ string.unpack("<I2I2", png, 9) }, { 300, 200, 13 })
  t.eq(png:byte(13), 7)
  local n = #reads
  t.eq(store.image(id), png)
  t.eq(#reads, n, "cached")
  local cached = 0
  for k in pairs(mock.cache_files) do if k:match("^map/%x+%.png$") then cached = cached + 1 end end
  t.eq(cached, 1)
  t.eq(store.image("/a/0/0/1#1"):byte(13), 9)         -- loose file
  t.eq(store.image("/a/0/0/0#3"):byte(13), 3)         -- LZ11 entry
  t.eq({ store.image("/a/0/0/0#2") }, { nil, "unknown_map" })
  t.eq({ store.image("garbage") }, { nil, "unknown_map" })
  t.eq({ store.image(nil) }, { nil, "unknown_map" })
end)

t.case("map_image during the scan is not_ready; oversize PNG is too_large", function()
  local store = make()
  t.eq({ store.image("/a/0/0/1#1") }, { nil, "not_ready" })
  local codec = formats.fake_codec({ png = function() return string.rep("p", maps.MAX_PNG + 1) end })
  local s2 = make({ codec = codec })
  finish(s2)
  t.eq({ s2.image("/a/0/0/1#1") }, { nil, "too_large" })
end)

t.case("candidate list is capped", function()
  local files = {}
  for i = 1, 60 do files[#files + 1] = formats.bclim(256, 128) end
  local store = make({ romfs = { ["/a/x/big"] = formats.garc(files) } })
  finish(store)
  t.eq(#store.candidates(), maps.LIST_CAP)
end)

t.case("map_selected from MAP_ID by game and revision", function()
  local store = make()
  t.eq(store.selected(), nil)
  maps.MAP_ID.pokemon_omega_ruby = "/a/x#1"
  t.eq(store.selected(), "/a/x#1")
  maps.MAP_ID.pokemon_omega_ruby = { rev2 = "/a/y#2", rev0_1 = "/a/z#3" }
  t.eq(store.selected(), "/a/y#2")
  maps.MAP_ID.pokemon_omega_ruby = nil
end)

t.case("unsupported without codec", function()
  local store = make({ codec = {} })
  t.eq({ store.candidates() }, { nil, "unsupported" })
  t.eq({ store.image("/a#1") }, { nil, "unsupported" })
end)

t.case("adapter exposes map methods and feature after ticks", function()
  local codec = formats.fake_codec()
  codec.pk6_decrypt = crypto.decrypt
  local mock = uz_mock.new({ game = { system = "3ds" }, codec = codec, i18n_dir = "plugin/i18n", romfs = world() })
  local a = oras.attach({ uz = mock.uz, game = { id = "pokemon_omega_ruby" }, detected = {} })
  t.eq(a:features().map, false)
  t.eq({ a:map_candidates() }, { nil, "not_ready" })
  for _ = 1, 20000 do
    if a:features().map then break end
    a:tick()
  end
  t.eq(a:features().map, true)
  t.eq(#a:map_candidates(), 4)
  t.eq(a:map_selected(), nil)
end)

-- noise filter and archive priority (v0.3)

local function noise_rgba(w, h)
  local seed, out = 12345, {}
  for i = 1, w * h do
    local px = {}
    for c = 1, 3 do
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
      px[c] = string.char((seed >> 16) & 0xFF)
    end
    out[i] = table.concat(px) .. "\255"
  end
  return table.concat(out)
end

local function gradient_rgba(w, h)
  local out = {}
  for y = 0, h - 1 do
    for x = 0, w - 1 do out[#out + 1] = string.char(x * 255 // w, y * 255 // h, 128, 255) end
  end
  return table.concat(out)
end

t.case("noisy: random pixels are noise, smooth images and tiny samples are not", function()
  t.eq(maps.noisy({ width = 256, height = 128, rgba = noise_rgba(256, 128) }), true)
  t.eq(maps.noisy({ width = 256, height = 128, rgba = gradient_rgba(256, 128) }), false)
  t.eq(maps.noisy({ width = 256, height = 128, rgba = string.rep("\0\0\0\255", 256 * 128) }), false)
  t.eq(maps.noisy({ width = 256, height = 128, rgba = string.rep("\255\0\0\0", 256 * 128) }), false, "fully transparent")
  t.eq(maps.noisy({ width = 4, height = 4, rgba = noise_rgba(4, 4) }), false, "too few pairs to judge")
  t.eq(maps.noisy(nil), false)
  t.eq(maps.noisy({ width = 256, height = 128, rgba = "short" }), false)
end)

t.case("the scan drops noisy candidates (also inside LZ and DARC) and keeps the others", function()
  local r = {
    ["/a/0/0/0"] = formats.garc({
      formats.bclim(300, 200, noise_rgba(300, 200)),                                   -- 1: garbage
      formats.bclim(300, 200, gradient_rgba(300, 200)),                                -- 2: real-looking
      formats.lz11_literal(formats.bclim(256, 128, noise_rgba(256, 128))),             -- 3: garbage, LZ
      formats.darc({ { path = "timg/n.bclim", data = formats.bclim(256, 128, noise_rgba(256, 128)) },
        { path = "timg/g.bclim", data = formats.bclim(256, 130, gradient_rgba(256, 130)) } }), -- 4
    }),
  }
  local store = make({ romfs = r })
  t.ok(finish(store))
  local ids = {}
  for _, c in ipairs(store.candidates()) do ids[#ids + 1] = c.id end
  table.sort(ids)
  t.eq(ids, { "/a/0/0/0#2", "/a/0/0/0#4/timg/g.bclim" })
end)

t.case("undecodable candidates are kept (only proven garbage is dropped)", function()
  local c = formats.fake_codec()
  c.bclim = function() return nil, "unsupported" end
  local store = make({ romfs = { ["/a/0/0/1"] = formats.bclim(400, 300) }, codec = c })
  t.ok(finish(store))
  t.eq(#store.candidates(), 1)
end)

t.case("the forum-listed town map archives are scanned first", function()
  local r = world()
  r["/a/0/6/8"] = formats.garc({ formats.bclim(512, 256) })
  r["/a/2/4/8"] = formats.garc({ formats.bclim(256, 256) })
  r["/a/2/7/6"] = formats.garc({ formats.bclim(300, 256) })
  r["/a/0/6/7"] = formats.garc({ formats.bclim(400, 256) })
  local store, _, reads = make({ romfs = r })
  t.ok(finish(store))
  t.eq({ reads[1], reads[2], reads[3], reads[4] }, { "/a/0/6/7", "/a/0/6/8", "/a/2/4/8", "/a/2/7/6" })
  t.eq(reads[5], "/a/0/0/0")
  t.eq(#store.candidates() >= 4, true)
end)

t.case("cache key combines scan revision and the manifest version", function()
  local f = assert(io.open("plugin/manifest.json", "r"))
  local manifest = f:read("a")
  f:close()
  t.eq(manifest:match('"version"%s*:%s*"([^"]+)"'), maps.PLUGIN_VERSION)
  t.eq(maps.CACHE_REV, maps.INDEX_REV .. "-" .. maps.MAP_SCAN_REV .. "-" .. maps.PLUGIN_VERSION)
end)

t.case("a finished scan of an older scan revision is rescanned, never reused", function()
  local stale_headers = { "complete 3", "partial 3", "complete 3-m1-0.6.2", "complete 3-m2-0.6.2", "complete" }
  for _, head in ipairs(stale_headers) do
    local store, mock = make({ cache = { ["map/index.txt"] = head .. "\n/a/9/9#1\t999\t999\n",
      ["map/files.txt"] = "/a/0/0/1\n", ["map/progress.txt"] = "1" } })
    t.eq(store.state(), "dirs", head)
    t.ok(finish(store), head)
    local ids = {}
    for i, c in ipairs(store.candidates()) do ids[i] = c.id end
    t.eq(ids, { "/a/0/0/0#3", "/a/0/0/1#1", "/a/0/0/0#4/timg/map.bclim", "/a/0/0/0#1" }, head)
    t.ok(store.diagnostics().map_archives_scanned > 0, head)
    t.eq(mock.cache_files["map/index.txt"]:match("^[^\n]+"), "complete " .. maps.CACHE_REV)
  end
end)

t.case("a result of the current revision is reused without scanning", function()
  local store = make({ cache = { ["map/index.txt"] = "complete " .. maps.CACHE_REV .. "\n/a/9/9#1\t640\t480\n" } })
  t.eq(store.state(), "done")
  t.eq(store.candidates(), { { id = "/a/9/9#1", w = 640, h = 480 } })
  t.eq(store.diagnostics().map_archives_scanned, 0)
end)

t.case("cached PNGs of an older revision are not served", function()
  local r = { ["/a/0/0/1"] = marker(400, 300, 9) }
  local store, mock = make({ romfs = r })
  t.ok(finish(store))
  local png = assert(store.image("/a/0/0/1#1"))
  local key
  for k in pairs(mock.cache_files) do if k:match("^map/%x+%.png$") then key = k end end
  t.ok(key)
  mock.cache_files[key] = "STALE"
  t.eq(store.image("/a/0/0/1#1"), "STALE") -- same key is a hit ...
  local old = {}
  for k, v in pairs(mock.cache_files) do if k ~= key then old[k] = v end end
  -- ... but a PNG written under any other key (older revision) is never looked up
  old["map/00000000.png"] = "OLD"
  local store2 = make({ romfs = r, cache = old })
  t.ok(finish(store2))
  t.eq(store2.image("/a/0/0/1#1"), png)
end)

t.case("textures larger than the screen are candidates, ranked first, and map_image returns them full size", function()
  local r = {
    ["/a/0/0/0"] = formats.garc({
      marker(400, 240, 1),                          -- screen sized
      formats.lz11_literal(marker(600, 400, 2)),    -- larger than the screen, LZ11
      marker(512, 512, 3),                          -- square atlas
      marker(1024, 256, 4),                         -- wide strip
    }),
  }
  local store = make({ romfs = r })
  t.ok(finish(store))
  local list = store.candidates()
  local ids = {}
  for i, c in ipairs(list) do ids[i] = c.id end
  t.eq(ids, { "/a/0/0/0#3", "/a/0/0/0#4", "/a/0/0/0#2", "/a/0/0/0#1" })
  t.eq({ list[1].w, list[1].h }, { 512, 512 })
  local png = assert(store.image("/a/0/0/0#2"))
  t.eq(string.unpack("<I2I2", png, 9), 600) -- fake PNG: width, height after the signature
  t.eq(select(2, string.unpack("<I2I2", png, 9)), 400)
  t.eq(store.diagnostics().map_rev, maps.CACHE_REV)
end)

t.case("an LZ wrapped 1024x1024 RGBA texture is not skipped by the size cap", function()
  local big = marker(1024, 1024, 5)
  t.ok(#big > 4 * 1024 * 1024)
  t.ok(#big <= maps.MAX_LZ_OUTPUT)
  local store = make({ romfs = { ["/a/0/0/0"] = formats.garc({ formats.lz11_literal(big) }) } })
  t.ok(finish(store))
  t.eq(store.candidates(), { { id = "/a/0/0/0#1", w = 1024, h = 1024 } })
end)

local t = require("t")
local uz_mock = require("uz_mock")
local formats = require("formats")
local crypto = require("pk6_crypto")
local oras = require("gen6.oras")
local icons = require("gen6.icons")
local order = require("gen6.icon_order")

t.case("icon order table: 721 species, entries 1..972 exactly once, egg 973", function()
  t.eq({ order.COUNT, order.EGG }, { 974, 973 })
  local seen, species = {}, 0
  for sp = 1, 721 do
    local g = order.group(sp)
    t.ok(g ~= nil, "group " .. sp)
    species = species + 1
    t.ok(g.base >= 0 and g.base < g.n, "base inside group " .. sp)
    for _, pos in pairs(g.forms) do t.ok(pos >= 0 and pos < g.n, "form inside group " .. sp) end
    for e = g.first, g.first + g.n - 1 do
      t.ok(not seen[e], "entry used twice " .. e)
      seen[e] = true
    end
  end
  t.eq(species, 721)
  for e = 1, 972 do t.ok(seen[e], "entry missing " .. e) end
  t.eq(order.group(722), nil)
end)

t.case("icon order entry(): species, forms, unknown forms", function()
  t.eq({ order.entry(6, 0) }, { 9, true })
  t.eq({ order.entry(6, 1) }, { 7, true })
  t.eq({ order.entry(6, 2) }, { 8, true })
  t.eq({ order.entry(6, 3) }, { 9, false })
  t.eq({ order.entry(25, 0) }, { 31, true })
  t.eq({ order.entry(255, 0) }, { 346, true })
  t.eq({ order.entry(559, 0) }, { 721, true })
  t.eq({ order.entry(721, 0) }, { 970, true })
  t.eq({ order.entry(479, 0) }, { 627, true })
  t.eq({ order.entry(0, 0) }, {})
end)

-- fake icon GARC with `count` entries; first pixel red byte = entry % 256
local function icon_garc(count)
  local files = {}
  for i = 0, count - 1 do
    local px = string.char(i % 256, 0, 0, 255) .. string.rep("\0\0\0\255", 40 * 30 - 1)
    files[#files + 1] = formats.bclim(40, 30, px)
  end
  return formats.garc(files)
end

local function personal_garc()
  local files = {}
  for s = 0, 721 do
    local e = {}
    for i = 1, 0x50 do e[i] = "\0" end
    files[#files + 1] = table.concat(e)
  end
  return formats.garc(files)
end

local function make(count)
  local codec = formats.fake_codec()
  codec.pk6_decrypt = crypto.decrypt
  local mock = uz_mock.new({ game = { system = "3ds" }, codec = codec, i18n_dir = "plugin/i18n",
    romfs = { ["/a/1/9/6"] = personal_garc(), ["/a/0/9/1"] = icon_garc(count) } })
  return oras.attach({ uz = mock.uz, game = {}, detected = {} }), mock
end

local function ready(a)
  for _ = 1, 20000 do
    if a:features().icons then return end
    a:tick()
  end
  error("icons not found")
end

local function red(png)
  -- the fake codec's PNG is the RGBA data itself or a wrapper; compare through the cache of the fake png
  return png
end

t.case("icons.lua uses the order table for a 974-entry GARC and falls back otherwise", function()
  local a, mock = make(974)
  ready(a)
  local p6, p6f1, p25 = a:icon(6, 0), a:icon(6, 1), a:icon(25, 0)
  t.ok(p6 and p6f1 and p25)
  t.ok(mock.cache_files["icons/6-0-" .. icons.CACHE_REV .. ".png"], "cached")
  t.ok(p6 ~= p6f1, "forms differ")
  -- entries beyond 721 are reachable: species 721 sits at entry 970
  t.ok(a:icon(721, 0), "species 721")

  local b = make(800)
  ready(b)
  t.ok(b:icon(25, 0), "fallback icon")
  -- fallback: entry = species (no personal forms in the fake table), so species 25 shows entry 25
  t.ok(red(b:icon(25, 0)) ~= red(p25), "different mapping than the table")
end)

t.case("info() carries icon_rev", function()
  local interface = require("core.interface")
  local a = make(974)
  local api = interface.new({ id = "x", name = "x", gen = 6, system = "3ds", version = "v" }, {}, a)
  t.eq(api.info().icon_rev, icons.CACHE_REV)
  t.eq(icons.CACHE_REV, "r3-o1")
end)

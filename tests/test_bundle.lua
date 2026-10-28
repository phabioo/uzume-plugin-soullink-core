local t = require("t")
local uz_mock = require("uz_mock")
local games = require("core.games")

local LUA = (arg and arg[-1]) or "lua5.4"

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("a"); f:close()
  return s
end
local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() end
  return f ~= nil
end

t.case("bundle --check passes", function()
  local ok = os.execute(LUA .. " tools/bundle.lua --check > /dev/null 2>&1")
  t.ok(ok == true, "plugin/main.lua is stale; run tools/bundle.lua")
end)

-- Run plugin/main.lua in a sandbox like the Player: no require/load/io/os.
local function run_bundle(opts, legacy_name)
  local mock = uz_mock.new(opts)
  local env = { [legacy_name or "uz"] = mock.uz }
  for _, n in ipairs({ "assert", "error", "getmetatable", "ipairs", "next", "pairs", "pcall", "select",
    "setmetatable", "tonumber", "tostring", "type", "xpcall", "rawequal", "rawget", "rawlen", "rawset",
    "string", "table", "math", "utf8", "coroutine" }) do
    env[n] = _G[n]
  end
  env.print = function(...) mock.uz.log.info(...) end
  env._VERSION = _VERSION
  for _, n in ipairs({ "require", "load", "loadstring", "dofile", "loadfile", "io", "os", "package", "debug" }) do
    t.eq(env[n], nil)
  end
  local chunk = assert(load(read("plugin/main.lua"), "=plugin/main.lua", "t", env))
  chunk()
  return mock
end

local function has_log(mock, level)
  for _, l in ipairs(mock.logs) do if l.level == level then return l end end
end
local function has_event(mock, name)
  for _, e in ipairs(mock.events) do if e.name == name then return e end end
end

t.case("sandbox: Omega Ruby", function()
  local mock = run_bundle({ game = { system = "3ds", code = "000400000011C400" } })
  local api = mock.provided["pokemon.core"]
  t.ok(api, "interface provided")
  local info = api.info()
  t.eq(info.game_id, "pokemon_omega_ruby")
  if exists("src/gen6/oras.lua") then
    t.ok(info.supported, "adapter attached")
    t.ok(has_event(mock, "game.detected"))
    mock.tick(30)
  else
    t.skip("src/gen6/oras.lua missing; adapter part not tested")
    t.eq(info.supported, false)
    t.ok(has_log(mock, "warn"))
  end
end)

t.case("sandbox: older app with only the global fb still starts", function()
  local mock = run_bundle({ game = { system = "3ds", code = "000400000011C400" } }, "fb")
  t.ok(mock.provided["pokemon.core"], "interface provided through the fb fallback")
end)

t.case("sandbox: X (no adapter)", function()
  local mock = run_bundle({ game = { system = "3ds", code = "0004000000055D00" } })
  local api = mock.provided["pokemon.core"]
  t.ok(api)
  t.eq(api.info().supported, false)
  local v, err = api.team()
  t.eq(v, nil); t.eq(err, "unsupported")
  local w = has_log(mock, "warn")
  t.ok(w and w.text:find("Pokemon X", 1, true), "no_adapter warning with name")
  t.eq(has_event(mock, "game.detected"), nil)
  mock.tick(30)
end)

t.case("sandbox: non-Pokemon game", function()
  local mock = run_bundle({ game = { system = "nds", code = "AMCE" } })
  t.eq(mock.provided["pokemon.core"], nil)
  local l = has_log(mock, "info")
  t.ok(l and l.text:find("Not a supported"), "not_pokemon log")
  t.eq(#mock.events, 0)
end)

t.case("sandbox: German NDS game language", function()
  local mock = run_bundle({ game = { system = "nds", code = "IPKD" }, language = "de" })
  t.eq(mock.provided["pokemon.core"].info().language, "de")
  t.ok(has_log(mock, "warn").text:find("Speicher-Adapter", 1, true), "German warning")
end)

t.case("i18n en/de have the same keys", function()
  local en = uz_mock.read_json_flat(read("plugin/i18n/en.json"))
  local de = uz_mock.read_json_flat(read("plugin/i18n/de.json"))
  for k in pairs(en) do t.ok(de[k], "missing in de: " .. k) end
  for k in pairs(de) do t.ok(en[k], "missing in en: " .. k) end
  t.ok(next(en))
end)

t.case("manifest lists every 3DS title ID", function()
  local m = read("plugin/manifest.json")
  for _, e in ipairs(games.GAMES) do
    if e.system == "3ds" then
      for _, c in ipairs(e.codes) do t.ok(m:find(c, 1, true), "manifest lacks " .. c) end
    elseif e.system == "nds" then
      for _, c in ipairs(e.codes) do t.ok(m:find('"' .. c .. '?"', 1, true), "manifest lacks " .. c) end
    end
  end
end)

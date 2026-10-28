-- Entry module of the SoulLink Core plugin.
local games = require("core.games")
local adapters = require("core.adapters")
local interface = require("core.interface")
local serialize = require("core.serialize")

local TEAM_EVERY = 15

local entry, detected = games.detect(uz.game)
if not entry then
  uz.log.info(uz.i18n.t("not_pokemon"))
  return
end

-- Developer setting "Demo data": plugin store key `dev.demo_data` = true (set it with the MCP tool store_put).
-- Off by default and never switched on by the plugin itself.
local DEMO_KEY = "dev.demo_data"
local function demo_enabled()
  if type(uz.store) ~= "table" or type(uz.store.get) ~= "function" then return false end
  local ok, value = pcall(uz.store.get, DEMO_KEY)
  return ok and value == true
end

local adapter
local demo = demo_enabled()
local adapter_mod = adapters.get(demo and "demo.adapter" or entry.adapter)
if demo then uz.log.info(uz.i18n.t("demo_on")) end
if adapter_mod then
  local ok, result = pcall(adapter_mod.attach, { uz = uz, game = entry, detected = detected })
  if ok and type(result) == "table" then
    adapter = result
  else
    uz.log.error(uz.i18n.t("adapter_failed", { name = entry.name, error = tostring(result) }))
  end
end
if not adapter then
  uz.log.warn(uz.i18n.t("no_adapter", { name = entry.name }))
end

local api = interface.new(entry, detected, adapter)
uz.provide("pokemon.core", api)

if adapter then
  uz.events.emit("game.detected", { game_id = entry.id, gen = entry.gen, supported = true, demo = demo })

  local ticks, last = 0, nil
  uz.on_tick(function()
    ticks = ticks + 1
    if type(adapter.tick) == "function" then adapter:tick() end
    if ticks % TEAM_EVERY ~= 0 then return end
    local team = api.team()
    if type(team) ~= "table" then return end
    local s = serialize.serialize(team)
    if s ~= last then
      last = s
      uz.events.emit("team.changed", { team = team })
    end
  end)
end

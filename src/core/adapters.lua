-- Static adapter registry. A module that is missing is skipped.
local M = {}

local function try(name)
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then return mod end
  return nil
end

M.REGISTRY = {}
for _, name in ipairs({ "gen6.oras", "demo.adapter" }) do
  M.REGISTRY[name] = try(name)
end

function M.get(name)
  if not name then return nil end
  return M.REGISTRY[name]
end

return M

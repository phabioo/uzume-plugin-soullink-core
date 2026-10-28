-- Fake `uz` for tests. See uz_mock.new.
local M = {}

-- Minimal reader for flat JSON objects with string values.
function M.read_json_flat(s)
  local out = {}
  local esc = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
  local pos = 1
  while true do
    local k, e = s:match('^%s*[{,]?%s*"([^"]*)"%s*:%s*()', pos)
    if not k then break end
    pos = e
    assert(s:sub(pos, pos) == '"', "flat string values only")
    pos = pos + 1
    local buf = {}
    while true do
      local c = s:sub(pos, pos)
      if c == "" then error("unterminated string") end
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local n = s:sub(pos + 1, pos + 1)
        if n == "u" then
          buf[#buf + 1] = utf8.char(tonumber(s:sub(pos + 2, pos + 5), 16))
          pos = pos + 6
        else
          buf[#buf + 1] = assert(esc[n], "bad escape")
          pos = pos + 2
        end
      else
        buf[#buf + 1] = c
        pos = pos + 1
      end
    end
    out[k] = table.concat(buf)
  end
  return out
end

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("a")
  f:close()
  return s
end

local function check_value(v, depth)
  local tv = type(v)
  if tv == "function" or tv == "userdata" or tv == "thread" then
    error("value of type " .. tv .. " cannot be passed between plugins", 3)
  end
  if tv == "table" then
    if depth > 32 then error("value too deep", 3) end
    for k, x in pairs(v) do
      if type(k) == "table" then error("table used as key", 3) end
      check_value(x, depth + 1)
    end
  end
end

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local c = {}
  for k, x in pairs(v) do c[k] = deep_copy(x) end
  return c
end

-- opts: game, memory = { {addr, data}, ... }, romfs = {path=data}, rom (string), codec, language, i18n_dir
function M.new(opts)
  opts = opts or {}
  local mock = { logs = {}, events = {}, provided = {}, watches = {}, dev_watches = {}, cache_files = {} }
  local regions = opts.memory or {}
  mock.regions = regions
  local uz = { api = 1, plugin = { id = "uzume.soullink-core", version = "0.3.1" } }
  uz.game = opts.game or {}
  if opts.language and not uz.game.language then uz.game.language = opts.language end
  mock.uz = uz

  local function read(addr, len)
    if type(addr) ~= "number" or len < 0 then return nil end
    for _, r in ipairs(regions) do
      if addr >= r.addr and addr + len <= r.addr + #r.data then
        local o = addr - r.addr
        return r.data:sub(o + 1, o + len)
      end
    end
    return nil
  end
  local function reader(fmt, size)
    return function(addr)
      local s = read(addr, size)
      if not s then return nil end
      return (string.unpack(fmt, s))
    end
  end

  uz.memory = {
    watch = function(key, addr, len) mock.watches[key] = { addr = addr, len = len } end,
    unwatch = function(key) mock.watches[key] = nil end,
    u8 = reader("<I1", 1), u16 = reader("<I2", 2), u32 = reader("<I4", 4), u64 = reader("<i8", 8),
    s8 = reader("<i1", 1), s16 = reader("<i2", 2), s32 = reader("<i4", 4),
    bytes = function(addr, len) return read(addr, len) end,
    frame = function() return opts.frame or 1 end,
  }

  for k, v in pairs(opts.cache or {}) do mock.cache_files[k] = v end

  local romfs = opts.romfs or {}
  uz.rom = {
    size = function() return opts.rom and #opts.rom or nil end,
    read = function(offset, len)
      if not opts.rom or offset >= #opts.rom then return nil end
      return opts.rom:sub(offset + 1, offset + len)
    end,
    romfs = function(path)
      local d = romfs[path]
      if d == nil then return nil, "file not found: " .. tostring(path) end
      return d
    end,
    romfs_list = function(dir)
      dir = dir:gsub("/+$", "")
      local seen, out = {}, {}
      for path, data in pairs(romfs) do
        local rest = path:match("^" .. dir:gsub("%p", "%%%0") .. "/([^/]+)")
        if rest and not seen[rest] then
          seen[rest] = true
          local is_dir = path ~= dir .. "/" .. rest
          out[#out + 1] = { name = rest, dir = is_dir, size = is_dir and 0 or #data }
        end
      end
      table.sort(out, function(a, b) return a.name < b.name end)
      if #out == 0 then return nil, "directory not found: " .. dir end
      return out
    end,
  }

  uz.codec = opts.codec or {}

  uz.log = {}
  for _, level in ipairs({ "debug", "info", "warn", "error" }) do
    uz.log[level] = function(...)
      local parts = table.pack(...)
      for i = 1, parts.n do parts[i] = tostring(parts[i]) end
      mock.logs[#mock.logs + 1] = { level = level, text = table.concat(parts, "\t", 1, parts.n) }
    end
  end

  local handlers = {}
  uz.events = {
    emit = function(name, value)
      check_value(value, 1)
      mock.events[#mock.events + 1] = { name = name, value = deep_copy(value) }
    end,
    on = function(plugin_id, name, fn) handlers[#handlers + 1] = { plugin_id, name, fn } end,
  }

  uz.provide = function(name, tbl)
    assert(type(name) == "string" and type(tbl) == "table", "bad provide")
    mock.provided[name] = tbl
  end

  local tick_fn
  uz.on_tick = function(fn) tick_fn = fn end
  mock.frame = 0
  function mock.tick(n)
    for _ = 1, n or 1 do
      mock.frame = mock.frame + 1
      if tick_fn then tick_fn(mock.frame) end
    end
  end

  local strings = {}
  local dir = opts.i18n_dir or "plugin/i18n"
  strings = M.read_json_flat(read_file(dir .. "/en.json"))
  if opts.language and opts.language ~= "en" then
    local f = io.open(dir .. "/" .. opts.language .. ".json", "rb")
    if f then
      local s = f:read("a"); f:close()
      for k, v in pairs(M.read_json_flat(s)) do strings[k] = v end
    end
  end
  uz.i18n = {
    t = function(key, vars)
      local s = strings[key] or key
      return (s:gsub("{([%w_]+)}", function(k)
        if vars and vars[k] ~= nil then return tostring(vars[k]) end
      end))
    end,
  }

  uz.cache = {
    write = function(name, data) mock.cache_files[name] = data; return true end,
    read = function(name) return mock.cache_files[name] end,
    exists = function(name) return mock.cache_files[name] ~= nil end,
  }

  local now = 0
  uz.clock = function() now = now + 1; return now end
  uz.dev = {
    watch = function(label, addr, kind) mock.dev_watches[label] = { addr = addr, kind = kind } end,
    unwatch = function(label) mock.dev_watches[label] = nil end,
  }

  return mock
end

return M

-- Synthetic emulator memory for the ORAS adapter tests, laid out as documented in
-- docs/games/omega-ruby-alpha-sapphire.md. All values are invented.
local crypto = require("pk6_crypto")
local build = require("pk6_build")
local addr = require("gen6.oras_addr")

local M = {}

function M.rev(name)
  for _, r in ipairs(addr.REVISIONS) do if r.name == name then return r end end
  error("unknown revision " .. tostring(name))
end

local function utf16(s, chars)
  local out = {}
  for _, c in utf8.codes(s) do out[#out + 1] = string.pack("<I2", c) end
  local b = table.concat(out)
  return b .. string.rep("\0", chars * 2 - #b)
end

-- slots[1..6] = PK6 field tables (see pk6_build) or nil
function M.party_blob(slots, play_time_at)
  local parts = {}
  for i = 1, 6 do
    parts[i] = slots[i] and build.ram_slot(slots[i]) or string.rep("\0", addr.PARTY_STRIDE)
  end
  return table.concat(parts)
end

-- entries[box][slot] = fields
function M.box_blob(entries)
  local parts = {}
  for b = 1, 31 do
    for s = 1, 30 do
      local f = entries[b] and entries[b][s]
      parts[#parts + 1] = f and crypto.encrypt(build.build(f)) or string.rep("\0", 232)
    end
  end
  return table.concat(parts)
end

-- t = { tid, sid, version, language_id, name }
function M.mystatus(t)
  local b = { string.pack("<I2I2I1", t.tid or 0, t.sid or 0, t.version or 27) }
  local s = table.concat(b)
  s = s .. string.rep("\0", 0x2D - #s) .. string.char(t.language_id or 2)
  s = s .. string.rep("\0", 0x48 - #s) .. utf16(t.name or "", 13)
  return s .. string.rep("\0", 0x70 - #s)
end

-- Items pouch: list of { id, count } (packed from slot 0), padded to 400 slots; a string is used as is.
function M.bag_blob(list)
  if type(list) == "string" then return list end
  local parts = {}
  for i, s in ipairs(list) do parts[i] = string.pack("<I2I2", s[1], s[2]) end
  local b = table.concat(parts)
  return b .. string.rep("\0", addr.BAG_SLOTS * 4 - #b)
end

-- Opponent/own mons array: list of { species, max_hp, hp, level } at array positions 1..8 (nil = empty).
function M.mons_blob(list)
  local parts = {}
  for i = 1, addr.MON_SLOTS do
    local m = list[i]
    local e = string.rep("\0", addr.MON_STRIDE)
    if m then
      e = e:sub(1, 0x0C) .. string.pack("<I2I2I2", m.species, m.max_hp, m.hp) .. e:sub(0x13)
      e = e:sub(1, 0x18) .. string.char(m.level) .. e:sub(0x1A)
    end
    parts[i] = e
  end
  return table.concat(parts)
end

function M.foes_blob(slots) return M.party_blob(slots) end

-- o: rev, party, boxes, trainer, misc = { money, badges }, play_time = { h, m, s }, zone, facing, x, y,
-- flag (battle flag u32), regions for anything else via o.extra = { {addr, data} }
function M.world(o)
  local rv = M.rev(o.rev or "v1.0").addr
  local mem = {}
  if o.party then
    local blob = M.party_blob(o.party)
    if o.play_time then
      local at = rv.play_time - rv.party
      blob = blob:sub(1, at) .. string.pack("<I2I1I1", o.play_time.h, o.play_time.m, o.play_time.s) .. blob:sub(at + 5)
    end
    mem[#mem + 1] = { addr = rv.party, data = blob }
  end
  if o.boxes then mem[#mem + 1] = { addr = rv.box, data = M.box_blob(o.boxes) } end
  if o.trainer then mem[#mem + 1] = { addr = rv.mystatus, data = M.mystatus(o.trainer) } end
  if o.misc then
    mem[#mem + 1] = { addr = rv.misc, data = string.rep("\0", 8) .. string.pack("<I4I1", o.misc.money or 0, o.misc.badges or 0)
      .. string.rep("\0", 3) }
  end
  if o.bag then mem[#mem + 1] = { addr = rv.bag, data = M.bag_blob(o.bag) } end
  -- other pouches: { key_items = list, tms = list, medicine = list, berries = list }
  for name, list in pairs(o.bag_more or {}) do
    local p = addr.POUCH[name]
    local parts = {}
    for i, sl in ipairs(list) do parts[i] = string.pack("<I2I2", sl[1], sl[2]) end
    local b = table.concat(parts)
    mem[#mem + 1] = { addr = rv.bag + p.off, data = b .. string.rep("\0", p.slots * 4 - #b) }
  end
  if o.zone then mem[#mem + 1] = { addr = rv.map_id, data = string.pack("<I2I2", o.zone, o.facing or 0) } end
  if o.x then mem[#mem + 1] = { addr = rv.player_x, data = string.pack("<f", o.x) } end
  if o.y then mem[#mem + 1] = { addr = rv.player_y, data = string.pack("<f", o.y) } end
  if o.flag then mem[#mem + 1] = { addr = rv.battle_flag, data = string.pack("<I4", o.flag) } end
  for _, r in ipairs(o.extra or {}) do mem[#mem + 1] = r end
  return mem
end

-- Replace bytes at an absolute address inside the region that contains it.
function M.poke(regions, a, data)
  for _, r in ipairs(regions) do
    if a >= r.addr and a + #data <= r.addr + #r.data then
      local o = a - r.addr
      r.data = r.data:sub(1, o) .. data .. r.data:sub(o + #data + 1)
      return true
    end
  end
  error(string.format("no region for 0x%08X", a))
end

return M

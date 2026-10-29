-- Address tables of Omega Ruby / Alpha Sapphire per game revision, and the address overrides.
-- Every value and its source: docs/games/omega-ruby-alpha-sapphire.md. A nil entry means "no
-- address known" (reported as open, never guessed).
--
-- Revisions are game versions (update patches), not regions: "v1.0" (no update) and "v1.4"
-- (final update). Inside the save-data range 0x08C6xxxx-0x08CFxxxx v1.4 = v1.0 + 0x3FF0.
local M = {}

M.SHIFT = 0x3FF0
M.OVERRIDE_FILE = "config/addresses.txt"
M.ZONE_OVERRIDE_FILE = "config/zone_addr.txt" -- older single override, equals the key map_id

-- Layout constants shared by adapter and tests.
M.PARTY_STRIDE = 0x1E4
M.PARTY_SLOTS = 6
M.BOX_COUNT, M.BOX_SLOTS, M.BOX_SIZE = 31, 30, 232
M.MON_STRIDE, M.MON_SLOTS = 0x244, 8
M.FLAG_BATTLE = 0x00040001
M.BAG_SLOTS = 400 -- Items pouch (Poke Balls live here)
-- Bag pouches, offsets relative to the bag start (= the Items pouch), each slot u16 item id + u16 count.
-- PKHeX SAV6AO / MyItem layout (recalled, not re-fetched; not checked on a real game). The order is the
-- order of bag().
M.POUCHES = {
  { name = "items", off = 0x000, slots = 400, max_count = 999 },
  { name = "key_items", off = 0x640, slots = 96, max_count = 1 },
  { name = "tms", off = 0x7C0, slots = 108, max_count = 1 },
  { name = "medicine", off = 0x970, slots = 64, max_count = 999 },
  { name = "berries", off = 0xA70, slots = 72, max_count = 999 },
}
M.POUCH = {}
for _, p in ipairs(M.POUCHES) do M.POUCH[p.name] = p end
M.BAG_BYTES = 0xA70 + 72 * 4 -- whole bag, 0xB90

-- key -> watched length in bytes
M.LENGTHS = {
  party = M.PARTY_SLOTS * M.PARTY_STRIDE,
  box = M.BOX_COUNT * M.BOX_SLOTS * M.BOX_SIZE,
  mystatus = 0x70,   -- TID +0, SID +2, version +4, language +0x2D, OT name +0x48 (0x1A bytes)
  misc = 0x10,       -- money u32 +8, badges u8 bitfield +0xC
  bag = M.BAG_BYTES, -- all 5 pouches, first the Items pouch: 400 slots x (u16 item id, u16 count)
  play_time = 4,     -- u16 hours, u8 minutes, u8 seconds
  map_id = 4,        -- u16 zone id, u16 facing
  player_x = 4,      -- f32
  player_y = 4,      -- f32
  event_flags = 0x1A0, -- 0xD00 flag bits
  battle_flag = 4,   -- u32, == FLAG_BATTLE while in battle (v1.4 only)
  battle_wild_foes = M.PARTY_SLOTS * M.PARTY_STRIDE,
  battle_trainer_foes = M.PARTY_SLOTS * M.PARTY_STRIDE,
  battle_wild_mons = M.MON_SLOTS * M.MON_STRIDE,
  battle_trainer_mons = M.MON_SLOTS * M.MON_STRIDE,
}
M.KEYS = {} -- sorted key names
for k in pairs(M.LENGTHS) do M.KEYS[#M.KEYS + 1] = k end
table.sort(M.KEYS)

-- State per address: "M" measured (first-hand or by tools on that exact version), "D" derived
-- (v1.4 community value - 0x3FF0), "C" community value for that version, "U" unverified (single
-- source, other version or arithmetic), see the docs.
M.REVISIONS = {
  {
    name = "v1.0",
    addr = {
      party = 0x08CF727C, box = 0x08C9A144,
      mystatus = 0x08C7D350, misc = 0x08C6DDC8, bag = 0x08C6AC80, play_time = 0x08CF7D98,
      map_id = 0x08C6A894, player_x = 0x08C6A8A4, player_y = 0x08C6A8AC, event_flags = 0x08C7DDDC,
      battle_wild_foes = 0x08805638, battle_trainer_foes = 0x08804AF4,
      battle_wild_mons = 0x082041F4, battle_trainer_mons = 0x08205D04,
    },
    state = {
      party = "M", box = "M", misc = "M", bag = "M", mystatus = "D", play_time = "D", map_id = "D", player_x = "D",
      player_y = "D", event_flags = "D", battle_wild_foes = "U", battle_trainer_foes = "U",
      battle_wild_mons = "U", battle_trainer_mons = "U",
    },
  },
  {
    name = "v1.4",
    addr = {
      party = 0x08CFB26C, box = 0x08C9E134,
      mystatus = 0x08C81340, misc = 0x08C71DB8, bag = 0x08C6EC70, play_time = 0x08CFBD88,
      map_id = 0x08C6E884, player_x = 0x08C6E894, player_y = 0x08C6E89C, event_flags = 0x08C81DCC,
      battle_flag = 0x081FB478, battle_wild_foes = 0x081FFA6C,
    },
    state = {
      party = "C", box = "C", misc = "C", bag = "D", mystatus = "C", play_time = "C", map_id = "C", player_x = "C",
      player_y = "C", event_flags = "C", battle_flag = "C", battle_wild_foes = "C",
    },
  },
}

-- "0x08C12345" or "08C12345" -> integer; nil when not a nonzero 32 bit hex number.
function M.parse_addr(s)
  if type(s) ~= "string" then return nil end
  local h = s:match("^%s*0[xX](%x+)%s*$") or s:match("^%s*(%x+)%s*$")
  if not h or #h > 8 then return nil end
  local n = tonumber(h, 16)
  if not n or n == 0 then return nil end
  return n
end

local function known_revision(name)
  for _, r in ipairs(M.REVISIONS) do if r.name == name then return true end end
  return false
end

-- Parses the text of config/addresses.txt. Lines: `key=0xADDR` (all revisions) or
-- `v1.0.key=0xADDR` (one revision); `#` starts a comment. Returns
-- { generic = {key=addr}, rev = {["v1.0"] = {key=addr}}, bad = { "line text", ... } }.
function M.parse_overrides(text)
  local out = { generic = {}, rev = {}, bad = {} }
  if type(text) ~= "string" then return out end
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local l = line:gsub("#.*$", ""):match("^%s*(.-)%s*$")
    if l ~= "" then
      local key, val = l:match("^([%w_%.]+)%s*=%s*(.-)$")
      local addr = M.parse_addr(val)
      local rev, k = nil, key
      if key then
        local r, rest = key:match("^(v%d+%.%d+)%.([%w_]+)$")
        if r then rev, k = r, rest end
      end
      if addr and k and M.LENGTHS[k] and (rev == nil or known_revision(rev)) then
        if rev then
          out.rev[rev] = out.rev[rev] or {}
          out.rev[rev][k] = addr
        else
          out.generic[k] = addr
        end
      else
        out.bad[#out.bad + 1] = l
      end
    end
  end
  return out
end

-- Reads both override files from the plugin cache. config/zone_addr.txt sets map_id for all revisions.
function M.load_overrides(uz)
  local function read(name)
    if uz.cache and uz.cache.read then
      local ok, v = pcall(uz.cache.read, name)
      if ok and type(v) == "string" then return v end
    end
  end
  local ov = M.parse_overrides(read(M.OVERRIDE_FILE))
  local z = M.parse_addr(read(M.ZONE_OVERRIDE_FILE))
  if z then ov.generic.map_id = z end
  return ov
end

-- Effective addresses for one revision: revision override > generic override > table.
function M.resolve(rev, overrides)
  local out = {}
  for k in pairs(M.LENGTHS) do out[k] = rev.addr[k] end
  if overrides then
    for k, a in pairs(overrides.generic or {}) do out[k] = a end
    for k, a in pairs((overrides.rev or {})[rev.name] or {}) do out[k] = a end
  end
  return out
end

return M

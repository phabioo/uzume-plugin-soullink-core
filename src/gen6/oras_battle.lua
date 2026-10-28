-- Battle state and wild encounters of Omega Ruby / Alpha Sapphire, derived from emulator memory.
-- The opponent party buffers and the battle-mon arrays PERSIST after a battle, so "in battle" is
-- inferred (docs/games/omega-ruby-alpha-sapphire.md, section Battle):
--   start : the content of an opponent buffer (slot 1) changed to valid, checksummed PK6 data AND
--           the battle-mon array holds a plausible entry matching it (AND, where an address is
--           known, the in-battle flag reads 0x00040001);
--   end   : the in-battle flag drops, or the map/zone changes, or the overworld position changes,
--           or the battle-mon array no longer matches the foes (3 polls in a row).
-- Wild vs trainer = which buffer changed. Horde = foe slots 2..5 all valid (and matched).
local addr = require("gen6.oras_addr")

local M = {}

M.PENDING_POLLS = 150  -- polls to wait for the battle-mon array after the buffer changed
M.END_MISS = 3         -- polls without a matching battle-mon before the battle counts as over
M.POS_EPSILON = 0.01   -- overworld position change that ends a battle
M.MAX_ENCOUNTERS = 64
M.WILD_SLOTS, M.TRAINER_SLOTS = 5, 6
M.MON_SPECIES, M.MON_MAX_HP, M.MON_HP, M.MON_LEVEL = 0x0C, 0x0E, 0x10, 0x18
M.MAX_SPECIES = 721
local RAW_LEN = 0xE8

-- env: addr(key) -> address|nil, read_slot(address) -> record|nil (checksummed, live stats merged),
--      position() -> zone, x, y, team() -> list|nil, location_id(zone) -> id|nil
function M.new(uz, env)
  local self = {}
  local st = { active = false }
  local last_raw = {}
  local pending = {}
  local encounters, seq = {}, 0
  local polls = 0

  local function kind_addr(kind, what) return env.addr("battle_" .. kind .. "_" .. what) end

  -- Plausible battle-mon entries { species, max_hp, hp, level, index }; nil when no array address,
  -- {} when the array is unreadable.
  local function read_mons(kind)
    local a = kind_addr(kind, "mons")
    if not a then return nil end
    local raw = uz.memory.bytes(a, addr.MON_SLOTS * addr.MON_STRIDE)
    local out = {}
    if not raw then return out end
    for i = 0, addr.MON_SLOTS - 1 do
      local o = i * addr.MON_STRIDE
      local species = string.unpack("<I2", raw, o + M.MON_SPECIES + 1)
      local max_hp = string.unpack("<I2", raw, o + M.MON_MAX_HP + 1)
      local hp = string.unpack("<I2", raw, o + M.MON_HP + 1)
      local level = raw:byte(o + M.MON_LEVEL + 1)
      if species >= 1 and species <= M.MAX_SPECIES and max_hp >= 1 and hp <= max_hp and level >= 1 and level <= 100 then
        out[#out + 1] = { species = species, max_hp = max_hp, hp = hp, level = level, index = i }
      end
    end
    return out
  end

  -- Valid PK6 records of an opponent buffer in slot order.
  local function candidates(kind)
    local a = kind_addr(kind, "foes")
    if not a then return {} end
    local n = kind == "wild" and M.WILD_SLOTS or M.TRAINER_SLOTS
    local out = {}
    for i = 1, n do
      local rec = env.read_slot(a + (i - 1) * addr.PARTY_STRIDE)
      if rec then rec.slot = i; out[#out + 1] = rec end
    end
    return out
  end

  local function matches(rec, mon)
    return mon.species == rec.species and (rec.level == nil or mon.level == rec.level)
  end

  local function foe_record(rec, mon)
    return {
      species = rec.species, form = rec.form, level = mon and mon.level or rec.level,
      hp = mon and mon.hp or rec.hp, max_hp = mon and mon.max_hp or rec.max_hp,
      shiny = rec.shiny, personality = rec.personality,
    }
  end

  -- Foes and horde flag of the battle of `kind` from the current memory.
  local function compute_foes(kind)
    local cands = candidates(kind)
    local mons = read_mons(kind)
    local foes, used, horde_slots = {}, {}, 0
    for _, rec in ipairs(cands) do
      local mon
      if mons then
        for j = #mons, 1, -1 do
          if not used[j] and matches(rec, mons[j]) then used[j] = true; mon = mons[j]; break end
        end
      end
      local active = mons == nil and rec.slot == 1 or mon ~= nil
      if active then
        foes[#foes + 1] = foe_record(rec, mon)
        if rec.slot >= 2 then horde_slots = horde_slots + 1 end
      end
    end
    local horde = kind == "wild" and horde_slots >= 4
    if mons == nil and kind == "wild" then -- no array: horde = slots 2..5 valid
      local n = 0
      for _, rec in ipairs(cands) do if rec.slot >= 2 then n = n + 1 end end
      horde = n >= 4
      foes = {}
      for _, rec in ipairs(cands) do
        if rec.slot == 1 or horde then foes[#foes + 1] = foe_record(rec, nil) end
      end
    end
    return foes, horde, mons, used
  end

  local function flag_ok()
    local a = env.addr("battle_flag")
    if not a then return true end
    return uz.memory.u32(a) == addr.FLAG_BATTLE
  end

  local function confirmed(kind)
    local cands = candidates(kind)
    local first = cands[1]
    if not first or first.slot ~= 1 then return false end
    local mons = read_mons(kind)
    if mons ~= nil then
      local hit = false
      for _, m in ipairs(mons) do if matches(first, m) then hit = true; break end end
      if not hit then return false end
    end
    return flag_ok()
  end

  local function species_list(foes)
    local out = {}
    for i, f in ipairs(foes) do out[i] = f.species end
    return out
  end

  local function start(kind)
    local foes, horde = compute_foes(kind)
    if #foes == 0 then return false end
    local zone, x, y = env.position()
    st = { active = true, kind = kind, horde = horde, zone = zone, x = x, y = y, miss = 0 }
    uz.events.emit("battle.started", { kind = kind, horde = horde, foes = species_list(foes) })
    if kind == "wild" then
      seq = seq + 1
      local first = foes[1]
      local entry = {
        seq = seq, species = first.species, form = first.form, level = first.level, shiny = first.shiny,
        horde = horde, zone = zone, location = zone and env.location_id(zone) or nil,
        frame = uz.memory.frame and uz.memory.frame() or polls,
      }
      entry.species_name = env.species_name and env.species_name(first.species) or nil
      encounters[#encounters + 1] = entry
      if #encounters > M.MAX_ENCOUNTERS then table.remove(encounters, 1) end
      uz.events.emit("encounter", entry)
    end
    return true
  end

  local function finish()
    local kind = st.kind
    st = { active = false }
    pending = {}
    uz.events.emit("battle.ended", { kind = kind })
  end

  local function over()
    local a = env.addr("battle_flag")
    if a then
      local v = uz.memory.u32(a)
      if v ~= nil and v ~= addr.FLAG_BATTLE then return true end
    end
    local zone, x, y = env.position()
    if zone and st.zone and zone ~= st.zone then return true end
    if x and y and st.x and st.y
      and (math.abs(x - st.x) > M.POS_EPSILON or math.abs(y - st.y) > M.POS_EPSILON) then
      return true
    end
    local foes, _, mons = compute_foes(st.kind)
    if mons ~= nil and #foes == 0 then
      st.miss = st.miss + 1
      return st.miss >= M.END_MISS
    end
    st.miss = 0
    return false
  end

  -- Called every tick. Never raises (the caller wraps it in pcall).
  function self.poll()
    polls = polls + 1
    local any = false
    for _, kind in ipairs({ "wild", "trainer" }) do
      local a = kind_addr(kind, "foes")
      if a then
        any = true
        local raw = uz.memory.bytes(a, RAW_LEN)
        if raw then
          if last_raw[kind] == nil then
            last_raw[kind] = raw -- baseline, no event
          elseif raw ~= last_raw[kind] then
            last_raw[kind] = raw
            if not st.active then
              local rec = env.read_slot(a)
              if rec then pending[kind] = 0 end
            end
          end
        end
      end
    end
    if not any then return end
    if st.active then
      if over() then finish() end
      return
    end
    for _, kind in ipairs({ "wild", "trainer" }) do
      if pending[kind] then
        pending[kind] = pending[kind] + 1
        if confirmed(kind) then
          pending = {}
          if start(kind) then return end
        elseif pending[kind] > M.PENDING_POLLS then
          pending[kind] = nil
        end
      end
    end
  end

  function self.available()
    return env.addr("battle_wild_foes") ~= nil or env.addr("battle_trainer_foes") ~= nil
  end

  -- { active, kind, horde, foes, own }
  function self.battle()
    if not st.active then return { active = false } end
    local foes, horde, mons, used = compute_foes(st.kind)
    local own = {}
    if mons then
      local team = env.team() or {}
      local taken = {}
      for j, m in ipairs(mons) do
        if not used[j] then
          for pi, p in ipairs(team) do
            if not taken[pi] and p.species == m.species and (p.level == nil or p.level == m.level) then
              taken[pi] = true
              own[#own + 1] = { personality = p.personality, species = m.species, hp = m.hp, max_hp = m.max_hp, slot = p.slot }
              break
            end
          end
        end
      end
    end
    return { active = true, kind = st.kind, horde = st.horde or horde, foes = foes, own = own }
  end

  function self.encounters()
    local out = {}
    for i, e in ipairs(encounters) do out[i] = e end
    return out
  end

  return self
end

return M

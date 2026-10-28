-- Game detection table for Pokemon games, Gen 3 to 7.
-- `name` is an English text identifier only; display names come from the game.
local M = {}

M.GAMES = {
  -- Gen 6 (3DS), exact title ID, uppercase
  { id = "pokemon_x", name = "Pokemon X", gen = 6, system = "3ds",
    codes = { "0004000000055D00" }, version = "x", adapter = nil },
  { id = "pokemon_y", name = "Pokemon Y", gen = 6, system = "3ds",
    codes = { "0004000000055E00" }, version = "y", adapter = nil },
  { id = "pokemon_omega_ruby", name = "Pokemon Omega Ruby", gen = 6, system = "3ds",
    codes = { "000400000011C400" }, version = "omega_ruby", adapter = "gen6.oras" },
  { id = "pokemon_alpha_sapphire", name = "Pokemon Alpha Sapphire", gen = 6, system = "3ds",
    codes = { "000400000011C500" }, version = "alpha_sapphire", adapter = "gen6.oras" },
  -- Gen 7 (3DS)
  { id = "pokemon_sun", name = "Pokemon Sun", gen = 7, system = "3ds",
    codes = { "0004000000164800" }, version = "sun", adapter = nil },
  { id = "pokemon_moon", name = "Pokemon Moon", gen = 7, system = "3ds",
    codes = { "0004000000175E00" }, version = "moon", adapter = nil },
  { id = "pokemon_ultra_sun", name = "Pokemon Ultra Sun", gen = 7, system = "3ds",
    codes = { "00040000001B5000" }, version = "ultra_sun", adapter = nil },
  { id = "pokemon_ultra_moon", name = "Pokemon Ultra Moon", gen = 7, system = "3ds",
    codes = { "00040000001B5100" }, version = "ultra_moon", adapter = nil },
  -- Gen 4 (NDS), 3-char prefix of the 4-char game code (4th char = region)
  { id = "pokemon_diamond", name = "Pokemon Diamond", gen = 4, system = "nds",
    codes = { "ADA" }, version = "diamond", adapter = nil },
  { id = "pokemon_pearl", name = "Pokemon Pearl", gen = 4, system = "nds",
    codes = { "APA" }, version = "pearl", adapter = nil },
  { id = "pokemon_platinum", name = "Pokemon Platinum", gen = 4, system = "nds",
    codes = { "CPU" }, version = "platinum", adapter = nil },
  { id = "pokemon_heartgold", name = "Pokemon HeartGold", gen = 4, system = "nds",
    codes = { "IPK" }, version = "heartgold", adapter = nil },
  { id = "pokemon_soulsilver", name = "Pokemon SoulSilver", gen = 4, system = "nds",
    codes = { "IPG" }, version = "soulsilver", adapter = nil },
  -- Gen 5 (NDS)
  { id = "pokemon_black", name = "Pokemon Black", gen = 5, system = "nds",
    codes = { "IRB" }, version = "black", adapter = nil },
  { id = "pokemon_white", name = "Pokemon White", gen = 5, system = "nds",
    codes = { "IRA" }, version = "white", adapter = nil },
  { id = "pokemon_black_2", name = "Pokemon Black 2", gen = 5, system = "nds",
    codes = { "IRE" }, version = "black_2", adapter = nil },
  { id = "pokemon_white_2", name = "Pokemon White 2", gen = 5, system = "nds",
    codes = { "IRD" }, version = "white_2", adapter = nil },
  -- Gen 3 (GBA); no adapter yet
  { id = "pokemon_ruby", name = "Pokemon Ruby", gen = 3, system = "gba",
    codes = { "AXV" }, version = "ruby", adapter = nil },
  { id = "pokemon_sapphire", name = "Pokemon Sapphire", gen = 3, system = "gba",
    codes = { "AXP" }, version = "sapphire", adapter = nil },
  { id = "pokemon_firered", name = "Pokemon FireRed", gen = 3, system = "gba",
    codes = { "BPR" }, version = "firered", adapter = nil },
  { id = "pokemon_leafgreen", name = "Pokemon LeafGreen", gen = 3, system = "gba",
    codes = { "BPG" }, version = "leafgreen", adapter = nil },
  { id = "pokemon_emerald", name = "Pokemon Emerald", gen = 3, system = "gba",
    codes = { "BPE" }, version = "emerald", adapter = nil },
}

-- Region letter (4th char of an NDS/GBA game code) -> language
local LANG = { D = "de", F = "fr", I = "it", S = "es", E = "en", P = "en", J = "ja", K = "ko" }

-- Returns entry, info for an uz.game-like table; nil for unknown games.
function M.detect(game)
  if type(game) ~= "table" or type(game.system) ~= "string" or type(game.code) ~= "string" then
    return nil
  end
  local system = game.system:lower()
  local code = game.code:upper()
  if system == "3ds" then
    code = code:gsub("^0X", "")
    for _, e in ipairs(M.GAMES) do
      if e.system == "3ds" then
        for _, c in ipairs(e.codes) do
          if c == code then return e, { region_letter = nil, language = nil } end
        end
      end
    end
    return nil
  end
  if #code < 4 then return nil end
  local prefix, letter = code:sub(1, 3), code:sub(4, 4)
  for _, e in ipairs(M.GAMES) do
    if e.system == system then
      for _, c in ipairs(e.codes) do
        if c == prefix then
          return e, { region_letter = letter, language = LANG[letter] }
        end
      end
    end
  end
  return nil
end

return M

-- Driver: does a TRAINER knockout pay the whole party under LET'S GO FULL?
--
-- The catch payout is easy to see (one throw, one award). A knockout is
-- not: it goes through the engine's own faint -> awardExp path, which is
-- the one this mode replaces wholesale. So fight a real trainer with a
-- deliberately uneven party and read the deltas -- every member should
-- gain, and the low ones should gain multiples of the high one.
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/letsgo_trainer_exp.lua \
--   SHOT_DIR=.scratchpad/letsgo "/c/Program Files/LOVE/lovec.exe" .
--
-- DS_LETSGO_MODE=off runs the same fight on the engine's own rules, which
-- is the control: there, only the Pokemon that fought should gain.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local MODE = os.getenv("DS_LETSGO_MODE") or "full"
  local Pokemon = require("src.pokemon.Pokemon")
  local BattleState = require("src.battle.BattleState")

  local exports = game.mods and game.mods.exports
  local lib = exports and exports.DRAMATIC_SHAPE and exports.DRAMATIC_SHAPE.lib
  if not lib then
    U.log("DRAMATIC_SHAPE is not loaded -- enable it and run again")
    return
  end
  local LetsGo = lib.require("LetsGo")
  LetsGo.setting:setValue(MODE == "off" and false or MODE, game)
  U.log("LET'S GO mode: " .. tostring(LetsGo.mode()))

  -- one strong fighter and two bystanders: only the fighter gains on the
  -- engine's own rules, so the bystanders ARE the test
  game.save.party = {
    Pokemon.new(game.data, "CHARIZARD", 45),
    Pokemon.new(game.data, "PIKACHU", 10),
    Pokemon.new(game.data, "RATTATA", 5),
  }
  game.save.player.name = "RED"

  -- The WEAKEST party in the game: one Pokemon, lowest level. Picked by
  -- measuring rather than by name -- an alphabetical first pick lands on
  -- OPP_AGATHA, whose Elite Four ghosts a level 45 Charizard does not
  -- reliably clear, and a fight that never resolves reads exactly like a
  -- payout that never happened.
  local class, partyIx, best = nil, 1, nil
  local ids = {}
  for id in pairs(game.data.trainers) do
    if type(id) == "string" and id:sub(1, 1) ~= "_" then ids[#ids + 1] = id end
  end
  table.sort(ids)                       -- stable across runs
  for _, id in ipairs(ids) do
    local rec = game.data.trainers[id]
    for pi, party in ipairs((type(rec) == "table" and rec.parties) or {}) do
      local n, top = 0, 0
      for _, mon in ipairs(party) do
        n = n + 1
        top = math.max(top, tonumber(mon.level) or 0)
      end
      if n > 0 then
        local score = n * 100 + top
        if not best or score < best then
          best, class, partyIx = score, id, pi
        end
      end
    end
  end
  U.log(("fighting %s party %d (weakest of %d classes)")
        :format(tostring(class), partyIx, #ids))

  local before = {}
  for i, m in ipairs(game.save.party) do
    before[i] = { exp = m.exp, level = m.level }
  end

  U.teleport(game, "ROUTE_1", 5, 8, "down")
  U.wait(60)

  local battle = BattleState.newTrainer(game, class, partyIx)
  battle.onFinish = function() end
  game.overworld:pushBattle(battle)
  U.wait(70)

  -- through the intro to the menu, then FIGHT + first move, over and
  -- over until the fight resolves. The enemy's HP is logged as it goes,
  -- so a fight that stalls is visibly a stall rather than a silent zero.
  local lastHP = nil
  for i = 1, 900 do
    if battle.result then break end
    if battle.phase == "menu" then
      battle.menuIndex = 1              -- FIGHT
      U.tap(game, "a")
    elseif battle.phase == "moveSelect" then
      battle.moveIndex = 1
      U.tap(game, "a")
    else
      U.tap(game, "a")
    end
    local hp = battle.enemy and battle.enemy.mon and battle.enemy.mon.hp
    if hp ~= lastHP then
      lastHP = hp
      U.log(("  foe HP -> %s  (phase %s, step %d)")
            :format(tostring(hp), tostring(battle.phase), i))
    end
    U.wait(5)
  end
  U.log("battle result: " .. tostring(battle.result)
        .. "  phase=" .. tostring(battle.phase))

  for i, m in ipairs(game.save.party) do
    local was = before[i]
    U.log(("EXP %-10s Lv%-3d -> Lv%-3d  exp %d -> %d  (+%d)")
          :format(game.data.pokemon[m.species].name, was.level, m.level,
                  was.exp, m.exp, m.exp - was.exp))
  end
  U.log("done")
end

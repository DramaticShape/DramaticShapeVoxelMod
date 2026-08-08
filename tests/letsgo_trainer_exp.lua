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

  -- count the summary cards at their SOURCE rather than by catching them
  -- on the stack: the driver taps fast enough to dismiss one between two
  -- polls, and an absence there would look like a card that never came
  local ExpPanel = lib.require("ExpPanel")
  local innerNew, cards = ExpPanel.new, 0
  ExpPanel.new = function(g, rows)
    local panel = innerNew(g, rows)
    cards = cards + 1
    -- read at DRAW time in the real thing; here the loop that fills it
    -- has already run, so peeking now is honest
    local parts = {}
    for _, r in ipairs(rows or {}) do
      parts[#parts + 1] = ("%s+%d%s"):format(
        (g.data.pokemon[r.mon.species] or {}).name or "?", r.gained or 0,
        (r.to or 0) > (r.from or 0) and ("->L" .. r.to) or "")
    end
    U.log(("EXP CARD #%d: %s"):format(cards, table.concat(parts, "  ")))
    CARD_HOLD = 20        -- frames to stop tapping, so it can be shot
    return panel
  end

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
  local lastHP, shotPanel = nil, false
  for i = 1, 900 do
    -- the fight ending does NOT end the loop until the card has been
    -- photographed: the last knockout resolves the battle in the same
    -- breath that queues the card, so breaking on `result` alone leaves
    -- every run with the card built and never seen
    if battle.result and shotPanel then break end
    -- hold the taps while the card is up, so it can be shot rather than
    -- dismissed on the next frame
    if (CARD_HOLD or 0) > 0 then
      CARD_HOLD = CARD_HOLD - 1
      if not shotPanel then
        local top = game.stack and game.stack:top()
        if top and rawget(top, "rows") then
          shotPanel = true
          U.shot(game, (os.getenv("SHOT_DIR") or ".scratchpad")
                       .. "/exp_panel.png")
          U.log("shot the card")
        end
      end
      U.wait(1)
    elseif battle.phase == "menu" then
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
    -- photograph the summary card the moment it is on top, then let the
    -- taps carry on and dismiss it
    local top = game.stack and game.stack:top()
    if top and not shotPanel and top ~= battle and rawget(top, "rows") then
      shotPanel = true
      U.shot(game, (os.getenv("SHOT_DIR") or ".scratchpad")
                   .. "/exp_panel.png")
      U.log("shot the card")
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

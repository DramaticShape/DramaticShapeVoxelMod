-- Driver: the two edges the capture mode has to hold on to.
--
--   A  FULL with an EMPTY BAG. The encounter must still be a Let's Go
--      encounter -- head-on seat, no player Pokemon, no classic menu --
--      with the readout saying there is nothing to throw and RUN as the
--      way out. The failure this catches is the old behaviour: falling
--      back to the battle menu, which under FULL offers a FIGHT against a
--      foe that never takes a turn.
--
--   B  FULL, running DRY MID-ENCOUNTER. One ball, thrown weakly enough to
--      fall short: the miss must land in the empty hand rather than
--      tearing the session down.
--
--   C  The SCRIPTED catch tutorial (the VIRIDIAN CITY old man; PROF.OAK
--      and the PIKACHU are the same makeOldManDemo). LET'S GO must not
--      touch it at any rung -- no session, no held camera, no veil -- and
--      it must play its scripted throw through to its own ending.
--
--   SHOT_DIR=.scratchpad/letsgo \
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/letsgo_empty.lua \
--   "/c/Program Files/LOVE/lovec.exe" .
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or ".scratchpad"
  local Pokemon = require("src.pokemon.Pokemon")
  local BattleState = require("src.battle.BattleState")
  local Bag = require("src.inventory.Bag")

  local exports = game.mods and game.mods.exports
  local lib = exports and exports.DRAMATIC_SHAPE and exports.DRAMATIC_SHAPE.lib
  if not lib then
    U.log("DRAMATIC_SHAPE is not loaded -- enable it and run again")
    return
  end
  local LetsGo = lib.require("LetsGo")
  local CatchThrow = lib.require("CatchThrow")
  local BattleScene = lib.require("BattleScene")

  game.save.party = {
    Pokemon.new(game.data, "CHARIZARD", 45),
    Pokemon.new(game.data, "PIKACHU", 10),
  }
  game.save.player.name = "RED"
  LetsGo.setting:setValue("full", game)
  if os.getenv("DS_RUNG") == "cards" then
    lib.require("OverworldBattle").setting:setValue(true, game)
    U.log("3D-BTL forced to 2D-3D A")
  end
  U.log("LET'S GO mode: " .. tostring(LetsGo.mode()))

  -- every ball out of the bag, whatever the save arrived with
  local BALLS = { "POKE_BALL", "GREAT_BALL", "ULTRA_BALL", "MASTER_BALL" }
  local function emptyBag()
    for _, id in ipairs(BALLS) do
      local n = game.save.inventory[id] or 0
      if n > 0 then pcall(Bag.remove, game.save, id, n) end
      game.save.inventory[id] = nil
    end
  end
  local function ballCount()
    local n = 0
    for _, id in ipairs(BALLS) do n = n + (game.save.inventory[id] or 0) end
    return n
  end

  -- A REAL key event, not U.tap's synthetic pressQueue inject. The bug
  -- this driver has to be able to see (button edges read on the render
  -- clock instead of the logic step) lives between love.keypressed and
  -- whoever polls the edge, so a driver that writes the queue itself
  -- jumps straight over it. "b" is the default binding for the B button.
  local function key(name)
    love.keypressed(name, name, false)
    U.wait(2)
    love.keyreleased(name, name)
    U.wait(2)
  end

  U.teleport(game, "ROUTE_1", 5, 8, "down")
  U.wait(90)

  -- drive the intro chatter until the menu would open (which under FULL is
  -- when capture mode takes over instead)
  local function toCapture(battle)
    U.wait(70)
    for _ = 1, 80 do
      if battle.phase == "menu" or CatchThrow.session() then break end
      U.tap(game, "a")
      U.wait(6)
    end
    U.wait(30)
  end

  local function describe(tag, battle)
    local s = CatchThrow.session()
    U.log(("%s: session=%s empty=%s phase=%s battle=%s veil=%s hidePlayer=%s")
          :format(tag, s and "yes" or "NO", s and tostring(s.empty) or "-",
                  s and s.phase or "-", tostring(battle.phase),
                  BattleScene.capture and "up" or "down",
                  tostring(BattleScene.capture
                           and BattleScene.capture.hidePlayer)))
    return s
  end

  -- ------- A: an empty bag still gets the capture screen

  emptyBag()
  U.log("== A: FULL with " .. ballCount() .. " balls")
  local a = BattleState.newWild(game, "PIDGEY", 5)
  a.onFinish = function() end
  game.overworld:pushBattle(a)
  toCapture(a)

  local s = describe("A", a)
  U.log(("A: hand is empty -> %s (want yes)"):format(
        (s and s.empty) and "yes" or "NO"))
  U.shot(game, DIR .. "/empty_1_aim.png")

  -- and B is the way out: a Let's Go wild always escapes
  key("b")
  for _ = 1, 120 do
    U.wait(2)
    if a.result then break end
    U.tap(game, "a")
  end
  U.log(("A: after B -- result=%s (want run)"):format(tostring(a.result)))
  -- the session and the held camera are swept by battle.ended, which is the
  -- teardown BELOW this, not the moment `result` is written -- so the sweep
  -- is only worth asserting once the battle has actually left the stack
  for _ = 1, 40 do U.tap(game, "a"); U.wait(4) end
  U.wait(60)
  U.log(("A: after teardown -- session=%s veil=%s (want gone/down)")
        :format(CatchThrow.session() and "still up" or "gone",
                BattleScene.capture and "still up" or "down"))

  -- ------- B: the LAST ball, thrown short

  Bag.add(game.save, "POKE_BALL", 1, game.data)
  CatchThrow.lastBall = "POKE_BALL"
  U.log("== B: FULL with " .. ballCount() .. " ball")
  local b = BattleState.newWild(game, "PIDGEY", 5)
  b.onFinish = function() end
  game.overworld:pushBattle(b)
  toCapture(b)
  describe("B", b)

  -- a deliberately feeble swipe: it must fall short of the Pokemon, so
  -- the miss is the outcome under test rather than a lucky catch
  local aim = CatchThrow._aimInfo()
  if aim then
    local uw, uh = love.graphics.getDimensions()
    local function toWin(gx, gy)
      return (aim.lx + gx * aim.scale) * uw / aim.pw,
             (aim.ly + gy * aim.scale) * uh / aim.ph
    end
    local hx, hy = aim.hand[1], aim.hand[2]
    local dx, dy = aim.ring[1] - hx, aim.ring[2] - hy
    local d = math.sqrt(dx * dx + dy * dy)
    dx, dy = dx / d, dy / d
    local step = 120 / 60
    local px, py = toWin(hx, hy)
    love.mousepressed(px, py, 1, false, 1)
    for i = 1, 8 do
      local wx, wy = toWin(hx + dx * step * i, hy + dy * step * i)
      love.mousemoved(wx, wy, 0, 0, false)
      U.wait(1)
    end
    local wx, wy = toWin(hx + dx * step * 8, hy + dy * step * 8)
    love.mousereleased(wx, wy, 1, false, 1)
  else
    U.log("B: NO AIM INFO -- capture mode did not open")
  end

  -- ride the throw out, then keep tapping through the miss text until the
  -- hand is refilled -- which, with the bag now empty, means the EMPTY hand
  for _ = 1, 400 do
    U.wait(2)
    local q = CatchThrow.session()
    if q and q.phase == "aim" and q.empty then break end
    if not q then break end
    if q.phase ~= "aim" and q.phase ~= "flight" then U.tap(game, "a") end
  end
  local sb = describe("B", b)
  U.log(("B: last ball thrown, balls=%d -> %s (want an empty hand)")
        :format(ballCount(),
                (sb and sb.empty) and "empty hand" or
                (sb and ("still holding " .. tostring(sb.ballId)))
                or "SESSION GONE"))
  U.shot(game, DIR .. "/empty_2_ranout.png")
  key("b")
  for _ = 1, 120 do
    U.wait(2)
    if b.result then break end
    U.tap(game, "a")
  end
  U.log("B: after B -- result=" .. tostring(b.result) .. " (want run)")
  for _ = 1, 40 do U.tap(game, "a"); U.wait(4) end
  U.wait(60)

  -- ------- C: the scripted tutorial, untouched

  Bag.add(game.save, "POKE_BALL", 10, game.data)
  U.log("== C: the old man's demo, at FULL, with " .. ballCount() .. " balls")
  local om = game.data.field.oldManBattle or { species = "WEEDLE", level = 5 }
  local c = BattleState.newWild(game, om.species, om.level)
  c:makeOldManDemo()
  c.onFinish = function() end
  U.log("C: LetsGo.scripted -> " .. tostring(LetsGo.scripted(c))
        .. "  fullWild -> " .. tostring(LetsGo.fullWild(c))
        .. "  wantsMinigame -> " .. tostring(LetsGo.wantsMinigame(c)))
  game.overworld:pushBattle(c)

  -- the demo drives ITSELF: the cursor, the bag and the throw are all
  -- scripted, so this only watches. Any session or veil appearing here is
  -- the failure.
  local sawSession, sawVeil = false, false
  local shotDemo = false
  for i = 1, 900 do
    if CatchThrow.session() then sawSession = true end
    if BattleScene.capture then sawVeil = true end
    if not shotDemo and i > 200 then
      shotDemo = true
      U.shot(game, DIR .. "/empty_3_oldman.png")
    end
    if c.result then break end
    U.wait(2)
    -- the scripted beats want A only to page the text along
    if i % 3 == 0 then U.tap(game, "a") end
  end
  U.log(("C: session ever opened=%s (want no)  veil ever up=%s (want no)")
        :format(tostring(sawSession), tostring(sawVeil)))
  U.log(("C: result=%s  balls=%d (want 10 -- the demo consumes none)")
        :format(tostring(c.result), ballCount()))
  U.log(("C: party still %d, first is %s")
        :format(#game.save.party,
                game.data.pokemon[game.save.party[1].species].name))

  -- ------- D: B RUNS, with a ball in hand, on a frame that runs several
  -- logic steps
  --
  -- The reported failure, reproduced rather than reasoned about. Input:step
  -- rebuilds the edge table once per FIXED step; Game:update runs the
  -- frame's steps first and the render-clock hooks after, so any frame
  -- carrying more than one step has already discarded the earlier steps'
  -- edges. Below 60fps -- which is where a 3D battle lives -- that is
  -- every press. speedOverride multiplies the logic clock, so it packs
  -- several steps into each frame on demand and turns "sometimes, on a
  -- slow machine" into "every time, here".
  for _, speed in ipairs({ 1, 4 }) do
    Bag.add(game.save, "POKE_BALL", 5, game.data)
    CatchThrow.lastBall = "POKE_BALL"
    game.speedOverride = speed > 1 and speed or nil
    U.log(("== D: FULL, ball in hand, B to run at %dX logic speed"):format(speed))
    local d = BattleState.newWild(game, "PIDGEY", 5)
    d.onFinish = function() end
    game.overworld:pushBattle(d)
    toCapture(d)
    local sd = describe("D" .. speed, d)
    if sd and not sd.empty then
      key("b")
      local ran = false
      for _ = 1, 60 do
        U.wait(2)
        if d.result then ran = true break end
      end
      U.log(("D%dX: after a REAL B -- result=%s (want run)  %s")
            :format(speed, tostring(d.result),
                    ran and "RAN" or "*** B DID NOTHING ***"))
    else
      U.log("D" .. speed .. ": no armed session to test")
    end
    -- escape hatch: a B that did nothing leaves the battle parked in the
    -- capture phase forever, and the rest of the run must still report
    if not d.result then
      pcall(CatchThrow.onBattleEnded)
      d.result, d.phase, d.afterQueue = "run", "messages", "finish"
    end
    for _ = 1, 80 do U.tap(game, "a"); U.wait(4) end
    U.wait(60)
    game.speedOverride = nil
  end
  U.log("done -- " .. DIR)
end

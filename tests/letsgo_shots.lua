-- Driver: photograph the LET'S GO capture mode end to end.
--
-- One wild encounter under FULL: the battle menu should never be seen --
-- capture mode opens over it with the ball hanging at the player's empty
-- cell and the ring pulsing on the foe -- then a synthetic mouse flick
-- throws the ball and the beats that follow are photographed: flight,
-- the open-mouth suck, the drop-and-wobble, and the outcome.
--
--   SHOT_DIR=.scratchpad/letsgo \
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/letsgo_shots.lua \
--   "/c/Program Files/LOVE/lovec.exe" .
--
-- SHOT_DIR must already exist. DS_LETSGO_MODE=catching runs the same
-- beats through the bag-menu route instead of the FULL auto-entry.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or ".scratchpad"
  local MODE = os.getenv("DS_LETSGO_MODE") or "full"
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

  -- a spread of levels, because the Let's Go award pays every party
  -- member against its OWN level: a low one should pull far more from
  -- the same catch than a high one, and a flat payout would hide that
  game.save.party = {
    Pokemon.new(game.data, "CHARIZARD", 45),
    Pokemon.new(game.data, "PIKACHU", 10),
    Pokemon.new(game.data, "RATTATA", 5),
  }
  game.save.player.name = "RED"
  Bag.add(game.save, "POKE_BALL", 20, game.data)
  Bag.add(game.save, "GREAT_BALL", 5, game.data)
  -- DS_BALL forces the ball, so a MASTER_BALL run is a guaranteed catch
  -- and the experience payout can be read deterministically
  local FORCE = os.getenv("DS_BALL")
  if FORCE then
    Bag.add(game.save, FORCE, 5, game.data)
    CatchThrow.lastBall = FORCE
  end
  local expBefore = {}
  for i, m in ipairs(game.save.party) do
    expBefore[i] = { exp = m.exp, level = m.level }
  end
  LetsGo.setting:setValue(MODE, game)
  -- DS_RUNG=cards forces the 2D-3D A rung: the control run for the pic
  -- measurement path, against the STADIUM models the save may be on
  if os.getenv("DS_RUNG") == "cards" then
    lib.require("OverworldBattle").setting:setValue(true, game)
    U.log("3D-BTL forced to 2D-3D A")
  end
  U.log("LET'S GO mode: " .. tostring(LetsGo.mode()))

  U.teleport(game, "ROUTE_1", 5, 8, "down")
  U.wait(90)

  local battle = BattleState.newWild(game, "PIDGEY", 5)
  battle.onFinish = function() end
  game.overworld:pushBattle(battle)

  -- the wipe and the "Wild X appeared!" chatter: tap until the menu (or
  -- capture mode, which under FULL opens the instant the menu would)
  U.wait(70)
  for i = 1, 80 do
    if battle.phase == "menu" or CatchThrow.session() then break end
    U.tap(game, "a")
    U.wait(6)
    if i % 20 == 0 then
      U.log(("still driving intro: phase=%s queue=%d anim=%s")
            :format(tostring(battle.phase), #(battle.queue or {}),
                    tostring(battle.animPlaying)))
    end
  end

  local function phase()
    local s = CatchThrow.session()
    return s and s.phase or ("battle:" .. tostring(battle.phase))
  end

  if MODE == "catching" then
    -- the bag route: ITEM on the menu, then the ball
    U.wait(20)
    U.log("menu phase: " .. tostring(battle.phase))
    -- cursor to ITEM (menu is 2x2: fight pkmn / item run) -- down once
    U.tap(game, "down"); U.wait(4)
    U.tap(game, "a"); U.wait(20)
    -- the bag opens on the first item; balls were added first
    U.tap(game, "a"); U.wait(10)
  else
    -- FULL: capture mode should have opened on its own
    U.wait(30)
  end

  U.log("capture phase: " .. phase())
  do
    local s = CatchThrow.session()
    if s then
      local b = s.artBox
      U.log(("probe: span=%.1f enemyGB=%.0f,%.0f playerGB=%.0f,%.0f")
            :format(s.shot.enemySpan or -1, s.shot.enemy[1], s.shot.enemy[2],
                    s.shot.player[1], s.shot.player[2]))
      U.log(("probe: eye=%.0f,%.0f,%.0f  enemyW=%.0f,%.0f playerW=%.0f,%.0f")
            :format(s.shot.eye[1], s.shot.eye[2], s.shot.eye[3],
                    s.enemyPos[1], s.enemyPos[3],
                    s.playerPos[1], s.playerPos[3]))
      if b then
        U.log(("probe: artBox ax=%d ay=%d box=%d..%d,%d..%d body r=%.1f yOff=%.1f")
              :format(b.ax, b.ay, b.x0, b.x1, b.y0, b.y1,
                      s.body.r, s.body.yOff))
      else
        U.log(("probe: artBox=nil body r=%.1f yOff=%.1f")
              :format(s.body.r, s.body.yOff))
      end
    end
  end
  U.shot(game, DIR .. "/1_aim.png")

  -- ------- the reach test
  --
  -- Drag the ball to the far corners of the WINDOW -- including well
  -- below where the battle's text box used to be -- and report where it
  -- actually ends up in the GB frame. A fence shows up here as a ball
  -- that stops moving while the pointer keeps going.
  do
    local W, H = love.graphics.getDimensions()
    local s = CatchThrow.session()
    if s and love.mousepressed then
      local hx, hy = s.handGB[1], s.handGB[2]
      love.mousepressed(W * 0.5, H * 0.62, 1, false, 1)
      U.wait(2)
      local CORNERS = {
        { "bottom-centre", 0.50, 0.97 },
        { "bottom-left",   0.06, 0.97 },
        { "bottom-right",  0.94, 0.97 },
        { "top-left",      0.06, 0.10 },
      }
      for _, c in ipairs(CORNERS) do
        for i = 1, 4 do
          if love.mousemoved then
            love.mousemoved(W * c[2], H * c[3], 0, 0, false)
          end
          U.wait(1)
        end
        local q = CatchThrow.session()
        U.log(("reach %-14s -> ball GB %.0f,%.0f  (frame is 160x144)")
              :format(c[1], q and q.handGB[1] or -1, q and q.handGB[2] or -1))
        if c[1] == "bottom-centre" then
          U.shot(game, DIR .. "/1b_drag_low.png")
        end
      end
      -- a slow release is a dead flick: nothing is thrown
      if love.mousereleased then
        love.mousereleased(W * 0.06, H * 0.10, 1, false, 1)
      end
      U.wait(30)
      U.log("after reach test: " .. phase()
            .. ("  (ball home was %.0f,%.0f)"):format(hx, hy))
    end
  end

  -- A synthetic flick aimed like a hand: from the session's own geometry,
  -- pick a release point short of the ring and a sweep speed for a
  -- comfortable sigma, so the aim model (release + reach along the flick)
  -- lands the ball on the ring centre. Window units; the session maps
  -- them back to GB through the live letterbox.
  local aim = CatchThrow._aimInfo()
  if aim then
    local uw, uh = love.graphics.getDimensions()
    local function toWin(gx, gy)
      return (aim.lx + gx * aim.scale) * uw / aim.pw,
             (aim.ly + gy * aim.scale) * uh / aim.ph
    end
    -- the throw is the swipe's own velocity now: grab the ball and sweep
    -- toward the ring at a comfortable ~190 GB px/s for 8 frames.
    -- DS_SWIPE overrides it, which is how the strength band is swept:
    -- weak should fall short, comfortable should land, hard should still
    -- reach rather than sail over.
    local SPEED = tonumber(os.getenv("DS_SWIPE") or "") or 190
    local FRAMES = 8
    SPEED_USED = SPEED
    local hx, hy = aim.hand[1], aim.hand[2]
    local dx, dy = aim.ring[1] - hx, aim.ring[2] - hy
    local d = math.sqrt(dx * dx + dy * dy)
    dx, dy = dx / d, dy / d
    U.log(("aim: hand %.0f,%.0f ring %.0f,%.0f outer %.0f")
          :format(hx, hy, aim.ring[1], aim.ring[2], aim.outer))
    local step = SPEED / 60
    if love.mousepressed then
      local px, py = toWin(hx, hy)
      love.mousepressed(px, py, 1, false, 1)
    end
    for i = 1, FRAMES do
      local wx, wy = toWin(hx + dx * step * i, hy + dy * step * i)
      if love.mousemoved then love.mousemoved(wx, wy, 0, 0, false) end
      U.wait(1)
    end
    if love.mousereleased then
      local wx, wy = toWin(hx + dx * step * FRAMES, hy + dy * step * FRAMES)
      love.mousereleased(wx, wy, 1, false, 1)
    end
    -- what actually left the hand, before gravity has touched it
    local s0 = CatchThrow.session()
    if s0 and s0.vel then
      local p = s0.ballInst.pos
      U.log(("LAUNCH fwd/up/lat = %.1f %.1f %.1f  from height %.1f, %.1f px out")
            :format(math.sqrt(s0.vel[1] ^ 2 + s0.vel[3] ^ 2), s0.vel[2], 0,
                    p[2] - s0.groundY,
                    math.sqrt((s0.enemyPos[1] - p[1]) ^ 2
                              + (s0.enemyPos[3] - p[3]) ^ 2)))
    else
      U.log("LAUNCH -- nothing was thrown (flick rejected)")
    end
  else
    U.log("NO AIM INFO -- capture mode did not open")
  end

  U.wait(4)
  -- did it CONNECT? poll the flight out and say plainly which way it
  -- went, so a strength sweep reads as a table instead of a guess
  do
    local verdict, peak = "no throw", 0
    for _ = 1, 200 do
      local s = CatchThrow.session()
      if not s then verdict = "session gone" break end
      if s.phase == "flight" then
        local h = s.ballInst.pos[2] - s.groundY
        if h > peak then peak = h end
        verdict = "MISS (fell short / wide)"
      elseif s.phase == "suck" or s.phase == "drop"
             or s.phase == "wobble" then
        verdict = "HIT" .. (s.tier and (" " .. s.tier) or " (outside ring)")
        break
      elseif s.phase ~= "aim" then
        break
      end
      U.wait(1)
    end
    local body = CatchThrow.session() and CatchThrow.session().body
    U.log(("THROW swipe=%d -> %s   (apex %.1f world px, body centre %.1f)")
          :format(SPEED_USED or -1, verdict, peak, body and body.yOff or -1))
  end
  U.log("after flick: " .. phase())
  U.shot(game, DIR .. "/2_flight.png")

  -- the suck: ball open at the foe, beam on, mon shrinking
  for _ = 1, 60 do
    U.wait(1)
    local s = CatchThrow.session()
    if s and s.phase == "suck" then break end
    if not CatchThrow.session() then break end
  end
  U.log("suck check: " .. phase()
        .. "  shrink=" .. tostring(BattleScene.capture
                                   and BattleScene.capture.shrink))
  U.shot(game, DIR .. "/3_suck.png")

  -- the drop and the first wobble
  for _ = 1, 120 do
    U.wait(1)
    local s = CatchThrow.session()
    if s and s.phase == "wobble" then break end
    if not s then break end
  end
  U.wait(30)
  U.log("wobble check: " .. phase()
        .. "  shrink=" .. tostring(BattleScene.capture
                                   and BattleScene.capture.shrink))
  U.shot(game, DIR .. "/4_wobble.png")

  -- the outcome: stars or burst, then the engine's own text
  for _ = 1, 300 do
    U.wait(1)
    local s = CatchThrow.session()
    if not s or s.phase == "epilogue" or s.phase == "burst" then break end
  end
  U.wait(20)
  U.log("outcome: " .. phase())
  U.shot(game, DIR .. "/5_outcome.png")

  -- under FULL a breakout must land straight back in throw mode -- no
  -- enemy turn between; a catch plays out its epilogue instead
  -- keep tapping through the caught chatter so storeCaughtMon (and the
  -- experience payout hanging off it) actually runs
  for _ = 1, 60 do U.tap(game, "a"); U.wait(6) end
  U.log(("after outcome: %s  battle=%s  balls=%d")
        :format(phase(), tostring(battle.phase),
                game.save.inventory.POKE_BALL or 0))
  for i, m in ipairs(game.save.party) do
    local was = expBefore[i]
    local nm = game.data.pokemon[m.species].name
    U.log(("EXP %-10s Lv%-3d -> Lv%-3d  exp %d -> %d  (+%d)")
          :format(nm, was.level, m.level, was.exp, m.exp, m.exp - was.exp))
  end
  local combo = lib.require("LetsGo").combo()
  U.log("combo: " .. (combo and (combo.species .. " x" .. combo.count)
                      or "none"))
  U.shot(game, DIR .. "/6_after.png")
  U.log("done -- " .. DIR)
end

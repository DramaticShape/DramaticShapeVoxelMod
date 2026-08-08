-- Probe: the reported grass along the TOP of the frame in GO-style
-- battles on ROUTE 6.
--
-- The capture seat is a different camera from the battle's own: the "tele"
-- rig stands 145 world px back at a height of 37.9 (well over two cells,
-- clear of anything that grows on the ground), while the head-on capture
-- seat stands 46 back at a height of 13 -- BELOW the top of a 16px grass
-- tuft or hedge. On a route lined with the stuff, the eye is inside it.
--
-- So: stage a capture at several spots along Route 6 and record where the
-- eye actually is relative to the ground, with a shot of each.
--
--   SHOT_DIR=.scratchpad/route6 \
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/letsgo_route6.lua \
--   "/c/Program Files/LOVE/lovec.exe" .
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or ".scratchpad/route6"
  local Pokemon = require("src.pokemon.Pokemon")
  local BattleState = require("src.battle.BattleState")
  local Bag = require("src.inventory.Bag")

  local exports = game.mods and game.mods.exports
  local lib = exports and exports.DRAMATIC_SHAPE and exports.DRAMATIC_SHAPE.lib
  if not lib then
    U.log("DRAMATIC_SHAPE is not loaded")
    return
  end
  local LetsGo = lib.require("LetsGo")
  local CatchThrow = lib.require("CatchThrow")
  local ChunkMesher = lib.require("ChunkMesher")

  pcall(os.execute, 'mkdir -p "' .. DIR .. '" 2>/dev/null')
  pcall(os.execute, 'mkdir "' .. DIR:gsub("/", "\\") .. '" 2>nul')

  game.save.party = { Pokemon.new(game.data, "CHARIZARD", 45) }
  game.save.player.name = "RED"
  Bag.add(game.save, "POKE_BALL", 99, game.data)
  CatchThrow.lastBall = "POKE_BALL"
  LetsGo.setting:setValue("full", game)

  local MAP = os.getenv("DS_MAP") or "ROUTE_6"
  -- a spread down the route: the reported shot is on the path with hedges
  -- both sides, which is where a low seat has the least room
  local SPOTS = {}
  for _, xy in ipairs({ { 5, 6 }, { 5, 14 }, { 9, 20 }, { 4, 26 }, { 10, 32 } }) do
    SPOTS[#SPOTS + 1] = xy
  end

  for i, sp in ipairs(SPOTS) do
    U.teleport(game, MAP, sp[1], sp[2], "up")
    U.wait(50)
    -- confirm the teleport actually landed: a first cut reported the SAME
    -- eye at all five spots, which meant the probe never left the save's
    -- own position and every "spot" was one place wearing five labels
    do
      local ow = game.overworld
      local m = ow and ow.map
      U.log(("spot %d: on map %s at cell %s,%s")
            :format(i, tostring(m and (m.id or m.name) or "?"),
                    tostring(ow and ow.player and ow.player.cellX),
                    tostring(ow and ow.player and ow.player.cellY)))
    end
    for _ = 1, 600 do
      if ChunkMesher.pending() == 0 then break end
      U.wait(1)
    end

    local bt = BattleState.newWild(game, "ODDISH", 13)
    bt.onFinish = function() end
    game.overworld:pushBattle(bt)
    U.wait(70)
    for _ = 1, 80 do
      if bt.phase == "menu" or CatchThrow.session() then break end
      U.tap(game, "a")
      U.wait(6)
    end
    U.wait(40)

    local s = CatchThrow.session()
    if s and s.shot and s.shot.eye then
      local e = s.shot.eye
      local p = s.playerPos
      local back = math.sqrt((e[1] - p[1]) ^ 2 + (e[3] - p[3]) ^ 2)
      U.log(("spot %d (%d,%d): eye = %.1f,%.1f,%.1f  height %.1f over ground  "
             .. "seat %.1f back (wants 46)%s")
            :format(i, sp[1], sp[2], e[1], e[2], e[3], e[2] - s.groundY, back,
                    back < 45.5 and "  <-- the world pulled it in" or ""))
    else
      U.log(("spot %d (%d,%d): no capture session"):format(i, sp[1], sp[2]))
    end
    U.shot(game, ("%s/spot%d.png"):format(DIR, i))

    -- out, and all the way off the stack before the next spot
    U.tap(game, "b")
    for _ = 1, 300 do
      if not CatchThrow.session() and game.stack:top() ~= bt then break end
      U.tap(game, "a")
      U.wait(4)
    end
    U.wait(30)
  end
  U.log("done -- " .. DIR)
end

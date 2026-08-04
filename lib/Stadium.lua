-- STADIUM battles: the two Pokemon as real 3D models.
--
-- The 3D-BTL row's third rung. OFF is the engine's own white battle field;
-- 2D-3D stands the GB's own pics up on the map as quads (BattleBillboard);
-- STADIUM replaces those quads with the Pokemon Stadium battle models --
-- skinned, animated, and playing the animation the move being used
-- actually calls for.
--
-- The models come out of the Stadium ROM through model_extract, and are
-- packed into assets/stadium/NNN.dsm by tools/stadium_pack.py. Nothing here
-- knows about the ROM; the pack is the interface.
--
-- ------- what this file is, and is not
--
-- It is the MODE: which species is out on each side, which animation the
-- fight is asking each of them for, whether the model or the flat pic is
-- standing in this frame, and the two draw calls. The arithmetic is
-- StadiumRig's, the file format is StadiumPack's, and one side's own state
-- is StadiumMon's.
--
-- It is not a rewrite of the staged battle. The arena is picked the same
-- way, the camera is solved the same way, the HUDs and the text box and the
-- move animations and the depth of field are all exactly what 2D-3D draws
-- -- because all of those are hung off the arena's CELLS, not off the
-- pics. Swapping what stands on a cell changes nothing about where the cell
-- projects to. That is why this is an option on the mode rather than a
-- second mode.
--
-- ------- declining, per Pokemon
--
-- Every gate here is per SIDE and per FRAME, not per battle:
--
--   no pack for that species, or its meshes would not build -> that side
--   falls back to its flat pic, and the other side keeps its model
--
--   the side is showing a TRAINER (the foe's class before the send-out,
--   the player's own back before "Go!") -> that is not a Pokemon and there
--   is no model for it; the pic stands, exactly as in 2D-3D
--
--   a SUBSTITUTE is up -> the engine replaces the pic with the mini doll,
--   which is the thing the player is being told is there. A model of the
--   Pokemon behind the doll would be a lie about the battle state.
--
-- So `covers` is asked per side per frame, and OverworldBattle renders a
-- billboard texture for exactly the sides it answers false for.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Voxel3D = V.require("Voxel3D")
local StadiumPack = V.require("StadiumPack")
local StadiumMon = V.require("StadiumMon")

local Stadium = {}

-- The stored values of the two 3D-BTL rungs that select this mode. Strings
-- rather than further booleans so an older save's `true` still means the
-- 2D-3D it was written for (see OverworldBattle.setting).
--
--   A  the models on the MAP -- real ground, the map's own light and sky
--   B  the models on two DISCS against the sky, with no map at all
--
-- Everything below is shared: which species is out, which animation the
-- fight is asking for, the skinning, the draw. The difference is entirely
-- in what the camera is pointed at, which is BattleScene's business and
-- StadiumStage's.
Stadium.VALUE = "stadium"
Stadium.VALUE_B = "stadiumB"

-- ------- the live pair

local session = nil     -- nil when no staged fight is running

local function game()
  return require("src.core.Game")
end

-- Whether the row is on this rung. Deliberately NOT gated on whether the
-- packs are installed: a mod folder without assets/stadium still cycles the
-- row, and each Pokemon declines on its own when its pack does not load --
-- which is one message on the console rather than a row that silently
-- refuses to move.
function Stadium.selected()
  return Stadium.mode() ~= nil
end

-- "A", "B", or nil when the row is on neither stadium rung.
function Stadium.mode()
  local OverworldBattle = V.require("OverworldBattle")
  local value = OverworldBattle.setting:get()
  if value == Stadium.VALUE then return "A" end
  if value == Stadium.VALUE_B then return "B" end
  return nil
end

-- Whether the fight is staged on the DISCS rather than on the map. Asked by
-- BattleScene (what to draw the pair against), BattleArena (whether the map
-- has to have room) and BattleCam (which framing to solve).
function Stadium.discs()
  return Stadium.mode() == "B"
end

function Stadium.enabled()
  if not Stadium.selected() then return false end
  return Voxel3D.available()
end

-- A staged fight has begun on `arena`. Called from OverworldBattle.begin,
-- which is the one place that knows a fight is being staged at all.
function Stadium.begin(arena)
  Stadium.finish()
  if not Stadium.enabled() then return false end
  session = {
    arena = arena,
    groundY = 0,
    player = StadiumMon.new("player"),
    enemy = StadiumMon.new("enemy"),
    -- what each side has been TRANSFORMED into, if anything (see install)
    transform = {},
    -- sides that are going to collapse, but whose HP bar has not finished
    -- emptying yet (see faintReady)
    faintPending = {},
  }
  return true
end

function Stadium.finish()
  if not session then return end
  session.player:release()
  session.enemy:release()
  session = nil
end

function Stadium.active()
  return session ~= nil
end

-- ------- which species each side is showing

-- The National Dex number for a battler, which is the number the Stadium
-- packs are keyed by. The engine's species are string keys ("PIKACHU") and
-- carry their dex number on the definition, so this is one lookup rather
-- than a table of its own.
local function dexOf(species)
  if not species then return nil end
  local data = game() and game().data
  local def = data and data.pokemon and data.pokemon[species]
  return def and def.dex or nil
end

-- Whether this side is showing a TRAINER rather than a Pokemon.
local function showingTrainer(battle, side)
  if side == "enemy" then
    return (battle.showEnemyTrainer and battle.trainerPic) and true or false
  end
  return (battle.showPlayerBack and battle.playerBackPic) and true or false
end

-- Whether this side has anything on the field at all this frame.
--
-- Mirrors BattleState's own guards, the same way OverworldBattle.sideVisible
-- mirrors them for the flat cards: there is no seam that reports "the foe is
-- off screen right now", and a model left standing through a send-out or a
-- damage blink would be the one thing in the frame that ignored the battle.
local function onField(battle, side)
  local battler = side == "player" and battle.player or battle.enemy
  if not (battler and battler.sprite) then return false end
  if side == "enemy" then
    if battle.enemyHidden or battle.enemySendingOut then return false end
  else
    if battle.safari or battle.demo or battle.sendingOut then return false end
  end
  local ok, hidden = pcall(battle.fxHidden, battle, battler)
  if ok and hidden then return false end
  -- a fainted Pokemon is gone once its slide has finished, exactly as its
  -- pic is
  if battler.fainted then
    local okF, sliding = pcall(battle.fxFaintActive, battle, battler)
    if not (okF and sliding) then return false end
  end
  return true
end

-- Whether the 3D model is standing in for this side's pic this frame. The
-- one question OverworldBattle asks, and the answer that decides whether a
-- billboard texture gets rendered for that side at all.
function Stadium.covers(battle, side)
  if not (session and battle) then return false end
  local mon = session[side]
  if not (mon and mon.rig) then return false end
  if showingTrainer(battle, side) then return false end
  local battler = side == "player" and battle.player or battle.enemy
  -- the substitute doll is what the player is being shown is out there
  if battler and battler.substituteHP then return false end
  return true
end

-- ------- the collapse waits for the bar
--
-- `onFaint` runs the instant HP reaches zero, which is NOT when a Pokemon
-- falls over. The engine queues the collapse -- the slide, the cry, the
-- "fainted!" line -- to run after the move animation and the HP-bar drain
-- (BattleState.onFaint's own comment), and the drain takes real frames: a
-- 150 HP mon's bar walks down over some four seconds.
--
-- So asking for the faint animation at `onFaint` played it against a bar
-- that was still emptying: the Pokemon lay down, and then its health went on
-- draining above the corpse. What the player reads as the moment of death is
-- the bar hitting zero, and that is what this waits for.
--
-- `shownHP` is the engine's own bar position (BattleState.stepHPDrain walks
-- it toward mon.hp a point at a time), so this is not a guess at the timing
-- -- it is the same number the bar is drawn from.
local function faintReady(battler)
  if not battler then return false end
  -- nothing is animating the bar for this battler: there is nothing to wait
  -- for, and waiting forever would mean never collapsing at all
  if battler.shownHP == nil then return true end
  return battler.shownHP <= 0
end

-- Whether a pending collapse is still owed. A switch, a revive or a battler
-- that was replaced under us drops it rather than firing late at whoever is
-- standing there now.
local function faintStillDue(battler)
  return (battler and battler.faintQueued
          and battler.mon and (battler.mon.hp or 0) <= 0) and true or false
end

-- named for the suite: the timing rule is the whole of this change, and it
-- is testable without a graphics context where the mode itself is not
Stadium._faintReady = faintReady
Stadium._faintStillDue = faintStillDue

-- ------- per frame
--
-- Runs from OverworldBattle.update, before the pics are rendered and before
-- the scene is drawn: what this decides is exactly which sides need a pic.
function Stadium.update(dt, battle, groundY)
  if not session then return end
  session.groundY = groundY or session.groundY or 0
  if not battle then return end

  local arena = session.arena
  for _, side in ipairs({ "enemy", "player" }) do
    local mon = session[side]
    local battler = side == "player" and battle.player or battle.enemy
    local dex = nil
    if battler and not showingTrainer(battle, side) then
      dex = session.transform[side] or dexOf(battler.mon and battler.mon.species)
    end
    -- the collapse this side is owed, once its bar has finished emptying
    if session.faintPending and session.faintPending[side] then
      if not faintStillDue(battler) then
        session.faintPending[side] = nil
      elseif faintReady(battler) then
        session.faintPending[side] = nil
        if mon and mon.rig then mon:request("faint") end
      end
    end

    mon:setSpecies(dex)
    mon.visible = (mon.rig ~= nil) and onField(battle, side)
                  and not (battler and battler.substituteHP)
    -- cleared up front, so a side that has just lost its rig cannot leave
    -- last frame's matrix behind it
    mon.model_matrix = nil

    if mon.rig then
      -- the send-out grow, borrowed whole from the engine: the pic scales
      -- up out of the ball in three steps and so does the model
      local okG, grow = pcall(battle.growInScale, battle, battler)
      mon.scale = (okG and grow) or 1
      mon:update(dt or 0)
      if mon.visible and arena then
        local cell = arena[side]
        local other = arena[side == "player" and "enemy" or "player"]
        if cell and other then
          mon.model_matrix = mon:matrix(cell[1], session.groundY, cell[2],
                                        other[1] - cell[1],
                                        other[2] - cell[2])
          mon:build()
        else
          mon.model_matrix = nil
        end
      else
        mon.model_matrix = nil
      end
    end
  end
  Stadium.debug(dt)
end

-- ------- the draws
--
-- Both take the pass as they find it: this is called from inside
-- BattleScene's own beginScene/endScene window (and, in a headset, from
-- VoxelScene's), so the camera, the shadow map, the hour's tint and the hit
-- flash are all already set. StadiumRig turns the wireframe and the glass
-- mask off around its own draws and puts them back.

function Stadium.draw(pull)
  if not session then return end
  for _, side in ipairs({ "enemy", "player" }) do
    local mon = session[side]
    if mon.rig and mon.visible and mon.model_matrix then
      mon.rig:draw(mon.model_matrix, pull)
    end
  end
end

-- The same models as the SUN sees them, so a Pokemon throws the shadow of
-- the pose it is actually in -- an outstretched wing puts an outstretched
-- wing on the ground.
function Stadium.cast(shadowMap)
  if not session then return end
  for _, side in ipairs({ "enemy", "player" }) do
    local mon = session[side]
    if mon.rig and mon.visible and mon.model_matrix then
      mon.rig:caster(shadowMap, mon.model_matrix)
    end
  end
end

-- Which state a side's model is playing, or nil. Named for the shot drivers:
-- checking that an animation starts on the right FRAME is an ordering
-- question, and a screenshot cannot answer one.
function Stadium.animOf(side)
  if not session then return nil end
  local mon = session[side]
  return mon and mon.state or nil
end

-- How wide the Pokemon on `side` stands, in world pixels, or nil when there
-- is not one. What STADIUM B sizes that side's platform to (StadiumStage).
function Stadium.footprint(side)
  if not session then return nil end
  local mon = session[side]
  if not (mon and mon.model) then return nil end
  local r = mon:worldRadius()
  return (r > 0) and r or nil
end

-- Whether anything at all is standing this frame -- what the shadow
-- signature keys on alongside the pics' own token.
function Stadium.standing()
  if not session then return false end
  return (session.player.visible or session.enemy.visible) and true or false
end

-- ------- what the fight asks for
--
-- The animation state machine is driven from four points in the engine's
-- own battle, and each is a wrap rather than a rewrite: the inner function
-- runs exactly as it always did and this reads what went past.

local function sideOf(battle, battler)
  if not (session and battler) then return nil end
  if battler == battle.player then return "player" end
  if battler == battle.enemy then return "enemy" end
  return nil
end

local function ask(battle, battler, state, animIndex, auxIndex)
  local side = sideOf(battle, battler)
  if not side then return end
  local mon = session[side]
  if mon and mon.rig then mon:request(state, animIndex, auxIndex) end
end

function Stadium.install()
  local BattleState = require("src.battle.BattleState")
  if BattleState.dramaticShapeStadiumHook then return end
  BattleState.dramaticShapeStadiumHook = true

  -- THE ATTACK. performMove is the one place a move is actually used, and
  -- the move's own `index` is the Gen 1 move id the Stadium tables are
  -- keyed by -- so the species' own animation for that move comes straight
  -- out of the pack, with no name mapping and no per-move code.
  local innerMove = BattleState.performMove
  function BattleState:performMove(user, target, moveInst, isCalled)
    if session then
      local side = sideOf(self, user)
      local mon = side and session[side]
      if mon and mon.rig then
        local okDef, def = pcall(self.moveDef, self, moveInst)
        local index = okDef and def and def.index or nil
        if not (index and mon:attack(index)) then
          -- a move the table has nothing for still swings: the generic
          -- attack is what the species' own reaction slot resolves to
          mon:request("attack")
        end
      end
    end
    return innerMove(self, user, target, moveInst, isCalled)
  end

  -- THE HIT. applyDamage is where HP actually comes off, which is the
  -- moment the reaction belongs to -- ahead of the bar drain and the
  -- message, both of which take frames.
  local innerDamage = BattleState.applyDamage
  function BattleState:applyDamage(target, dmg)
    local dealt = innerDamage(self, target, dmg)
    -- a substitute soaking the hit means the Pokemon behind it did not
    -- flinch, and its model is not the thing on screen anyway
    if session and (dealt or 0) > 0 and not (target and target.substituteHP) then
      ask(self, target, "hit")
    end
    return dealt
  end

  -- THE FAINT. Held on its last frame rather than looped (see StadiumMon's
  -- STATES), because a Pokemon that collapses and then stands back up
  -- while the message is still on screen is worse than no animation.
  --
  -- RECORDED HERE, PLAYED LATER. This runs the moment HP reaches zero, which
  -- is several seconds before the Pokemon is supposed to fall over -- the
  -- engine queues the collapse behind the move animation and the HP-bar
  -- drain. Marking the side and letting Stadium.update fire it when the bar
  -- empties is what keeps the two together (see faintReady).
  local innerFaint = BattleState.onFaint
  function BattleState:onFaint(battler)
    if session and not (battler and battler.faintQueued) then
      local side = sideOf(self, battler)
      if side and session.faintPending then
        session.faintPending[side] = true
      end
    end
    return innerFaint(self, battler)
  end

  -- THE ENTRANCE. startGrowIn is the send-out: the ball opens, the pic
  -- scales up over twelve frames, and the model plays the animation the
  -- battle system's own entrance slot names.
  local innerGrow = BattleState.startGrowIn
  function BattleState:startGrowIn(battler)
    if session then ask(self, battler, "entrance") end
    return innerGrow(self, battler)
  end

  -- TRANSFORM. The engine records a transform by swapping the battler's
  -- sprite and nothing else, so this is the only seam that reports one --
  -- and it reports the side, which is all that is needed to point that
  -- side's model at the copied species. Cleared when a side's own species
  -- changes under it (a switch, or the next battle).
  local innerSpecies = BattleState.speciesSprite
  function BattleState:speciesSprite(species, isPlayerSide)
    if session then
      session.transform[isPlayerSide and "player" or "enemy"] = dexOf(species)
    end
    return innerSpecies(self, species, isPlayerSide)
  end

  -- and a switch or a send-out ends any transform on that side
  local innerSwitch = BattleState.resolveSwitch
  function BattleState:resolveSwitch(newMon)
    if session then session.transform.player = nil end
    return innerSwitch(self, newMon)
  end
end

-- ------- when a draw goes wrong
--
-- The draw and the shadow cast are both called through a pcall, because a
-- throw inside the scene pass would hand the whole voxel mode to Pipelines'
-- guard and retire it for the session. Swallowed silently, though, a broken
-- model is indistinguishable from an invisible one -- so the first failure
-- of a battle says so, once, and the rest of the fight carries on without
-- it.
local reported = false

function Stadium.report(err)
  if reported then return end
  reported = true
  V.mod.log:warn("stadium: a model failed to draw: %s -- this battle runs "
                 .. "without it", tostring(err))
end

-- DS_STADIUM_DEBUG=1 prints what each side resolved to once a second, which
-- is how "nothing is on screen" gets told apart from "nothing was asked
-- for". Read through pcall: the loader's sandbox does not hand a mod `os`,
-- and a diagnostic must never be why the mod fails to load.
local DEBUG = select(2, pcall(function() return os.getenv("DS_STADIUM_DEBUG") end))
if DEBUG == nil or DEBUG == false then DEBUG = nil end

local debugAt = 0

function Stadium.debug(dt)
  if not (DEBUG and session) then return end
  debugAt = debugAt + (dt or 0)
  if debugAt < 1 then return end
  debugAt = 0
  for _, side in ipairs({ "enemy", "player" }) do
    local mon = session[side]
    local m = mon.model_matrix
    V.mod.log:info("stadium %s: dex=%s rig=%s visible=%s anim=%s t=%.2f "
                   .. "height=%.1f at=%s",
                   side, tostring(mon.species), tostring(mon.rig ~= nil),
                   tostring(mon.visible), tostring(mon.anim), mon.time or 0,
                   mon.model and mon:worldHeight() or 0,
                   m and ("%.0f,%.0f,%.0f"):format(m[4], m[8], m[12]) or "-")
  end
end

function Stadium.invalidate()
  if session then
    session.player:release()
    session.enemy:release()
  end
  StadiumPack.invalidate()
  -- the discs are a mesh and a texture like anything else, and a graphics
  -- context that went away took them with it
  pcall(function() V.require("StadiumStage").invalidate() end)
end

return Stadium

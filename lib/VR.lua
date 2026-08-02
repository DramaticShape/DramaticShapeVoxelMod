-- VR: the conductor -- one call per game frame that runs the whole
-- headset side, and the row that switches it on.
--
-- The shape of a VR frame, from the pipeline's update hook (which ticks
-- every frame whatever is on the stack, which is exactly what a headset
-- needs -- the world must keep arriving through menus, dialogs and
-- battles):
--
--   poll the runtime's events (begin the session when it says READY)
--   xrWaitFrame            <- BLOCKS until the headset wants a frame;
--                             with vsync handed off (set to 0 while the
--                             session runs) this is what paces the whole
--                             app at headset rate, while FixedStep keeps
--                             the game's own logic at its 60 Hz
--   locate the two eyes
--   render the world once per eye (VoxelScene.render's `eyes` path:
--     shared shadow map, shared pose capture, per-eye cameras from VRRig)
--   blit each eye canvas into its swapchain image (VRGL)
--   copy the window's front buffer into the UI quad when a menu, dialog,
--     battle or wipe is what the flat screen is showing
--   xrEndFrame with the projection layer and/or the quad
--
-- WHICH VR YOU GET mirrors the VOXEL ladder, deliberately: on the orbit
-- rungs the world is a TABLETOP DIORAMA pinned below and ahead of where
-- your head started -- lean in, walk around it; on 1ST you stand inside
-- at life scale, the HMD steers FirstPerson's yaw and pitch, and FreeMove
-- walks where you look exactly as it does on the flat screen. The flat
-- window keeps running as the mirror (left eye when the world is up), so
-- menus stay usable at the desk and every existing input keeps working --
-- v1 has no XR controller bindings on purpose.
--
-- Failure is a status, never a crash: no runtime, no headset, no GL
-- interop, or a mid-session loss all land back on the flat screen with
-- the reason readable off VR.status().

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ModSetting")
local Voxel = V.require("VoxelState")
local Voxel3D = V.require("Voxel3D")
local VoxelScene = V.require("VoxelScene")
local FirstPerson = V.require("FirstPerson")
local BattleCam = V.require("BattleCam")
local VRRig = V.require("VRRig")
local VRXR = V.require("VRXR")
local VRGL = V.require("VRGL")

local VR = {}

-- the row: plain OFF/ON. No hotkey -- the engine's display keys are
-- spoken for, and a headset is not something to toggle by accident.
VR.setting = ModSetting.new("vr", "VR", { false, true }, { "OFF", "ON" })

-- where the diorama's UI panel floats vs first person's
local QUAD_DIORAMA = { pos = { 0, 0.1, -1.0 }, width = 0.8 }
local QUAD_FP = { pos = { 0, 0, -1.4 }, width = 1.1 }

local started = false           -- start() succeeded this enablement
local failed = nil              -- start() failed; wait for a re-toggle
local wasOn = false
local savedVsync = nil
local fboCache = setmetatable({}, { __mode = "k" })   -- canvas -> GL FBO id
local mirrorSrc = nil           -- last left-eye canvas, for the window
local mirrorCanvas = nil
local status = "off"

-- the diorama's live adjustments: the right stick's zoom (a multiplier on
-- the model's size), the grab-drag's height (metres of world travel), and
-- the orbit rung the view toggle returns to from first person
local zoom = 1
local heightOff = 0
local lastOrbit = 4             -- the 50-degree rung, a sane middle
local held = {}                 -- GB buttons this module is holding down
local lastHandY = nil           -- the gripping hand's height, last frame

-- the palette closure the engine hands drawWorld; stashed there (see
-- main.lua) because the VR frame renders from update, where no ctx exists
VR.paletteFor = nil

function VR.enabled()
  return VR.setting:get() == true
end

function VR.active()
  return started and VRXR.isRunning()
end

function VR.status()
  if not VR.enabled() then return "off" end
  if failed then return failed end
  return VRXR.status()
end

-- Let go of every input this module was holding: the GB buttons pressed
-- through the overlay path, and the synthetic left stick. Runs when the
-- session ends and whenever a frame has no controller state to read.
local function releaseInputs()
  local ok, Game = pcall(require, "src.core.Game")
  if not ok or not Game.input then return end
  for btn in pairs(held) do
    pcall(function() Game.input:overlayReleased(btn) end)
    held[btn] = nil
  end
  pcall(function()
    Game.input:gamepadaxis(nil, "leftx", 0)
    Game.input:gamepadaxis(nil, "lefty", 0)
  end)
  lastHandY = nil
end

local function shutdown(reason)
  if started then
    VRXR.stop()
    started = false
  end
  if savedVsync ~= nil then
    pcall(love.window.setVSync, savedVsync)
    savedVsync = nil
  end
  -- the placed camera may still be a VR eye's; the orbit must get the
  -- pass back clean
  Voxel3D.camera = nil
  mirrorSrc = nil
  releaseInputs()
  BattleCam.still = false
  zoom, heightOff = 1, 0
  status = reason or "off"
end

VR.shutdown = shutdown          -- named for the probe driver

-- ------- the world, once per eye

local function renderWorld(views)
  local ok, Game = pcall(require, "src.core.Game")
  local ow = ok and Game.overworld or nil
  if not (ow and ow.map and ow.camera and Voxel.active()
          and Voxel3D.available()) then
    return false
  end
  local vw, vh = 320, 288
  pcall(function() vw, vh = Game.renderer:worldViewSize() end)

  local pivot, anchor, scale
  local fp = FirstPerson.engaged()
  if fp then
    local p = ow.player
    local gh = 0
    pcall(function() gh = VoxelScene.groundAt(ow.map, p.cellX, p.cellY) end)
    pivot = VRRig.fpPivot(p.px, p.py, gh, FirstPerson.EYE_HEIGHT)
    anchor = { 0, 0, 0 }
    scale = VRRig.FP_SCALE
    -- the HMD is the head: its yaw and pitch become FirstPerson's, so
    -- FreeMove walks where you look and A talks to what you face
    local yaw, pitch = VRRig.headYawPitch(views[1].pose.quat)
    FirstPerson.yaw = yaw
    FirstPerson.pitch = math.max(FirstPerson.PITCH_UP,
                          math.min(FirstPerson.PITCH_DOWN, pitch))
  else
    -- The table presents the world exactly as the flat screen does at
    -- rest: the pivot sits VIEW_DIST away along the RUNG'S own angle
    -- (stepping rungs re-tilts the model, easing with the rung tween),
    -- at the scale that reproduces the flat framing -- then the player's
    -- own adjustments go on top: the stick's zoom, the grip's height.
    pivot = VRRig.dioramaPivot(ow.camera.x + vw / 2, ow.camera.y + vh / 2)
    anchor = VRRig.dioramaAnchor(Voxel.angle, heightOff)
    scale = VRRig.dioramaScale(vh, Voxel.FOCAL) / zoom
  end

  local eyes = {}
  for i = 1, 2 do
    local v = views[i]
    eyes[i] = {
      camera = VRRig.eyeCamera(v.pose, v.fov, pivot, anchor, scale),
      w = v.w, h = v.h,
      slot = i == 1 and "vrL" or "vrR",
      adopt = true,
    }
  end
  eyes.cx, eyes.cy = pivot[1], pivot[3]

  local okR, canvases = pcall(VoxelScene.render, ow, 0, 0, vw, vh,
                              VR.paletteFor, eyes)
  if not (okR and type(canvases) == "table" and canvases[1] and canvases[2])
  then
    return false
  end

  for i = 1, 2 do
    local canvas = canvases[i]
    local tex, tw, th = VRXR.acquireEye(i)
    if tex then
      local fbo = fboCache[canvas]
      if not fbo then
        fbo = VRGL.canvasFBO(canvas)
        fboCache[canvas] = fbo
      end
      if fbo then
        VRGL.blitToTexture(fbo, canvas:getWidth(), canvas:getHeight(),
                           tex, tw, th)
      end
    end
    VRXR.releaseEye(i)
  end
  mirrorSrc = canvases[1]
  return true
end

-- ------- the UI panel

-- Whether the flat screen is showing something the world pass cannot: a
-- menu, a dialog, a battle, a transition wipe -- or everything, when the
-- world pass is off entirely.
local function wantQuad(worldUp)
  if not worldUp then return true end
  local ok, showing = pcall(function()
    local Game = require("src.core.Game")
    local top = Game.stack and Game.stack:top()
    return top ~= Game.overworld
           or (Game.overworld and Game.overworld.transitioning) or false
  end)
  return ok and showing or false
end

local function updateQuad(worldUp, fp)
  if not wantQuad(worldUp) then return nil end
  local tex, qw, qh = VRXR.acquireQuad()
  if not tex then return nil end
  local ww, wh = qw, qh
  pcall(function() ww, wh = love.graphics.getPixelDimensions() end)
  VRGL.copyFrontBuffer(tex, math.min(qw, ww), math.min(qh, wh))
  VRXR.releaseQuad()
  return fp and QUAD_FP or QUAD_DIORAMA
end

-- ------- the controllers
--
-- The mapping the mod ships (rebindable in the runtime's own UI):
--
--   both modes    left stick moves (through the engine's own stick path,
--                 so it grid-walks the diorama and free-walks 1ST);
--                 A/B are A/B; either trigger is START; clicking the
--                 LEFT stick toggles first/third person.
--   diorama only  right stick up/down zooms the model; clicking the
--                 RIGHT stick cycles the viewing angle through the orbit
--                 rungs; squeezing a grip and moving that hand up or
--                 down drags the whole table with it.

-- Flip between the 1ST rung and the last orbit rung, through the same
-- gate and plumbing the keyboard hotkey uses.
function VR.toggleView()
  pcall(function()
    local Game = require("src.core.Game")
    local Pipelines = require("src.render.Pipelines")
    local top = Game.stack and Game.stack:top()
    if not Pipelines.canToggle("voxel", top, Game.overworld) then return end
    local level = Pipelines.level("voxel")
    if Voxel.isFirstPerson(level) then
      Pipelines.setLevel("voxel", lastOrbit)
    else
      if level > 0 and not Voxel.isFull(level) then lastOrbit = level end
      Pipelines.setLevel("voxel", Voxel.FP_LEVEL)
    end
    if Game.save and Game.save.options then
      Pipelines.syncOptions(Game.save.options)
      pcall(Game.writeOptions, Game)
    end
  end)
end

-- Step the diorama's presentation angle through the orbit rungs (the
-- anchor re-derives from the rung's angle, so the table re-tilts on the
-- rung's own tween). FULL counts as its 35-degree twin, like the hotkey.
function VR.cycleAngle()
  pcall(function()
    local Game = require("src.core.Game")
    local Pipelines = require("src.render.Pipelines")
    local top = Game.stack and Game.stack:top()
    if not Pipelines.canToggle("voxel", top, Game.overworld) then return end
    local level = Pipelines.level("voxel")
    if Voxel.isFirstPerson(level) then return end
    local order = { 2, 3, 4, 5 }
    local at = nil
    for i, rung in ipairs(order) do
      if rung == level then at = i break end
    end
    if not at then
      local deg = Voxel.ANGLES_DEG[level + 1]
      for i, rung in ipairs(order) do
        if Voxel.ANGLES_DEG[rung + 1] == deg then at = i break end
      end
    end
    Pipelines.setLevel("voxel", order[at and (at % #order + 1) or 1])
    if Game.save and Game.save.options then
      Pipelines.syncOptions(Game.save.options)
      pcall(Game.writeOptions, Game)
    end
  end)
end

local function setGB(inp, btn, down)
  if down and not held[btn] then
    held[btn] = true
    inp:overlayPressed(btn)
  elseif not down and held[btn] then
    held[btn] = nil
    inp:overlayReleased(btn)
  end
end

local function driveControls(ctl, dt, fp)
  if not ctl then
    releaseInputs()
    return
  end
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game.input) then return end
  local inp = Game.input

  setGB(inp, "a", ctl.a)
  setGB(inp, "b", ctl.b)
  setGB(inp, "start", ctl.start)

  -- the left stick, through the engine's OWN stick handler: it quantises
  -- to the grid d-pad for the diorama, and FirstPerson.moveVector reads
  -- the same raw pair for the free walk. OpenXR's +Y is up; the engine's
  -- lefty is +down.
  inp:gamepadaxis(nil, "leftx", ctl.moveX or 0)
  inp:gamepadaxis(nil, "lefty", -(ctl.moveY or 0))

  if ctl.toggleChanged and ctl.toggle then VR.toggleView() end

  if not fp then
    local zy = ctl.lookY or 0
    if math.abs(zy) > 0.15 then
      zoom = math.max(0.35, math.min(4, zoom * math.exp(zy * (dt or 0) * 1.6)))
    end
    if ctl.angleChanged and ctl.angle then VR.cycleAngle() end
    -- the grab-drag: while a grip is squeezed, the table follows that
    -- hand's height, metre for metre
    local gl, gr = ctl.gripL or 0, ctl.gripR or 0
    local y = (gr >= gl) and ctl.handrY or ctl.handlY
    if math.max(gl, gr) > 0.6 and y then
      if lastHandY then
        heightOff = math.max(-1.5, math.min(1.5, heightOff + (y - lastHandY)))
      end
      lastHandY = y
    else
      lastHandY = nil
    end
  else
    lastHandY = nil
  end
end

-- ------- the per-frame drive

function VR.update(dt)
  local on = VR.enabled()
  if not on then
    if wasOn then
      shutdown("off")
      failed = nil
    end
    wasOn = false
    return
  end

  if not wasOn then failed = nil end   -- a fresh toggle earns a fresh try
  wasOn = true
  if failed then return end

  if not started then
    local qw, qh = 1024, 768
    pcall(function() qw, qh = love.graphics.getPixelDimensions() end)
    if VRXR.start(qw, qh) then
      started = true
      status = "session created"
      print("[DRAMATIC_SHAPE] VR: " .. VRXR.status())
    else
      failed = VRXR.status()
      print("[DRAMATIC_SHAPE] VR unavailable: " .. failed
            .. " -- fix that, then toggle the VR row to retry")
      return
    end
  end

  if not VRXR.poll() then
    -- the runtime took the session away (headset off, runtime shut down)
    shutdown("session lost")
    failed = "session lost -- toggle VR off and on to retry"
    return
  end
  if not VRXR.isRunning() then return end

  -- the headset paces the app now; vsync would fight it
  if savedVsync == nil then
    savedVsync = 1
    pcall(function() savedVsync = love.window.getVSync() end)
    pcall(love.window.setVSync, 0)
  end

  -- the battle camera holds still for as long as a headset is watching:
  -- its drift is a flat screen's depth cue, and a swaying picture inside
  -- VR reads as the world lurching
  BattleCam.still = true

  local time, should = VRXR.waitFrame()
  if not time then return end

  -- the controllers, before the world renders: the frame the toggle
  -- flips rungs on should be the frame that renders the new rig
  driveControls(VRXR.input(time), dt, FirstPerson.engaged())

  local worldUp = false
  if should then
    local views = VRXR.locateViews(time)
    if views then
      worldUp = renderWorld(views)
    end
  end
  local quadPose = updateQuad(worldUp, FirstPerson.engaged())
  VRXR.endFrame(time, worldUp or nil, quadPose)
end

-- ------- the window while a headset owns the picture

-- The flat window becomes the mirror: the left eye, fitted to the window.
-- Returns nil when there is nothing to mirror (the caller draws the flat
-- path as ever).
function VR.mirror(sw, sh)
  if not (VR.active() and mirrorSrc) then return nil end
  if not (mirrorCanvas and mirrorCanvas:getWidth() == sw
          and mirrorCanvas:getHeight() == sh) then
    local ok, c = pcall(love.graphics.newCanvas, sw, sh)
    if not ok then return nil end
    mirrorCanvas = c
  end
  local ok = pcall(function()
    love.graphics.setCanvas(mirrorCanvas)
    love.graphics.clear(0, 0, 0, 1)
    local mw, mh = mirrorSrc:getDimensions()
    local s = math.min(sw / mw, sh / mh)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(mirrorSrc, (sw - mw * s) / 2, (sh - mh * s) / 2, 0, s, s)
    love.graphics.setCanvas()
  end)
  pcall(love.graphics.setCanvas)
  return ok and mirrorCanvas or nil
end

-- window resize, hot reload: the eye canvases are Voxel3D's and go with
-- its invalidate; ours is the mirror and the FBO ids learned from dead
-- canvases
function VR.invalidate()
  if mirrorCanvas and mirrorCanvas.release then
    pcall(mirrorCanvas.release, mirrorCanvas)
  end
  mirrorCanvas, mirrorSrc = nil, nil
  for k in pairs(fboCache) do fboCache[k] = nil end
end

return VR

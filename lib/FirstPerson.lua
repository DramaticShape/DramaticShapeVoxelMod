-- Voxel world mode: the first-person camera -- the 1ST rung.
--
-- Every other rung is the same camera at a different pitch: an orbit over
-- the view centre, described by one number. 1ST is a different rig
-- entirely: the eye stands in the player's own head, the view direction is
-- the player's to steer -- mouse, right stick or a touch drag -- and the
-- rig rides the placed-camera seam (Voxel3D.camera) that the staged battle
-- already proved out. Everything downstream of that seam -- the shader
-- uniforms, project(), the sky's vanishing line, the water's lean -- reads
-- eye and focus the same way it always has.
--
-- What this module owns:
--
--   the ATTITUDE   yaw and pitch, fed by whichever look input speaks:
--                  relative mouse motion, the right stick's rate, or a
--                  touch dragged across open screen. All three drive the
--                  same two numbers, so they compose instead of fighting.
--
--   the BLEND      easing between the orbit and the head. Stepping onto
--                  the rung dives the camera from wherever the orbit was
--                  into the player's eyes over half a second; stepping off
--                  flies it back out. Mid-blend the rig is a straight lerp
--                  of the two cameras -- eye, focus, fov, up -- through
--                  the same placed-camera record.
--
--   the MOVE INTENT   the analog vector FreeMove walks the player by,
--                  gathered here because it is made of the same devices:
--                  the left stick's raw axes, the touch d-pad's true
--                  deflection, or the held keys, rotated by this camera's
--                  yaw so "forward" means "where I am looking".
--
-- Deliberately NOT here: movement itself (lib/FreeMove.lua, which owns the
-- collision walk and the grid the game logic still lives on), and the
-- billboard math that faces cards at this eye (VoxelScene, which owns
-- every other card matrix too).
--
-- Everything the module reaches -- the mouse's relative mode, the wrapped
-- love handlers, the touch overlay's hit test -- is pcall-guarded the same
-- way the 3D pass is: headless runs and drivers without a mouse simply
-- never see the input, and the rung falls back to holding the 75-degree
-- orbit.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")
local Voxel = V.require("VoxelState")
local Voxel3D = V.require("Voxel3D")
local WorldCurve = V.require("WorldCurve")
local ModSetting = V.require("ModSetting")

local FirstPerson = {}

-- ------- the rig's numbers
--
-- EYE_HEIGHT stands the eye near the top of the 16px sprite -- the head,
-- not the hat tip -- above the same ground-plus-lift the character card
-- stands on, so surfing bobs and ledge hops carry the view with them.
--
-- FOV is wider than the diorama's ~53 degrees: inside the world, the
-- diorama's lens reads as a keyhole. 65 vertical is the modern-shooter
-- middle ground.
--
-- FOCUS_DIST is short on purpose: the placed-camera branch derives its
-- near plane from |eye - focus| (dist * 0.05), and the eye walks within
-- 2-3 world pixels of a wall face when sliding along it -- a far focus
-- would push the near plane through the wall and clip a hole in it.
FirstPerson.EYE_HEIGHT = 13
FirstPerson.FOV = math.rad(65)
FirstPerson.FOCUS_DIST = 24

-- Pitch limits, in radians below horizontal (positive looks DOWN). The
-- world has no ceiling and the sky's bands sit low, so looking far up
-- shows the void above the gradient; the up-range is clamped tighter than
-- the down-range for that reason, not a technical one.
FirstPerson.PITCH_DOWN = math.rad(70)
FirstPerson.PITCH_UP = -math.rad(50)
FirstPerson.PITCH_DEFAULT = math.rad(10)

-- how long the dive into (and out of) the head takes, in seconds
FirstPerson.BLEND_TIME = 0.45

-- ------- look input tuning
--
-- MOUSE_SENS is radians per relative-mode count -- about 0.18 degrees per
-- count, the conventional shooter default. STICK rates are radians per
-- second at full deflection, with a squared response curve so small
-- deflections aim and full ones turn. TOUCH_TURN is what one full screen
-- width of drag turns, mobile-shooter convention.
FirstPerson.MOUSE_SENS = 0.0032
FirstPerson.STICK_YAW = 3.5
FirstPerson.STICK_PITCH = 2.4
FirstPerson.STICK_DEAD = 0.18
FirstPerson.TOUCH_TURN = 2.2 * math.pi
FirstPerson.MOVE_DEAD = 0.25

-- ------- the player's own look preferences
--
-- SPEED multiplies every look input rather than any one of them, so the
-- stick, the mouse and a drag all move together -- a player who finds the
-- view too twitchy means the view, not the device they happened to use.
--
-- INVERT Y is not a nicety: a substantial minority of people fly a camera
-- pull-back-to-look-up and cannot use one that does the opposite. It
-- negates pitch only, which is the axis that convention actually splits on.
--
-- STICK hides the on-screen stick for anyone playing with a controller, or
-- who prefers the drag-anywhere look and would rather have the glass back.
-- Hiding it also stops it claiming touches, or it would be an invisible
-- control swallowing thumbs.
FirstPerson.stickSetting = ModSetting.new("lookstick", "LOOK STICK",
                                          { true, false }, { "ON", "OFF" })
FirstPerson.speedSetting = ModSetting.new("lookspeed", "LOOK SPEED",
                                          { 0.6, 1.0, 1.6 },
                                          { "SLOW", "NORMAL", "FAST" }, 2)
FirstPerson.invertSetting = ModSetting.new("lookinvert", "INVERT Y",
                                           { false, true }, { "OFF", "ON" })

function FirstPerson.stickShown()
  local ok, v = pcall(function() return FirstPerson.stickSetting:get() end)
  if not ok or v == nil then return true end
  return v and true or false
end

-- ------- state
--
-- Yaw is a world bearing: 0 faces south (+Z, the way a resting sprite
-- faces), pi/2 east -- the same convention VoxelScene.YAW uses, so a
-- facing converts to a yaw by table lookup.
FirstPerson.yaw = 0
FirstPerson.pitch = FirstPerson.PITCH_DEFAULT
FirstPerson.blend = 0

-- A multiplier on the first-person field of view, for anything that wants
-- to narrow the lens without owning the rig: 1 is the ordinary 65
-- degrees, and horde mode's iron sights ease it down toward 40 while the
-- player is looking down them (lib/HordeGun). Kept here rather than in
-- the caller because the fov is folded into the orbit blend below, and
-- because signature() has to know -- a lens that narrows while the player
-- stands still still has to re-fit the shadow box.
FirstPerson.fovScale = 1

local wasEngaged = false
local stick = { x = 0, y = 0 }        -- right stick, latest event values
local stickTouch = nil                -- the finger holding the on-screen look stick
local mouseDX, mouseDY = 0, 0         -- relative counts since last update
local lookTouch = nil                 -- { id, x, y } of the claimed finger
local touchMove = nil                 -- the touch d-pad's analog deflection
local captured = false                -- mouse relative mode engaged by us

-- the placed-camera record this module last handed to Voxel3D, so passes
-- that key behaviour off "is the first-person rig the one drawing" (the
-- billboard yaw, the frame remap) can ask by identity rather than by mode
-- -- the battle's own placed camera must never read as first person
local rig = nil

local FACING_ANGLE = {
  down = 0,
  right = math.pi / 2,
  up = math.pi,
  left = -math.pi / 2,
}
local FACING_ORDER = { "down", "right", "up", "left" }

local function wrapPi(a)
  return (a + math.pi) % (2 * math.pi) - math.pi
end

local function ease(t)
  return t * t * (3 - 2 * t)
end

-- ------- gates

-- Whether the 1ST rung is selected and the 3D pass can carry it.
function FirstPerson.engaged()
  return Voxel.isFirstPerson(Voxel.level) and Voxel3D.available()
end

-- Whether first person should be READING the player's inputs right now:
-- engaged, with the overworld on top of the stack (a menu, a dialog or a
-- battle above it owns the buttons, exactly as it does for grid walking).
function FirstPerson.driving()
  if not FirstPerson.engaged() then return false end
  local ok, top, ow = pcall(function()
    local Game = require("src.core.Game")
    return Game.stack and Game.stack:top(), Game.overworld
  end)
  return ok and top ~= nil and top == ow
end

-- The eased blend, 0 at the orbit and 1 in the head.
function FirstPerson.blendEased()
  return ease(FirstPerson.blend)
end

-- The blend, but only while the free-roam pass's own rig is the placed
-- camera. The battle scene places a camera of its own through the same
-- seam, and its cards must keep their stage lean rather than yawing at a
-- first-person eye that is not looking at them.
function FirstPerson.cardBlend()
  if not rig or Voxel3D.camera ~= rig then return 0 end
  return ease(FirstPerson.blend)
end

-- A VR eye stepping into the rig's shoes: the VR pass builds its own
-- placed cameras (one per eye) and hands each one here as it draws, so
-- everything keyed to "the first-person rig is drawing" -- the billboard
-- yaw, the frame remap, the hidden player card -- answers for that eye.
-- In the diorama (blend 0) adoption is inert: cardBlend still reports
-- zero and the cards keep their lean.
function FirstPerson.adoptVReye(record)
  rig = record
end

-- Whether the player's own card should be left out of the camera draw:
-- deep enough into the blend that the card would fill the lens from
-- inside. The sun pass keeps drawing it either way -- a first-person
-- player still throws a shadow on the ground ahead.
function FirstPerson.hidePlayer()
  return FirstPerson.cardBlend() > 0.9
end

-- ------- attitude

-- Apply a look delta, in radians. Everything that turns the head funnels
-- through here, so the clamps live once.
function FirstPerson.lookBy(dyaw, dpitch)
  FirstPerson.yaw = wrapPi(FirstPerson.yaw + dyaw)
  FirstPerson.pitch = math.max(FirstPerson.PITCH_UP,
                       math.min(FirstPerson.PITCH_DOWN,
                                FirstPerson.pitch + dpitch))
end

-- Every look input goes through here rather than calling lookBy directly,
-- so the mouse, the stick and a drag cannot drift apart -- and a fourth
-- input added later inherits both preferences without knowing they exist.
--
-- Deliberately NOT inside lookBy: that is the primitive the rig and the
-- tests drive, and a turn of exactly 2*pi has to come out as exactly one
-- turn whatever the player has the sensitivity set to.
function FirstPerson.steer(dyaw, dpitch)
  local okS, mul = pcall(function() return FirstPerson.speedSetting:get() end)
  if okS and type(mul) == "number" then
    dyaw, dpitch = dyaw * mul, dpitch * mul
  end
  local okI, inv = pcall(function() return FirstPerson.invertSetting:get() end)
  if okI and inv then dpitch = -dpitch end
  return FirstPerson.lookBy(dyaw, dpitch)
end

-- The view direction's flat compass facing, for everything that still
-- thinks in the grid's four directions: the cell A interacts with, the
-- sprite the sun sees, the direction a blocked slide bonks in.
function FirstPerson.compassFacing()
  local s, c = math.sin(FirstPerson.yaw), math.cos(FirstPerson.yaw)
  if math.abs(s) > math.abs(c) then
    return s > 0 and "right" or "left"
  end
  return c > 0 and "down" or "up"
end

-- The unit look direction, and its flat (ground-plane) part.
local function lookDir()
  local cp = math.cos(FirstPerson.pitch)
  return math.sin(FirstPerson.yaw) * cp,
         -math.sin(FirstPerson.pitch),
         math.cos(FirstPerson.yaw) * cp
end

function FirstPerson.lookFlat()
  return math.sin(FirstPerson.yaw), math.cos(FirstPerson.yaw)
end

-- ------- billboards seen from inside the world
--
-- The diorama's cards face south and lean back by the camera's pitch --
-- correct for a camera that always stands south. An eye that can stand
-- ANYWHERE sees a south-facing card edge-on from the east, so in first
-- person every card yaws about its feet to face the eye (cylindrical
-- billboarding: upright, never tipping). VoxelScene blends its matrices
-- between the two by cardBlend.

-- The yaw that turns a card's south-facing normal toward the eye.
function FirstPerson.cardYaw(wx, wz)
  local eye = rig and rig.eye
  if not eye then return 0 end
  local dx, dz = eye[1] - wx, eye[3] - wz
  if dx * dx + dz * dz < 1e-9 then return 0 end
  return math.atan2(dx, dz)
end

-- Which of the four sprite frames an entity shows THIS eye: its facing
-- rotated into the viewer's own frame, quantised. The flat game's frames
-- are "how this pose looks from the south", so the apparent facing is the
-- pose rotated by where the viewer actually stands -- walk behind an NPC
-- and you see their back, circle to their flank and you see the profile,
-- exactly as the four frames Gen 1 drew intend.
function FirstPerson.apparentFacing(facing, wx, wz)
  local eye = rig and rig.eye
  local phi = FACING_ANGLE[facing]
  if not (eye and phi) then return facing end
  local dx, dz = eye[1] - wx, eye[3] - wz
  if dx * dx + dz * dz < 1e-9 then return facing end
  local rel = wrapPi(phi - math.atan2(dx, dz))
  local idx = math.floor((rel + math.pi / 4) / (math.pi / 2)) % 4
  return FACING_ORDER[idx + 1]
end

-- ------- the move intent
--
-- The analog vector FreeMove walks by, in CAMERA space: mx strafes (+
-- right), mz advances (+ forward). Whichever device is actually deflected
-- answers -- the left stick's raw axes first (the engine quantises them to
-- a d-pad; the raw pair is the analog truth), then a touch d-pad finger,
-- then the held keys. Magnitude caps at 1.
function FirstPerson.moveVector()
  local ok, Game = pcall(require, "src.core.Game")
  local input = ok and Game.input or nil

  local ax = input and input.stickAxis or nil
  if ax then
    local mag = math.sqrt(ax.x * ax.x + ax.y * ax.y)
    if mag > FirstPerson.MOVE_DEAD then
      local t = math.min(1, (mag - FirstPerson.MOVE_DEAD)
                            / (1 - FirstPerson.MOVE_DEAD))
      return ax.x / mag * t, -ax.y / mag * t
    end
  end

  if touchMove then
    local mag = math.sqrt(touchMove.x * touchMove.x
                          + touchMove.y * touchMove.y)
    if mag > FirstPerson.MOVE_DEAD then
      local t = math.min(1, mag)
      return touchMove.x / mag * t, -touchMove.y / mag * t
    end
  end

  if input then
    local mx = (input:isDown("right") and 1 or 0)
               - (input:isDown("left") and 1 or 0)
    local mz = (input:isDown("up") and 1 or 0)
               - (input:isDown("down") and 1 or 0)
    if mx ~= 0 or mz ~= 0 then
      local mag = math.sqrt(mx * mx + mz * mz)
      return mx / mag, mz / mag
    end
  end
  return 0, 0
end

-- Rotate a camera-space move into world space: forward is the flat look
-- direction, strafe-right is its right hand. (cross(forward, up) with
-- forward = (sin y, 0, cos y) and up = +Y lands right on (-cos y, 0,
-- sin y): face south and your right hand points west.)
function FirstPerson.moveWorld(mx, mz)
  local s, c = math.sin(FirstPerson.yaw), math.cos(FirstPerson.yaw)
  return -c * mx + s * mz, s * mx + c * mz
end

-- ------- the tick

-- Runs from the pipeline's update hook, every frame whatever the level --
-- the same tick VoxelState eases the orbit on. Owns the blend, the mouse
-- capture lifecycle, and the frame's stick-rate look.
function FirstPerson.update(dt)
  local engagedNow = FirstPerson.engaged()

  -- entering the rung: the head starts looking the way the sprite faces,
  -- pitched gently down -- the reading pose of the flat game
  if engagedNow and not wasEngaged then
    local ok, facing = pcall(function()
      local Game = require("src.core.Game")
      return Game.overworld and Game.overworld.player
             and Game.overworld.player.facing
    end)
    FirstPerson.yaw = (ok and FACING_ANGLE[facing]) or 0
    FirstPerson.pitch = FirstPerson.PITCH_DEFAULT
  end
  wasEngaged = engagedNow

  -- the blend, held at flat until there is terrain to dive into -- the
  -- same wait Voxel.update keeps for the orbit tween, for the same reason
  local target = engagedNow and 1 or 0
  if target > FirstPerson.blend and FirstPerson.blend == 0
     and not Voxel.ready then
    target = 0
  end
  local step = dt / FirstPerson.BLEND_TIME
  if FirstPerson.blend < target then
    FirstPerson.blend = math.min(target, FirstPerson.blend + step)
  elseif FirstPerson.blend > target then
    FirstPerson.blend = math.max(target, FirstPerson.blend - step)
  end
  if FirstPerson.blend <= 0 and rig then
    -- fully out: let go of the placed camera (unless a battle already
    -- swapped its own in, which is not ours to clear)
    if Voxel3D.camera == rig then Voxel3D.camera = nil end
    rig = nil
  end

  -- mouse capture follows engagement: captured whenever the rung is on and
  -- the window has focus, released the moment either ends. Checked against
  -- the live mode rather than toggled on edges, so a capture lost to the
  -- OS (alt-tab) re-arms itself on the next focused frame.
  local wantCapture = engagedNow
  if wantCapture and love.window and love.window.hasFocus then
    local okF, focus = pcall(love.window.hasFocus)
    wantCapture = okF and focus or false
  end
  if love.mouse and love.mouse.setRelativeMode then
    local okM, isRel = pcall(love.mouse.getRelativeMode)
    if okM and isRel ~= wantCapture then
      pcall(love.mouse.setRelativeMode, wantCapture)
    end
    captured = wantCapture
  end

  local driving = FirstPerson.driving()

  -- The mouse's counts, accumulated by the wrapped handler since the last
  -- tick; dropped unread while something else owns the screen.
  --
  -- The yaw sign is NEGATED, here and in every look input below: yaw grows
  -- south -> east -> north (the world runs +X east, +Z south, and the
  -- direction is (sin yaw, cos yaw)), which seen from behind the eye is a
  -- LEFT turn -- so "move the mouse right, look right" means subtracting.
  local dx, dy = mouseDX, mouseDY
  mouseDX, mouseDY = 0, 0
  if driving and (dx ~= 0 or dy ~= 0) then
    FirstPerson.steer(-dx * FirstPerson.MOUSE_SENS,
                      dy * FirstPerson.MOUSE_SENS)
  end

  -- the right stick is a rate: radians per second, squared response so
  -- the first half of the throw aims and the rest turns
  if driving then
    local rx, ry = stick.x, stick.y
    local function curve(v)
      local a = math.abs(v)
      if a < FirstPerson.STICK_DEAD then return 0 end
      a = (a - FirstPerson.STICK_DEAD) / (1 - FirstPerson.STICK_DEAD)
      return (v < 0 and -1 or 1) * a * a
    end
    local cy, cp = curve(rx), curve(ry)
    if cy ~= 0 or cp ~= 0 then
      -- negated yaw for the same reason as the mouse above
      FirstPerson.steer(-cy * FirstPerson.STICK_YAW * dt,
                        cp * FirstPerson.STICK_PITCH * dt)
    end
  end
end

-- ------- the rig itself

-- The orbit camera's eye/focus/fov/up for the frame's centre -- the same
-- arithmetic Voxel3D.viewProjection runs, restated here because the blend
-- needs both ends as DATA. Kept textually tiny so the two cannot drift:
-- focus on the centre, eye FOCAL*vh away at the pitch, up perpendicular
-- in the YZ plane.
local function orbitRig(cx, cy, vh)
  local a = Voxel.angle
  local dist = Voxel.FOCAL * vh
  return { cx, dist * math.cos(a), cy + dist * math.sin(a) },
         { cx, 0, cy },
         2 * math.atan(1 / (2 * Voxel.FOCAL)),
         { 0, math.sin(a), -math.cos(a) }
end

local lastEye = nil                   -- frozen head pose for player-less frames

-- Build this frame's placed camera and hand it to Voxel3D, plus the scene
-- centre the curve and the depth reference should use. `me` is the
-- player's posed entry (px, py, gh, lift) or nil (a Fly animation), and
-- (cx, cy) the orbit's own view centre.
--
-- Returns nil with the blend fully out, which is the caller's signal to
-- leave the orbit in charge.
function FirstPerson.frame(me, cx, cy, vw, vh)
  local b = FirstPerson.blend
  if b <= 0 then
    if rig and Voxel3D.camera == rig then Voxel3D.camera = nil end
    rig = nil
    return nil
  end
  local e = ease(b)

  local head
  if me then
    head = { me.px + 8,
             (me.gh or 0) + (me.lift or 0) + FirstPerson.EYE_HEIGHT,
             me.py + 8 }
    lastEye = head
  else
    head = lastEye or { cx, FirstPerson.EYE_HEIGHT, cy }
  end
  local lx, ly, lz = lookDir()
  local fpFocus = { head[1] + lx * FirstPerson.FOCUS_DIST,
                    head[2] + ly * FirstPerson.FOCUS_DIST,
                    head[3] + lz * FirstPerson.FOCUS_DIST }

  local oEye, oFocus, oFov, oUp = orbitRig(cx, cy, vh)
  local function mix(p, q)
    return { p[1] + (q[1] - p[1]) * e,
             p[2] + (q[2] - p[2]) * e,
             p[3] + (q[3] - p[3]) * e }
  end
  local up = mix(oUp, { 0, 1, 0 })
  local ul = math.sqrt(up[1] * up[1] + up[2] * up[2] + up[3] * up[3])
  if ul > 1e-6 then up[1], up[2], up[3] = up[1] / ul, up[2] / ul, up[3] / ul
  else up = { 0, 1, 0 } end

  -- the world curve eases out with the blend: standing inside the world,
  -- the bend that sells the diorama reads as the ground falling away. A
  -- true zero (curve declined) needs the field present -- nil would let
  -- Voxel3D fall back to the setting
  local k = WorldCurve.k(vh) * (1 - e)

  rig = {
    eye = mix(oEye, head),
    focus = mix(oFocus, fpFocus),
    fov = oFov + (FirstPerson.FOV * FirstPerson.fovScale - oFov) * e,
    up = up,
    curve = k,
  }
  Voxel3D.camera = rig

  -- the scene centre walks from the orbit's view centre to the head, so
  -- the curve's focus, the depth reference and the glint's travel follow
  -- the camera that is actually in charge
  local sx = cx + (head[1] - cx) * e
  local sy = cy + (head[3] - cy) * e
  return rig, sx, sy
end

-- Where the shadow pass should centre its box: pushed along the flat look
-- so the fitted frustum -- built for an orbit that always looks north --
-- covers the ground THIS camera sees. The push is strongest looking
-- south (the direction the orbit's box barely reaches) and scales with
-- the blend.
function FirstPerson.shadowCenter(sx, sy, vh)
  local e = FirstPerson.cardBlend()
  if e <= 0 then return sx, sy end
  local fx, fz = FirstPerson.lookFlat()
  local ShadowMap = V.require("ShadowMap")
  local cap = (ShadowMap.FAR_CAP or 2.5) * vh
  return sx + fx * 0.6 * vh * e,
         sy + fz * (fz > 0 and (cap - vh * 0.5) or vh * 0.4) * e
end

-- The first-person facts a shadow signature has to include: the sun's
-- box is fitted around this camera, so turning the head or walking the
-- blend has to re-fit it even standing still.
function FirstPerson.signature()
  local b = FirstPerson.blend
  if b <= 0 then return "" end
  return table.concat({
    math.floor(b * 64),
    math.floor(FirstPerson.yaw * 64),
    math.floor(FirstPerson.pitch * 64),
    math.floor(FirstPerson.fovScale * 64),
  }, ",")
end

-- ------- input capture
--
-- The seams: relative mouse motion has no Game handler at all (the
-- engine's love.mousemoved only feeds the mouse-as-touch debug path), the
-- right stick's axes are explicitly ignored by Input, and a touch
-- anywhere off the overlay's controls dies in TouchControls. Each wrap
-- forwards everything it does not claim, and claims only while first
-- person is actually driving -- so with the rung off, every byte flows
-- exactly where it always did.

-- ------- drawing the look stick
--
-- Called from the flat overlay pass, which draws into the world canvas in
-- SUPERSAMPLED canvas pixels -- hence the scale, the same one HordeHud is
-- handed. The engine's own pad is composited over the top of this canvas
-- afterwards, which is exactly why the stick sits ABOVE A/B rather than
-- under them: anything overlapping a button would be drawn beneath it.
--
-- Nothing here is load-bearing. A failure to work out where the pad is
-- (headless, no overlay) simply draws nothing, and drag-anywhere still
-- steers the view.
function FirstPerson.drawLookStick(rw, rh)
  if not FirstPerson.driving() then return end
  if not FirstPerson.stickShown() then return end
  local z = FirstPerson.lookStick and FirstPerson.lookStick()
  if not z then return end
  local TouchControls = require("src.core.TouchControls")
  if not TouchControls:visible() then return end
  -- The pad's layout is in LOVE UNITS; this canvas is in framebuffer pixels
  -- (times the AA factor). The ratio between the canvas we were handed and
  -- the window's unit width is the exact conversion -- and it stays exact
  -- whatever the density or the supersampling, which is why it is measured
  -- rather than assumed. Passing ctx.scale here (the world-pixel scale the
  -- FX closures use) put the stick hundreds of pixels off-screen.
  local ww = love.graphics.getWidth()
  if not (ww and ww > 0 and rw and rw > 0) then return end
  local s = rw / ww
  local cx, cy, r = z.cx * s, z.cy * s, z.r * s
  local held = stickTouch ~= nil
  love.graphics.push("all")
  -- the well: dark ring, faint fill, matching the pad's own restraint so it
  -- reads as part of the overlay rather than as HUD
  love.graphics.setColor(0, 0, 0, held and 0.30 or 0.20)
  love.graphics.circle("fill", cx, cy, r)
  love.graphics.setColor(1, 1, 1, held and 0.45 or 0.28)
  love.graphics.setLineWidth(math.max(1, 2 * s))
  love.graphics.circle("line", cx, cy, r)
  -- the knob, sitting where the thumb has pushed it
  local kx = cx + (stick.x or 0) * r * 0.62
  local ky = cy + (stick.y or 0) * r * 0.62
  love.graphics.setColor(1, 1, 1, held and 0.55 or 0.34)
  love.graphics.circle("fill", kx, ky, r * 0.38)
  love.graphics.pop()
end

local installed = false

function FirstPerson.install()
  if installed then return end
  installed = true

  local Game = require("src.core.Game")

  -- ------- right stick
  do
    local inner = Game.gamepadaxis
    function Game:gamepadaxis(joystick, axis, value)
      if axis == "rightx" then stick.x = value
      elseif axis == "righty" then stick.y = value end
      return inner(self, joystick, axis, value)
    end
  end
  -- generic (non-gamepad) sticks: axes 1/2 are the left stick by SDL
  -- convention and Input already claims them; 3/4 are the usual right
  -- pair on the same class of device. Real gamepads are excluded -- they
  -- already spoke through the mapped rightx/righty above, and their RAW
  -- axis 3 is as likely a trigger as a stick.
  --
  -- Two more exclusions, both learned the hard way on Android, where this
  -- wrap runs BEFORE the engine's own generic-joystick guards:
  --
  --   the accelerometer arrives as a joystick named for what it is, with
  --   gravity pinning an axis well past any deadzone -- the same device
  --   Game:joystickaxis refuses for movement (#459), refused here by the
  --   same name test, or the view spins on its own the moment 1ST opens.
  --
  --   and a raw axis is only BELIEVED after it has been seen near centre
  --   once. A stick at rest sits at zero, so a real one earns trust with
  --   its first touch; a gravity-pinned sensor axis or a trigger resting
  --   at an extreme never centres and so never steers the look.
  local function isAccelerometer(joystick)
    local ok, name = pcall(function() return joystick:getName() end)
    return ok and type(name) == "string"
           and name:lower():find("accelerometer", 1, true) ~= nil
  end
  local rawCentred = {}
  do
    local inner = Game.joystickaxis
    function Game:joystickaxis(joystick, axis, value)
      local mapped = joystick and joystick.isGamepad and joystick:isGamepad()
      if not mapped and (axis == 3 or axis == 4)
         and not isAccelerometer(joystick) then
        if math.abs(value) < 0.3 then rawCentred[axis] = true end
        if rawCentred[axis] then
          if axis == 3 then stick.x = value else stick.y = value end
        end
      end
      return inner(self, joystick, axis, value)
    end
  end

  -- ------- mouse
  --
  -- love.mousemoved rather than a Game method, because the engine has no
  -- Game:mousemoved to wrap -- the callback in the project's main.lua is
  -- the one place relative counts arrive. Claimed only while captured;
  -- pass-through otherwise, including the mouse-as-touch path.
  do
    local inner = love.mousemoved
    love.mousemoved = function(x, y, dx, dy, istouch)
      if captured and not istouch then
        mouseDX = mouseDX + (dx or 0)
        mouseDY = mouseDY + (dy or 0)
        return
      end
      if inner then return inner(x, y, dx, dy, istouch) end
    end
  end
  -- While the mouse is captured there is no cursor to click UI with, so
  -- the buttons become GB buttons: left is A, right is B -- through the
  -- overlay's own press path, which a rebind can never detach. What WE
  -- pressed is remembered per button, so the release always reaches the
  -- overlay even if the capture ended while the button was down --
  -- otherwise a click that outlives the rung strands A held forever.
  --
  -- HORDE MODE re-reads the same two buttons as a weapon: left fires,
  -- right holds the sights. Claimed BEFORE the A/B mapping below rather
  -- than on top of it, so a click during the mode never also lands as a
  -- GB button -- otherwise the A that ends the GAME OVER card would be
  -- spent by the shot that ended the run.
  local mouseHeld = {}
  local MOUSE_BTN = { [1] = "a", [2] = "b" }
  local function hordeMouse(button, down)
    local Horde = V.require("Horde")
    if not Horde.playing() then return false end
    if button == 1 then
      if down then V.require("HordeGun").fire() end
      return true
    elseif button == 2 then
      V.require("HordeGun").setAds(down)
      return true
    end
    return false
  end
  do
    local inner = love.mousepressed
    love.mousepressed = function(x, y, button, istouch, presses)
      if captured and not istouch and hordeMouse(button, true) then return end
      if captured and not istouch and MOUSE_BTN[button] then
        local Input = require("src.core.Input")
        mouseHeld[button] = true
        Input:overlayPressed(MOUSE_BTN[button])
        return
      end
      if inner then return inner(x, y, button, istouch, presses) end
    end
  end
  do
    local inner = love.mousereleased
    love.mousereleased = function(x, y, button, istouch, presses)
      -- a release always reaches whoever owns the press: the horde's
      -- aim-hold has to let go even if the mode ended mid-click
      if not mouseHeld[button] and hordeMouse(button, false) then return end
      if mouseHeld[button] then
        local Input = require("src.core.Input")
        mouseHeld[button] = nil
        Input:overlayReleased(MOUSE_BTN[button])
        return
      end
      if inner then return inner(x, y, button, istouch, presses) end
    end
  end

  -- ------- touch
  --
  -- A finger on open screen -- not on the overlay's d-pad or buttons --
  -- becomes the look drag. One finger owns the look at a time; every
  -- other touch flows to TouchControls untouched, so a thumb can drag the
  -- view while the other walks the d-pad. That d-pad finger is also read
  -- back ANALOG here: TouchControls quantises it to four directions for
  -- the grid game, but the deflection it quantised is exactly the move
  -- vector a free walk wants.
  local TouchControls = require("src.core.TouchControls")

  local function dpadVector(x, y)
    local ok, v = pcall(function()
      local L = TouchControls:layout()
      local dz = L.dpad
      local half = dz.w * 0.65
      return { x = math.max(-1, math.min(1, (x - dz.cx) / half)),
               y = math.max(-1, math.min(1, (y - dz.cy) / half)) }
    end)
    return ok and v or nil
  end

  -- ------- the on-screen look stick
  --
  -- A thumbstick above A/B, drawn only while 1ST PERSON is driving. It
  -- writes into the SAME `stick` table the physical right stick writes to,
  -- so it inherits the rate-based response already implemented for a
  -- gamepad: a held deflection keeps turning, and the squared curve means
  -- small pushes aim while full ones spin. A drag would only turn by how far
  -- the finger travelled, which runs out at the edge of the glass.
  --
  -- Drag-anywhere is deliberately left in place underneath. The stick is an
  -- affordance for the thumb that is already over there, not a replacement
  -- for a flick with whatever finger is free.
  local function lookStick()
    local ok, z = pcall(function()
      local L = TouchControls:layout()
      local a, b = L.a, L.b
      if not (a and b) then return nil end
      -- centred on the A/B cluster horizontally, sitting above the higher
      -- of the two so it never overlaps a button the engine draws on top
      local r = a.w * 1.15
      return { cx = (a.cx + b.cx) / 2,
               cy = math.min(a.cy, b.cy) - a.w * 0.75 - r,
               r = r }
    end)
    return ok and z or nil
  end
  FirstPerson.lookStick = lookStick

  -- deflection of a point within the stick, clamped to the rim, or nil
  local function stickDeflect(z, x, y)
    local dx, dy = (x - z.cx) / z.r, (y - z.cy) / z.r
    local m = math.sqrt(dx * dx + dy * dy)
    if m > 1 then dx, dy = dx / m, dy / m end
    return dx, dy
  end

  do
    local inner = Game.touchpressed
    function Game:touchpressed(id, x, y)
      if FirstPerson.driving() then
        local z = FirstPerson.stickShown() and lookStick() or nil
        if z and not stickTouch then
          local dx, dy = (x - z.cx) / z.r, (y - z.cy) / z.r
          if dx * dx + dy * dy <= 1 then
            stickTouch = { id = id, z = z }
            stick.x, stick.y = stickDeflect(z, x, y)
            return
          end
        end
        local onControl = nil
        pcall(function() onControl = TouchControls:hitTest(x, y) end)
        if not onControl and not lookTouch then
          -- HORDE MODE: a tap on open screen is a SHOT, fired on the press
          -- rather than on a release that turned out not to be a drag --
          -- a shooter that waits to find out whether you meant it is a
          -- shooter that misses. The same finger still becomes the look
          -- drag below, so aiming and firing are one gesture.
          if V.require("Horde").playing() then
            V.require("HordeGun").fire()
          end
          lookTouch = { id = id, x = x, y = y }
          return
        end
        inner(self, id, x, y)
        if onControl == "dpad" and TouchControls.dpadTouch == id then
          touchMove = dpadVector(x, y)
        end
        return
      end
      return inner(self, id, x, y)
    end
  end
  do
    local inner = Game.touchmoved
    function Game:touchmoved(id, x, y)
      if stickTouch and stickTouch.id == id then
        stick.x, stick.y = stickDeflect(stickTouch.z, x, y)
        return
      end
      if lookTouch and lookTouch.id == id then
        local w = 1280
        pcall(function() w = love.graphics.getWidth() end)
        local per = FirstPerson.TOUCH_TURN / math.max(320, w)
        if FirstPerson.driving() then
          -- negated yaw for the same reason as the mouse (see update):
          -- drag right, look right, the mobile-shooter convention
          FirstPerson.steer(-(x - lookTouch.x) * per,
                            (y - lookTouch.y) * per)
        end
        lookTouch.x, lookTouch.y = x, y
        return
      end
      if touchMove and TouchControls.dpadTouch == id then
        touchMove = dpadVector(x, y) or touchMove
      end
      return inner(self, id, x, y)
    end
  end
  do
    local inner = Game.touchreleased
    function Game:touchreleased(id, x, y)
      if stickTouch and stickTouch.id == id then
        stickTouch = nil
        stick.x, stick.y = 0, 0
        return
      end
      if lookTouch and lookTouch.id == id then
        lookTouch = nil
        return
      end
      if TouchControls.dpadTouch == id then touchMove = nil end
      return inner(self, id, x, y)
    end
  end

  -- a reset that drops held input state drops ours with it
  do
    local inner = Game.focus
    function Game:focus(f)
      lookTouch, touchMove = nil, nil
      stick.x, stick.y = 0, 0
      mouseDX, mouseDY = 0, 0
      return inner(self, f)
    end
  end
  -- a disconnected controller cannot send the centering event for whatever
  -- its stick last held -- the engine drops all input state here, and the
  -- look rate (plus the raw axes' earned trust) goes with it
  do
    local inner = Game.joystickremoved
    function Game:joystickremoved(joystick)
      stick.x, stick.y = 0, 0
      rawCentred[3], rawCentred[4] = nil, nil
      return inner(self, joystick)
    end
  end
end

return FirstPerson

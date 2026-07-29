-- A camera move between the walking diorama and the staged battle rig.
--
-- This module is intentionally pure.  Battle orchestration decides when the
-- move begins and ends; this only supplies a smooth camera for a normalized
-- time, which keeps the visual motion independently testable.

local BattleSweep = {}

BattleSweep.DURATION = 0.7

local function clamp01(t)
  return math.max(0, math.min(1, tonumber(t) or 0))
end

function BattleSweep.ease(t)
  t = clamp01(t)
  -- Smootherstep has zero velocity and acceleration at both ends, so neither
  -- the overworld camera nor the battle camera gets a visible kick.
  return t * t * t * (t * (t * 6 - 15) + 10)
end

local function lerp(a, b, t)
  return (tonumber(a) or 0) + ((tonumber(b) or 0) - (tonumber(a) or 0)) * t
end

local function vector(a, b, t)
  return {
    lerp(a and a[1], b and b[1], t),
    lerp(a and a[2], b and b[2], t),
    lerp(a and a[3], b and b[3], t),
  }
end

function BattleSweep.camera(from, to, t)
  if not from then return to end
  if not to then return from end
  local e = BattleSweep.ease(t)
  local eye = vector(from.eye, to.eye, e)
  local focus = vector(from.focus, to.focus, e)

  -- A straight lerp feels like a zoom.  A restrained sideways arc makes it
  -- read as the camera sweeping around the scene while a small lift keeps
  -- terrain from filling the lens halfway through. Both return exactly to
  -- zero at the endpoints.
  local dx = (to.eye[1] or 0) - (from.eye[1] or 0)
  local dy = (to.eye[2] or 0) - (from.eye[2] or 0)
  local dz = (to.eye[3] or 0) - (from.eye[3] or 0)
  local horiz = math.sqrt(dx * dx + dz * dz)
  local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
  local arc = math.sin(math.pi * e)
  if horiz > 1e-4 then
    local side = math.min(24, horiz * 0.12) * arc
    eye[1] = eye[1] - dz / horiz * side
    eye[3] = eye[3] + dx / horiz * side
  end
  eye[2] = eye[2] + math.min(48, distance * 0.1) * arc

  -- Interpolate the visible half-height rather than the angle itself. It
  -- prevents the narrow battle lens from rushing in at the end.
  local fromTan = math.tan((from.fov or math.rad(45)) / 2)
  local toTan = math.tan((to.fov or math.rad(45)) / 2)
  local fov = 2 * math.atan(lerp(fromTan, toTan, e))

  return {
    eye = eye,
    focus = focus,
    fov = fov,
    curve = lerp(from.curve, to.curve, e),
  }
end

return BattleSweep

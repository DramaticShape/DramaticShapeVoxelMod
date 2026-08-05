-- Voxel world mode: the day/night cycle -- one clock, and everything the
-- frame asks it.
--
-- THE CLOCK is twenty minutes around: ten of day, ten of night. The DAYTIME
-- row either PINS it -- DAY, NIGHT, DUSK and DAWN are fixed times on that
-- dial, not separate looks -- or lets it run (CYCLE), in which case the pin
-- the player left is where the cycle picks up. Everything below is a pure
-- function of the clock, so the pinned settings and the running cycle can
-- never drift apart: DUSK is simply the cycle stopped at sunset.
--
-- THE SUN follows a simplified northern-hemisphere trajectory. It rises
-- in the east, crosses the southern sky and sets in the west. Its elevation
-- creates long shadows during dawn, short shadows around noon and long
-- shadows in the opposite direction during dusk.
--
-- THE MOON follows a weaker east-to-west trajectory during the night. Its
-- lower elevation and reduced alpha keep moon shadows visible without making
-- the night look as strongly illuminated as daytime.
--
-- SHADOWS use the direction opposite to the active body. Their length is
-- calculated from the cotangent of its elevation and safely clamped near
-- the horizon. Their opacity fades smoothly while the sun or moon rises and
-- sets, preventing a sudden switch between solar and lunar shadows.
--
-- OUTDOOR ONLY. Indoors keeps the noon rig, the untinted world and no sky:
-- a cave at midnight is exactly as dark as a cave at noon, which is what a
-- room with no windows looks like. Map.isOutdoor is the same test the sky
-- already rests on; the caller passes its answer in (applyRig/tint).
--
-- Persistence: the running cycle's clock is written into the mod's own
-- save-file bucket (save.modData.DRAMATIC_SHAPE, via mod.save) on the
-- engine's save.writing event, and read back on save.loaded/created. A save
-- with no clock in it starts at noon.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ModSetting")
local PaletteFX = require("src.render.PaletteFX")

local DayNight = {}

-- ------- the dial

DayNight.CYCLE = 1200         -- seconds around the whole dial
DayNight.DAY_LEN = 600        -- the sun's half; the moon has the rest
DayNight.BLEND = 75           -- seconds of palette blend either side of a twilight

-- where the pinned settings stop the clock
DayNight.T = { dawn = 0, day = 300, dusk = 600, night = 900 }

DayNight.KEY = "daytime"
DayNight.LABEL = "DAYTIME"

-- "sync" first: an unset or unreadable value follows the machine's own
-- clock, per the row's contract (ModSetting values[1] is the default) --
-- and forceSync below reaches for it by the same position.
DayNight.setting = ModSetting.new(DayNight.KEY, DayNight.LABEL,
                                  { "sync", "day", "night", "dusk",
                                    "dawn", "cycle" },
                                  { "SYNC", "DAY", "NIGHT", "DUSK",
                                    "DAWN", "CYCLE" })

-- The one writer for the FULL pin. While VOXEL sits on FULL the DAYTIME
-- row is off the menu with the rest of the rows the preset owns, and the
-- value is held HERE at SYNC -- the diorama preset's sky follows the clock
-- on the wall, whatever was chosen before. Called from every path that can
-- arrive at or act under FULL (main.lua: the preset itself, the rows hook,
-- the manager's options_changed), mirroring OverworldBattle.forceOG.
function DayNight.forceSync(game)
  if DayNight.setting:get() ~= "sync" then
    DayNight.setting:setIndex(1, game)
  end
end

DayNight.clock = DayNight.T.day     -- the running cycle's own position

-- ------- the two arcs
--
-- Bearings in DEGREES from east toward south (the world's +X is east, +Z
-- south), elevations in degrees up from the ground plane.

-- noon IS the existing sun: shear (-0.85, -0.55) hangs it at
-- atan2(0.55, 0.85) south of east, atan(1/hypot) = 44.65 degrees up

local TH_RISE, TH_NOON, TH_SET = 0, 90, 180
local EL_NOON = 62

-- A lua segue uma trajetoria semelhante, mas um pouco mais baixa.
-- Isso mantem a iluminacao noturna suave e produz sombras lunares
-- discretamente mais longas.
local TH_MRISE, TH_MMID, TH_MSET = 0, 90, 180
local EL_MOON = 48

-- Ao se aproximar do horizonte, cotangente tende ao infinito.
-- O limite preserva sombras longas sem estourar o frustum do shadow map.
DayNight.K_MAX = 1.55
DayNight.ALPHA_SUN = 0.40
DayNight.ALPHA_MOON = 0.18
DayNight.FADE_DEG = 16

-- disc PLACEMENT only: the true elevation would put the noon sun far above
-- any frame, so the arc the discs ride is squashed toward the horizon. The
-- shadows always use the true elevation.
DayNight.ELEV_SQUASH = 0.14

-- three-point arc: a at s=0, b at s=0.5, c at s=1
local function smoothstep(value)
  value = math.max(0, math.min(1, value))
  return value * value * (3 - 2 * value)
end

-- Interpolacao suave em duas metades. A velocidade angular diminui
-- naturalmente perto do meio-dia e nao sofre uma quebra visivel.
local function arc(a, b, c, s)
  if s < 0.5 then
    local u = smoothstep(s * 2)
    return a + (b - a) * u
  end

  local u = smoothstep((s - 0.5) * 2)
  return b + (c - b) * u
end

-- The body lighting the world at clock `t`: bearing and elevation in
-- degrees, and whether it is the moon. The t == DAY_LEN boundary belongs to
-- the SUN, so the pinned DUSK setting is the sun half-set in the northwest,
-- not the moon rising.
function DayNight.bodyAt(t)
  t = t % DayNight.CYCLE

  if t <= DayNight.DAY_LEN then
    local progress = t / DayNight.DAY_LEN

    -- Leste ao nascer, sul ao meio-dia e oeste ao entardecer.
    local bearing = arc(
      TH_RISE,
      TH_NOON,
      TH_SET,
      progress
    )

    -- O seno cria uma elevacao fisicamente intuitiva:
    -- zero no horizonte e maxima no meio do periodo.
    local elevation = EL_NOON * math.sin(math.pi * progress)

    return bearing, elevation, false
  end

  local nightLength = DayNight.CYCLE - DayNight.DAY_LEN
  local progress = (t - DayNight.DAY_LEN) / nightLength

  local bearing = arc(
    TH_MRISE,
    TH_MMID,
    TH_MSET,
    progress
  )

  local elevation = EL_MOON * math.sin(math.pi * progress)

  return bearing, elevation, true
end


-- The shadow shear that body throws: drift per pixel of height, opposite
-- the bearing, cot(elevation) long, clamped.
function DayNight.shearAt(t)
  local bearing, elevation, moon = DayNight.bodyAt(t)

  -- A cotangente descreve o comprimento geometrico da sombra.
  -- Perto do horizonte esse valor cresce demais para a escala
  -- compacta do diorama.
  local safeElevation = math.max(elevation, 0.25)
  local physicalLength = 1 / math.tan(math.rad(safeElevation))

  -- Compressao exponencial suave. Sombras pequenas preservam sua
  -- variacao, enquanto valores extremos se aproximam de K_MAX sem
  -- encontrar um corte abrupto.
  local normalized = 1 - math.exp(
    -physicalLength / DayNight.K_MAX
  )

  local length = DayNight.K_MAX * normalized

  -- Nos primeiros graus acima do horizonte, a sombra recebe uma
  -- reducao adicional. Isso representa visualmente a difusao
  -- atmosferica do amanhecer e impede projecoes exageradas.
  local horizonProgress = math.max(
    0,
    math.min(1, elevation / 12)
  )

  local horizonFactor = 0.72 + 0.28 * horizonProgress
  length = length * horizonFactor

  local angle = math.rad(bearing)

  -- A sombra aponta para o lado oposto ao corpo luminoso.
  local kx = -math.cos(angle) * length
  local kz = -math.sin(angle) * length

  -- Remove residuos numericos nas direcoes cardeais.
  if math.abs(kx) < 1e-10 then kx = 0 end
  if math.abs(kz) < 1e-10 then kz = 0 end

  return kx, kz, moon
end

function DayNight.strengthAt(t)
  local _, elevation = DayNight.bodyAt(t)

  -- No horizonte, a sombra pode ser longa, mas deve ser muito
  -- difusa. O contraste aumenta conforme o corpo luminoso sobe.
  local strength = elevation / DayNight.FADE_DEG
  strength = math.max(0, math.min(1, strength))

  -- Smootherstep possui transicao suave nos dois extremos.
  -- Isso impede pulsos ao nascer do sol e ao atingir a
  -- intensidade completa.
  return strength * strength * strength
         * (strength * (strength * 6 - 15) + 10)
end

function DayNight.mix(t)
  t = t % DayNight.CYCLE
  local d = dial()
  for i = 1, #d - 1 do
    local a, b = d[i], d[i + 1]
    if t >= a[1] and t < b[1] then
      if a[2] == b[2] then return { [a[2]] = 1 } end
      local u = (t - a[1]) / (b[1] - a[1])
      return { [a[2]] = 1 - u, [b[2]] = u }
    end
  end
  return { dawn = 1 }
end

-- back onto the 5-bit lattice after any blend
local function q8(v)
  v = math.floor(v / 8 + 0.5) * 8
  if v < 0 then return 0 end
  return v > 248 and 248 or v
end

local function blend3(key, mix, fallback)
  local r, g, b = 0, 0, 0
  for name, w in pairs(mix) do
    local c = key[name] or fallback
    r = r + c[1] * w
    g = g + c[2] * w
    b = b + c[3] * w
  end
  return { q8(r), q8(g), q8(b) }
end

-- The sky palette for clock `t`, blended between the phase palettes and
-- re-quantised to the lattice. Memoised per whole second: the answer only
-- moves as the cycle runs, and the cycle moves it slowly.
local palCache = { key = nil, pal = nil }

function DayNight.palette(t)
  t = t or DayNight.time()
  local key = math.floor(t % DayNight.CYCLE)
  if palCache.key == key then return palCache.pal end
  local mix = DayNight.mix(t)
  local pal = {}
  for i = 1, #DayNight.PALETTES.day do
    local r, g, b = 0, 0, 0
    for name, w in pairs(mix) do
      local c = DayNight.PALETTES[name][i]
      r = r + c[1] * w
      g = g + c[2] * w
      b = b + c[3] * w
    end
    pal[i] = { q8(r), q8(g), q8(b) }
  end
  palCache.key, palCache.pal = key, pal
  return pal
end

-- The world tint for clock `t`, {r, g, b} in 0..1. Neutral indoors -- the
-- caller answers for where it is standing (see the header).
local tintCache = { key = nil, tint = nil }
local NEUTRAL = { 1, 1, 1 }

function DayNight.tint(outdoor, t)
  if not outdoor then return NEUTRAL end
  t = t or DayNight.time()
  local key = math.floor(t % DayNight.CYCLE)
  if tintCache.key ~= key then
    -- NOT re-quantised: this is a light level the shader multiplies by, not
    -- a palette colour, and the lattice's 248 ceiling would make even noon
    -- fractionally dim
    local mix = DayNight.mix(t)
    local r, g, b = 0, 0, 0
    for name, w in pairs(mix) do
      local c = DayNight.TINTS[name] or DayNight.TINTS.day
      r = r + c[1] * w
      g = g + c[2] * w
      b = b + c[3] * w
    end
    tintCache.key = key
    tintCache.tint = { r / 255, g / 255, b / 255 }
  end
  return tintCache.tint
end

-- The twilight glow: how strongly (0..1) and in what colour the sky warms
-- around the low sun. Only the SUN glows -- a moonrise is silver, not gold.
function DayNight.glow(t)
  t = t or DayNight.time()
  local _, _, moon = DayNight.bodyAt(t)
  if moon then return 0, nil end
  local mix = DayNight.mix(t)
  local amt = (mix.dawn or 0) + (mix.dusk or 0)
  if amt <= 0 then return 0, nil end
  return amt, blend3(DayNight.GLOWS, mix, DayNight.GLOWS.dusk)
end

-- ------- the clock itself

local lastMode = nil

local function mode()
  return DayNight.setting:get() or "day"
end

-- Where SYNC reads the real clock: local hours, 0..24 with the minutes as
-- fraction. A named seam rather than a bare os.date call, so the suite can
-- hand it a fixed hour.
function DayNight.hours()
  local d = os.date("*t")
  return d.hour + d.min / 60 + d.sec / 3600
end

-- SYNC: the machine's own time of day laid onto the dial. Local noon is
-- the DAY pin, midnight the NIGHT pin, six and eighteen the twilights --
-- an hour of the real day is fifty seconds of dial, and Kanto's evening
-- falls when the player's does.
function DayNight.syncTime()
  return ((DayNight.hours() - 6) * (DayNight.CYCLE / 24)) % DayNight.CYCLE
end

-- The effective time: the pin, the running clock under CYCLE, or the wall
-- clock under SYNC.
function DayNight.time()
  local m = mode()
  if m == "cycle" then return DayNight.clock end
  if m == "sync" then return DayNight.syncTime() end
  return DayNight.T[m] or DayNight.T.day
end

-- Advance the cycle. Runs every frame from the voxel pipeline's update hook
-- (which ticks through battles and menus too, so night falls during a long
-- fight exactly as it does on a walk). Stepping ONTO cycle picks up from
-- the pin the player was just looking at: DUSK then CYCLE rolls on into
-- night rather than teleporting the sky.
function DayNight.update(dt)
  local m = mode()
  if m ~= lastMode then
    if m == "cycle" then
      -- from a pin, its time; from SYNC, wherever the real sky already was
      DayNight.clock = DayNight.T[lastMode]
                       or (lastMode == "sync" and DayNight.syncTime())
                       or DayNight.clock
    end
    lastMode = m
  end
  if m == "cycle" and dt and dt > 0 then
    DayNight.clock = (DayNight.clock + dt) % DayNight.CYCLE
  end
end

-- The clock the RIG runs on: quantised, so the shadow map redraws a few
-- times a minute as the sun crawls rather than every frame.
DayNight.STEP = 0.5

function DayNight.rigTime()
  local t = DayNight.time()
  return math.floor(t / DayNight.STEP) * DayNight.STEP
end

-- ------- what the frame reads

-- Point the shared light rig at the clock -- or at noon, indoors. This
-- writes the same fields everything already reads (ShadowMap.KX/KZ for the
-- sun pass and its frustum, Voxel3D.SHADOW_* for the decal fallback and the
-- sunDark uniform), so no draw path changes to follow the sun; they follow
-- the rig, and the rig follows the clock.
function DayNight.applyRig(outdoor)
  local ShadowMap = V.require("ShadowMap")
  local Voxel3D = V.require("Voxel3D")
  local t = outdoor and DayNight.rigTime() or DayNight.T.day
  local kx, kz, moon = DayNight.shearAt(t)
  ShadowMap.KX, ShadowMap.KZ = kx, kz
  Voxel3D.SHADOW_KX, Voxel3D.SHADOW_KZ = kx, kz
  local base = moon and DayNight.ALPHA_MOON or DayNight.ALPHA_SUN
  Voxel3D.SHADOW_ALPHA = base * DayNight.strengthAt(t)
  return t
end

-- How much of a pass's OWN shadow weight the hour leaves it, 0..1 -- for a
-- caller that sets its own alpha (the battle arena) and should still lose
-- its shadows to a sunset.
function DayNight.shadowScale(outdoor, t)
  if not outdoor then return 1 end
  t = t or DayNight.rigTime()
  local _, _, moon = DayNight.bodyAt(t)
  local s = DayNight.strengthAt(t)
  return moon and s * (DayNight.ALPHA_MOON / DayNight.ALPHA_SUN) or s
end

-- The disc to hang in the sky, or nil when the body is set or behind the
-- camera's half of the sky. Returns a direction for the PLACEMENT arc --
-- true bearing, squashed elevation (see ELEV_SQUASH) -- plus which body it
-- is; the caller projects it through its own camera.
function DayNight.body(t)
  t = t or DayNight.time()
  local th, el, moon = DayNight.bodyAt(t)
  if el < -2 then return nil end
  local e = math.rad(el * DayNight.ELEV_SQUASH)
  local b = math.rad(th)
  return {
    dx = math.cos(b) * math.cos(e),
    dy = math.sin(e),
    dz = math.sin(b) * math.cos(e),
    moon = moon,
  }
end

-- Maps under a CANOPY: not outdoor -- there is no sky to paint and no sun
-- or moon to see, so the shadow rig stays the mod's fixed noon light,
-- which is all that ever filtered through the leaves -- but not a sealed
-- room either: night still FALLS in them. Of everything the clock does,
-- exactly one thing reaches a canopy map: the hour's tint.
DayNight.CANOPY = { VIRIDIAN_FOREST = true }

function DayNight.isCanopy(map)
  return (map and map.id and DayNight.CANOPY[map.id]) and true or false
end

-- How lit the WINDOWS are, 0..1 -- the lamps behind the glass, not the sky.
-- They come on through dusk (a lit window against a sunset is half the point
-- of having either), burn all night, and are mostly out again by dawn:
-- people wake before it is bright, they do not read at sunrise.
local LAMPS = { night = 1, violet = 1, dusk = 0.7, dawn = 0.25 }

function DayNight.windowLight(t)
  local mix = DayNight.mix(t or DayNight.time())
  local lit = 0
  for name, w in pairs(mix) do
    lit = lit + (LAMPS[name] or 0) * w
  end
  return lit
end

-- The period name for the engine's world.tod hook (map.palette ctx.tod,
-- music.select): the dominant phase, in the vocabulary day/night mods use.
local TOD = { day = "DAY", golden = "DAY", night = "NIGHT",
              violet = "NIGHT", dawn = "MORNING", dusk = "EVENING" }

function DayNight.tod(t)
  local mix = DayNight.mix(t or DayNight.time())
  local best, bestW = "day", -1
  for name, w in pairs(mix) do
    if w > bestW then best, bestW = name, w end
  end
  return TOD[best] or "DAY"
end

-- ------- persistence
--
-- The clock rides the SAVE SLOT, not the options file: what time it is in
-- Kanto is a fact about that journey, like where the player is standing.
-- mod.save is the loader's per-mod bucket in save.modData, which persists
-- with the slot on its own -- writing the value is all there is to do.

DayNight.SAVE_KEY = "clock"

function DayNight.store()
  local saveApi = V.mod and V.mod.save
  if not (saveApi and saveApi.set) then return end
  pcall(saveApi.set, saveApi, DayNight.SAVE_KEY, DayNight.clock)
end

function DayNight.restore()
  local saveApi = V.mod and V.mod.save
  local stored = nil
  if saveApi and saveApi.get then
    local ok, got = pcall(saveApi.get, saveApi, DayNight.SAVE_KEY)
    if ok then stored = got end
  end
  -- no time set: it is day (the requirement, verbatim)
  DayNight.clock = type(stored) == "number"
                   and stored % DayNight.CYCLE or DayNight.T.day
end

return DayNight

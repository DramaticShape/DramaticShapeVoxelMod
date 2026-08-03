-- HORDE MODE: the readout.
--
-- Health, ammunition, score, wave, the crosshair, the hit marker, the red
-- that closes in when something reaches you, and the banners -- "A
-- DARKNESS APPROACHES", then "WAVE 1" and every wave after it.
--
-- IT IS DRAWN TWICE, INTO TWO DIFFERENT PLACES, and that is not
-- duplication for its own sake. The flat screen's HUD goes into the SCENE
-- canvas through Voxel3D.beginOverlay -- the same seam the overworld's FX
-- bubbles use -- because that canvas is what the window composites. A
-- headset never sees that canvas: with VR live the window's world pass
-- short-circuits to the mirror, and the eyes are rendered on their own in
-- lib/VR. So the eye canvases get their own pass, at the same instant the
-- VR frame paints its fade over them, in the same 2D idiom.
--
-- Both call the same draw with a different scale and a different safe
-- area: a headset wants everything well inside the lens rather than
-- pinned to the corners, because the corners of a VR frame are off the
-- edge of the visible world.
--
-- EVERY WORD IS ON A WHITE PLATE, and that is not a style choice -- it is
-- what the font is. The Game Boy font sheets are BLACK glyphs on
-- transparent, so setColor cannot make a letter pale: multiplying black
-- by white is still black. That is why every box in the game is drawn
-- white first and its text black on top (Font.drawBox, then
-- setColor(0,0,0)), and it is why a first cut of this HUD -- pale text,
-- straight onto the night -- composited as black letters on a black
-- street and could not be read at all. Plates also happen to be the right
-- answer aesthetically: the game already talks to the player in white
-- boxes, and a horde mode that shouts in the same voice belongs to it.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Horde = V.require("Horde")

local HordeHud = {}

local Font = nil
local function font()
  if Font then return Font end
  local ok, F = pcall(require, "src.render.Font")
  if ok then Font = F end
  return Font
end

-- the pulse under the low-health plate and the banner's own breathing
local blink = 0

function HordeHud.update(dt)
  blink = (blink + (dt or 0)) % 1.0
end

-- ------- pieces
--
-- Every helper takes a scale `s` and draws in GB pixels multiplied by it,
-- so one layout serves a 4x window and a headset's eye buffer alike.

local PAD = 3           -- plate padding, in GB pixels

-- A white plate with a dark edge: the surface a black glyph can be read
-- on. Returns the interior origin, so a caller lays text out from there.
local function plate(x, y, w, h, s, alpha)
  love.graphics.setColor(0.06, 0.05, 0.09, (alpha or 1) * 0.92)
  love.graphics.rectangle("fill", x - s, y - s, w + 2 * s, h + 2 * s)
  love.graphics.setColor(0.93, 0.94, 0.90, alpha or 1)
  love.graphics.rectangle("fill", x, y, w, h)
  return x + PAD * s, y + PAD * s
end

local function textWidth(str, s)
  local F = font()
  if not F then return 0 end
  return F.width(str) * s
end

-- Black glyphs at `s` times their size. Black because that is the only
-- colour the font has (see the header).
local function text(str, x, y, s)
  local F = font()
  if not F then return 0 end
  love.graphics.setColor(0, 0, 0, 1)
  love.graphics.push()
  love.graphics.translate(math.floor(x), math.floor(y))
  love.graphics.scale(s, s)
  F.draw(str, 0, 0)
  love.graphics.pop()
end

-- One line of text on its own plate, anchored left or right.
local function label(str, x, y, s, align)
  local tw = textWidth(str, s)
  local pw, ph = tw + PAD * 2 * s, 8 * s + PAD * 2 * s
  local px = (align == "right") and (x - pw) or x
  local ix, iy = plate(px, y, pw, ph, s)
  text(str, ix, iy, s)
  return pw, ph
end

-- The health bar: a plate with a red bar inside it, so the red reads
-- against white rather than against a night street.
local function healthBar(x, y, w, h, s, fill, flash)
  local ix, iy = plate(x, y, w, h, s)
  local iw, ih = w - PAD * 2 * s, h - PAD * 2 * s
  love.graphics.setColor(0.80, 0.80, 0.78, 1)
  love.graphics.rectangle("fill", ix, iy, iw, ih)
  local r, g, b = 0.78, 0.12, 0.16
  if flash then r, g, b = 1, 0.45, 0.35 end
  love.graphics.setColor(r, g, b, 1)
  love.graphics.rectangle("fill", ix, iy, math.max(0, iw * fill), ih)
end

-- The crosshair: four ticks around a gap that opens as the gun kicks, and
-- gone entirely down the sights, where the iron sights ARE the crosshair.
-- Drawn as a dark pair under a light pair so it survives both a white
-- wall and a black doorway.
local function crosshair(cx, cy, s, spread, alpha)
  local gap = (3 + spread * 4) * s
  local len = 4 * s
  local t = math.max(1, s)
  local function ticks(o, thick, r, g, b, a)
    love.graphics.setColor(r, g, b, a)
    love.graphics.rectangle("fill", cx - gap - len - o, cy - thick / 2 - o,
                            len + 2 * o, thick + 2 * o)
    love.graphics.rectangle("fill", cx + gap - o, cy - thick / 2 - o,
                            len + 2 * o, thick + 2 * o)
    love.graphics.rectangle("fill", cx - thick / 2 - o, cy - gap - len - o,
                            thick + 2 * o, len + 2 * o)
    love.graphics.rectangle("fill", cx - thick / 2 - o, cy + gap - o,
                            thick + 2 * o, len + 2 * o)
  end
  ticks(math.max(1, s * 0.5), t, 0, 0, 0, alpha * 0.85)
  ticks(0, t, 0.98, 0.98, 1, alpha)
end

local function hitMarker(cx, cy, s, amount)
  if amount <= 0 then return end
  love.graphics.setColor(1, 0.30, 0.26, amount)
  local o = 5 * s
  local len = 5 * s
  local t = math.max(1, s)
  for _, d in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
    love.graphics.push()
    love.graphics.translate(cx + d[1] * o, cy + d[2] * o)
    love.graphics.rotate(math.pi / 4 * (d[1] * d[2] > 0 and 1 or -1))
    love.graphics.rectangle("fill", -t / 2, -len / 2, t, len)
    love.graphics.pop()
  end
end

-- The banner: one wide plate across the middle of the frame with the
-- words on it, big. It fades in and out rather than cutting -- an
-- announcement, not a notification -- and the plate fades with it.
local function banner(w, h, scale)
  local sess = Horde.session
  if not (sess and sess.bannerText) then return end
  local t, hold = sess.bannerT, sess.bannerHold
  local alpha
  if t < 0.4 then alpha = t / 0.4
  elseif t < hold then alpha = 1
  else alpha = math.max(0, 1 - (t - hold) / 1.1) end
  if alpha <= 0 then return end

  local F = font()
  if not F then return end
  local str = sess.bannerText
  local bs = scale * 2
  local track = 2 * scale          -- extra pixels between glyphs
  local codes = F.encode(str)
  local total = 0
  for _, code in ipairs(codes) do
    total = total + F.advanceOf(code) * bs + track
  end
  total = total - track

  local ph = 8 * bs + PAD * 2 * scale * 2
  local y = math.floor(h * 0.28)
  -- the plate runs the full width: a band across the world, which reads
  -- as the game interrupting itself rather than as a label on it
  local _, iy = plate(0, y, w, ph, scale, alpha)
  local pen = math.floor((w - total) / 2)
  love.graphics.setColor(0, 0, 0, alpha)
  for _, code in ipairs(codes) do
    love.graphics.push()
    love.graphics.translate(pen, iy)
    love.graphics.scale(bs, bs)
    F.drawCode(code, 0, 0)
    love.graphics.pop()
    pen = pen + F.advanceOf(code) * bs + track
  end
end

-- ------- the whole thing
--
-- `inset` is how far off the edges the corners sit, which is the one real
-- difference between a window and a headset.

local function draw(w, h, s, inset)
  local sess = Horde.session
  if not sess then return end
  local Gun = V.require("HordeGun")
  local ammo, mag, reloading = Gun.ammo()
  local ads = Gun.adsBlend()

  love.graphics.push("all")
  love.graphics.setBlendMode("alpha")

  -- The red. A VIGNETTE rather than a wash over everything: a full-screen
  -- fill strong enough to register at a glance also hides the thing that
  -- just hit you, which in a mode about being surrounded is the one thing
  -- it must not do. Bands closing in from the edges instead, so the
  -- middle of the frame stays readable and the alarm arrives in the
  -- corner of the eye.
  local hurt = sess.damageFlash
  local low = 1 - math.min(1, sess.hp / (sess.maxHp * 0.35))
  local wash = math.max(hurt * 0.9, low * 0.6
                        * (0.7 + 0.3 * math.sin(blink * math.pi * 2)))
  if wash > 0 then
    local band = math.min(w, h) * 0.38
    local steps = 8
    for i = 1, steps do
      local t = i / steps
      local d = band * t
      love.graphics.setColor(0.60, 0.02, 0.06, wash * 0.13)
      love.graphics.rectangle("fill", 0, 0, w, d)
      love.graphics.rectangle("fill", 0, h - d, w, d)
      love.graphics.rectangle("fill", 0, 0, d, h)
      love.graphics.rectangle("fill", w - d, 0, d, h)
    end
  end

  -- health, top left
  local barW, barH = 60 * s, 8 * s + PAD * 2 * s
  healthBar(inset, inset, barW, barH, s, sess.hp / sess.maxHp, hurt > 0.3)
  label(("%d"):format(math.ceil(sess.hp)), inset, inset + barH + 3 * s, s)

  -- score and wave, top right
  label(("SCORE %d"):format(math.floor(sess.score)), w - inset, inset, s,
        "right")
  label(("WAVE %d"):format(math.max(1, sess.wave)),
        w - inset, inset + (8 * s + PAD * 2 * s) + 3 * s, s, "right")

  -- ammunition, bottom right: the rounds as pips over the count, which
  -- reads at a glance in a firefight where a number does not
  local ammoStr = reloading and "RELOADING" or ("%d / %d"):format(ammo, mag)
  local _, ah = label(ammoStr, w - inset, h - inset - (8 * s + PAD * 2 * s), s,
                      "right")
  local pipW, pipH, pipGap = 3 * s, 7 * s, 2 * s
  local pipsW = mag * (pipW + pipGap) - pipGap
  local px = w - inset - pipsW
  local py = h - inset - ah - pipH - 5 * s
  love.graphics.setColor(0.06, 0.05, 0.09, 0.85)
  love.graphics.rectangle("fill", px - 2 * s, py - 2 * s,
                          pipsW + 4 * s, pipH + 4 * s)
  for i = 1, mag do
    if i <= ammo and not reloading then
      love.graphics.setColor(0.98, 0.86, 0.36, 1)
    else
      love.graphics.setColor(0.32, 0.30, 0.36, 1)
    end
    love.graphics.rectangle("fill", px + (i - 1) * (pipW + pipGap), py,
                            pipW, pipH)
  end
  if reloading then
    local t = math.min(1, Gun.state.reloadT / Gun.RELOAD_TIME)
    love.graphics.setColor(0.55, 0.78, 0.98, 1)
    love.graphics.rectangle("fill", px, py + pipH + 1 * s, pipsW * t, 2 * s)
  end

  -- the sight picture
  local cx, cy = w / 2, h / 2
  if ads < 0.6 then
    crosshair(cx, cy, s, Gun.state.kick, (1 - ads / 0.6) * 0.9)
  end
  hitMarker(cx, cy, s, sess.hitMarker)

  banner(w, h, s)

  love.graphics.pop()
  love.graphics.setColor(1, 1, 1, 1)
end

-- ------- the two callers

-- The flat window. Called from the voxel pipeline's overlay block, into
-- the scene canvas -- which is at the window's PIXEL size and may be
-- supersampled on top of that, so the caller's scale carries both.
function HordeHud.drawFlat(w, h, scale)
  if not Horde.active then return end
  local s = math.max(1, math.floor((scale or 1) + 0.5))
  draw(w, h, s, 8 * s)
end

-- One VR eye, at the moment lib/VR paints its own fade over the finished
-- eye canvas. The inset is generous: the corners of an eye buffer are
-- outside the lens, and a health bar nobody can see is not a health bar.
function HordeHud.drawEye(w, h)
  if not Horde.active then return end
  local s = math.max(1, math.floor(h / 260 + 0.5))
  draw(w, h, s, math.floor(math.min(w, h) * 0.17))
end

return HordeHud

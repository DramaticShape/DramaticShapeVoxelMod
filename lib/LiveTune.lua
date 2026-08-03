-- Live tuning: change the world's look while you are looking at it.
--
-- The OPTIONS menu is the wrong instrument for a setting you judge with your
-- eyes. START, OPTION, step a row, B, B, look, decide, and back again --
-- five inputs and a scene change between seeing STRONG and seeing MEDIUM,
-- which is exactly long enough to forget what STRONG looked like. Every row
-- this mod owns is visual, so all of them have that problem.
--
-- This is a translucent handle in the corner that opens a small panel of the
-- same rows, drawn OVER the running world. The game never stops: stepping a
-- value re-renders the next frame with it, so the comparison is immediate
-- and the decision is made looking at the thing being decided.
--
-- WHERE IT LIVES. After Game:draw, on the composited frame, in window units.
-- It started inside the 3D pass's overlay next to the horde HUD, which was
-- wrong twice over: that canvas is upstream of the tilt-shift blur, so the
-- handle came out soft inside MINIATURE's blurred band, and the pass only
-- runs on a 3D rung, so the panel could not be used to switch 3D ON in the
-- first place. Drawing last fixes both -- it is sharp, and it is reachable
-- from the flat game.
--
-- WHAT IT STEPS. Nothing of its own. Every row here is the same
-- ModSetting:cycle / Pipelines.cycle the OPTIONS row calls, so a value
-- changed here persists exactly as one changed there, and the two can never
-- drift into disagreeing about what is set.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local LiveTune = {}

-- Set by main.lua: a function answering the rows to show, each
-- { label = string, value = function -> string, step = function(dir) }.
-- A function rather than a table because which rows apply depends on the
-- rung -- the first-person rows only exist on 1ST.
LiveTune.provider = nil

LiveTune.open = false

-- The row that turns the handle off. Declared here rather than in main.lua
-- so the module that draws the handle is the one that owns whether it is
-- drawn -- there is no way to add the panel without also adding its off
-- switch.
local ModSetting = V.require("ModSetting")
LiveTune.setting = ModSetting.new("livetune", "TUNE PANEL",
                                  { true, false }, { "ON", "OFF" })

function LiveTune.enabled()
  local ok, v = pcall(function() return LiveTune.setting:get() end)
  if not ok or v == nil then return true end
  return v and true or false
end

-- Shown while the player is standing in the world: not over a menu, a
-- dialog or a battle, which own the screen and the touches while they are
-- up. Same test first person uses to decide whether it is steering.
function LiveTune.visible()
  if not LiveTune.enabled() then return false end
  local ok, top, ow = pcall(function()
    local Game = require("src.core.Game")
    return Game.stack and Game.stack:top(), Game.overworld
  end)
  return ok and top ~= nil and top == ow
end

-- geometry, in LOVE units
local HANDLE_R = 21
local ROW_H = 27
local PANEL_W = 232
local MARGIN = 14

local font = nil
local function theFont()
  if not font then
    local ok, f = pcall(love.graphics.newFont, 13)
    font = ok and f or love.graphics.getFont()
  end
  return font
end

-- The window's usable rectangle: the handle must not sit under the Dynamic
-- Island, and in landscape must not sit under the notch either.
local function insets(ww)
  local t, l, r = 0, 0, 0
  if love.window and love.window.getSafeArea then
    local ok, ax, ay, aw = pcall(love.window.getSafeArea)
    if ok and type(aw) == "number" and aw > 0 then
      t = math.max(0, ay or 0)
      l = math.max(0, ax or 0)
      r = math.max(0, ww - ((ax or 0) + aw))
    end
  end
  return t, l, r
end

-- Handle centre, top-right: the d-pad owns the bottom left, A/B and the look
-- stick own the right side lower down, and the top-left is where the engine
-- puts its own notices.
function LiveTune.handle()
  local ww = love.graphics.getWidth()
  local insetT, _, insetR = insets(ww)
  return { cx = ww - insetR - MARGIN - HANDLE_R,
           cy = insetT + MARGIN + HANDLE_R,
           r = HANDLE_R }
end

local function rows()
  if type(LiveTune.provider) ~= "function" then return {} end
  local ok, list = pcall(LiveTune.provider)
  if not ok or type(list) ~= "table" then return {} end
  return list
end

-- The panel's rectangle and its row rectangles, so drawing and hit-testing
-- cannot disagree about where anything is.
local function panelRects()
  local list = rows()
  if #list == 0 then return nil, list end
  local h = LiveTune.handle()
  local ww = love.graphics.getWidth()
  local _, insetL = insets(ww)
  local w = math.min(PANEL_W, ww - insetL - MARGIN * 2)
  local x = math.max(insetL + MARGIN, h.cx + h.r - w)
  local y = h.cy + h.r + 8
  return { x = x, y = y, w = w, h = #list * ROW_H + 10 }, list
end

-- ------- drawing

local function roundRect(mode, x, y, w, h, r)
  love.graphics.rectangle(mode, x, y, w, h, r, r)
end

function LiveTune.draw()
  if not LiveTune.visible() then return end
  if #rows() == 0 then return end
  -- Drawn in plain LOVE units, straight onto the window, because this runs
  -- AFTER Game:draw has composited everything. The first version drew into
  -- the 3D pass's overlay canvas, which put it upstream of the tilt-shift
  -- blur -- so the handle sat inside MINIATURE's blurred top band and came
  -- out soft, while everything around it was sharp.
  local s = 1

  love.graphics.push("all")
  love.graphics.setFont(theFont())

  local h = LiveTune.handle()
  -- the handle: deliberately faint. It sits over the world all the time, and
  -- a bright chip in the corner of every screenshot is worse than a dim one
  -- that takes a moment to find the first time.
  love.graphics.setColor(0, 0, 0, LiveTune.open and 0.55 or 0.34)
  love.graphics.circle("fill", h.cx * s, h.cy * s, h.r * s)
  love.graphics.setColor(1, 1, 1, LiveTune.open and 0.75 or 0.42)
  love.graphics.setLineWidth(math.max(1, 1.5 * s))
  love.graphics.circle("line", h.cx * s, h.cy * s, h.r * s)
  -- a small cube glyph, drawn rather than shipped as an asset so there is no
  -- image to load, fail to load, or mismatch the density
  do
    local q = h.r * 0.42 * s
    local cx, cy = h.cx * s, h.cy * s
    love.graphics.polygon("line", cx - q, cy - q * 0.3, cx, cy - q,
                          cx + q, cy - q * 0.3, cx, cy + q * 0.4)
    love.graphics.line(cx - q, cy - q * 0.3, cx - q, cy + q * 0.7)
    love.graphics.line(cx + q, cy - q * 0.3, cx + q, cy + q * 0.7)
    love.graphics.line(cx, cy + q * 0.4, cx, cy + q * 1.4)
    love.graphics.line(cx - q, cy + q * 0.7, cx, cy + q * 1.4)
    love.graphics.line(cx + q, cy + q * 0.7, cx, cy + q * 1.4)
  end

  if LiveTune.open then
    local p, list = panelRects()
    if p then
      love.graphics.setColor(0, 0, 0, 0.62)
      roundRect("fill", p.x * s, p.y * s, p.w * s, p.h * s, 10 * s)
      love.graphics.setColor(1, 1, 1, 0.22)
      roundRect("line", p.x * s, p.y * s, p.w * s, p.h * s, 10 * s)

      for i, row in ipairs(list) do
        local ry = p.y + 5 + (i - 1) * ROW_H
        local ok, val = pcall(row.value)
        val = (ok and val) or "-"
        -- label left, value right, arrows at the two ends of the row
        love.graphics.setColor(1, 1, 1, 0.62)
        love.graphics.print(row.label, (p.x + 30) * s,
                            (ry + 6) * s, 0, s, s)
        love.graphics.setColor(1, 1, 1, 0.95)
        local vw = theFont():getWidth(tostring(val))
        love.graphics.print(tostring(val),
                            (p.x + p.w - 30) * s - vw * s, (ry + 6) * s, 0, s, s)
        -- the steppers
        love.graphics.setColor(1, 1, 1, 0.55)
        local ay = (ry + ROW_H * 0.5) * s
        local aw = 5 * s
        local lx = (p.x + 15) * s
        love.graphics.polygon("fill", lx + aw, ay - aw, lx + aw, ay + aw, lx - aw * 0.4, ay)
        local rx = (p.x + p.w - 15) * s
        love.graphics.polygon("fill", rx - aw, ay - aw, rx - aw, ay + aw, rx + aw * 0.4, ay)
      end
    end
  end
  love.graphics.pop()
end

-- ------- input
--
-- Answers true when the touch was ours, so the caller knows to stop: a tap
-- on the panel must not also walk the player or fire a horde shot.

function LiveTune.touchpressed(x, y)
  if not LiveTune.visible() then return false end
  if #rows() == 0 then return false end
  local h = LiveTune.handle()
  local dx, dy = x - h.cx, y - h.cy
  -- a generous target: the handle is small on purpose, the tap area is not
  local reach = h.r * 1.45
  if dx * dx + dy * dy <= reach * reach then
    LiveTune.open = not LiveTune.open
    return true
  end
  if not LiveTune.open then return false end
  local p, list = panelRects()
  if not p then return false end
  if x < p.x or x > p.x + p.w or y < p.y or y > p.y + p.h then
    -- a tap anywhere else closes it, the way a popover does. Not consumed:
    -- closing should not also swallow the tap that closed it.
    LiveTune.open = false
    return false
  end
  local i = math.floor((y - p.y - 5) / ROW_H) + 1
  local row = list[i]
  if not row or type(row.step) ~= "function" then return true end
  -- Left half steps down, right half steps up. Splitting the whole row
  -- rather than hit-testing the little arrows keeps the targets thumb-sized;
  -- the arrows are there to say which way, not to be aimed at.
  pcall(row.step, (x < p.x + p.w * 0.5) and -1 or 1)
  return true
end

function LiveTune.install(Game)
  if LiveTune._installed then return end
  LiveTune._installed = true
  do
    -- After Game:draw, so the panel lands on top of the composited frame --
    -- past the 3D pass, past the tilt-shift blur, past the touch overlay --
    -- and in window units, which is what keeps it crisp.
    local innerDraw = Game.draw
    function Game:draw(...)
      local r = innerDraw(self, ...)
      pcall(LiveTune.draw)
      return r
    end
  end
  local inner = Game.touchpressed
  function Game:touchpressed(id, tx, ty)
    -- First refusal: this panel is drawn over everything, so it has to be
    -- offered the touch before the pad, the look stick or the horde gun.
    local ok, taken = pcall(LiveTune.touchpressed, tx, ty)
    if ok and taken then return end
    return inner(self, id, tx, ty)
  end
end

return LiveTune

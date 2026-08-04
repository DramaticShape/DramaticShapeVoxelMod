-- STADIUM battles: the one-time build, on screen.
--
-- A pushed game state, so it draws in the Game Boy's own 160x144 and stops
-- everything under it -- which is what it should do, because it is doing real
-- work and the player should not be walking around while it happens.
--
-- ------- why a species a frame
--
-- A species takes roughly fifty milliseconds to extract, and there are 151 of
-- them. That is ten seconds, which has to go somewhere. Doing them one per
-- frame puts the whole cost on this screen where it is explained, keeps the
-- bar moving at a visible rate, and leaves the frame free to draw between
-- them. Batching more per frame would finish no sooner -- the work is the
-- same -- and would only make the bar jump.
--
-- ------- what it says
--
-- Three things, and each of them is answering a question the player would
-- otherwise have to guess at while the game sits there:
--
--   WHAT is happening -- "STADIUM EXTRACTION", which is what it is.
--
--   HOW FAR through it is -- a bar, filled by species written rather than by
--   elapsed time, so it cannot lie about the remaining work.
--
--   THAT IT IS ALIVE -- which Pokemon it is on, by name. Not decoration: it
--   is the difference between a progress bar the player trusts and one they
--   suspect has hung, and it costs one lookup a frame.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local StadiumInstall = V.require("StadiumInstall")

local StadiumScreen = {}
StadiumScreen.__index = StadiumScreen

-- The Game Boy frame this draws in.
local W, H = 160, 144

-- How long the finished message stays up before the screen retires itself.
StadiumScreen.HOLD = 1.1

local Font = nil
local function font()
  if Font then return Font end
  local ok, F = pcall(require, "src.render.Font")
  if ok then Font = F end
  return Font
end

-- Black glyphs, because that is the only colour the Game Boy font sheets
-- have -- they are black on transparent, so setColor cannot lighten one.
-- Everything here is therefore laid out dark-on-light.
local function text(str, x, y)
  local F = font()
  if not F then return end
  love.graphics.setColor(0, 0, 0, 1)
  F.draw(str, math.floor(x), math.floor(y))
end

local function centred(str, y)
  local F = font()
  if not F then return end
  text(str, (W - F.width(str)) / 2, y)
end

-- How many glyphs fit across the frame. The font is a fixed eight pixels, so
-- twenty is the line -- and a centred string longer than that does not
-- overflow tidily off one side, it clips off BOTH and loses its first word as
-- well as its last ("that is not a Pokemon Stadium ROM" came out as "at is
-- not a Pokemon").
local COLS = 20

-- Break a reason into lines that fit, on word boundaries, and never more than
-- `limit` of them -- the plate has room for two and a message nobody can read
-- the end of is not improved by adding a third.
local function wrapped(str, limit)
  local lines, line = {}, nil
  for word in tostring(str):gmatch("%S+") do
    local try = line and (line .. " " .. word) or word
    if #try <= COLS then
      line = try
    else
      if line then lines[#lines + 1] = line end
      -- a single word too long to fit is cut rather than dropped: it is
      -- usually a filename, and its first twenty characters still identify it
      line = (#word <= COLS) and word or word:sub(1, COLS)
    end
    if #lines >= (limit or 2) then break end
  end
  if line and #lines < (limit or 2) then lines[#lines + 1] = line end
  return lines
end

-- ------- dex number -> the engine's own species key
--
-- Built once, from the loaded data rather than from a list of names carried
-- here: a list would be a second place for the same 151 facts to live, and
-- would go stale against a mod that renames one.
local dexNames = nil

local function speciesName(dex)
  if not dex then return nil end
  if not dexNames then
    dexNames = {}
    local ok, data = pcall(function()
      return require("src.core.Game").data
    end)
    if ok and data and data.pokemon then
      for key, def in pairs(data.pokemon) do
        if type(def) == "table" and def.dex then dexNames[def.dex] = key end
      end
    end
  end
  return dexNames[dex]
end

-- `adopt` means the caller has ALREADY started the build, or already decided
-- it cannot start -- which is the imported path (StadiumRomPick opens the
-- picked file itself, because love.filesystem cannot read an absolute path).
-- Without it this screen would call begin() on the way in and throw away the
-- job it was pushed to display, or overwrite the failure it was pushed to
-- explain with a fresh "no ROM in baseroms" -- which would be true, and would
-- have nothing to do with what just went wrong.
function StadiumScreen.new(game, adopt)
  return setmetatable({ game = game, hold = 0, started = adopt and true or false,
                        adopted = adopt and true or false }, StadiumScreen)
end

-- Opaque: the loading screen owns the frame, so the map underneath is not
-- drawn and not paying for a render it cannot be seen through.
StadiumScreen.isOpaque = true

function StadiumScreen:enter()
  if self.adopted then return end
  local ok, err = StadiumInstall.begin()
  self.started = ok and true or false
  if not ok then
    StadiumInstall.status.state = "failed"
    StadiumInstall.status.error = err
  end
end

function StadiumScreen:update()
  local status = StadiumInstall.status
  if status.state == "building" then
    if not StadiumInstall.step() then
      -- fell out of building: either finished or failed, both of which hold
      -- for a moment so the player sees which
      self.hold = 0
    end
    return
  end
  self.hold = self.hold + 1 / 60
  -- a failure stays up longer, because it is the one the player has to read
  local wait = StadiumScreen.HOLD
  if status.state == "failed" then
    wait = StadiumScreen.HOLD * 4
  elseif status.wrongVersion then
    -- a warning nobody can read is not a warning
    wait = StadiumScreen.HOLD * 3
  end
  if self.hold >= wait then
    if self.game and self.game.stack and self.game.stack:top() == self then
      self.game.stack:pop()
    end
  end
end

-- Let the player out of a build that has gone wrong, or that they would
-- rather not wait for. Cancelling leaves the packs unbuilt, so the STADIUM
-- rungs stay off the row until the next boot offers again -- which is
-- honest, and better than a half-built set.
function StadiumScreen:onKeyPressed(key)
  if key == "escape" or key == "x" or key == "backspace" then
    StadiumInstall.cancel()
    if self.game and self.game.stack and self.game.stack:top() == self then
      self.game.stack:pop()
    end
    return true
  end
  return false
end

function StadiumScreen:draw()
  local status = StadiumInstall.status
  love.graphics.setColor(0.93, 0.94, 0.90, 1)
  love.graphics.rectangle("fill", 0, 0, W, H)

  -- One line, and it is the whole heading: eighteen glyphs at the font's
  -- fixed eight pixels is 144 of the frame's 160.
  centred("STADIUM EXTRACTION", 34)

  if status.state == "failed" then
    centred("COULD NOT BUILD", 68)
    local lines = wrapped(status.error or "unknown", 2)
    for i, line in ipairs(lines) do centred(line, 82 + (i - 1) * 10) end
    centred("STADIUM IS OFF", 110)
    love.graphics.setColor(1, 1, 1, 1)
    return
  end

  local done = status.done or 0
  local total = status.total or StadiumInstall.COUNT
  local frac = (total > 0) and (done / total) or 1
  if status.state == "done" then frac = 1 end
  if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end

  -- The bar: a dark frame, an EMPTY interior the same colour as the plate,
  -- and a dark fill growing left to right.
  --
  -- The track has to be the plate's own white rather than a light grey. This
  -- draws inside the Game Boy frame, so the colorization pass quantises
  -- everything here into the four GB shades and paints them -- and a grey
  -- track lands one shade down, which comes out as a bar that is GREEN where
  -- the work is still to do and dark where it is done. The eye reads colour
  -- as the filled part and gets the progress exactly backwards.
  local bx, by, bw, bh = 24, 68, W - 48, 9
  love.graphics.setColor(0.06, 0.05, 0.09, 1)
  love.graphics.rectangle("fill", bx - 1, by - 1, bw + 2, bh + 2)
  love.graphics.setColor(0.93, 0.94, 0.90, 1)
  love.graphics.rectangle("fill", bx, by, bw, bh)
  love.graphics.setColor(0.06, 0.05, 0.09, 1)
  love.graphics.rectangle("fill", bx, by, math.floor(bw * frac + 0.5), bh)

  if status.state == "done" then
    centred("READY", 86)
    -- and say so if it was built from something other than the revision every
    -- offset in the reader was measured against: it may look fine, it may be
    -- subtly wrong, and the player is the only one who can swap the file
    if status.wrongVersion then
      centred("NOT US 1.0 --", 104)
      centred("MODELS MAY BE WRONG", 114)
    end
  else
    local name = speciesName(status.species)
    centred(("%d/%d"):format(done, total), 86)
    if name then centred(name, 98) end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

-- ------- when this comes up
--
-- The first frame the player is actually IN the world, rather than at boot.
-- Two reasons. The engine has its own launcher and ROM importer before the
-- game starts, and pushing over those would be fighting them for the screen.
-- And `Game.data` has to be loaded for the species names above to resolve.
--
-- Asked once. If the player cancels, or there is no ROM, this does not come
-- back until the next run -- a loading screen that reappears every time you
-- step outside would be worse than no stadium models.
local asked = false

function StadiumScreen.maybePush()
  if asked then return false end
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game and Game.stack and Game.overworld) then return false end
  if Game.stack:top() ~= Game.overworld then return false end
  asked = true
  if not StadiumInstall.pending() then
    -- Say where to put a cartridge, ONCE, and only when there is nothing to
    -- build from and nothing already built. The two STADIUM rungs are simply
    -- absent in that case (ModSetting.setGate), which is the right thing for
    -- a row to do and tells the player nothing about why -- and the answer
    -- they need is an absolute path that depends on how the game was
    -- installed, so it cannot be written into the options help text.
    if not StadiumInstall.available() then
      -- The IMPORT row is the answer wherever a file dialog can be opened,
      -- and it is the better one: no folder to create, no path to get right,
      -- no restart. The folder is still said, once, for the platforms with no
      -- dialog (Android, a handheld Linux with neither zenity nor kdialog)
      -- and for anyone who would rather drop a file than click through one.
      local okPick, pick = pcall(V.require, "StadiumRomPick")
      local canPick = okPick and pick and pick.available()
      V.mod.log:info("stadium: no Pokemon Stadium ROM found, so the STADIUM "
                     .. "battle rungs are off. %s",
                     canPick
                       and ("Import one from OPTIONS -> " .. pick.LABEL
                            .. ", or put a .z64/.n64/.v64 in "
                            .. StadiumInstall.romHint() .. " and restart.")
                       or ("Put one (.z64/.n64/.v64) in "
                           .. StadiumInstall.romHint() .. " and restart."))
    end
    return false
  end
  Game.stack:push(StadiumScreen.new(Game))
  return true
end

-- named for the suite, which drives the screen without a boot
function StadiumScreen._reset()
  asked = false
end

return StadiumScreen

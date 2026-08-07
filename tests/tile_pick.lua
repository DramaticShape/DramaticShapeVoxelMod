-- Driver: the tile picker -- point at a tile, get the voxelize prompt.
--
-- The voxelize-tiles skill is driven per TILE, and its first argument is
-- always the same thing: which map, and which cell on it. Finding that pair
-- by hand means walking the game to the object, counting cells off a corner
-- and hoping the count is right. This is the same window the arena editor is
-- -- the map drawn from its OWN art, the tiles the cartridge holds, through
-- the game's own palette -- with a cursor on it instead of an arena, and one
-- button: COPY PROMPT.
--
-- What lands on the clipboard is exactly:
--
--   run voxelize-tile on the tile found in PALLET_TOWN- (5,4). Return
--   screenshots of the voxelization in .claude/voxelizations/
--
-- on one line, ready to paste into Claude. Every copy is also appended to
-- SHOT_DIR/prompts.txt and printed to the console, because a session of this
-- is a LIST of jobs -- you walk a map picking out every object worth shape
-- and hand the list over at the end, rather than pasting one and waiting.
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/tile_pick.lua \
--     "/c/Program Files/LOVE/lovec.exe" .
--
-- from the PROJECT ROOT, with this mod enabled. lovec rather than love, so
-- the console is attached and the transcript alone is the list.
--
-- ------- the keys
--
--   arrows      move the cursor (hold shift for 5 cells)
--   click       put the cursor on that tile
--   [  ]        previous / next map (shift: 10 at a time)
--   c / enter   COPY PROMPT for the tile under the cursor
--   z           zoom the inset in / out (shift: out)
--   g           what the plan shows: the map's own tiles, the walk grid over
--               them, or the walk grid alone
--   m           HIDE the plan, so the window is the game -- the panel keeps
--               the coordinates, the inset and the button, so a tile is
--               still copied from here while looking at it standing up in 3D
--   t           stand the player on this tile, so the 3D view behind the
--               panel is looking at the thing you are about to voxelize
--   y           screenshot (shift: with this panel in it)
--   l           re-print every prompt copied so far
--   F1          the key legend on screen
--   escape      quit
--
-- ------- environment
--
--   TILE_MAPS=ID,ID    work this list instead of every map in the game
--   TILE_START=ID      open on this map
--   TILE_OUT=path      where prompts.txt is written
--   TILE_RUNG=N        the voxel angle rung to sit on (default 3)
--   SHOT_DIR=path      screenshots, and the default prompt-list directory
return function(game)
  local U = dofile("tests/drivers/util.lua")

  local function truthy(v) return v ~= nil and v ~= "" and v ~= "0" end

  local DIR = os.getenv("SHOT_DIR")
  if not DIR or DIR == "" then DIR = ".scratchpad/tile_pick" end
  local OUT = os.getenv("TILE_OUT")
  if not OUT or OUT == "" then OUT = DIR .. "/prompts.txt" end
  local RUNG = tonumber(os.getenv("TILE_RUNG") or "") or 3

  -- U.shot's own mkdir is Unix-flavoured and does nothing on Windows, which
  -- is where this tool is driven from -- so the shell is asked in its own
  -- language, or the screenshots and the prompt list never reach disk.
  local WINDOWS = love.system and love.system.getOS() == "Windows"
  local function mkdirp(dir)
    if not dir or dir == "" then return end
    if WINDOWS then
      local d = dir:gsub("/", "\\")
      os.execute('if not exist "' .. d .. '" mkdir "' .. d .. '"')
    else
      os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
    end
  end
  mkdirp(DIR)
  mkdirp(OUT:match("^(.*)[/\\][^/\\]+$"))

  -- ------- the mod
  --
  -- Only for the camera rung: the picking itself is engine-only, but the
  -- view behind the panel is what `t` is for, and a flat 2D world behind a
  -- 3D-tile picker would be looking at the wrong thing.
  local exports = game.mods and game.mods.exports
  local lib = exports and exports.DRAMATIC_SHAPE and exports.DRAMATIC_SHAPE.lib
  local Pipelines = require("src.render.Pipelines")
  local PaletteFX = require("src.render.PaletteFX")
  local Pokemon = require("src.pokemon.Pokemon")

  local wasRung
  if lib then
    local DayNight = lib.require("DayNight")
    DayNight.setting:setValue("day")     -- one light to look at them all in
    wasRung = Pipelines.level("voxel")
    Pipelines.setLevel("voxel", RUNG)
  else
    U.log("DRAMATIC_SHAPE is not loaded -- the picker still works, but the "
          .. "view behind it will be the flat 2D map")
  end

  game.save.party = { Pokemon.new(game.data, "CHARIZARD", 45) }
  game.save.player.name = "RED"

  -- ------- which maps
  --
  -- EVERY map, unlike the arena tools: a tile worth voxelizing is as likely
  -- to be a shop counter or a bedroom desk as anything on a route, and those
  -- are exactly the maps a "where can a fight happen" filter throws away.
  local ids = {}
  local explicit = os.getenv("TILE_MAPS")
  if explicit and explicit ~= "" then
    for id in explicit:gmatch("[^,%s]+") do ids[#ids + 1] = id end
  else
    for id, def in pairs(game.data.maps) do
      if type(id) == "string" and type(def) == "table" and def.width then
        ids[#ids + 1] = id
      end
    end
    table.sort(ids)
  end
  if #ids == 0 then
    U.log("no maps to work on")
    return
  end

  local S = {
    i = 1,
    map = nil,
    cx = 0, cy = 0,        -- the cursor, in cells
    plan = nil,
    tiles = nil,           -- the map baked from its own tileset
    planMode = 1,
    showPlan = true,       -- is the plan drawn at all
    zoom = 5,              -- how many cells across the inset shows
    msg = "",
    legend = true,
    copied = {},           -- every prompt this session, in order
    shooting = false,
    quit = false,
    planRect = nil,        -- where the plan landed, for the mouse
    buttonRect = nil,      -- and the button
  }

  local queue = {}
  local function post(cmd, arg) queue[#queue + 1] = { cmd = cmd, arg = arg } end
  local function say(fmt, ...)
    S.msg = select("#", ...) > 0 and fmt:format(...) or fmt
  end
  local function mapId() return ids[S.i] end

  -- ------- the prompt
  --
  -- One line, and the ONLY thing this tool exists to produce. Kept in one
  -- function so the text that reaches the clipboard, the console and the
  -- file is provably the same text.
  local function promptFor(id, cx, cy)
    return ("run voxelize-tile on the tile found in %s- (%d,%d). "
            .. "Return screenshots of the voxelization in "
            .. ".claude/voxelizations/"):format(id, cx, cy)
  end

  local function copyPrompt()
    local text = promptFor(mapId(), S.cx, S.cy)
    local ok = false
    if love.system and love.system.setClipboardText then
      ok = pcall(love.system.setClipboardText, text)
    end
    S.copied[#S.copied + 1] = text
    -- The clipboard holds ONE of these and the session produces many, so the
    -- file is not a convenience -- it is where the list actually lives. Open
    -- per copy and closed again: a tool driving a game can be killed at any
    -- moment, and a buffered list is a lost afternoon.
    local f = io.open(OUT, "a")
    if f then
      f:write(text, "\n")
      f:close()
    end
    U.log("PROMPT " .. text)
    say("%s (%d,%d) copied%s -- %d so far", mapId(), S.cx, S.cy,
        ok and "" or " to the list only (no clipboard here)", #S.copied)
  end

  -- ------- what the map looks like from above
  --
  -- Lifted from the arena editor, and for its reason: the plan is the
  -- surface a tile is chosen on, and a grid of coloured squares is a map of
  -- the walk grid rather than of the place. You are picking out a bookshelf.
  -- Baked once per map into a canvas, during UPDATE rather than inside a
  -- draw, because it binds a canvas of its own.
  local PLAN_MAX = 2048

  local function paletteFor(m)
    local ow = game.overworld
    if ow and ow.paletteNameFor then
      local okName, name = pcall(ow.paletteNameFor, ow, m)
      if okName and name then
        local okPal, colours = pcall(PaletteFX.pal, game.data, name)
        if okPal and colours then return colours end
      end
    end
    local okOg, og = pcall(PaletteFX.ogBg)
    return okOg and og or nil
  end

  local function bakeTiles()
    if S.tiles then pcall(S.tiles.release, S.tiles) end
    S.tiles = nil
    local m = S.map
    if not (m and m.renderer and love.graphics and love.graphics.newCanvas) then
      return
    end
    local w, h = m.widthCells * 16, m.heightCells * 16
    local scale = math.min(1, PLAN_MAX / math.max(w, h))
    local okNew, canvas = pcall(love.graphics.newCanvas,
                                math.max(1, math.floor(w * scale)),
                                math.max(1, math.floor(h * scale)))
    if not (okNew and canvas) then return end
    -- Nearest, unlike the arena editor's plan: that one is a whole route
    -- minified to a panel, where nearest keeps a moire. This one gets
    -- magnified in the inset, where a tile has to be READABLE -- linear
    -- there is a smear of a bookshelf, and the drawing is the whole point.
    pcall(canvas.setFilter, canvas, "nearest", "nearest")

    local g = love.graphics
    local prev = g.getCanvas()
    local wasTrue = m.renderer.trueColor
    m.renderer.trueColor = false
    local ok, err = pcall(function()
      g.push("all")
      g.origin()
      g.setCanvas(canvas)
      g.clear(0, 0, 0, 0)
      g.setBlendMode("alpha")
      g.setColor(1, 1, 1, 1)
      g.scale(scale, scale)
      local shader = PaletteFX.shader()
      local colours = paletteFor(m)
      if shader and colours then
        g.setShader(shader)
        PaletteFX.sendColors(shader, colours)
      end
      m.renderer:drawMapOnly(0, 0, w, h)
      g.pop()
    end)
    m.renderer.trueColor = wasTrue
    if prev then pcall(g.setCanvas, prev) else pcall(g.setCanvas) end
    if not ok then
      pcall(canvas.release, canvas)
      U.log("could not bake the map's tiles: " .. tostring(err))
      return
    end
    S.tiles = canvas
  end

  local PLAN_MODES = { "both", "tiles", "grid" }

  local CELL_COLOUR = {
    open  = { 0.78, 0.74, 0.63 },
    grass = { 0.33, 0.60, 0.30 },
    water = { 0.24, 0.44, 0.78 },
    warp  = { 0.85, 0.68, 0.20 },
    solid = { 0.17, 0.17, 0.20 },
  }

  local function buildPlan()
    local m = S.map
    if not m then S.plan = nil return end
    local w, h = m.widthCells, m.heightCells
    local plan = { w = w, h = h }
    for cy = 0, h - 1 do
      for cx = 0, w - 1 do
        local kind
        if not m:isWalkableCell(cx, cy) then
          kind = m:isWaterCell(cx, cy) and "water" or "solid"
        elseif m:warpAtCell(cx, cy) or m:isWarpTileCell(cx, cy) then
          kind = "warp"
        elseif m.isGrassCell and m:isGrassCell(cx, cy) then
          kind = "grass"
        else
          kind = "open"
        end
        plan[cy * w + cx] = kind
      end
    end
    S.plan = plan
  end

  -- ------- moving between maps

  local function enterMap(index)
    S.i = ((index - 1) % #ids) + 1
    local id = mapId()
    local ok, err = pcall(function() U.teleport(game, id, 1, 1, "down") end)
    if not ok then
      S.map, S.plan = nil, nil
      say("could not enter %s (%s)", id, tostring(err))
      U.log(("SKIP   %s -- could not enter (%s)"):format(id, tostring(err)))
      return
    end
    S.map = game.overworld.map
    buildPlan()
    bakeTiles()
    -- the middle of the map, which is where the furniture tends to be
    S.cx = math.floor(S.map.widthCells / 2)
    S.cy = math.floor(S.map.heightCells / 2)
    say("%s -- %dx%d cells", id, S.map.widthCells, S.map.heightCells)
    U.log(("MAP    %s (%d/%d) %dx%d cells"):format(id, S.i, #ids,
          S.map.widthCells, S.map.heightCells))
  end

  -- ------- the frame
  --
  -- The driver harness turns the frame cap off (a scripted run is not
  -- paced), so each step is held to a 60th of a second by hand.
  local lastT = love.timer.getTime()
  local function step(n)
    for _ = 1, (n or 1) do
      local rest = (1 / 60) - (love.timer.getTime() - lastT)
      if rest > 0 then love.timer.sleep(rest) end
      lastT = love.timer.getTime()
      U.wait(1)
    end
  end

  local function shoot(withHud)
    -- the plan being away is part of what a panel shot IS, or the two write
    -- one file twice and whichever came last is the only one kept
    local tag = ""
    if withHud then tag = S.showPlan and "_panel" or "_panel_noplan" end
    local name = ("%s_x%d_y%d%s"):format(mapId():lower(), S.cx, S.cy, tag)
    local path = ("%s/%s.png"):format(DIR, name)
    S.shooting = not withHud
    game.capturePath = path
    for _ = 1, 120 do
      if not game.capturePath then break end
      step(1)
    end
    step(2)
    S.shooting = false
    local f = io.open(path, "rb")
    if f then
      f:close()
      say("shot %s.png", name)
      U.log("SHOT   " .. path)
    else
      say("screenshot did not reach disk: %s", path)
    end
  end

  -- Stand the player on the tile, so the world behind the panel is looking
  -- at the thing about to be voxelized. The tile itself is usually SOLID --
  -- a counter, a shelf, a house -- so the walk of shame outwards: the
  -- nearest walkable cell to it, searched in rings, which is where a player
  -- would have to stand to see it anyway.
  local function standHere()
    local m = S.map
    if not m then return end
    for r = 0, 6 do
      for dy = -r, r do
        for dx = -r, r do
          if math.max(math.abs(dx), math.abs(dy)) == r then
            local x, y = S.cx + dx, S.cy + dy
            if m:inBounds(x, y) and m:isWalkableCell(x, y) then
              game.overworld.player.cellX = x
              game.overworld.player.cellY = y
              say("standing at %d,%d", x, y)
              return
            end
          end
        end
      end
    end
    say("nowhere walkable within 6 cells of %d,%d", S.cx, S.cy)
  end

  -- ------- the keys

  local function shifted()
    return love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")
  end

  local function moveCursor(dx, dy)
    local m = S.map
    if not m then return end
    local n = shifted() and 5 or 1
    S.cx = math.max(0, math.min(m.widthCells - 1, S.cx + dx * n))
    S.cy = math.max(0, math.min(m.heightCells - 1, S.cy + dy * n))
  end

  local function handle(key)
    if key == "left" then moveCursor(-1, 0) return true end
    if key == "right" then moveCursor(1, 0) return true end
    if key == "up" then moveCursor(0, -1) return true end
    if key == "down" then moveCursor(0, 1) return true end
    if key == "[" then post("map", shifted() and -10 or -1) return true end
    if key == "]" then post("map", shifted() and 10 or 1) return true end
    if key == "c" or key == "return" or key == "kpenter" then
      copyPrompt()
      return true
    end
    if key == "z" then
      S.zoom = math.max(3, math.min(21, S.zoom + (shifted() and 2 or -2)))
      return true
    end
    if key == "g" then
      S.planMode = (S.planMode % #PLAN_MODES) + 1
      say("plan: %s", PLAN_MODES[S.planMode])
      return true
    end
    -- The plan covers most of the window, and the thing UNDER it is the game
    -- -- the tile standing up in 3D, which is what the voxelizing is for.
    -- With the plan away, the panel still carries the coordinates, the inset
    -- and the button, so a tile can still be copied while looking at it.
    if key == "m" then
      S.showPlan = not S.showPlan
      say("plan %s", S.showPlan and "shown" or "hidden -- the game is under it")
      return true
    end
    if key == "t" then standHere() return true end
    if key == "y" then post("shot", shifted() and "hud" or nil) return true end
    if key == "l" then
      if #S.copied == 0 then
        U.log("nothing copied yet")
      else
        for i, t in ipairs(S.copied) do U.log(("%3d  %s"):format(i, t)) end
      end
      say("%d prompt%s printed to the console", #S.copied,
          #S.copied == 1 and "" or "s")
      return true
    end
    if key == "f1" then S.legend = not S.legend return true end
    if key == "escape" then S.quit = true return true end
    return false
  end

  local innerKey = love.keypressed
  function love.keypressed(key, scancode, isrepeat)
    local ok, claimed = pcall(handle, key)
    if ok and claimed then return end
    if not ok then U.log("key error: " .. tostring(claimed)) end
    if innerKey then return innerKey(key, scancode, isrepeat) end
  end

  -- The mouse is the reason this tool is faster than counting cells: click
  -- the bookshelf, read the coordinates back off the panel, copy. Both hit
  -- tests read rectangles the draw left behind, so what is clickable is
  -- exactly what was drawn -- no second copy of the layout to drift.
  local innerMouse = love.mousepressed
  function love.mousepressed(x, y, button, istouch, presses)
    if button == 1 then
      local b = S.buttonRect
      if b and x >= b[1] and y >= b[2] and x <= b[1] + b[3]
         and y <= b[2] + b[4] then
        copyPrompt()
        return
      end
      local r = S.planRect
      if r and S.map and x >= r.x and y >= r.y and x <= r.x + r.w
         and y <= r.y + r.h then
        S.cx = math.max(0, math.min(S.map.widthCells - 1,
                                    math.floor((x - r.x) / r.cell)))
        S.cy = math.max(0, math.min(S.map.heightCells - 1,
                                    math.floor((y - r.y) / r.cell)))
        return
      end
    end
    if innerMouse then
      return innerMouse(x, y, button, istouch, presses)
    end
  end

  -- ------- the overlay

  local font = love.graphics.newFont(13)
  local smallFont = love.graphics.newFont(11)
  local bigFont = love.graphics.newFont(16)

  local function drawPlan(x, y, w, h)
    local plan = S.plan
    S.planRect = nil
    if not plan then return end
    local g = love.graphics
    local cell = math.min(w / plan.w, h / plan.h)
    if cell < 1 then cell = 1 end
    local pw, ph = plan.w * cell, plan.h * cell
    local ox, oy = x + (w - pw) / 2, y + (h - ph) / 2
    S.planRect = { x = ox, y = oy, w = pw, h = ph, cell = cell }

    g.setColor(0, 0, 0, 0.55)
    g.rectangle("fill", ox - 4, oy - 4, pw + 8, ph + 8)

    local mode = PLAN_MODES[S.planMode or 1]
    if S.tiles and mode ~= "grid" then
      g.setColor(1, 1, 1, 1)
      g.draw(S.tiles, ox, oy, 0, pw / S.tiles:getWidth(),
             ph / S.tiles:getHeight())
    end
    if mode ~= "tiles" then
      local alpha = (mode == "grid" or not S.tiles) and 1 or 0.22
      for cy = 0, plan.h - 1 do
        for cx = 0, plan.w - 1 do
          local kind = plan[cy * plan.w + cx]
          local c = CELL_COLOUR[kind]
          if c and not (alpha < 1 and kind == "open") then
            g.setColor(c[1], c[2], c[3], alpha)
            g.rectangle("fill", ox + cx * cell, oy + cy * cell, cell, cell)
          end
        end
      end
    end

    local ow = game.overworld
    if ow and ow.player then
      g.setColor(1, 1, 1, 0.8)
      g.circle("fill", ox + (ow.player.cellX + 0.5) * cell,
               oy + (ow.player.cellY + 0.5) * cell, math.max(2, cell * 0.4))
    end

    -- The cursor, with crosshair arms out to the edges of the plan. On a
    -- route the cell is three pixels across and a box round it is invisible;
    -- the arms are what actually says WHICH one is selected.
    local cx, cy = ox + S.cx * cell, oy + S.cy * cell
    g.setColor(1, 0.85, 0.2, 0.35)
    g.setLineWidth(1)
    g.line(ox, cy + cell / 2, ox + pw, cy + cell / 2)
    g.line(cx + cell / 2, oy, cx + cell / 2, oy + ph)
    g.setColor(1, 0.85, 0.2, 1)
    g.setLineWidth(2)
    g.rectangle("line", cx - 1, cy - 1, cell + 2, cell + 2)
    g.setLineWidth(1)
    g.setColor(1, 1, 1, 1)
  end

  -- The tile itself, magnified. The whole judgement this tool supports is
  -- "is THAT the drawing I mean to voxelize", and at plan scale a cell is a
  -- few pixels. Drawn as a scissored blow-up of the same baked canvas rather
  -- than a second render of the map: one bake, one truth.
  local function drawInset(x, y, size)
    local g = love.graphics
    g.setColor(0, 0, 0, 0.7)
    g.rectangle("fill", x - 3, y - 3, size + 6, size + 6)
    if not (S.tiles and S.map) then return end
    local span = S.zoom                       -- cells across the inset
    local pxPerCell = S.tiles:getWidth() / S.map.widthCells
    local mag = size / (span * pxPerCell)
    -- the top-left canvas pixel the inset starts at, so the cursor's cell
    -- sits in the middle of it
    local sx = (S.cx + 0.5 - span / 2) * pxPerCell
    local sy = (S.cy + 0.5 - span / 2) * pxPerCell
    g.setScissor(x, y, size, size)
    g.setColor(1, 1, 1, 1)
    g.draw(S.tiles, x - sx * mag, y - sy * mag, 0, mag, mag)
    g.setScissor()
    local cell = size / span
    local mx = x + size / 2 - cell / 2
    local my = y + size / 2 - cell / 2
    g.setColor(1, 0.85, 0.2, 1)
    g.setLineWidth(2)
    g.rectangle("line", mx, my, cell, cell)
    g.setLineWidth(1)
    g.setColor(1, 1, 1, 1)
  end

  local LEGEND = {
    "arrows  move the cursor (shift x5)",
    "click   put the cursor on that tile",
    "[  ]    previous / next map (shift x10)",
    "c       COPY PROMPT  (also enter, also the button)",
    "z       zoom the inset in (shift: out)",
    "g       plan: tiles / walk grid / both",
    "m       hide the plan (the game is under it)",
    "t       stand the player on this tile",
    "y       screenshot (shift: with this panel)",
    "l       list every prompt copied so far",
    "F1      this list      escape  quit",
  }

  local function drawOverlay()
    local g = love.graphics
    local W, H = g.getDimensions()
    local panel = math.min(320, math.floor(W * 0.34))

    g.setColor(0, 0, 0, 0.72)
    g.rectangle("fill", 0, 0, panel, H)

    local y = 10
    g.setFont(bigFont)
    g.setColor(1, 1, 1, 1)
    g.print(mapId(), 10, y)
    y = y + 22
    g.setFont(font)
    g.setColor(0.72, 0.78, 0.9, 1)
    g.print(("map %d / %d"):format(S.i, #ids), 10, y)
    y = y + 20

    -- the coordinates, big, because they are what the prompt is made of and
    -- what gets read back against the game
    g.setFont(bigFont)
    g.setColor(1, 0.85, 0.2, 1)
    g.print(("tile  (%d,%d)"):format(S.cx, S.cy), 10, y)
    y = y + 24
    g.setFont(smallFont)
    g.setColor(0.8, 0.8, 0.85, 1)
    local m = S.map
    if m then
      local okTile, tile = pcall(m.cellTile, m, S.cx, S.cy)
      local kind = S.plan and S.plan[S.cy * S.plan.w + S.cx] or "?"
      -- tileset and tile id are not in the prompt, and are here anyway: they
      -- are what the skill's data files are keyed by, so this is the line
      -- that tells you two different-looking cells are the same drawing
      g.print(("tileset %s   tile %s   %s")
              :format(tostring(m.def and m.def.tileset),
                      okTile and tostring(tile) or "?", kind), 10, y)
      y = y + 16
      g.print(("block (%d,%d)"):format(math.floor(S.cx / 2),
                                       math.floor(S.cy / 2)), 10, y)
      y = y + 18
    end

    -- the inset
    local inset = math.min(panel - 20, 180)
    drawInset(10, y, inset)
    y = y + inset + 14

    -- THE BUTTON. A real rectangle with a real hit test, not a hint that a
    -- key exists: the tool is used with one hand on the mouse walking a map,
    -- and reaching for the keyboard per tile is the whole friction.
    local bw, bh = panel - 20, 34
    S.buttonRect = { 10, y, bw, bh }
    local mx, my = love.mouse.getPosition()
    local hot = mx >= 10 and my >= y and mx <= 10 + bw and my <= y + bh
    g.setColor(hot and 0.30 or 0.18, hot and 0.62 or 0.42, hot and 0.34 or 0.22,
               1)
    g.rectangle("fill", 10, y, bw, bh, 5, 5)
    g.setColor(0.45, 0.9, 0.55, 1)
    g.rectangle("line", 10, y, bw, bh, 5, 5)
    g.setFont(font)
    g.setColor(1, 1, 1, 1)
    local label = "COPY PROMPT"
    g.print(label, 10 + (bw - font:getWidth(label)) / 2, y + 9)
    y = y + bh + 12

    -- what it will copy, shown in full and wrapped: the prompt is the
    -- product, so it is never hidden behind the button that makes it
    g.setFont(smallFont)
    g.setColor(0.65, 0.75, 0.85, 1)
    local preview = promptFor(mapId(), S.cx, S.cy)
    local _, lines = smallFont:getWrap(preview, panel - 20)
    for _, l in ipairs(lines) do
      g.print(l, 10, y)
      y = y + 13
    end
    y = y + 8

    g.setColor(0.55, 0.9, 0.6, 1)
    local _, outLines = smallFont:getWrap(
      ("%d copied  ->  %s"):format(#S.copied, OUT), panel - 20)
    for _, l in ipairs(outLines) do
      g.print(l, 10, y)
      y = y + 13
    end
    y = y + 5

    if S.msg ~= "" then
      g.setColor(1, 0.9, 0.6, 1)
      local _, msgLines = smallFont:getWrap(S.msg, panel - 20)
      for _, l in ipairs(msgLines) do
        g.print(l, 10, y)
        y = y + 13
      end
      y = y + 6
    end

    if S.legend then
      y = y + 6
      g.setColor(0.75, 0.8, 0.9, 1)
      for _, l in ipairs(LEGEND) do
        g.print(l, 10, y)
        y = y + 14
      end
    end

    if S.showPlan then
      local px = panel + 12
      drawPlan(px, 12, W - px - 12, H - 24)
    else
      -- and with nothing drawn there, nothing there is clickable: the mouse
      -- reads the rectangle the draw leaves behind, so clearing it is what
      -- stops a click on the game moving the cursor
      S.planRect = nil
    end
    g.setColor(1, 1, 1, 1)
  end

  local innerDraw = love.draw
  function love.draw()
    if innerDraw then innerDraw() end
    if S.shooting then return end
    local g = love.graphics
    g.push("all")
    g.origin()
    local ok, err = pcall(drawOverlay)
    g.pop()
    if not ok and not S.drawWarned then
      S.drawWarned = true
      U.log("overlay draw failed: " .. tostring(err))
    end
  end

  -- ------- the session

  U.log("tile picker -- " .. #ids .. " maps")
  for _, l in ipairs(LEGEND) do U.log("  " .. l) end
  U.log("prompts append to " .. OUT)

  local start = os.getenv("TILE_START")
  local at = 1
  if start and start ~= "" then
    for i, id in ipairs(ids) do
      if id == start then at = i break end
    end
  end
  enterMap(at)

  local function dispatch(job)
    if job.cmd == "map" then
      enterMap(S.i + job.arg)
    elseif job.cmd == "shot" then
      shoot(job.arg == "hud")
    end
  end

  -- One frame of the session: the next thing a key asked for, or a frame of
  -- standing still while the game runs underneath. Map changes and captures
  -- go through the queue rather than happening inside the key handler --
  -- both of them bind canvases, and doing that from inside love.keypressed
  -- is doing it inside the engine's own frame.
  local function pump(frames)
    for _ = 1, (frames or 1) do
      local job = table.remove(queue, 1)
      if job then dispatch(job) else step(1) end
      if S.quit then return end
    end
  end

  -- ------- TILE_SELFTEST=1: the same session, with the keys pressed for you
  --
  -- Not a substitute for sitting in front of it -- the thing this tool is
  -- judged on is whether a bookshelf is recognisable in the inset -- but it
  -- proves the session starts, both wraps hold, every key path runs, a map
  -- change re-bakes, and a prompt reaches the clipboard and the file. Which
  -- is the whole of what can fail without a person noticing.
  if truthy(os.getenv("TILE_SELFTEST")) then
    OUT = DIR .. "/selftest_prompts.txt"
    local function press(key, frames)
      local ok, err = pcall(handle, key)
      if not ok then U.log("SELFTEST key " .. key .. " failed: " .. tostring(err)) end
      pump(frames or 20)
    end
    press("right")
    press("down")
    press("left")
    press("up")
    press("c")                -- a prompt, copied
    press("z")                -- the inset both ways
    press("z")
    press("g")                -- each way of drawing the plan
    press("g")
    press("g")
    press("t")                -- stand on it
    press("m")                -- the plan away, and back -- with a shot of
    post("shot", "hud")       -- the window without it, which is the only
    pump(240)                 -- thing that proves the panel stands alone
    press("m")
    press("]", 90)            -- the next map, which re-bakes
    press("c")                -- and a prompt from there
    press("[", 90)            -- back
    press("y", 240)           -- a screenshot of the world
    post("shot", "hud")       -- and one WITH the panel, which is the only
    pump(240)                 -- thing that proves the overlay draws
    press("l")                -- the list
    press("f1")
    -- the click paths, which the key presses above never touch
    local b = S.buttonRect
    if b then
      love.mousepressed(b[1] + 4, b[2] + 4, 1)
      pump(20)
    end
    local r = S.planRect
    if r then
      love.mousepressed(r.x + r.w * 0.5, r.y + r.h * 0.5, 1)
      pump(20)
    end
    U.log(("SELFTEST %d prompts, cursor %d,%d on %s -- %s")
          :format(#S.copied, S.cx, S.cy, mapId(), tostring(S.msg)))
    press("escape", 5)
    S.quit = true
  end

  while not S.quit do pump(1) end

  -- Hand the install back the way it was found.
  if S.tiles then pcall(S.tiles.release, S.tiles) end
  love.draw = innerDraw
  love.keypressed = innerKey
  love.mousepressed = innerMouse
  if wasRung then pcall(Pipelines.setLevel, "voxel", wasRung) end

  if #S.copied > 0 then
    U.log(("-- %d prompt%s this session"):format(#S.copied,
          #S.copied == 1 and "" or "s"))
    for i, t in ipairs(S.copied) do U.log(("%3d  %s"):format(i, t)) end
  end
  U.log("done -- " .. OUT)
end

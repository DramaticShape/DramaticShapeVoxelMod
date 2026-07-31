-- Render targets measured in real framebuffer PIXELS.
--
-- love.graphics.newCanvas defaults its `dpiscale` to
-- love.graphics.getDPIScale(), so on a highdpi surface the texture it
-- allocates is NOT the size it was asked for -- newCanvas(2752, 2064) on a
-- panel reporting a DPI scale of 2 asks the driver for 5504x4128.
--
-- Every target in this mod is already counted in framebuffer pixels: the
-- free-roam scene canvas is love.graphics.getPixelDimensions() (see
-- sceneSize in main.lua, and the 1/dpi blit the engine composites it with),
-- the shadow map is a resolution rung, the blur pairs are the size of the
-- image they were handed. Letting LOVE scale them a second time is the DPI
-- factor applied twice.
--
-- On an iPad at DPI scale 2 that took the scene canvas past the driver's
-- maximum texture size. newCanvas threw, beginScene returned false,
-- drawWorld returned nil -- and returning nil IS the 2D fallback, so the
-- engine quietly kept drawing the flat world. Every switch said the mode was
-- on (the OPTIONS row, the mod manager, the hotkey) and nothing ever
-- appeared. Desktop never saw it: dpiscale is 1 there.
--
-- getWidth()/getHeight() always report the REQUESTED size, so pinning the
-- scale changes only the resolution of the target -- no geometry, no UV, no
-- compositing scale anywhere moves, and the FX overlay's projected pixel
-- coordinates finally land on the pixels they name. The engine's own render
-- targets do this for the same reason (src/render/PixelCanvas.lua).

-- the mod namespace (see main.lua)
local V = ...

local PixelCanvas = {}

-- One framebuffer pixel per w/h, always. Returns ok, canvas -- the shape the
-- pcall-guarded call sites already branch on, so a driver that refuses the
-- allocation still degrades instead of erroring.
function PixelCanvas.new(w, h)
  return pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
end

return PixelCanvas

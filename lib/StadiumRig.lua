-- STADIUM battles: posing a skeleton and skinning it, on the CPU.
--
-- One instance of this is one Pokemon standing on the map -- the meshes it
-- draws through and the scratch space its pose is computed in. The MODEL
-- (geometry, bones, animations, textures) is shared and read-only; this is
-- everything about it that is per-Pokemon and changes every frame.
--
-- ------- why the CPU
--
-- Because these models are tiny and the mod's shader already exists. A
-- battle model is 674 vertices on average and 1311 at the worst, of which
-- exactly two are on screen at a time -- so skinning them by hand costs
-- about two thousand vertex transforms a frame, which is less than the
-- grass pass does on an empty route. What it buys is that the finished
-- vertices go into Voxel3D's OWN vertex format, through Voxel3D's OWN
-- shader, and therefore get every single thing the rest of the diorama
-- gets for free: the depth buffer decides what is in front of what, the
-- sun pass throws a real shadow of the actual pose, the hour's tint lands
-- on it, the hit flash flattens it, and the tilt-shift and the
-- depth-of-field see it as part of the picture. A GPU skinning path would
-- have needed a second shader that then had to re-implement all of that,
-- and a second shadow shader beside it.
--
-- It is also what makes the FORMAT work. Every vertex in the Stadium set is
-- rigidly bound to ONE bone with weight 1 (model_extract/README.md), so
-- skinning is a single matrix multiply per vertex with no blend -- and the
-- per-vertex `shade` Voxel3D wants, which no glTF has, is computed here
-- from the bone-local normal.
--
-- ------- the two matrix chains
--
-- The game keeps bone scale OUT of the matrix chain (func_800143C0): scale
-- accumulates in its own stack, a bone's local translation is
-- pre-multiplied by its parent's accumulated scale, and a bone's own
-- accumulated scale is applied to the finished matrix only at draw time.
-- glTF cannot express that -- its node scale propagates to children -- and
-- the reference export works around it by splitting every bone into two
-- nodes.
--
-- Here it falls out naturally, as two arrays:
--
--   pivot   rotation and translation only. This is what a CHILD inherits,
--           and it is a pure rotation, which is also why the normals are
--           transformed with it rather than with the draw matrix.
--   draw    the same matrix with the bone's accumulated scale applied on
--           the right, which is the one vertices go through.
--
-- Folding the scale into the chain instead is the obvious mistake and it
-- applies every ancestor's scale once per generation. It is caught by the
-- suite: tools/stadium_pack.py measures the bind pose with this exact walk
-- and its answer matches the verified glTF export on all 151 species.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Voxel3D = V.require("Voxel3D")
local StadiumPack = V.require("StadiumPack")

local StadiumRig = {}
StadiumRig.__index = StadiumRig

local sin, cos, floor = math.sin, math.cos, math.floor

-- binary angle (32768 = pi) to radians
local ANG = math.pi / 32768

-- ------- how a surface is lit
--
-- Voxel3D shades a face by its DIRECTION rather than by a light uniform:
-- every terrain and character mesh in this mode carries a per-vertex
-- `shade` baked from which way its face points, and the shadow map
-- multiplies on top of that (see Voxel3D.FACE_SHADE). A skinned model has
-- no fixed faces to bake, so the same answer is computed per vertex from
-- the posed normal -- and these four numbers are FACE_SHADE's own six
-- values, fitted:
--
--     +Y up 1.00   -Y down 0.55   +X east 0.84   -X west 0.72
--     +Z south 0.90   -Z north 0.68
--
-- so a Pokemon's flank catches the same southeastern sun the roof of the
-- house behind it does, and the two read as being in one picture.
local SHADE_BASE = 0.7725
local SHADE_X = 0.06
local SHADE_Y = 0.225
local SHADE_Z = 0.11

-- ------- an instance

-- `model` is a StadiumPack model. Returns nil where meshes cannot be made,
-- which is the same "no 3D" answer every other GPU object in this mod gives.
function StadiumRig.new(model)
  if not (model and model.prims) then return nil end
  if not (love.graphics and love.graphics.newMesh) then return nil end

  local self = setmetatable({
    model = model,
    -- The two chains, flat: twelve numbers a bone, row-major 3x4.
    --
    -- Named with the M rather than `pivot` and `draw` because an instance
    -- field called `draw` shadows the DRAW METHOD through __index, and the
    -- failure that causes is a nasty one: the shadow pass calls caster()
    -- and keeps working, so a Pokemon casts a perfect animated shadow onto
    -- ground it is not standing on.
    pivotM = {},
    drawM = {},
    -- the accumulated scale, which is the third thing the game's own walk
    -- carries and neither matrix can hold
    accX = {}, accY = {}, accZ = {},
    parts = {},
    -- what the pose walk last answered, so a frame that neither moved the
    -- animation nor turned the model can skip the whole thing
    poseKey = nil,
  }, StadiumRig)

  -- One mesh per primitive: a primitive is already "the triangles sharing
  -- one texture", which is exactly one draw call's worth.
  --
  -- "dynamic" rather than "static": every vertex is rewritten every frame
  -- the pose changes, which is what the usage hint exists to say.
  for i, prim in ipairs(model.prims) do
    local rows = {}
    local uv = prim.uv
    for k = 1, prim.vertCount do
      -- position and shade are filled by skin(); the texture coordinates
      -- never change, so they are written once here
      rows[k] = { 0, 0, 0, uv[k * 2 - 1], uv[k * 2], 1 }
    end
    local ok, mesh = pcall(love.graphics.newMesh, Voxel3D.FORMAT, rows,
                           "triangles", "dynamic")
    if not ok then return nil end
    pcall(mesh.setVertexMap, mesh, prim.index)
    self.parts[i] = { mesh = mesh, rows = rows, prim = prim }
  end
  return self
end

function StadiumRig:release()
  for _, part in ipairs(self.parts or {}) do
    if part.mesh and part.mesh.release then
      pcall(part.mesh.release, part.mesh)
    end
  end
  self.parts = {}
end

-- ------- sampling one track
--
-- `c` is the pack's own fold: a bare number when the component holds still
-- for the whole animation, or one value a frame when it does not. Two frame
-- indices and a blend come in because the caller has already resolved what
-- "between frame 12 and 13, three tenths of the way" means for THIS
-- animation's looping.

-- One component at one frame.
--
-- ------- why there is no interpolation here
--
-- There used to be, and it was the cause of a real glitch: bones snapping to
-- an upside-down pose for a frame, arms turning inside out for a few.
--
-- These streams are not keyframes. They carry ONE VALUE PER FRAME at 30 Hz
-- -- the sampler they come out of indexes them by frame number and clamps
-- (`min(frame, count - 1)`), with no times and nothing to interpolate
-- between. The game plays them a frame at a time, and at 60 Hz each pose
-- simply holds for two.
--
-- Blending between consecutive entries therefore invented motion that was
-- never authored, and for ROTATION it invented the wrong motion. These are
-- Euler triples, and a Euler triple is not a direction you can walk along:
-- interpolating (0, 20976, 32736) toward (0, -19936, -5904) component by
-- component passes through orientations that are nothing like either end --
-- which is precisely a bone flipping over and back inside one frame.
-- Slerping proper quaternions would fix the direction, but there is still
-- nothing to slerp TOWARD: the next entry is the next frame, not a keyframe
-- some distance away, and holding it is what the source does.
local function sampleAt(c, i)
  if type(c) == "number" then return c end
  return c[i]
end

-- ------- the pose
--
-- `anim` is an index into model.anims (or nil for the bind pose), `frame` a
-- FLOAT frame in that animation's own 30 Hz timeline, and `wrap` whether
-- the far end joins back to loopStart (a standby loop) or holds on the last
-- frame (a faint).
function StadiumRig:pose(anim, frame, wrap)
  local model = self.model
  local n = model.boneCount
  local tracks = anim and StadiumPack.tracks(model, anim) or nil
  local frames = anim and model.anims[anim] and model.anims[anim].frames or 1

  -- which frame of the animation this instant shows. One frame, not two:
  -- the streams are per-frame and are stepped, not blended (see sampleAt).
  local i0 = 1
  if tracks and frames > 1 then
    local f = frame
    if f < 0 then f = 0 end
    local base = floor(f)
    if base >= frames then
      if wrap then
        -- the far end joins back to loopStart, which is where the game's own
        -- player sends the counter (func_80016FBC)
        local loop = model.anims[anim].loopStart or 0
        if loop > 0 and loop < frames then
          base = loop + (base - loop) % (frames - loop)
        else
          base = base % frames
        end
      else
        base = frames - 1                   -- a faint holds where it fell
      end
    end
    i0 = base + 1
    if i0 > frames then i0 = frames end
    if i0 < 1 then i0 = 1 end
  end

  -- The frame this animation is actually SHOWING, after the wrap or the
  -- hold, 0-based. Stashed rather than recomputed because the texture
  -- animation is sampled at the very same frame (see textures) -- in the
  -- game one counter drives both, and 73% of the paired animations in the
  -- set are the same length as each other, which is what that looks like
  -- from the outside. Two copies of this arithmetic would be two things to
  -- keep in step; one number cannot drift from itself.
  self.frameAt = i0 - 1

  local parent = model.parent
  local restT, restR, restS = model.restT, model.restR, model.restS
  local pivot, drw = self.pivotM, self.drawM
  local accX, accY, accZ = self.accX, self.accY, self.accZ

  for b = 1, n do
    local o3 = (b - 1) * 3
    local tx, ty, tz, rx, ry, rz, kx, ky, kz
    local comps = tracks and tracks[b]
    if comps then
      tx = sampleAt(comps[1], i0)
      ty = sampleAt(comps[2], i0)
      tz = sampleAt(comps[3], i0)
      rx = sampleAt(comps[4], i0)
      ry = sampleAt(comps[5], i0)
      rz = sampleAt(comps[6], i0)
      kx = sampleAt(comps[7], i0)
      ky = sampleAt(comps[8], i0)
      kz = sampleAt(comps[9], i0)
    else
      -- a bone this animation never touches keeps its rest transform
      tx, ty, tz = restT[o3 + 1], restT[o3 + 2], restT[o3 + 3]
      rx, ry, rz = restR[o3 + 1], restR[o3 + 2], restR[o3 + 3]
      kx, ky, kz = restS[o3 + 1], restS[o3 + 2], restS[o3 + 3]
    end

    local p = parent[b]
    local pax, pay, paz = 1, 1, 1
    if p > 0 then pax, pay, paz = accX[p], accY[p], accZ[p] end
    -- the parent's accumulated scale, applied to the CHILD's offset. This
    -- is the whole of what the game does instead of propagating scale.
    tx, ty, tz = tx * pax, ty * pay, tz * paz

    -- Rx * Ry * Rz in the game's own row-vector form (src/F420.c
    -- func_8000F730), written out as the rows of a 3x3
    local ax, ay, az = rx * ANG, ry * ANG, rz * ANG
    local sx, cx = sin(ax), cos(ax)
    local sy, cy = sin(ay), cos(ay)
    local sz, cz = sin(az), cos(az)
    local m11, m12, m13 = cy * cz, sx * sy * cz - cx * sz, cx * sy * cz + sx * sz
    local m21, m22, m23 = cy * sz, sx * sy * sz + cx * cz, cx * sy * sz - sx * cz
    local m31, m32, m33 = -sy, sx * cy, cx * cy

    local o = (b - 1) * 12
    if p > 0 then
      local q = (p - 1) * 12
      local a1, a2, a3, a4 = pivot[q + 1], pivot[q + 2], pivot[q + 3], pivot[q + 4]
      local b1, b2, b3, b4 = pivot[q + 5], pivot[q + 6], pivot[q + 7], pivot[q + 8]
      local c1, c2, c3, c4 = pivot[q + 9], pivot[q + 10], pivot[q + 11], pivot[q + 12]
      pivot[o + 1] = a1 * m11 + a2 * m21 + a3 * m31
      pivot[o + 2] = a1 * m12 + a2 * m22 + a3 * m32
      pivot[o + 3] = a1 * m13 + a2 * m23 + a3 * m33
      pivot[o + 4] = a1 * tx + a2 * ty + a3 * tz + a4
      pivot[o + 5] = b1 * m11 + b2 * m21 + b3 * m31
      pivot[o + 6] = b1 * m12 + b2 * m22 + b3 * m32
      pivot[o + 7] = b1 * m13 + b2 * m23 + b3 * m33
      pivot[o + 8] = b1 * tx + b2 * ty + b3 * tz + b4
      pivot[o + 9] = c1 * m11 + c2 * m21 + c3 * m31
      pivot[o + 10] = c1 * m12 + c2 * m22 + c3 * m32
      pivot[o + 11] = c1 * m13 + c2 * m23 + c3 * m33
      pivot[o + 12] = c1 * tx + c2 * ty + c3 * tz + c4
    else
      pivot[o + 1], pivot[o + 2], pivot[o + 3], pivot[o + 4] = m11, m12, m13, tx
      pivot[o + 5], pivot[o + 6], pivot[o + 7], pivot[o + 8] = m21, m22, m23, ty
      pivot[o + 9], pivot[o + 10], pivot[o + 11], pivot[o + 12] = m31, m32, m33, tz
    end

    local ex, ey, ez = pax * kx, pay * ky, paz * kz
    accX[b], accY[b], accZ[b] = ex, ey, ez
    -- the bone's own accumulated scale, on the right: it scales the axes of
    -- THIS bone's space and cannot reach the children, which is exactly the
    -- game's draw-time application
    drw[o + 1], drw[o + 2] = pivot[o + 1] * ex, pivot[o + 2] * ey
    drw[o + 3], drw[o + 4] = pivot[o + 3] * ez, pivot[o + 4]
    drw[o + 5], drw[o + 6] = pivot[o + 5] * ex, pivot[o + 6] * ey
    drw[o + 7], drw[o + 8] = pivot[o + 7] * ez, pivot[o + 8]
    drw[o + 9], drw[o + 10] = pivot[o + 9] * ex, pivot[o + 10] * ey
    drw[o + 11], drw[o + 12] = pivot[o + 11] * ez, pivot[o + 12]
  end
end

-- ------- the skin
--
-- Every vertex through its one bone's draw matrix, and its normal through
-- the same bone's pivot (a pure rotation, so the normal survives a
-- non-uniformly scaled bone -- which several species have).
--
-- `yaw` is the model matrix's own turn, and it is folded in HERE rather
-- than left to the matrix because the shade has to be computed against the
-- WORLD normal: a Pokemon turned to face its opponent has a differently lit
-- flank than one facing the camera, and the sun does not turn with it.
function StadiumRig:skin(yaw)
  local cy, sy = cos(yaw or 0), sin(yaw or 0)
  local drw, piv = self.drawM, self.pivotM
  for _, part in ipairs(self.parts) do
    local prim, rows = part.prim, part.rows
    local px, py, pz = prim.px, prim.py, prim.pz
    local nx, ny, nz = prim.nx, prim.ny, prim.nz
    local bone = prim.bone
    for k = 1, prim.vertCount do
      local o = (bone[k] - 1) * 12
      local x, y, z = px[k], py[k], pz[k]
      local row = rows[k]
      row[1] = drw[o + 1] * x + drw[o + 2] * y + drw[o + 3] * z + drw[o + 4]
      row[2] = drw[o + 5] * x + drw[o + 6] * y + drw[o + 7] * z + drw[o + 8]
      row[3] = drw[o + 9] * x + drw[o + 10] * y + drw[o + 11] * z + drw[o + 12]
      local ax, ay, az = nx[k], ny[k], nz[k]
      local wx = piv[o + 1] * ax + piv[o + 2] * ay + piv[o + 3] * az
      local wy = piv[o + 5] * ax + piv[o + 6] * ay + piv[o + 7] * az
      local wz = piv[o + 9] * ax + piv[o + 10] * ay + piv[o + 11] * az
      -- the model matrix's yaw, by hand: (x, z) turned, y untouched
      row[6] = SHADE_BASE + SHADE_X * (cy * wx + sy * wz) + SHADE_Y * wy
               + SHADE_Z * (cy * wz - sy * wx)
    end
    pcall(part.mesh.setVertices, part.mesh, rows)
  end
end

-- ------- which texture each part wears this frame
--
-- The eyes. A primitive whose display list carried geo command 0x23 with a
-- channel index has its texture REPLACED every frame from a stream of
-- texture-table indices (src/18140.c func_800176DC) -- which is how every
-- Pokemon in the game blinks, and how a confused one gets swirls. glTF has
-- no channel for that, so the .glb files carry only the first frame; the
-- pack carries the streams.
--
-- `aux` is an index into model.auxAnims (the stream set) and `frame` its
-- own frame counter, which runs independently of the skeletal one.
-- The eyes, and everything else a material swaps per frame.
--
-- Sampled at the SKELETAL animation's own frame -- the one pose() just
-- resolved -- and CLAMPED past the end of the stream rather than wrapped.
-- Both halves of that matter, and getting either wrong is visible.
--
-- The frame is the skeleton's because in the game a single counter drives
-- both; the data says so plainly, since 507 of the 691 paired animations in
-- the set have a texture animation exactly as long as the skeletal one it
-- rides with.
--
-- The clamp is what the game's own sampler does (func_80017540 indexes the
-- stream and holds the last entry past its end), and it is the whole
-- difference between a blink and a twitch. Rattata's standby loop is forty
-- frames and its blink is FIVE -- `6 8 7 8 6`, open through closed and back.
-- Wrapped on the blink's own length that plays six times a second, which is
-- what it looked like. Clamped, the eye blinks once at the top of the loop
-- and stays open for the remaining thirty-five frames, so it blinks about
-- once a second and a half.
function StadiumRig:textures(aux)
  local model = self.model
  local anim = aux and model.auxAnims and model.auxAnims[aux] or nil
  local frame = self.frameAt or 0
  for _, part in ipairs(self.parts) do
    local prim = part.prim
    local index = prim.tex
    if anim and prim.texAnim and prim.texAnim >= 0 and prim.texMap then
      local stream = anim.channels[prim.texAnim + 1]
      local n = stream and #stream or 0
      if n > 0 then
        local at = frame + 1
        if at > n then at = n end
        if at < 1 then at = 1 end
        local mapped = prim.texMap[stream[at]]
        if mapped then index = mapped end
      end
    end
    part.texture = StadiumPack.image(model, index)
  end
end

-- ------- the draw
--
-- `model` here is the MODEL MATRIX -- where this Pokemon stands, how big
-- and which way round -- and `sunModel` the transform the shadow pass drew
-- it with, which for these is the same matrix (unlike a character's leaning
-- card; see Voxel3D.draw).
--
-- Seams off for the whole of it: the voxel wireframe draws the integer
-- planes of a mesh's own model space, and these vertices are in the N64's
-- own units where an integer plane means nothing (see VoxelGrid). Glass off
-- for the same reason the sprite passes turn it off -- the mask's
-- coordinates belong to the tileset atlas, not to a Pokemon's texture.
function StadiumRig:draw(matrix, pull)
  Voxel3D.seams(false)
  Voxel3D.glass(false)
  local additive = nil
  for _, part in ipairs(self.parts) do
    if part.prim.additive then
      -- held back to a second pass so the flames composite over the body
      -- rather than depth-fighting it
      additive = additive or {}
      additive[#additive + 1] = part
    elseif part.texture then
      Voxel3D.draw(part.mesh, part.texture, matrix, pull)
    end
  end
  if additive then
    Voxel3D.blend("add")
    for _, part in ipairs(additive) do
      if part.texture then
        Voxel3D.draw(part.mesh, part.texture, matrix, pull)
      end
    end
    Voxel3D.blend(nil)
  end
  Voxel3D.glass(true)
  Voxel3D.seams(true)
end

-- The same geometry as the SUN sees it: no camera-ward pull (a trick for
-- the view's own depth buffer, which would drag a shadow off its owner) and
-- through the shadow pass's own draw call. The generated flame prims are
-- skipped -- a fire casts light, not a shadow.
function StadiumRig:caster(shadowMap, matrix)
  for _, part in ipairs(self.parts) do
    if part.texture and not part.prim.additive then
      shadowMap.draw(part.mesh, part.texture, matrix)
    end
  end
end

return StadiumRig

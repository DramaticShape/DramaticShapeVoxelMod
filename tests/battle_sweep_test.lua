local source = assert(loadfile("lib/BattleSweep.lua"))
local Sweep = source({})

assert(Sweep.DURATION == 0.7, "battle sweep duration")

local function near(a, b, epsilon, message)
  assert(math.abs(a - b) <= (epsilon or 1e-6),
         ("%s: %.8f ~= %.8f"):format(message or "value", a, b))
end

local from = {
  eye = { 0, 144, 0 },
  focus = { 0, 0, 0 },
  fov = math.rad(53),
  curve = 0.001,
}
local to = {
  eye = { 100, 40, 120 },
  focus = { 20, 4, 30 },
  fov = math.rad(18),
  curve = 0,
}

local start = Sweep.camera(from, to, 0)
local finish = Sweep.camera(from, to, 1)
for i = 1, 3 do
  near(start.eye[i], from.eye[i], 1e-6, "start eye")
  near(start.focus[i], from.focus[i], 1e-6, "start focus")
  near(finish.eye[i], to.eye[i], 1e-6, "finish eye")
  near(finish.focus[i], to.focus[i], 1e-6, "finish focus")
end
near(start.fov, from.fov, 1e-6, "start fov")
near(finish.fov, to.fov, 1e-6, "finish fov")
near(start.curve, from.curve, 1e-6, "start curve")
near(finish.curve, to.curve, 1e-6, "finish curve")

local middle = Sweep.camera(from, to, 0.5)
assert(middle.eye[2] > (from.eye[2] + to.eye[2]) / 2,
       "sweep lifts above the straight path")
assert(Sweep.ease(0) == 0 and Sweep.ease(1) == 1, "ease endpoints")

print("battle sweep: all checks passed")

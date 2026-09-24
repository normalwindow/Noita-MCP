-- Direct player control ("hijack") levers.
--
-- Stage-0 established that the official input path cannot be forged: writing
-- ControlsComponent fields has no effect, because the engine overwrites them from
-- real input outside any hook a mod can reach. This module takes a different
-- route -- it stops trying to be the input and instead acts on the state the
-- input feeds: velocity, transform, gravity, mass, and the movement gates.
--
-- Everything here is a *lever* with a matching release:
--   * `engage` records the pristine values (and whether the component was
--     enabled) so `disengage` puts the player back exactly as they were;
--   * levers are re-applied every frame from OnWorldPreUpdate, because the
--     engine rewrites these fields every frame just like the controls;
--   * actions are time-boxed so a test can never leave the player flying off.
--
-- The important unknown is whether the engine *observes* our writes before it
-- overwrites them. For controls the answer was no; for physics it may be yes,
-- because the collision/integration systems read these values. `lever_experiment`
-- measures that instead of assuming it.

lever = lever or {}

local active = nil       -- current engagement (or nil)
local snapshot = nil     -- pristine values captured at engage time

-- Movement-relevant fields, grouped by component.
--
-- WHICH COMPONENT HOLDS THE VELOCITY VECTOR -- measured, because guessing it cost a lot.
--
-- The player carries TWO components with a field called `mVelocity`, and they are different
-- things:
--
--   CharacterDataComponent.mVelocity   a PAIR   (0, 60)  -- the vector the engine integrates
--   VelocityComponent.mVelocity        a SCALAR (0)      -- not a vector at all
--
-- Writing {x, y} into the scalar one does nothing, quietly. Because VELOCITY_FIELDS listed
-- the VelocityComponent, every velocity-based movement in this project wrote to the scalar
-- and had no effect -- which is why direct motion control appeared to work once (measured
-- 126px) and then could not be reproduced. Both were real: the working case wrote to the
-- character component.
--
-- Measured side by side in one live run, same 220px/s for 50 frames:
--   VelocityComponent.mVelocity        dx =   0.0   (moved=false)
--   CharacterDataComponent.mVelocity   dx = 171.4   (moved=true)
--
-- So the vector belongs in CHAR_FIELDS. VELOCITY_FIELDS keeps the scalar physics knobs,
-- which are real fields on that component and are still worth being able to set, but the
-- velocity itself is no longer written there.
local CHAR_FIELDS = {
  "mVelocity", "gravity", "mass", "dont_update_velocity_and_xform",
  "mFlyingTimeLeft", "fly_time_max", "flying_needs_recharge",
  "fly_recharge_spd", "fly_recharge_spd_ground", "platforming_type",
  "is_on_ground", "send_transform_update_message",
}
-- Scalars on VelocityComponent. `mVelocity` is deliberately NOT here: it is a scalar on this
-- component and writing a pair to it is a silent no-op.
local VELOCITY_FIELDS = { "mPrevVelocity", "gravity_y", "gravity_x",
  "air_friction", "updates_velocity", "affect_physics_bodies", "mass" }

-- Reads a component field, preserving its shape.
--
-- Scalars are returned as scalars (NOT wrapped in a table). This matters: an
-- earlier version wrapped booleans as {value=false, shape="scalar"} and the
-- writer had to unwrap them, which it got wrong for a field whose shape tag went
-- missing -- it took the vector branch and passed a table where the engine
-- wanted a boolean. Returning the value unchanged removes that whole class of
-- bug, and the writer only has to distinguish "two numbers" from "one value".
local function read(comp, field)
  if not comp then return nil end
  local ok, a, b = pcall(ComponentGetValue2, comp, field)
  if not ok or a == nil then return nil end
  if type(a) == "table" then return { x = a[1], y = a[2] } end
  if b ~= nil then return { x = a, y = b } end
  return a                     -- number, boolean, or string: untouched
end

-- Writes a field. Accepts either a plain value or {x=,y=} for a pair, and also
-- tolerates the {value=..., shape=...} form so callers can pass explicit specs.
local function write(comp, field, v)
  if not comp or v == nil then return false end

  local vt = type(v)
  if vt == "table" then
    -- {x,y} pair, however it was expressed
    if v.x ~= nil and v.y ~= nil then
      return (pcall(ComponentSetValue2, comp, field, v.x, v.y))
    end
    -- explicit single-value spec
    if v.value ~= nil then
      return (pcall(ComponentSetValue2, comp, field, v.value))
    end
    return false
  end

  -- plain scalar (number / boolean / string)
  return (pcall(ComponentSetValue2, comp, field, v))
end

local function comps()
  local p = ser.player()
  if not p then return nil end
  return p,
    ser.comp(p, "CharacterDataComponent"),
    ser.comp(p, "VelocityComponent"),
    ser.comp(p, "ControlsComponent"),
    ser.comp(p, "PhysicsBodyComponent")
end

-- ---------------------------------------------------------------- read state

function lever.state()
  local p, ch, vel, ctl, body = comps()
  if not p then return { ok = false, error = "no player" } end

  local out = {
    entity = p,
    frame = GameGetFrameNum(),
    has_character_data = ch ~= nil,
    has_velocity = vel ~= nil,
    has_controls = ctl ~= nil,
    has_physics_body = body ~= nil,
    character = {},
    velocity = {},
    physics = {},
  }
  local function dump(dst, comp, fields)
    for _, f in ipairs(fields) do dst[f] = read(comp, f) end
  end
  dump(out.character, ch, CHAR_FIELDS)
  dump(out.velocity, vel, VELOCITY_FIELDS)
  if body then
    for _, f in ipairs({ "is_enabled", "is_static", "is_kinematic", "is_character",
                         "gravity_scale_if_has_no_image_shapes", "linear_damping",
                         "allow_sleep", "update_entity_transform", "mActiveState" }) do
      out.physics[f] = read(body, f)
    end
  end
  local x, y, rot = EntityGetTransform(p)
  out.x, out.y, out.rotation = x, y, rot
  out.engaged = active ~= nil
  return out
end

-- ---------------------------------------------------------------- engagement

function lever.engage(params)
  params = params or {}
  local p, ch, vel = comps()
  if not p then return { ok = false, error = "no player" } end

  local snap = { character = {}, velocity = {}, controls = {} }
  for _, f in ipairs(CHAR_FIELDS) do snap.character[f] = read(ch, f) end
  for _, f in ipairs(VELOCITY_FIELDS) do snap.velocity[f] = read(vel, f) end
  if active and active.snapshot then
    snap = active.snapshot          -- keep the ORIGINAL pristine values
  end
  snapshot = snap

  local frames = math.max(1, math.min(tonumber(params.frames) or 300, 3600))
  active = {
    snapshot = snap,
    fields = params.fields or {},        -- CharacterDataComponent writes
    velocity_fields = params.velocity_fields or {},
    controls_fields = params.controls_fields or {},
    phase = (params.phase == "post") and "post" or "pre",
    frames_left = frames,
    start_frame = GameGetFrameNum(),
    samples = {},
  }
  return {
    ok = true,
    frame = GameGetFrameNum(),
    frames = frames,
    fields = active.fields,
    velocity_fields = active.velocity_fields,
    note = "levers re-applied every frame from phase=" .. active.phase ..
      "; call lever_disengage to restore the captured values",
  }
end

function lever.disengage()
  local p, ch, vel, ctl = comps()
  if not p then return { ok = false, error = "no player" } end
  if not snapshot then return { ok = false, error = "nothing engaged" } end

  local restored = {}
  for f, v in pairs(snapshot.character or {}) do
    if write(ch, f, v) then restored[#restored + 1] = f end
  end
  for f, v in pairs(snapshot.velocity or {}) do
    if write(vel, f, v) then restored[#restored + 1] = f end
  end
  active = nil
  local snap = snapshot
  snapshot = nil
  return { ok = true, frame = GameGetFrameNum(), restored = restored, from = snap ~= nil }
end

function lever.status()
  if not active then return { active = false } end
  return {
    active = active.frames_left > 0,
    frames_left = active.frames_left,
    start_frame = active.start_frame,
    phase = active.phase,
    fields = active.fields,
    velocity_fields = active.velocity_fields,
    controls_fields = active.controls_fields,
    samples = active.samples,
  }
end

function lever.cancel()
  active = nil
  return { ok = true, note = "cancelled WITHOUT restoring; call lever_disengage for that" }
end

-- ---------------------------------------------------------------- tick

function lever.tick(phase)
  phase = phase or "pre"
  if not active or active.frames_left <= 0 then return end
  if active.phase ~= phase then return end

  local p, ch, vel, ctl = comps()
  if not p then return end

  for f, v in pairs(active.fields) do write(ch, f, v) end
  for f, v in pairs(active.velocity_fields) do write(vel, f, v) end
  for f, v in pairs(active.controls_fields) do write(ctl, f, v) end

  -- sample what the engine left behind, to see if our write survived the frame
  if #active.samples < 8 then
    local x, y = EntityGetTransform(p)
    active.samples[#active.samples + 1] = {
      frame = GameGetFrameNum(),
      x = x, y = y,
      vx = (read(ch, "mVelocity") or {}).x,
      vy = (read(ch, "mVelocity") or {}).y,
      engine_vx = (read(vel, "mVelocity") or {}).x,
      engine_vy = (read(vel, "mVelocity") or {}).y,
    }
  end

  active.frames_left = active.frames_left - 1
end

-- ---------------------------------------------------------------- experiments

-- The decisive question: does writing a movement field actually MOVE the player?
-- Horizontal motion is the cleanest signal -- the player receives no horizontal
-- input during the test, so any x drift is ours.
local experiment = nil

function lever.run_experiment(params)
  params = params or {}
  local p, ch, vel = comps()
  if not p then return { ok = false, error = "no player" } end

  local frames = math.max(10, math.min(tonumber(params.frames) or 30, 600))
  local vx = tonumber(params.vx) or 200
  local vy = tonumber(params.vy) or 0

  local x0, y0 = EntityGetTransform(p)
  local original_v = read(ch, "mVelocity") or { x = 0, y = 0 }
  local original_vy_comp = read(vel, "mVelocity")

  -- engage with a horizontal velocity, no gravity interference
  local eng = lever.engage({
    frames = frames,
    fields = params.fields or { gravity = 0 },
    velocity_fields = params.velocity_fields or {},
    phase = params.phase,
  })

  -- the velocity write itself (character data drives the player)
  active.fields["mVelocity"] = { x = vx, y = vy }

  experiment = {
    params = params, frames = frames, vx = vx, vy = vy,
    x0 = x0, y0 = y0,
    original_v = original_v,
    start_frame = GameGetFrameNum(),
  }
  return {
    ok = true,
    frame = GameGetFrameNum(),
    frames = frames,
    wrote_velocity = { vx = vx, vy = vy },
    from = { x = x0, y = y0 },
    phase = active.phase,
    note = "sampling starts now; call lever_experiment_result a second later",
  }
end

function lever.experiment_result()
  local p = comps()
  if not p then return { ok = false, error = "no player" } end
  if not experiment then return { ok = false, error = "no experiment run" } end

  local x1, y1 = EntityGetTransform(p)
  local dx, dy = x1 - experiment.x0, y1 - experiment.y0
  local status = lever.status()
  local samples = status.samples or {}

  -- did our value survive inside a frame?
  local survived = false
  for _, s in ipairs(samples) do
    if s.vx and math.abs(s.vx - experiment.vx) < 1 then survived = true break end
  end

  return {
    ran_frames = experiment.frames,
    from = { x = experiment.x0, y = experiment.y0 },
    to = { x = x1, y = y1 },
    delta = { x = dx, y = dy },
    distance = math.sqrt(dx * dx + dy * dy),
    wrote_velocity = { vx = experiment.vx, vy = experiment.vy },
    write_survived_in_frame = survived,
    samples = samples,
    verdict = (math.abs(dx) > 5)
      and ("MOVED: the player was displaced " .. string.format("%.1f", dx) ..
           "px horizontally by our velocity write -> direct motion control WORKS")
      or "NO DISPLACEMENT: our velocity write did not move the player",
  }
end

return lever

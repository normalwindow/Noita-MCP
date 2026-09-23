-- Experimental probes for player control.
--
-- Noita exposes the player's input through ControlsComponent. Its button fields
-- are documented as "Privates" but are readable and writable from Lua (the Iota
-- multiplayer mod drives them), and the component also carries a private aiming
-- vector. Whether a write STICKS depends on when in the frame it happens,
-- because the engine rewrites the fields from real input every frame.
--
-- These probes answer three questions the AI-control feature depends on:
--   1. which control fields can be read
--   2. whether a write survives to the next frame, and from which hook
--   3. whether the aiming vector can be overridden
--
-- Everything here is opt-in, reversible, and reports raw observations instead of
-- assuming an answer.

-- Stage-0 findings, measured in a live run (2026-09-21). These drive the design
-- of the real control feature that replaces this module.
--
-- READABLE   : all 18 button groups and their frame counters, plus
--              ControlsComponent.enabled and a two-value aim vector. 37/37
--              probed fields read back, 0 missing.
--
-- WRITABLE   : yes -- a write is visible in the same frame.
--
-- NOT STICKY : the engine rewrites every field from the REAL input each frame.
--              A one-shot write is gone by the next frame.
--
-- NOT DRIVABLE: writing these fields does NOT drive the game. Measured with an
--              attribution test (synthetic aim 87.8deg away from the physical
--              mouse, player holding still): the aim vector read back as the
--              mouse direction 5/5 samples, no projectile was fired by our input,
--              and mana stayed at 120 for 2.5s of held fire. Doing the same from
--              OnWorldPreUpdate (before the engine's update) changed nothing.
--
--              CONSEQUENCE: Noita does not let a mod forge player input through
--              ControlsComponent. Movement, wand fire and interact must be done
--              with the direct APIs (EntitySetTransform, mVelocity,
--              GameShootProjectile, GamePickUpInventoryItem, ...) instead.
--
--              A NOTE ON FALSE POSITIVES: writing the aim vector and reading it
--              back in the SAME frame returns the written value, which looks like
--              success. It is not -- the engine recomputes it from the mouse
--              before the next frame. Any experiment here must judge by BEHAVIOUR
--              and must separate synthetic input from the human's, or it will
--              credit the human's actions to the mod.

exp = exp or {}

-- Button fields we probe. `fire` also gets frame counters because the wand
-- system keys off "was fire pressed THIS frame".
local BUTTONS = {
  { down = "mButtonDownFire", frame = "mButtonFrameFire", last = "mButtonLastFrameFire" },
  { down = "mButtonDownFire2", frame = "mButtonFrameFire2" },
  { down = "mButtonDownInteract", frame = "mButtonFrameInteract" },
  { down = "mButtonDownLeft", frame = "mButtonFrameLeft" },
  { down = "mButtonDownRight", frame = "mButtonFrameRight" },
  { down = "mButtonDownUp", frame = "mButtonFrameUp" },
  { down = "mButtonDownDown", frame = "mButtonFrameDown" },
  { down = "mButtonDownJump", frame = "mButtonFrameJump" },
  { down = "mButtonDownRun", frame = "mButtonFrameRun" },
  { down = "mButtonDownFly", frame = "mButtonFrameFly" },
  { down = "mButtonDownDig", frame = "mButtonFrameDig" },
  { down = "mButtonDownKick", frame = "mButtonFrameKick" },
  { down = "mButtonDownThrow", frame = "mButtonFrameThrow" },
  { down = "mButtonDownDropItem", frame = "mButtonFrameDropItem" },
  { down = "mButtonDownChangeItemL", frame = "mButtonFrameChangeItemL" },
  { down = "mButtonDownChangeItemR", frame = "mButtonFrameChangeItemR" },
  { down = "mButtonDownInventory", frame = "mButtonFrameInventory" },
  { down = "mButtonDownEat", frame = "mButtonFrameEat" },
}

-- Aiming vector candidates, in the order we will test them.
local AIM_FIELDS = { "mAimingVector", "mSmoothedAimingVector", "mAimVector", "mAimingVectorNormalized" }

local function controls_comp()
  local p = ser.player()
  if not p then return nil, nil end
  return ser.comp(p, "ControlsComponent"), p
end

-- Read every candidate field. Values can be multi-return (vec2), so the raw
-- shape is reported too instead of guessing.
local function read_field(comp, field)
  local ok, a, b = pcall(ComponentGetValue2, comp, field)
  if not ok then return { readable = false, error = tostring(a) } end
  if a == nil then return { readable = false, error = "nil" } end
  if type(a) == "table" then
    return { readable = true, shape = "table", x = a[1], y = a[2] }
  end
  if b ~= nil then
    return { readable = true, shape = "two-values", x = a, y = b }
  end
  return { readable = true, shape = "scalar", value = a }
end

function exp.probe_controls()
  local comp, p = controls_comp()
  if not comp then return { ok = false, error = "no player ControlsComponent" } end

  local fields = {}
  local readable, missing = 0, 0
  for _, spec in ipairs(BUTTONS) do
    local entry = { down_field = spec.down }
    local r = read_field(comp, spec.down)
    entry.down = r
    if r.readable then readable = readable + 1 else missing = missing + 1 end
    if spec.frame then
      local fr = read_field(comp, spec.frame)
      entry.frame_field = spec.frame
      entry.frame = fr
      if fr.readable then readable = readable + 1 else missing = missing + 1 end
    end
    if spec.last then
      local lr = read_field(comp, spec.last)
      entry.last_field = spec.last
      entry.last = lr
      if lr.readable then readable = readable + 1 else missing = missing + 1 end
    end
    fields[#fields + 1] = entry
  end

  local aim = {}
  for _, f in ipairs(AIM_FIELDS) do
    aim[f] = read_field(comp, f)
  end

  local enabled = read_field(comp, "enabled")

  return {
    entity = p,
    enabled = enabled,
    readable_count = readable,
    missing_count = missing,
    buttons = fields,
    aim_candidates = aim,
  }
end

-- Set one or more control fields right now. Used to find out whether a write
-- survives, so the caller can read back on a later frame.
function exp.set_controls(params)
  params = params or {}
  local comp = controls_comp()
  if not comp then return { ok = false, error = "no player ControlsComponent" } end

  local before, applied, failed = {}, {}, {}
  local wanted = params.fields or {}

  for field, value in pairs(wanted) do
    local b = read_field(comp, field)
    before[field] = b
    local ok, err = pcall(ComponentSetValue2, comp, field, value)
    if ok then
      applied[field] = value
    else
      failed[field] = tostring(err)
    end
  end

  if params.enabled ~= nil then
    before["enabled"] = read_field(comp, "enabled")
    local ok, err = pcall(ComponentSetValue2, comp, "enabled", params.enabled and true or false)
    if ok then applied["enabled"] = params.enabled and true or false else failed["enabled"] = tostring(err) end
  end

  -- immediate read-back in the same frame: proves the write landed at all
  local after = {}
  for field in pairs(applied) do
    after[field] = read_field(comp, field)
  end

  return {
    frame = GameGetFrameNum(),
    before = before,
    applied = applied,
    failed = failed,
    same_frame_readback = after,
    note = "same_frame_readback proves the write landed; a later read on a new frame proves it stuck",
  }
end

-- Aim override experiment: write a vector into every candidate field and report
-- which ones accepted a table vs two scalars.
function exp.set_aim(params)
  params = params or {}
  local comp = controls_comp()
  if not comp then return { ok = false, error = "no player ControlsComponent" } end

  local x = tonumber(params.x) or 1
  local y = tonumber(params.y) or 0

  local results = {}
  for _, f in ipairs(AIM_FIELDS) do
    local before = read_field(comp, f)
    local shape = before.shape

    -- try the shape the field already reports, then the other one
    local attempts = {}
    if shape == "two-values" or shape == "scalar" then
      attempts[#attempts + 1] = { kind = "two-scalars" }
      attempts[#attempts + 1] = { kind = "table" }
    else
      attempts[#attempts + 1] = { kind = "table" }
      attempts[#attempts + 1] = { kind = "two-scalars" }
    end

    local entry = { before = before, attempts = {} }
    for _, a in ipairs(attempts) do
      local ok, err
      if a.kind == "table" then
        ok, err = pcall(ComponentSetValue2, comp, f, { x, y })
      else
        ok, err = pcall(ComponentSetValue2, comp, f, x, y)
      end
      local readback = read_field(comp, f)
      entry.attempts[#entry.attempts + 1] = {
        kind = a.kind, ok = ok, error = ok and nil or tostring(err), readback = readback,
      }
      if ok and readback.readable then break end
    end
    results[f] = entry
  end

  return { frame = GameGetFrameNum(), wanted = { x = x, y = y }, fields = results }
end

-- Capture / restore the whole control state so experiments never leave the
-- player stuck in a state the human did not ask for.
local snapshot = nil

function exp.snapshot_controls()
  local comp = controls_comp()
  if not comp then return { ok = false, error = "no player ControlsComponent" } end
  local snap = { enabled = read_field(comp, "enabled"), buttons = {}, aim = {} }
  for _, spec in ipairs(BUTTONS) do
    snap.buttons[spec.down] = read_field(comp, spec.down)
    if spec.frame then snap.buttons[spec.frame] = read_field(comp, spec.frame) end
  end
  for _, f in ipairs(AIM_FIELDS) do snap.aim[f] = read_field(comp, f) end
  snapshot = snap
  return { ok = true, frame = GameGetFrameNum(), captured = snap }
end

function exp.restore_controls()
  local comp = controls_comp()
  if not comp then return { ok = false, error = "no player ControlsComponent" } end
  if not snapshot then return { ok = false, error = "nothing captured; call snapshot first" } end

  local restored = {}
  local function put(field, entry)
    if not entry or not entry.readable then return end
    if entry.shape == "two-values" or entry.shape == "table" then
      pcall(ComponentSetValue2, comp, field, entry.x, entry.y)
    elseif entry.shape == "scalar" then
      pcall(ComponentSetValue2, comp, field, entry.value)
    end
    restored[#restored + 1] = field
  end

  for field, entry in pairs(snapshot.buttons) do put(field, entry) end
  for field, entry in pairs(snapshot.aim) do put(field, entry) end
  if snapshot.enabled and snapshot.enabled.readable then
    pcall(ComponentSetValue2, comp, "enabled", snapshot.enabled.value and true or false)
    restored[#restored + 1] = "enabled"
  end
  return { ok = true, frame = GameGetFrameNum(), restored = restored }
end

-- Timed push: write control fields on N consecutive frames starting next frame.
-- This is how we test whether a write sticks when it lands in a different hook
-- than the read, and whether the engine overwrites it between frames.
--
-- State lives in this module (not in the request), so it survives across frames.
local push = nil

function exp.push_controls(params)
  params = params or {}
  local comp = controls_comp()
  if not comp then return { ok = false, error = "no player ControlsComponent" } end

  local frames = math.max(1, math.min(tonumber(params.frames) or 3, 3600))
  local phase = params.phase
  if phase ~= "post" and phase ~= "both" then phase = "pre" end
  push = {
    fields = params.fields or {},
    aim = params.aim,
    fire = params.fire and true or false,
    disable_controls = params.disable_controls,
    phase = phase,
    frames_left = frames,
    start_frame = GameGetFrameNum(),
    observed = {},
  }
  return {
    ok = true,
    frame = GameGetFrameNum(),
    frames = frames,
    phase = phase,
    fields = params.fields or {},
    aim = params.aim,
    fire = push.fire,
    note = "phase=pre writes before the engine reads input; that is the one that can affect the current frame",
  }
end

function exp.push_status()
  if not push then return { active = false } end
  return {
    active = push.frames_left > 0,
    frames_left = push.frames_left,
    start_frame = push.start_frame,
    phase = push.phase,
    fields = push.fields,
    aim = push.aim,
    fire = push.fire,
    observed = push.observed,
  }
end

function exp.cancel_push()
  push = nil
  return { ok = true }
end

-- Push driver. `phase` selects which hook drives it, because the engine reads
-- the control fields during its own update: a write from OnWorldPostUpdate
-- lands after that read has already happened for the frame, so the game never
-- sees it. OnWorldPreUpdate runs before the engine's update and is therefore the
-- only phase where synthetic input can influence the current frame.
--
--   exp.tick("pre")  <- from OnWorldPreUpdate  (this is the one that matters)
--   exp.tick("post") <- from OnWorldPostUpdate (still useful for aim vectors and
--                       for observing what the engine wrote)
function exp.tick(phase)
  phase = phase or "post"
  if not push or push.frames_left <= 0 then return end
  if (push.phase or "pre") ~= phase then return end

  local comp = controls_comp()
  if not comp then push = nil return end

  local frame = GameGetFrameNum()

  for field, value in pairs(push.fields) do
    pcall(ComponentSetValue2, comp, field, value)
  end
  if push.disable_controls ~= nil then
    pcall(ComponentSetValue2, comp, "enabled", push.disable_controls and true or false)
  end
  if push.fire then
    -- The wand system keys off the frame counters, not only the down flags:
    -- mButtonFrameFire marks "fire was pressed on this frame", and
    -- mButtonLastFrameFire suppresses re-triggering while held.
    pcall(ComponentSetValue2, comp, "mButtonDownFire", true)
    pcall(ComponentSetValue2, comp, "mButtonFrameFire", frame)
    pcall(ComponentSetValue2, comp, "mButtonLastFrameFire", frame - 1)
  end
  if push.aim then
    -- write both the raw and the normalized vector: the engine reads whichever
    -- it needs and would otherwise overwrite ours from real mouse input
    for _, f in ipairs(AIM_FIELDS) do
      pcall(ComponentSetValue2, comp, f, push.aim.x, push.aim.y)
    end
  end

  -- record the post-write read-back for the first pushed frame
  if #push.observed < 4 then
    local obs = { frame = GameGetFrameNum(), readback = {} }
    for field in pairs(push.fields) do
      obs.readback[field] = read_field(comp, field)
    end
    if push.aim then
      obs.aim_readback = {}
      for _, f in ipairs(AIM_FIELDS) do obs.aim_readback[f] = read_field(comp, f) end
    end
    push.observed[#push.observed + 1] = obs
  end

  push.frames_left = push.frames_left - 1
end

return exp

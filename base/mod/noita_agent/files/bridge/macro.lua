-- Macro actions: named intents instead of raw key timings.
--
-- WHY
--
-- Forging input directly means every caller re-derives the same key sequences. "Jump to the
-- right" is four decisions -- which keys, for how many frames, in what order, released when
-- -- and those decisions were being made in JavaScript, in Python, and in ad-hoc scripts.
-- Keeping them in one place means they are made once, tested once, and are the same
-- whichever client is driving. It also makes replay tractable: a macro has a name and a
-- duration, so `macro jump_right 12f` reconstructs what was pressed, whereas a bare key
-- stream needs the reader to re-derive the intent.
--
-- TWO WAYS TO RUN, AND WHY THAT MATTERS
--
-- A macro can drive the player two ways:
--
--   * KEYS, through the optional input extension. Exact -- it is the real input path -- and
--     the only way to do anything that has to be a button press: firing the wand, picking
--     something up.
--   * VELOCITY, through lever.lua, which writes motion directly. This needs no DLL, so it
--     works in the base package, and it is how movement macros run there.
--
-- So a step may carry a direction (`move`) alongside or instead of a key. When the
-- extension is armed the key is used; when it is not, the direction is used; and a step
-- that needs a key it cannot get is REFUSED rather than silently skipped. That last part is
-- the point: the base package can walk, jump-arc and climb, and it says plainly that it
-- cannot fire, instead of appearing to succeed.
--
-- The executor is driven from the bridge's per-frame update, not from a hook: pushing an
-- event while SDL holds its queue lock would deadlock.

macro = macro or {}

-- Directions a velocity-driven step can push toward. The magnitude is added to the
-- player's existing velocity rather than replacing it, so a macro nudges rather than
-- teleports: measured earlier, 30 frames of a +250 write moved the player 126.3px, which is
-- a movement speed rather than a teleport.
local MOVE_AXIS = {
  left = { -1, 0 }, right = { 1, 0 }, up = { 0, -1 }, down = { 0, 1 },
  up_left = { -1, -1 }, up_right = { 1, -1 },
  down_left = { -1, 1 }, down_right = { 1, 1 },
}

-- Each macro is pure data, so it can be listed, diffed and logged without running it.
--
-- `key` is what the input extension sends; `move` is what the velocity path uses. `needs`
-- names a capability a step cannot do without, so a refusal can say what is missing.
local MACROS = {
  -- movement: runnable without the DLL
  walk_left = { { key = "A", move = "left", frames = 20 } },
  walk_right = { { key = "D", move = "right", frames = 20 } },
  walk_left_long = { { key = "A", move = "left", frames = 60 } },
  walk_right_long = { { key = "D", move = "right", frames = 60 } },
  fly_up = { { key = "SPACE", move = "up", frames = 40 } },
  crouch = { { key = "S", move = "down", frames = 20 } },
  jump = { { key = "SPACE", move = "up", frames = 10 } },
  jump_left = {
    { key = "SPACE", move = "up", frames = 10 },
    { key = "A", move = "left", frames = 24 },
  },
  jump_right = {
    { key = "SPACE", move = "up", frames = 10 },
    { key = "D", move = "right", frames = 24 },
  },
  dodge_left = { { key = "A", move = "left", frames = 14 } },
  dodge_right = { { key = "D", move = "right", frames = 14 } },

  -- interaction: needs the input extension, no velocity equivalent exists
  interact = { { key = "E", frames = 8, needs = "keys" } },
  kick = { { key = "F", frames = 8, needs = "keys" } },

  -- combat: needs the input extension. The wand fires on the left mouse button and nothing
  -- in the physics state can stand in for that.
  fire = { { mouse = 1, frames = 20, needs = "keys" } },
  fire_long = { { mouse = 1, frames = 90, needs = "keys" } },
  fire_and_advance = {
    { mouse = 1, frames = 20, needs = "keys" },
    { key = "D", move = "right", frames = 30 },
  },
  fire_and_retreat = {
    { mouse = 1, frames = 20, needs = "keys" },
    { key = "A", move = "left", frames = 30 },
  },

  -- inventory: needs the input extension
  next_item = { { key = "NUM2", frames = 6, needs = "keys" } },
  prev_item = { { key = "NUM1", frames = 6, needs = "keys" } },
  item_slot_1 = { { key = "NUM1", frames = 6, needs = "keys" } },
  item_slot_2 = { { key = "NUM2", frames = 6, needs = "keys" } },
  item_slot_3 = { { key = "NUM3", frames = 6, needs = "keys" } },
  item_slot_4 = { { key = "NUM4", frames = 6, needs = "keys" } },
  item_slot_5 = { { key = "NUM5", frames = 6, needs = "keys" } },
}

-- A macro that names a key we do not know about would fail mid-sequence. Checking at load
-- means a typo is caught by the test suite instead.
local function validate()
  local problems = {}
  local known = (xinput and type(xinput.scancodes) == "function")
    and xinput.scancodes() or nil
  local names = {}
  if known then for _, k in ipairs(known) do names[k.name] = true end end

  for name, steps in pairs(MACROS) do
    if type(steps) ~= "table" or #steps == 0 then
      problems[#problems + 1] = name .. ": no steps"
    end
    for i, s in ipairs(steps or {}) do
      if s.key and known and not names[s.key] then
        problems[#problems + 1] = string.format("%s step %d: unknown key %s", name, i, s.key)
      end
      if not s.key and not s.mouse and not s.move then
        problems[#problems + 1] =
          string.format("%s step %d: has neither a key, a mouse button nor a direction", name, i)
      end
      if s.move and not MOVE_AXIS[s.move] then
        problems[#problems + 1] =
          string.format("%s step %d: unknown direction %s", name, i, tostring(s.move))
      end
      if not (tonumber(s.frames) and s.frames > 0) then
        problems[#problems + 1] = string.format("%s step %d: bad frame count", name, i)
      end
    end
  end
  return problems
end

macro.problems = validate

-- Whether input forging is available right now. Cached per call rather than per frame: the
-- extension can be armed between two macros.
local function keys_available()
  return (xinput and xinput.available and xinput.available()) and true or false
end

-- The running sequence, or nil. Only one macro runs at a time: two overlapping sequences
-- would fight over the same keys and the same velocity, producing motion neither intended.
local running = nil

function macro.names()
  local out = {}
  for name in pairs(MACROS) do out[#out + 1] = name end
  table.sort(out)
  return out
end

-- Classifies every macro by what it needs, so a caller can pick one that will actually run.
function macro.capabilities()
  local with_keys = keys_available()
  local ok_now, can_run_now, needs_keys = {}, {}, {}
  for _, name in ipairs(macro.names()) do
    local m = macro.describe(name)
    local needs = false
    local runnable = true
    for _, s in ipairs(m.steps) do
      if s.needs == "keys" then needs = true
        if not with_keys then runnable = false end
      end
      if s.key and not s.move and not with_keys then runnable = false end
      if s.mouse and not with_keys then runnable = false end
    end
    if needs then needs_keys[#needs_keys + 1] = name end
    if runnable then can_run_now[#can_run_now + 1] = name end
  end
  return {
    input_extension = with_keys,
    method = with_keys and "keys (the input extension is armed)" or "velocity (pure Lua)",
    runnable_now = can_run_now,
    needs_extension = needs_keys,
    note = with_keys
      and "every macro is available"
      or "movement macros run by writing velocity; anything that must be a button press " ..
         "is listed in needs_extension and will refuse rather than pretend",
  }
end

function macro.status()
  local with_keys = keys_available()
  if not running then
    return {
      running = false,
      available = #macro.names() > 0,
      input_extension = with_keys,
      method = with_keys and "keys" or "velocity",
      runnable_now = #macro.capabilities().runnable_now,
    }
  end
  return {
    running = true,
    available = true,
    name = running.name,
    step = running.step,
    steps = #running.steps,
    frames_left = running.frames_left,
    frames_total = running.frames_total,
    elapsed = running.elapsed,
    method = running.method,
    input_extension = with_keys,
  }
end

function macro.describe(name)
  local steps = MACROS[name]
  if not steps then return nil end
  local total = 0
  for _, s in ipairs(steps) do total = total + (tonumber(s.frames) or 0) end
  return { name = name, steps = steps, total_frames = total }
end

-- ---------------------------------------------------------------- velocity path

-- Starts or updates the velocity lever for a step. The magnitude is modest on purpose: a
-- large write is a teleport and skips collisions, which is not what "walk right" means.
local VELOCITY = 220

local function apply_move(dir)
  local axis = MOVE_AXIS[dir]
  if not axis then return false end
  -- `fields` writes CharacterDataComponent; `velocity_fields` writes VelocityComponent,
  -- where mVelocity is a SCALAR and a pair write is a silent no-op. Measured: the same
  -- 220px/s write moved the player 0.0px through velocity_fields and 171.4px through
  -- fields. lever re-applies this every frame from its own tick, so one engage covers the
  -- step.
  local ok = lever.engage({
    frames = 2,
    fields = {
      mVelocity = { x = axis[1] * VELOCITY, y = axis[2] * VELOCITY },
    },
  })
  return ok and ok.ok or false
end

local function clear_move()
  pcall(lever.disengage)
end

-- ---------------------------------------------------------------- start

function macro.start(name, params)
  params = params or {}
  local steps = MACROS[name]
  if not steps then
    return { ok = false, error = "unknown macro: " .. tostring(name), available = macro.names() }
  end

  local with_keys = keys_available()

  -- Refuse before doing anything, and say exactly what is missing. A macro that half-ran
  -- and then stopped would leave the player mid-motion with no explanation.
  if not with_keys then
    local blocked = {}
    for i, s in ipairs(steps) do
      local needs_key = s.needs == "keys" or (s.key and not s.move) or s.mouse
      if needs_key then blocked[#blocked + 1] = i end
    end
    if #blocked > 0 then
      return {
        ok = false,
        error = "macro '" .. name .. "' needs the input extension and it is not armed",
        blocked_steps = blocked,
        hint = "load and arm it (noita_input_load, noita_input_install), or use a movement " ..
               "macro, which runs on velocity instead",
        runnable_now = macro.capabilities().runnable_now,
      }
    end
  end

  -- An optional speed factor scales every hold, for a caller that wants a slower or faster
  -- version of the same intent without a new macro being defined for it.
  local scale = tonumber(params.scale) or 1
  scale = math.max(0.25, math.min(scale, 4))

  local scaled = {}
  local total = 0
  for i, s in ipairs(steps) do
    local f = math.max(1, math.floor((tonumber(s.frames) or 1) * scale + 0.5))
    scaled[i] = { key = s.key, mouse = s.mouse, move = s.move, needs = s.needs, frames = f }
    total = total + f
  end

  -- Starting a macro cancels whatever was running, so a caller that changes its mind does
  -- not have to release first. The old sequence is released cleanly rather than abandoned
  -- mid-hold, which would leave a key down or the velocity lever engaged.
  if running then macro.stop("superseded") end

  local first = scaled[1]
  if with_keys then
    -- xinput.push_key returns a TABLE ({ ok = true, scancode = n }), not a number.
    --
    -- Checking `rc ~= 1` therefore failed on every call and macro.start reported "the
    -- extension refused the first key-down" while the RPC path, which reads .ok, worked.
    -- Found by running a macro in a live game; the mock could not catch it because its
    -- xinput is unavailable and an earlier guard short-circuited first.
    local function pushed(called, res)
      return called and type(res) == "table" and res.ok == true
    end
    if first.mouse then
      local called, res = pcall(xinput.push_mouse, first.mouse, true, 0, 0)
      if not pushed(called, res) then
        return { ok = false, error = "the extension refused the first mouse-down",
                 detail = called and res or nil }
      end
    elseif first.key then
      local called, res = pcall(xinput.push_key, first.key, true)
      if not pushed(called, res) then
        return { ok = false, error = "the extension refused the first key-down",
                 detail = called and res or nil }
      end
    end
  elseif first.move then
    if not apply_move(first.move) then
      return { ok = false, error = "could not drive velocity along '" .. first.move .. "'" }
    end
  end

  running = {
    name = name,
    steps = scaled,
    step = 1,
    frames_left = first.frames,
    frames_total = first.frames,
    elapsed = 1,
    total_frames = total,
    method = with_keys and "keys" or "velocity",
  }
  panel.info(string.format("macro %s started (%d steps, %d frames, via %s)",
    name, #scaled, total, running.method), { source = "macro" })
  return {
    ok = true, name = name, steps = #scaled, total_frames = total, scale = scale,
    method = running.method,
  }
end

function macro.stop(reason)
  if not running then return { ok = true, note = "nothing running" } end

  -- Release whatever the current step is holding. A key left down, or a velocity lever left
  -- engaged, would keep the player moving after the macro "ended" -- the worst kind of bug
  -- here, because it is silent and persistent.
  local s = running.steps[running.step]
  if s then
    if s.key then pcall(xinput.push_key, s.key, false) end
    if s.mouse then pcall(xinput.push_mouse, s.mouse, false, 0, 0) end
    if s.move then clear_move() end
  end

  local name, method = running.name, running.method
  running = nil
  panel.info(string.format("macro %s stopped (%s, via %s)", name, tostring(reason or "requested"),
    method), { source = "macro" })
  return { ok = true, stopped = name, reason = reason }
end

-- Called every frame from the bridge. Emits one key-down per frame of the current step --
-- the event stream the engine consumes -- or keeps the velocity lever applied, and releases
-- between steps.
function macro.tick()
  if not running then return end

  local s = running.steps[running.step]
  if not s then macro.stop("out of steps") return end

  if running.frames_left <= 0 then
    -- end of this step: release it, then either start the next or finish
    if s.key then pcall(xinput.push_key, s.key, false) end
    if s.mouse then pcall(xinput.push_mouse, s.mouse, false, 0, 0) end
    if s.move then clear_move() end

    running.step = running.step + 1
    local nxt = running.steps[running.step]
    if not nxt then
      local name = running.name
      running = nil
      panel.info("macro " .. name .. " finished", { source = "macro" })
      return
    end
    running.frames_left = nxt.frames
    running.frames_total = nxt.frames

    if running.method == "keys" then
      if nxt.key then pcall(xinput.push_key, nxt.key, true) end
      if nxt.mouse then pcall(xinput.push_mouse, nxt.mouse, true, 0, 0) end
    end
    if nxt.move then apply_move(nxt.move) end
    return
  end

  -- Keep the current step asserted. Keys are repeated every frame because that is what the
  -- engine needs to see; the velocity lever is re-engaged because lever.lua expires its own
  -- engagement and would otherwise drop the movement mid-step.
  if running.method == "keys" then
    if s.key then pcall(xinput.push_key, s.key, true) end
    if s.mouse then pcall(xinput.push_mouse, s.mouse, true, 0, 0) end
  end
  if s.move then apply_move(s.move) end

  running.frames_left = running.frames_left - 1
  running.elapsed = running.elapsed + 1
end

macro.MACROS = MACROS
macro.MOVE_AXIS = MOVE_AXIS
macro.VELOCITY = VELOCITY

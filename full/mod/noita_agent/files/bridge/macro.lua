-- Macro actions: named intents instead of raw key timings.
--
-- WHY
--
-- Forging input directly means every caller re-derives the same key sequences. "Jump to
-- the right" is four decisions -- which keys, for how many frames, in what order, released
-- when -- and those decisions were being made in JavaScript, in Python, and in ad-hoc
-- scripts. Keeping them in one place means they are made once, tested once, and are the
-- same whichever client is driving.
--
-- It also makes replay tractable: a macro has a name and a duration, so a log line like
-- `macro jump_right 12f` reconstructs exactly what was pressed, whereas a bare key stream
-- needs the reader to re-derive the intent.
--
-- HOW
--
-- Macros are declarative: a list of steps, each a key or mouse button held for N frames.
-- The executor walks them in order, one step at a time, emitting a key-down per frame and
-- a key-up at the end of the step. That is the event stream the engine consumes; a single
-- key-down per press is ignored (measured earlier -- a lone edge pair was discarded, a
-- per-frame repeat was accepted).
--
-- The executor is driven from the bridge's per-frame update, not from a hook: pushing an
-- event while SDL holds its queue lock would deadlock.

macro = macro or {}

-- Every macro is pure data, so it can be listed, diffed and logged without running it.
--
-- Hold lengths are in frames at 60 fps, which is what the engine's own input handling
-- counts in. They were measured by holding each key and watching the engine's counters:
-- a jump needs its key held long enough to clear the apex, a direction change needs a
-- few frames before the character's velocity follows.
local MACROS = {
  -- movement
  walk_left = { { key = "A", frames = 20 } },
  walk_right = { { key = "D", frames = 20 } },
  walk_left_long = { { key = "A", frames = 60 } },
  walk_right_long = { { key = "D", frames = 60 } },
  jump = { { key = "SPACE", frames = 10 } },
  jump_left = { { key = "SPACE", frames = 10 }, { key = "A", frames = 24 } },
  jump_right = { { key = "SPACE", frames = 10 }, { key = "D", frames = 24 } },
  -- fly/levitate upward, which is SPACE held rather than a separate key
  fly_up = { { key = "SPACE", frames = 40 } },
  crouch = { { key = "S", frames = 20 } },

  -- interaction
  interact = { { key = "E", frames = 8 } },
  kick = { { key = "F", frames = 8 } },

  -- combat
  fire = { { mouse = 1, frames = 20 } },
  fire_long = { { mouse = 1, frames = 90 } },
  fire_and_advance = { { mouse = 1, frames = 20 }, { key = "D", frames = 30 } },
  fire_and_retreat = { { mouse = 1, frames = 20 }, { key = "A", frames = 30 } },

  -- inventory
  next_item = { { key = "NUM2", frames = 6 } },
  prev_item = { { key = "NUM1", frames = 6 } },
  item_slot_1 = { { key = "NUM1", frames = 6 } },
  item_slot_2 = { { key = "NUM2", frames = 6 } },
  item_slot_3 = { { key = "NUM3", frames = 6 } },
  item_slot_4 = { { key = "NUM4", frames = 6 } },
  item_slot_5 = { { key = "NUM5", frames = 6 } },
}

-- A macro that names a key we do not know about would fail at run time, in the middle of
-- a sequence. Checking at load means a typo is caught by the test suite instead.
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
      if not s.key and not s.mouse then
        problems[#problems + 1] = string.format("%s step %d: neither key nor mouse", name, i)
      end
      if not (tonumber(s.frames) and s.frames > 0) then
        problems[#problems + 1] = string.format("%s step %d: bad frame count", name, i)
      end
    end
  end
  return problems
end

macro.problems = validate

-- The running sequence, or nil. Only one macro runs at a time: two overlapping sequences
-- would fight over the same keys and produce input neither of them intended.
local running = nil

function macro.status()
  if not running then
    return { running = false, available = #(macro.names()) > 0 }
  end
  return {
    running = true,
    name = running.name,
    step = running.step,
    steps = #running.steps,
    frames_left = running.frames_left,
    frames_total = running.frames_total,
    elapsed_frames = running.elapsed,
  }
end

function macro.names()
  local out = {}
  for name in pairs(MACROS) do out[#out + 1] = name end
  table.sort(out)
  return out
end

function macro.describe(name)
  local steps = MACROS[name]
  if not steps then return nil end
  local total = 0
  for _, s in ipairs(steps) do total = total + (tonumber(s.frames) or 0) end
  return { name = name, steps = steps, total_frames = total }
end

-- Starts a macro. Returns immediately; the bridge's update advances it.
function macro.start(name, params)
  params = params or {}
  local steps = MACROS[name]
  if not steps then
    return {
      ok = false,
      error = "unknown macro: " .. tostring(name),
      available = macro.names(),
    }
  end

  if not (xinput and xinput.available and xinput.available()) then
    return {
      ok = false,
      error = "input forging is unavailable, so no macro can run",
      hint = "load and arm the input extension (noita_input_load, noita_input_install)",
      available = macro.names(),
    }
  end

  -- An optional speed factor scales every hold, for callers that want a slower or faster
  -- version of the same intent without a new macro being defined for it.
  local scale = tonumber(params.scale) or 1
  scale = math.max(0.25, math.min(scale, 4))

  local scaled = {}
  local total = 0
  for i, s in ipairs(steps) do
    local f = math.max(1, math.floor((tonumber(s.frames) or 1) * scale + 0.5))
    scaled[i] = { key = s.key, mouse = s.mouse, frames = f }
    total = total + f
  end

  -- Starting a macro cancels whatever was running, so a caller that changes its mind does
  -- not have to release first. The old sequence is released cleanly rather than abandoned
  -- mid-hold, which would leave a key stuck down.
  if running then macro.stop("superseded") end

  -- xinput.push_key returns a TABLE ({ ok = true, scancode = n }), not a number.
  --
  -- Checking `rc ~= 1` therefore failed on every call -- a table is never equal to 1 -- and
  -- macro.start reported "SDL refused the first key-down" while the RPC path, which reads
  -- .ok, worked fine. Found by running a macro in a live game; the mock could not catch it
  -- because the mock's xinput is unavailable, so the guard above short-circuits first.
  local function pushed(result_ok, value)
    return result_ok and type(value) == "table" and value.ok == true
  end

  local first = scaled[1]
  if first.key then
    local called, res = pcall(xinput.push_key, first.key, true)
    if not pushed(called, res) then
      return {
        ok = false,
        error = "the extension refused the first key-down",
        detail = called and res or nil,
      }
    end
  else
    local called, res = pcall(xinput.push_mouse, first.mouse, true, 0, 0)
    if not pushed(called, res) then
      return {
        ok = false,
        error = "the extension refused the first mouse-down",
        detail = called and res or nil,
      }
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
  }
  panel.info(string.format("macro %s started (%d steps, %d frames)", name, #scaled, total),
    { source = "macro" })
  return { ok = true, name = name, steps = #scaled, total_frames = total, scale = scale }
end

function macro.stop(reason)
  if not running then return { ok = true, note = "nothing running" } end

  -- Release whatever the current step is holding. A key left down would keep moving the
  -- character after the macro "ended", which is the worst kind of bug here: silent and
  -- persistent.
  local s = running.steps[running.step]
  if s then
    if s.key then pcall(xinput.push_key, s.key, false)
    else pcall(xinput.push_mouse, s.mouse, false, 0, 0) end
  end

  local name = running.name
  running = nil
  panel.info(string.format("macro %s stopped (%s)", name, tostring(reason or "requested")),
    { source = "macro" })
  return { ok = true, stopped = name, reason = reason }
end

-- Called every frame from the bridge. Emits one key-down per frame of the current step,
-- which is the event stream the engine consumes, and a key-up between steps.
function macro.tick()
  if not running then return end
  local a = xinput
  if not a or not a.push_key then
    -- the extension went away mid-sequence; release and stop rather than hold forever
    macro.stop("input extension unavailable")
    return
  end

  local s = running.steps[running.step]
  if not s then macro.stop("out of steps") return end

  if running.frames_left <= 0 then
    -- end of this step: release it, then either start the next or finish
    if s.key then pcall(a.push_key, s.key, false)
    else pcall(a.push_mouse, s.mouse, false, 0, 0) end

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
    if nxt.key then pcall(a.push_key, nxt.key, true)
    else pcall(a.push_mouse, nxt.mouse, true, 0, 0) end
    return
  end

  -- repeat the hold every frame, which is what the engine needs to see
  if s.key then pcall(a.push_key, s.key, true)
  else pcall(a.push_mouse, s.mouse, true, 0, 0) end

  running.frames_left = running.frames_left - 1
  running.elapsed = running.elapsed + 1
end

macro.MACROS = MACROS

return macro

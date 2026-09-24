-- Measures the engine's frame acceptance rate against wall-clock time.
--
-- WHY THIS EXISTS
--
-- Two uses, and the second is why it is a permanent tool rather than a probe:
--
--   1. Diagnosis. "The bridge stopped responding" and "the engine stopped advancing" look
--      the same from outside. This tells them apart: if game frames per real second is zero,
--      the engine is not running, and no amount of retrying a call will help.
--
--   2. Acceptance testing for anything that changes how fast the game runs. The engine keeps
--      time with QueryPerformanceCounter (confirmed from noita.exe's import table), so a
--      frame's dt comes from real elapsed time, and a change to the effective dt is
--      measurable as a divergence between two rates:
--
--        real frames per second  -- how often the engine completes an update
--        game frames per second  -- GameGetFrameNum's advance per real second
--
--      Under normal play the two are equal. If a write halves the effective dt, the second
--      halves while the first may not change at all: the engine still runs the same number of
--      updates, each representing half as much game time.
--
--      That distinction is the point. "Does the game feel slower" cannot tell a correct write
--      from one that merely stutters, and a wrong write is the failure mode here. A number
--      can.
--
-- CALIBRATION
--
-- The pause menu is a known slow state, which gives the instrument a reference point:
-- measure in normal play, pause, measure again. The difference is what "the engine advances
-- less per real second" looks like on this machine, and it is what any candidate time-scale
-- change has to be compared against.
--
-- HOW IT SAMPLES
--
-- From the bridge's per-frame update, one row per frame. NOT from a wait loop: Lua runs on
-- the game's main thread, so a loop waiting for the frame counter to advance would stop the
-- engine from ever advancing it. The first version did exactly that and could only time out.

framerate = framerate or {}

local active = nil

function framerate.start(params)
  params = params or {}
  local p = ser.player()
  active = {
    label = params.label or "unlabelled",
    rows = {},
    had_player = p ~= nil,
  }
  return {
    ok = true,
    label = active.label,
    started_frame = GameGetFrameNum(),
    had_player = active.had_player,
    note = "the bridge samples it each frame; call noita_framerate with finish=true to read it",
  }
end

function framerate.sample()
  if not active then return end
  -- Two values per frame, taken together: the engine's own count of game time, and the wall
  -- clock. Comparing them over the window is the whole measurement.
  active.rows[#active.rows + 1] = { f = GameGetFrameNum(), t = os.clock() }
end

function framerate.finish()
  if not active then return { ok = false, error = "no measurement running" } end
  local a = active
  active = nil

  local n = #a.rows
  if n < 10 then
    return { ok = false, error = "only " .. n .. " samples; need at least 10", samples = n }
  end

  local first, last = a.rows[1], a.rows[n]
  local df = last.f - first.f
  local dt = last.t - first.t
  if df <= 0 then
    -- The engine did not advance at all during the window. That is a finding, not an error:
    -- it means the game is stopped (paused, loading, or not in a run).
    return {
      ok = true, label = a.label, samples = n, game_frames = 0,
      real_seconds = math.floor(dt * 1000) / 1000,
      game_frames_per_real_second = 0,
      stalled = true,
      note = "the engine did not advance a single frame; the game is paused, loading or " ..
             "not in a run",
    }
  end
  if dt <= 0 then
    return { ok = false, error = "no wall-clock time passed", samples = n }
  end

  -- Frame-to-frame intervals, so a stutter stays visible instead of being averaged away. A
  -- time-scale change moves the mean; a hitch is one large interval among small ones.
  local sum, worst = 0, 0
  for i = 2, n do
    local d = a.rows[i].t - a.rows[i - 1].t
    sum = sum + d
    if d > worst then worst = d end
  end
  local mean_interval = sum / (n - 1)

  return {
    ok = true,
    label = a.label,
    samples = n,
    had_player = a.had_player,
    game_frames = df,
    real_seconds = math.floor(dt * 1000) / 1000,
    game_frames_per_real_second = math.floor((df / dt) * 100) / 100,
    mean_ms_between_frames = math.floor(mean_interval * 100000) / 100,
    worst_ms_between_frames = math.floor(worst * 100000) / 100,
    first_frame = first.f,
    last_frame = last.f,
    note = "normal play has this near the display rate; a stalled engine reports 0. Compare " ..
           "a measurement taken in a known state before drawing conclusions from one taken " ..
           "after a change.",
  }
end

function framerate.state()
  if not active then return { ok = true, running = false } end
  return { ok = true, running = true, label = active.label, samples = #active.rows }
end

return framerate

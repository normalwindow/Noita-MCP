-- Decision stream: a fast, append-only record of (state, action, outcome).
--
-- THE PROBLEM IT SOLVES
--
-- Every decision currently costs one RPC round trip. Measured previously: a single call
-- is about 16 ms -- one frame -- and the socket only wins for batched calls. A 5-10 Hz
-- closed loop built that way is mostly waiting, and the latency lands between the
-- observation and the action rather than in the model.
--
-- WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT
--
-- It is transport, not inference. The model stays in its own process; mixing inference
-- into the bridge would make latency attribution impossible, which is the stated reason
-- for keeping them apart. So this publishes observations to a file the external process
-- can read at its own rate, and records what was decided and what happened next.
--
-- A state feed is not a dataset, though. Training needs (state, action, outcome), and the
-- outcome is only knowable LATER. So the stream keeps a ring of recent samples and
-- retro-fills the outcome when it arrives -- that is what makes delayed-reward labelling
-- possible without a second pass over a replay.
--
-- Output is JSON Lines: one record per line, appended, so a reader can tail it while the
-- game runs and a crash cannot corrupt earlier records.

stream = stream or {}

-- How many frames between published observations. 0 means every frame, which is what a
-- 5-10 Hz loop needs (60 fps / 6 = 10 Hz). Configurable because a caller watching a long
-- trend wants fewer.
local DEFAULT_INTERVAL = 6
local MAX_RING = 240
local MAX_LINES = 20000

local ring = {}
local ring_head = 0
local ring_count = 0
local seq = 0
local frames_since = 0
local lines_written = 0
local started_at_frame = nil

local enabled = false
local interval = DEFAULT_INTERVAL
local path = nil
local last_error = nil

-- ---------------------------------------------------------------- state capture

-- A compact observation. Deliberately not the full snapshot: the point is to be cheap
-- enough to write at 10 Hz, and a decision rarely needs the whole nearby list.
local function observe()
  local p = ser.player()
  if not p then return nil end

  local px, py = EntityGetTransform(p)
  local vx, vy = 0, 0
  local okv, a, b = pcall(EntityGetVelocity, p)
  if okv then vx, vy = a or 0, b or 0 end

  local o = {
    f = GameGetFrameNum(),
    x = math.floor(px), y = math.floor(py),
    vx = math.floor((vx or 0) * 100) / 100,
    vy = math.floor((vy or 0) * 100) / 100,
  }

  local st = ser.player_state and ser.player_state() or nil
  if st then
    o.hp = st.hp
    o.max_hp = st.max_hp
    o.money = st.money
    o.biome = st.biome
    if st.effects then o.effects = st.effect_count end
  end

  -- The nearest few entities, because "what is about to hit me" is the most common thing
  -- a decision needs and the full list is too large to write at 10 Hz.
  local near = ser.nearby(160, 6) or {}
  if #near > 0 then
    local list = {}
    for i = 1, #near do
      local e = near[i]
      list[i] = {
        e = e.entity,
        k = e.kind,
        n = e.name,
        d = e.dist and math.floor(e.dist) or nil,
      }
    end
    o.near = list
  end

  return o
end

-- ---------------------------------------------------------------- file output

local function can_write()
  return io and io.open and os and os.date
end

-- Opens once and keeps the handle, so the per-record cost is a write rather than an open.
local handle = nil

local function ensure_handle()
  if handle then return handle end
  if not can_write() then
    last_error = "io is unavailable in this sandbox"
    return nil
  end
  local ok, h = pcall(io.open, path, "a")
  if not ok or not h then
    last_error = "could not open " .. tostring(path) .. ": " .. tostring(h)
    return nil
  end
  handle = h
  return h
end

local function write_record(rec)
  if lines_written >= MAX_LINES then return false end
  local h = ensure_handle()
  if not h then return false end
  local ok, err = pcall(function()
    h:write(json.encode(rec))
    h:write("\n")
    h:flush()
  end)
  if not ok then
    last_error = "write failed: " .. tostring(err)
    pcall(function() h:close() end)
    handle = nil
    return false
  end
  lines_written = lines_written + 1
  return true
end

-- ---------------------------------------------------------------- control

function stream.start(params)
  params = params or {}
  if not can_write() then
    return { ok = false, error = "io is unavailable in this sandbox, so nothing can be logged" }
  end

  interval = math.max(0, math.min(tonumber(params.interval) or DEFAULT_INTERVAL, 60))
  path = params.path
  if not path then
    local base = (rpc and rpc.base_dir) or "mods/noita_agent/run/"
    path = base .. "decisions.jsonl"
  end

  -- Truncate on start, so a reader is never mixing two sessions. Named by start frame in
  -- the first record instead of by filename, so the path stays predictable.
  local ok, err = pcall(function()
    local h = assert(io.open(path, "w"))
    h:write("")
    h:close()
  end)
  if not ok then
    return { ok = false, error = "could not create " .. path .. ": " .. tostring(err) }
  end

  handle = nil
  ring, ring_head, ring_count = {}, 0, 0
  seq, frames_since, lines_written = 0, 0, 0
  started_at_frame = GameGetFrameNum()
  enabled = true
  last_error = nil

  write_record({
    kind = "session",
    schema = 1,
    started_frame = started_at_frame,
    interval_frames = interval,
    note = "one observation every N frames; actions and outcomes are appended inline",
  })

  panel.info(string.format("decision stream started (%s, every %d frames)", path, interval),
    { source = "stream" })
  return { ok = true, path = path, interval = interval, started_frame = started_at_frame }
end

function stream.stop(reason)
  if not enabled then return { ok = true, note = "not running" } end
  enabled = false
  if handle then
    pcall(function() handle:close() end)
    handle = nil
  end
  panel.info(string.format("decision stream stopped (%s), %d lines", tostring(reason or "requested"),
    lines_written), { source = "stream" })
  return { ok = true, lines = lines_written, path = path }
end

function stream.status()
  return {
    running = enabled,
    path = path,
    interval = interval,
    observations = seq,
    lines = lines_written,
    ring = ring_count,
    started_frame = started_at_frame,
    io_available = can_write(),
    last_error = last_error,
    max_lines = MAX_LINES,
  }
end

-- ---------------------------------------------------------------- actions and outcomes

-- Records that an action was taken at the current observation. Called by the MCP side
-- through a handler, and by the macro executor, so a caller does not have to remember.
function stream.action(name, detail)
  if not enabled then return false end
  local rec = {
    kind = "action",
    f = GameGetFrameNum(),
    seq = seq,
    action = name,
  }
  if detail then rec.detail = detail end

  -- Attach it to the newest observation, so the record pairs state and action on one line
  -- and a reader does not have to correlate by frame number.
  if ring_count > 0 then
    local idx = ((ring_head - 1) % MAX_RING) + 1
    local obs = ring[idx]
    if obs then
      obs.actions = obs.actions or {}
      obs.actions[#obs.actions + 1] = name
    end
  end

  write_record(rec)
  return true
end

-- Retro-fills the outcome of an observation made `delay` frames ago.
--
-- This is the part that makes the stream a dataset: at the time of an observation nobody
-- knows whether the action worked. Recording the observation and amending it later is what
-- allows delayed-reward labelling without keeping the whole history in memory.
function stream.outcome(obs, label)
  if not obs then return end
  obs.outcome = label
end

-- ---------------------------------------------------------------- tick

function stream.tick()
  if not enabled then return end

  frames_since = frames_since + 1
  if frames_since < interval then return end
  frames_since = 0

  local obs = observe()
  if not obs then return end

  seq = seq + 1
  obs.seq = seq

  -- Before overwriting the oldest slot, close its outcome: whatever changed since it was
  -- taken is its result. This is a crude label -- health and position deltas -- but it is
  -- exactly the signal that would otherwise be lost, and a model can be given a better one
  -- from the same data.
  if ring_count == MAX_RING then
    local oldest_idx = ((ring_head) % MAX_RING) + 1
    local oldest = ring[oldest_idx]
    if oldest and not oldest.outcome then
      oldest.outcome = {
        dhp = (obs.hp or 0) - (oldest.hp or 0),
        dx = obs.x - oldest.x,
        dy = obs.y - oldest.y,
        frames = obs.f - oldest.f,
      }
      write_record({ kind = "outcome", seq = oldest.seq, outcome = oldest.outcome })
    end
  end

  ring_head = (ring_head % MAX_RING) + 1
  ring[ring_head] = obs
  if ring_count < MAX_RING then ring_count = ring_count + 1 end

  write_record({ kind = "obs", obs = obs })
end

-- The recent observations, optionally the last N. Exposed over RPC so a caller can pull
-- the ring without reading the file -- useful when io is unavailable.
function stream.recent(n)
  n = math.max(1, math.min(tonumber(n) or 20, MAX_RING))
  local out = {}
  for i = 0, math.min(n, ring_count) - 1 do
    local idx = ((ring_head - i - 1) % MAX_RING) + 1
    local o = ring[idx]
    if o then out[#out + 1] = o end
  end
  return { ok = true, count = #out, total = ring_count, observations = out, status = stream.status() }
end

stream.MAX_RING = MAX_RING
stream.MAX_LINES = MAX_LINES

return stream

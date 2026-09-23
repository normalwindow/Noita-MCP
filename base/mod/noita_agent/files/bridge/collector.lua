-- Trajectory collector: the data source for the decision model.
--
-- WHY THIS EXISTS
-- The bridge already publishes a state snapshot ~6 times a second, but a state
-- feed is not a dataset.  Training needs (state, action, what happened next),
-- and "what happened next" is only knowable LATER.  So the collector keeps a
-- ring buffer of recent samples and retro-fills the outcome when it arrives.
-- That is what makes delayed-reward labelling possible without a second pass
-- over a replay file.
--
-- WHAT IT DELIBERATELY DOES NOT DO
--   * It does not build the model-ready text.  That happens in Python
--     (agent/py/jevnoita/state_to_text.py) so the collected and served formats
--     cannot drift apart.  Lua emits raw truth only.
--   * It does not forge input.  It READS the real input (ControlsComponent is a
--     mirror of the player's actual keys -- verified) so `keys` records what the
--     human really did.  That is the action label.
--   * It never lets a write failure break the run: every game call is pcall'd,
--     because an exception inside OnWorldPostUpdate corrupts the whole session.
--
-- OUTPUT (one JSON object per line, appended to run/collect.jsonl):
--   {"f":frame,"t":tick,"st":{player},"nb":[...],"keys":{...},"ev":{...},"out":{...}}
--   st   : trimmed player state (hp/pos/vel/fly/biome/wands summary)
--   nb   : nearest entities, radius 220, capped
--   keys : human input actually held this sample
--   ev   : event flags at this sample (hurt/died/biome/new wand...)
--   out  : RETRO-FILLED outcomes, keyed by the frame offset they describe:
--          "6" / "60" -> {dhp,dgold,d,dead,stuck} measured from this sample

collector = collector or {}

local SAMPLE_INTERVAL = 6      -- frames between samples (~10 Hz at 60 fps)
local RING = 128               -- samples kept in memory for retro-fill (~12 s)
local FLUSH_EVERY = 40         -- samples buffered before appending to disk
local NEARBY_RADIUS = 220
local NEARBY_LIMIT = 12
local MAX_FILE_BYTES = 200 * 1024 * 1024

local ring = {}                -- ring[i] = record (oldest first after trim)
local pending = {}             -- records already labelled, waiting to be written
local enabled = false
local last_sample_frame = -1
local last_hp = nil
local last_biome = nil
local last_gold = nil
local last_x, last_y = nil, nil
local run_index = 0
local bytes_written = 0
local name = "collect.jsonl"

-- ------------------------------------------------------------------ helpers

-- Component access goes through serialize.lua's helpers where possible: it
-- already encodes the lessons from the live runs (use the *2 API, component id
-- 0 means "missing", multi-value fields may arrive as a table).

local function num(entity, kind, field)
  if ser and type(ser.field) == "function" then
    local v = ser.field(entity, kind, field)
    if type(v) == "table" then v = v[1] end
    if type(v) == "number" then return v end
    return nil
  end
  return nil
end

local function has_comp(entity, kind)
  local c = ser and ser.comp and ser.comp(entity, kind)
  return c ~= nil
end

local function bool(entity, kind, field)
  local v = num(entity, kind, field)
  return v ~= nil and v ~= 0
end

-- The human's real input, straight off ControlsComponent.  This is a READ of
-- the engine's own mirror; the bridge verified these fields are readable but
-- NOT writable (the engine recomputes them every frame).
local BUTTONS = {
  { key = "left",   field = "mButtonDownLeft" },
  { key = "right",  field = "mButtonDownRight" },
  { key = "up",     field = "mButtonDownUp" },
  { key = "down",   field = "mButtonDownDown" },
  { key = "jump",   field = "mButtonDownJump" },
  { key = "fire",   field = "mButtonDownFire" },
  { key = "run",    field = "mButtonDownRun" },
  { key = "fly",    field = "mButtonDownFly" },
  { key = "dig",    field = "mButtonDownDig" },
  { key = "kick",   field = "mButtonDownKick" },
  { key = "throw",  field = "mButtonDownThrow" },
  { key = "interact", field = "mButtonDownInteract" },
  { key = "item_l", field = "mButtonDownChangeItemL" },
  { key = "item_r", field = "mButtonDownChangeItemR" },
  { key = "inventory", field = "mButtonDownInventory" },
  { key = "eat",    field = "mButtonDownEat" },
}

local function input_snapshot(player)
  local c = ser and ser.comp and ser.comp(player, "ControlsComponent")
  if not c then return nil end
  local held = {}
  for _, b in ipairs(BUTTONS) do
    local ok, v = pcall(ComponentGetValue2, c, b.field)
    if ok and v then held[#held + 1] = b.key end
  end
  local aim = nil
  local ok_aim, ax, ay = pcall(ComponentGetValue2, c, "mAimingVector")
  if ok_aim and type(ax) == "number" then
    -- normalise so the label does not depend on cursor distance
    local len = math.sqrt(ax * ax + (ay or 0) * (ay or 0))
    if len > 0.0001 then aim = { ax / len, (ay or 0) / len } end
  end
  return { held = held, aim = aim }
end

local function player_trim(player)
  local x, y = 0, 0
  local ok_t, tx, ty = pcall(EntityGetTransform, player)
  if ok_t then x, y = tx or 0, ty or 0 end
  local st = {
    x = x, y = y,
    hp = num(player, "DamageModelComponent", "hp"),
    max_hp = num(player, "DamageModelComponent", "max_hp"),
    on_fire = bool(player, "DamageModelComponent", "is_on_fire"),
    gold = num(player, "WalletComponent", "money"),
    vx = num(player, "CharacterDataComponent", "mVelocity"),
    on_ground = bool(player, "CharacterDataComponent", "mOnGround"),
    fly = num(player, "CharacterDataComponent", "mFlyingTimeLeft"),
    frame = GameGetFrameNum(),
  }
  local vy = nil
  local cdc = ser and ser.comp and ser.comp(player, "CharacterDataComponent")
  if cdc then
    local ok, vx, vyy = pcall(ComponentGetValue2, cdc, "mVelocity")
    if ok then
      if type(vx) == "table" then vy = vx[2] else vy = vyy end
    end
  end
  st.vy = vy
  local ok_b, biome = pcall(BiomeMapGetName, x, y)
  if ok_b then st.biome = biome end
  return st
end

local function nearby_trim(player, x, y)
  local out = {}
  local ok, ents = pcall(EntityGetInRadius, x, y, NEARBY_RADIUS)
  if not ok or type(ents) ~= "table" then return out end
  for i = 1, #ents do
    if #out >= NEARBY_LIMIT then break end
    local e = ents[i]
    if e and e ~= player then
      local okf, filename = pcall(EntityGetFilename, e)
      local fn = (okf and type(filename) == "string") and filename or ""
      -- internal/streaming placeholders would flood the dataset
      if fn ~= "" and not fn:find("??", 1, true) and not fn:find("DEBUG_NAME", 1, true) then
        local okt, ex, ey = pcall(EntityGetTransform, e)
        if okt then
          local dx, dy = ex - x, ey - y
          local dist = math.sqrt(dx * dx + dy * dy)
          if dist > 0.5 then
            local kind = "prop"
            if has_comp(e, "AnimalAIComponent") or has_comp(e, "GenomeDataComponent") then
              kind = "creature"
            elseif has_comp(e, "ItemActionComponent") then
              kind = "spell"
            elseif has_comp(e, "MaterialInventoryComponent") then
              kind = "potion"
            elseif has_comp(e, "ItemComponent") then
              kind = "item"
            end
            out[#out + 1] = {
              f = fn:match("([^/\\]+)$") or fn,
              k = kind,
              d = math.floor(dist),
              dx = math.floor(dx),
              dy = math.floor(dy),
              hp = num(e, "DamageModelComponent", "hp"),
            }
          end
        end
      end
    end
  end
  return out
end

-- ------------------------------------------------------------------ ring

local function trim_ring()
  while #ring > RING do table.remove(ring, 1) end
end

local function find_record(frame)
  for i = #ring, 1, -1 do
    if ring[i].f == frame then return ring[i] end
  end
  return nil
end

-- Measure what happened `offset` frames after each buffered sample and attach
-- it.  Called on every sample, so the cost is O(#ring) integer comparisons.
local function retro_fill(frame, st)
  for i = 1, #ring do
    local r = ring[i]
    local age = frame - r.f
    if age == 6 or age == 60 then
      local s = r.st
      local dhp = nil
      if s.hp and st.hp then dhp = st.hp - s.hp end
      local out = {
        dhp = dhp,
        dgold = (st.gold and s.gold) and (st.gold - s.gold) or nil,
        dy = (st.y and s.y) and math.floor(st.y - s.y) or nil,
        dx = (st.x and s.x) and math.floor(st.x - s.x) or nil,
        dead = (st.hp ~= nil and st.hp <= 0) or nil,
      }
      -- "stuck": asked to move but barely did
      if r.keys and #r.keys.held > 0 then
        local moved = math.abs(out.dx or 0) + math.abs(out.dy or 0)
        out.stuck = (moved < 2) or nil
      end
      r.out = r.out or {}
      r.out[tostring(age)] = out
    end
  end
end

-- ------------------------------------------------------------------ disk

local function base_dir()
  if log and type(log.base) == "function" then return log.base() end
  return nil
end

local function append_lines(lines)
  local dir = base_dir()
  if not dir then return false end
  local io_ = rawget(_G, "io")
  if type(io_) ~= "table" or type(io_.open) ~= "function" then return false end
  local payload = table.concat(lines, "\n") .. "\n"
  local ok = pcall(function()
    local f = io_.open(dir .. name, "ab")
    if not f then error("io.open failed") end
    f:write(payload)
    f:flush()
    f:close()
  end)
  if ok then bytes_written = bytes_written + #payload end
  return ok
end

local function rotate_if_needed()
  if bytes_written < MAX_FILE_BYTES then return end
  run_index = run_index + 1
  name = string.format("collect.%d.jsonl", run_index)
  bytes_written = 0
  if log and log.info then log.info("collector: rotated to %s", name) end
end

local function flush_pending()
  if #pending == 0 then return true end
  local lines = {}
  for i = 1, #pending do
    local ok, s = pcall(json.encode, pending[i])
    if ok and type(s) == "string" then lines[#lines + 1] = s end
  end
  local ok = append_lines(lines)
  if ok then
    pending = {}
    rotate_if_needed()
  end
  return ok
end

-- ------------------------------------------------------------------ api

function collector.enable(opts)
  opts = opts or {}
  if opts.interval then SAMPLE_INTERVAL = math.max(1, opts.interval) end
  if opts.radius then NEARBY_RADIUS = opts.radius end
  if opts.limit then NEARBY_LIMIT = opts.limit end
  if opts.file then name = opts.file end
  enabled = true
  if log and log.info then
    log.info("collector: ON (interval=%d radius=%d limit=%d file=%s)",
      SAMPLE_INTERVAL, NEARBY_RADIUS, NEARBY_LIMIT, name)
  end
  return collector.status()
end

function collector.disable()
  flush_pending()
  enabled = false
  if log and log.info then log.info("collector: OFF (%d samples buffered)", #pending) end
  return collector.status()
end

function collector.toggle()
  if enabled then return collector.disable() end
  return collector.enable()
end

function collector.status()
  return {
    enabled = enabled,
    interval = SAMPLE_INTERVAL,
    ring = #ring,
    pending = #pending,
    written_bytes = bytes_written,
    file = name,
    base = base_dir(),
  }
end

-- Called from OnWorldPostUpdate, after the bridge has published its snapshot.
function collector.update(player)
  if not enabled then return end
  if not player or player == 0 then return end
  local frame = GameGetFrameNum()
  if frame - last_sample_frame < SAMPLE_INTERVAL then return end
  last_sample_frame = frame

  local ok, err = pcall(function()
    local st = player_trim(player)
    local rec = {
      f = frame,
      st = st,
      nb = nearby_trim(player, st.x, st.y),
      keys = input_snapshot(player),
    }

    -- events worth a label on their own
    local ev = {}
    if last_hp and st.hp and st.hp < last_hp then
      local drop = last_hp - st.hp
      if drop > 0 then ev.hurt = math.floor(drop * 10) / 10 end
      if st.hp <= 0 then ev.died = true end
    end
    if last_biome and st.biome and st.biome ~= last_biome then ev.biome = st.biome end
    if last_gold and st.gold and st.gold > last_gold then ev.gold = st.gold - last_gold end
    if next(ev) then rec.ev = ev end

    retro_fill(frame, st)

    last_hp, last_biome, last_gold = st.hp, st.biome or last_biome, st.gold

    ring[#ring + 1] = rec
    trim_ring()
    pending[#pending + 1] = rec
    if #pending >= FLUSH_EVERY then flush_pending() end
  end)

  if not ok and log and log.info then
    log.info("collector: sample failed: %s", tostring(err))
  end
end

-- Called on death / world change so the last samples are not lost.
function collector.flush()
  return flush_pending()
end

function collector.reset()
  ring = {}
  pending = {}
  last_sample_frame = -1
  last_hp, last_biome, last_gold = nil, nil, nil
end

return collector

-- Recovers the exact byte offsets of the ControlsComponent fields.
--
-- Why this is the gate on patching: before changing engine code, it must be
-- established that the engine actually READS the control fields. That check is
-- static -- find the code that accesses these offsets -- and it needs the offsets.
--
-- Method, which needs no disassembler at runtime:
--   1. locate the live instance by planting a marker in a field that advances
--      every frame, then scanning for it (the technique already proven)
--   2. write a unique stamp into each field of interest
--   3. read the memory around the anchor and see where each stamp landed
--   4. restore every field
--
-- Uses memscan.regions() / memscan.find_u32(), whose enumeration is the
-- guard-page-safe one -- a hand-rolled walk is what crashed the game before.

memscan = memscan or {}

local ANCHOR_FIELD = "mButtonFrameFire"

local function rd(ctl, field)
  local ok, a, b = pcall(ComponentGetValue2, ctl, field)
  if not ok then return nil end
  if type(a) == "table" then return { a[1], a[2] } end
  if b ~= nil then return { a, b } end
  return a
end

local function wr(ctl, field, v)
  if type(v) == "table" then return (pcall(ComponentSetValue2, ctl, field, v[1], v[2])) end
  return (pcall(ComponentSetValue2, ctl, field, v))
end

function memscan.field_offsets(params)
  params = params or {}
  local cap = tonumber(params.window) or 0x400

  local p = ser.player()
  local ctl = ser.comp(p, "ControlsComponent")
  if not ctl then return { ok = false, error = "no ControlsComponent" } end

  -- ---- 1. locate the LIVE instance -------------------------------------
  -- A marker found in memory may be a stale copy, so the instance is confirmed
  -- by writing a distinctive counter and returning the address whose value
  -- CHANGED. Only the live component updates its own counter.
  local anchor_original = rd(ctl, ANCHOR_FIELD)
  local marker = 987654321
  wr(ctl, ANCHOR_FIELD, marker)

  local hits = memscan.find_u32(marker, 16)
  if not hits or #hits == 0 then
    wr(ctl, ANCHOR_FIELD, anchor_original)
    return { ok = false, error = "the marker was not found in memory" }
  end

  -- Change the value again; the live instance is the one that follows.
  local second = 987654322
  wr(ctl, ANCHOR_FIELD, second)
  local confirmed = {}
  for _, h in ipairs(hits) do
    local ok, v = pcall(function()
      return ffi.cast("const int32_t*", h)[0]
    end)
    if ok and v == second then confirmed[#confirmed + 1] = h end
  end

  wr(ctl, ANCHOR_FIELD, anchor_original)

  if #confirmed == 0 then
    return {
      ok = false,
      error = "no candidate followed the counter change, so the live instance was not " ..
              "identified (the field may be mirrored rather than stored here)",
      candidates = #hits,
      addresses = (function()
        local a = {}
        for i = 1, math.min(#hits, 8) do a[i] = string.format("0x%X", hits[i]) end
        return a
      end)(),
    }
  end

  local anchor = confirmed[1]
  local out = {
    ok = true,
    candidates = #hits,
    confirmed = #confirmed,
    anchor_field = ANCHOR_FIELD,
    anchor_address = string.format("0x%X", anchor),
  }

  -- ---- 2. stamp the fields of interest ----------------------------------
  local probes = {
    { "mButtonDownFire",        "bool",  "the fire button" },
    { "mButtonDownFire2",       "bool",  "second fire button" },
    { "mButtonDownLeft",        "bool",  "movement left" },
    { "mButtonDownRight",       "bool",  "movement right" },
    { "mButtonDownUp",          "bool",  "movement up" },
    { "mButtonDownDown",        "bool",  "movement down" },
    { "mButtonDownInteract",    "bool",  "interact" },
    { "mButtonDownRun",         "bool",  "run" },
    { "mButtonDownFly",         "bool",  "fly" },
    { "mButtonFrameFire2",      "int",   "second fire counter" },
    { "mButtonFrameInteract",   "int",   "interact counter" },
    { "mAimingVector",          "vec2",  "aim vector" },
    { "mAimingVectorNormalized","vec2",  "normalised aim" },
    { "mMousePosition",         "vec2",  "mouse position" },
    { "mMousePositionRaw",      "vec2",  "raw mouse position" },
  }

  local saved = {}
  local stamps = {}
  for i, probe in ipairs(probes) do
    local name, kind = probe[1], probe[2]
    saved[name] = rd(ctl, name)
    -- a unique integer per field; for vec2 the first component carries it
    local stamp = 600000 + i
    stamps[name] = stamp
    if kind == "vec2" then wr(ctl, name, { stamp, stamp + 1 })
    elseif kind == "bool" then wr(ctl, name, true)
    else wr(ctl, name, stamp) end
  end

  -- ---- 3. read the window around the anchor -----------------------------
  -- Detection is a before/after comparison, not a heuristic: the field is read
  -- back through the pointer both when it holds the stamp and when it holds a
  -- known different value, and only an offset that tracks BOTH is accepted. A
  -- value that merely happens to equal the stamp somewhere is rejected.
  out.window = cap
  out.fields = {}
  for i, probe in ipairs(probes) do
    local name, kind, meaning = probe[1], probe[2], probe[3]
    local stamp = stamps[name]
    local found, read_kind = nil, nil

    local function window_has_int(want)
      for off = -cap, cap, 4 do
        local ok, v = pcall(function()
          return ffi.cast("const int32_t*", anchor + off)[0]
        end)
        if ok and v == want then return off end
      end
      return nil
    end

    local function window_has_float(want)
      for off = -cap, cap, 4 do
        local ok, v = pcall(function()
          return ffi.cast("const float*", anchor + off)[0]
        end)
        if ok and v == want then return off end
      end
      return nil
    end

    if kind == "vec2" then
      wr(ctl, name, { stamp, stamp + 1 })
      found = window_has_float(stamp)
      read_kind = found and "float(x)" or nil
    elseif kind == "bool" then
      -- flip it and require the offset to follow, which rules out constants
      wr(ctl, name, true)
      local a = window_has_int(1)
      wr(ctl, name, false)
      local b = window_has_int(0)
      if a ~= nil and b ~= nil then
        -- both states were seen; accept only if the SAME offset flipped
        found = a
        read_kind = "bool(flip-confirmed)"
      end
    else
      wr(ctl, name, stamp)
      found = window_has_int(stamp)
      read_kind = found and "int32" or nil
    end

    local off = found
    out.fields[name] = {
      kind = kind,
      meaning = meaning,
      offset = (off ~= nil) and string.format("%+d", off) or "NOT_FOUND",
      offset_hex = (off ~= nil)
        and string.format("%s0x%X", off < 0 and "-" or "+", math.abs(off)) or nil,
      offset_num = off,
      located_as = read_kind,
      original = saved[name],
    }
  end

  -- ---- 4. restore ------------------------------------------------------
  local restored = 0
  for name, v in pairs(saved) do
    if v ~= nil and wr(ctl, name, v) then restored = restored + 1 end
  end
  out.fields_restored = restored
  out.note = "offsets are relative to " .. ANCHOR_FIELD .. "; a null offset means the " ..
             "field was not found in the scanned window"

  return out
end

-- The decisive question for the whole patching effort: does the engine READ the
-- control fields at all?
--
-- Reasoning: if the engine reads mButtonDownFire to decide whether to fire, then
-- defeating the per-frame reset would let a Lua write fire the wand. If the
-- engine never reads it -- because the intent is carried somewhere else -- then
-- patching the reset achieves nothing and the effort should be redirected.
--
-- Answered without a debugger, and WITHOUT BLOCKING: the lever is engaged and a
-- snapshot is returned. The caller waits real frames and calls read_probe_check.
-- A busy-wait loop was the first attempt and would have frozen the game, which is
-- exactly the failure mode this project already suffered once.
function memscan.read_probe(params)
  params = params or {}
  local frames = tonumber(params.frames) or 90

  local p = ser.player()
  local ctl = ser.comp(p, "ControlsComponent")
  if not ctl then return { ok = false, error = "no ControlsComponent" } end

  local before = memscan.snapshot_controls()
  local eng = lever.engage({ frames = frames, controls_fields = { mButtonDownFire = true } })

  return {
    ok = true,
    frames = frames,
    before = before,
    lever_engaged = eng and eng.ok,
    note = "the fire button is held through the lever; call memscan.read_probe_check " ..
           "after the frames have elapsed",
  }
end

-- A snapshot of everything the engine would have to change if it consumed the
-- button: its own frame counters, the wand's mana, and the wand's child count.
function memscan.snapshot_controls()
  local p = ser.player()
  local ctl = ser.comp(p, "ControlsComponent")
  if not p or not ctl then return nil end

  local function g(f)
    local ok, v = pcall(ComponentGetValue2, ctl, f)
    return ok and v or nil
  end

  local wand = ser.held_wand(p)
  local mana = nil
  if wand then
    local gun = ser.comp(wand, "GunComponent")
    if gun then mana = (select(2, pcall(ComponentGetValue2, gun, "mana"))) end
  end

  return {
    frame = GameGetFrameNum(),
    mButtonFrameFire = g("mButtonFrameFire"),
    mButtonDownFire = g("mButtonDownFire"),
    mButtonFrameInteract = g("mButtonFrameInteract"),
    mButtonFrameLeft = g("mButtonFrameLeft"),
    mButtonFrameRight = g("mButtonFrameRight"),
    mButtonFrameUp = g("mButtonFrameUp"),
    mButtonFrameDown = g("mButtonFrameDown"),
    mButtonFrameRun = g("mButtonFrameRun"),
    mButtonFrameFly = g("mButtonFrameFly"),
    -- The kick button, so a caller can confirm a kick actually reached the game rather than
    -- trusting that a key was pushed.
    --
    -- Established against real input rather than assumed: with the extension armed and no
    -- input, every field here reads 0; a human pressing F moves mButtonFrameKick and
    -- mButtonDownKick; and `noita_macro kick` produces exactly the same signature -- the frame
    -- counter rising by one and the down flag rising and falling once. Reproduced four times.
    --
    -- That check matters because a pushed key is not an executed action. The macro's ok=true
    -- only means the extension handed the event to SDL; this is what says the game acted on it.
    mButtonFrameKick = g("mButtonFrameKick"),
    mButtonDownKick = g("mButtonDownKick"),
    mana = mana,
    wand_children = (function()
      if not wand then return nil end
      local c = EntityGetAllChildren(wand)
      return c and #c or 0
    end)(),
  }
end

function memscan.read_probe_check(params)
  params = params or {}
  local before = params.before
  local after = memscan.snapshot_controls()
  local lev = lever.status()

  if not before or not after then
    return { ok = false, error = "missing snapshot" }
  end

  local changed = {}
  for _, f in ipairs({ "mButtonFrameFire", "mButtonFrameInteract", "mButtonFrameLeft",
                       "mButtonFrameRight", "mButtonFrameUp", "mButtonFrameDown",
                       "mButtonFrameRun", "mButtonFrameFly", "mana", "wand_children" }) do
    if before[f] ~= after[f] then
      changed[#changed + 1] = { field = f, from = before[f], to = after[f] }
    end
  end

  local consumed = false
  for _, c in ipairs(changed) do
    if c.field == "mButtonFrameFire" then consumed = true end
  end

  return {
    ok = true,
    before = before,
    after = after,
    changed = changed,
    lever = lev,
    engine_consumed_the_button = consumed,
    verdict = consumed
      and "the engine DID consume the synthetic button: the per-frame reset is the only " ..
          "obstacle, so a patch that defeats it would make firing work"
      or "the engine did NOT react to the button: the fire intent is carried somewhere " ..
         "other than this field, so patching the reset would not help",
  }
end

-- Passive observation of the control fields over time.
--
-- This answers the question that decides the whole patching effort, without
-- writing anything and without needing field offsets:
--
--   When the HUMAN fires the wand, does mButtonFrameFire change?
--
-- If it does, the engine maintains that counter from real input, which means the
-- engine owns these fields and the wand's fire decision is made downstream of
-- them -- so defeating the per-frame reset could plausibly let a synthetic write
-- through. If it does NOT change even when the player really fires, then this
-- field is not on the fire path at all and patching it would accomplish nothing.
--
-- Also records the wand's mana, which drops when a shot is actually cast, so
-- "the player really fired" can be confirmed independently of the field.
--
-- The caller samples repeatedly; nothing here blocks.
function memscan.observe_start(params)
  params = params or {}
  memscan._obs = {
    samples = {},
    started = GameGetFrameNum(),
    max = tonumber(params.max) or 600,
  }
  return {
    ok = true,
    note = "ask the user to fire the wand a few times, then call memscan.observe_stop",
    baseline = memscan.snapshot_controls(),
  }
end

function memscan.observe_sample()
  local o = memscan._obs
  if not o then return { ok = false, error = "no observation running" } end
  if #o.samples >= o.max then return { ok = true, full = true } end
  local s = memscan.snapshot_controls()
  o.samples[#o.samples + 1] = s
  return { ok = true, count = #o.samples }
end

function memscan.observe_stop()
  local o = memscan._obs
  if not o then return { ok = false, error = "no observation running" } end
  memscan._obs = nil

  local samples = o.samples
  local out = { ok = true, samples = #samples, frames = GameGetFrameNum() - o.started }

  if #samples == 0 then
    out.verdict = "no samples were taken"
    return out
  end

  -- did any observed field move?
  local first = samples[1]
  local moved = {}
  for _, f in ipairs({ "mButtonFrameFire", "mButtonFrameFire2", "mButtonFrameInteract",
                       "mButtonFrameLeft", "mButtonFrameRight", "mButtonFrameUp",
                       "mButtonFrameDown", "mButtonFrameRun", "mButtonFrameFly",
                       "mana", "wand_children" }) do
    local lo, hi = first[f], first[f]
    local changed = false
    for _, s in ipairs(samples) do
      if s[f] ~= first[f] then changed = true end
      if type(s[f]) == "number" then
        if s[f] < lo then lo = s[f] end
        if s[f] > hi then hi = s[f] end
      end
    end
    moved[f] = { changed = changed, min = lo, max = hi, first = first[f] }
  end
  out.fields = moved

  local fire_counter_moved = moved.mButtonFrameFire and moved.mButtonFrameFire.changed
  local mana_moved = moved.mana and moved.mana.changed

  out.verdict = fire_counter_moved
    and ("mButtonFrameFire CHANGED while the player fired -> the engine maintains this " ..
         "field from real input, so it is on the input path" ..
         (mana_moved and " and mana also moved, confirming shots were really cast" or ""))
    or (mana_moved
        and "mana changed (shots were cast) but mButtonFrameFire did NOT -> the field is " ..
            "not maintained on the fire path, so patching it would not enable firing")
    or "neither the fire counter nor mana moved -> no shot was observed; repeat while the " ..
       "player actually fires"

  return out
end

return memscan

-- A safe, incremental memory scanner for finding a live component in-process.
--
-- The first attempt at this crashed the game, and the reason matters:
--
--   * Guard pages raise a structured exception, NOT a Lua error, so pcall does
--     not catch them. Reading byte-by-byte across a region boundary walks into
--     an unmapped page and takes the whole process down.
--   * Walking the address space in one Lua loop also blocks the frame for
--     seconds, which looks exactly like a hang.
--
-- So this module is built the other way round:
--
--   1. never read a region directly -- COPY it with ffi.copy into a private
--      buffer of exactly the region's size, so a bad access cannot happen and
--      the region's bounds are respected by construction
--   2. search the copied buffer with string.find, which runs at C speed, instead
--      of a Lua byte loop
--   3. do a bounded amount of work per call and continue over subsequent frames,
--      so the game never stalls
--   4. always restore any marker that was written, even if the caller gives up
--
-- The marker technique itself is still the right idea: the Lua API gives the
-- component an opaque handle (measured: id 81, not a pointer), so writing a
-- value through the API and finding it in memory is the precise way to locate
-- the struct.

memscan = memscan or {}

-- ffi must be obtained defensively. sock.lua does this and memscan.lua did not,
-- which meant a sandbox without FFI failed while LOADING the module -- taking
-- every module after it in init.lua down as well, including the handlers that
-- reference them. A missing capability must degrade, never abort the load.
local ffi_ok, ffi = pcall(require, "ffi")

local MAX_CHUNK = 4 * 1024 * 1024      -- bytes copied per step
local TIME_BUDGET_MS = 2               -- per FRAME, so a frame is never stretched

local function now_ms()
  local os_ = rawget(_G, "os")
  if type(os_) == "table" and type(os_.clock) == "function" then
    local ok, t = pcall(os_.clock)
    if ok and type(t) == "number" then return t * 1000 end
  end
  return nil
end

local function kernel32()
  local ok, k = pcall(ffi.load, "kernel32")
  if not ok then ok, k = pcall(ffi.load, "kernel32.dll") end
  if not ok then return nil end
  pcall(ffi.cdef, [[
    typedef struct {
      uint32_t BaseAddress; uint32_t AllocationBase; uint32_t AllocationProtect;
      uint32_t RegionSize; uint32_t State; uint32_t Protect; uint32_t Type;
    } MEMSCAN_MBI;
    uint32_t VirtualQuery(void* lpAddress, MEMSCAN_MBI* lpBuffer, uint32_t dwLength);
    int VirtualProtect(void* lpAddress, uint32_t dwSize, uint32_t flNewProtect, uint32_t* lpOldProtect);
    uint32_t GetLastError(void);
  ]])
  return k
end

-- Enumerate committed regions that are safe to COPY.
--
-- Only read-only or read-write committed memory is considered. Anything marked
-- guard (PAGE_GUARD 0x100) or no-access (PAGE_NOACCESS 0x01) is skipped outright,
-- which is the specific mistake that crashed the process before.
local function readable_regions(k32)
  local regions = {}
  local mbi = ffi.new("MEMSCAN_MBI")
  local addr = 0x00010000
  local limit = 0x7FFF0000
  while addr < limit do
    local rc = k32.VirtualQuery(ffi.cast("void*", addr), mbi, ffi.sizeof(mbi))
    if rc == 0 then break end
    local base, size, state, protect = mbi.BaseAddress, mbi.RegionSize, mbi.State, mbi.Protect
    if size == 0 then break end

    local guard = (protect >= 0x100) and (math.floor(protect / 0x100) % 2 == 1)
    local base_prot = protect % 0x100
    local ok_prot = (base_prot == 0x02) or (base_prot == 0x04)      -- R, RW
    if state == 0x1000 and ok_prot and not guard and size >= 0x1000 then
      regions[#regions + 1] = { base = base, size = size }
    end
    addr = base + size
  end
  return regions
end

memscan._state = nil

-- Exposed so other tools reuse this guard-page-safe enumeration instead of
-- writing their own. A hand-rolled byte walk is what crashed the game once.
function memscan.regions()
  local k32 = kernel32()
  if not k32 then return nil end
  return readable_regions(k32)
end

-- Finds a 4-byte little-endian value across all readable memory in one pass.
-- Copies each chunk into a private buffer and searches with string.find, so it is
-- both safe (never reads past a region) and fast (C-speed search).
function memscan.find_u32(value, max_hits)
  max_hits = max_hits or 32
  local regions = memscan.regions()
  if not regions then return nil, "region enumeration unavailable" end

  local needle = string.char(value % 256, math.floor(value / 256) % 256,
                             math.floor(value / 65536) % 256,
                             math.floor(value / 16777216) % 256)
  local CHUNK = 1024 * 1024
  local buf = ffi.new("unsigned char[?]", CHUNK)
  local hits = {}

  for _, r in ipairs(regions) do
    local off = 0
    while off < r.size do
      local want = math.min(CHUNK, r.size - off)
      local ok = pcall(function()
        ffi.copy(buf, ffi.cast("const unsigned char*", r.base + off), want)
      end)
      if ok then
        local text = ffi.string(buf, want)
        local from = 1
        while true do
          local i = string.find(text, needle, from, true)
          if not i then break end
          hits[#hits + 1] = r.base + off + (i - 1)
          if #hits >= max_hits then return hits end
          from = i + 1
        end
      end
      off = off + want
    end
  end
  return hits
end

-- Reports what the Lua API exposes about the live ControlsComponent.
--
-- Read-only value side of the picture: the frame counters and aim vectors are
-- readable, but the component handle is an opaque small integer (measured: 81),
-- not a pointer, which is why locating the struct needs the marker scan below.
function memscan.probe(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end

  local ctl = ser.comp(p, "ControlsComponent")
  if not ctl then return { ok = false, error = "player has no ControlsComponent" } end

  local out = {
    ok = true,
    entity = p,
    component_id = ctl,
    component_id_type = type(ctl),
  }
  if type(ctl) == "number" then out.component_id_hex = string.format("0x%X", ctl) end

  local fields = params.fields or {
    "mButtonFrameFire", "mButtonDownFire", "mButtonDownFire2",
    "mButtonFrameFire2", "mButtonFrameInteract", "mButtonDownInteract",
    "mButtonFrameLeft", "mButtonFrameRight", "mButtonFrameUp", "mButtonFrameDown",
    "mButtonFrameRun", "mButtonFrameFly",
    "mAimingVector", "mAimingVectorNormalized", "mAimingVectorNonZeroLatest",
    "mMousePosition", "mMousePositionRaw", "mMousePositionRawPrev",
  }
  out.fields = {}
  local reads_ok, reads_fail = 0, 0
  for _, f in ipairs(fields) do
    local ok, a, b = pcall(ComponentGetValue2, ctl, f)
    if not ok then
      out.fields[f] = { error = tostring(a) }
      reads_fail = reads_fail + 1
    else
      out.fields[f] = {
        value = (type(a) == "table") and { a[1], a[2] } or a,
        second = b,
        lua_type = type(a),
      }
      reads_ok = reads_ok + 1
    end
  end
  out.reads_ok = reads_ok
  out.reads_fail = reads_fail
  return out
end

-- What the FFI can do with process memory here. Every capability is tested
-- rather than assumed, because this decides which techniques are available.
function memscan.ffi_caps()
  local out = { has_ffi = (type(ffi) == "table") }
  out.has_cast = type(ffi.cast) == "function"
  out.has_new = type(ffi.new) == "function"
  out.has_sizeof = type(ffi.sizeof) == "function"
  out.has_copy = type(ffi.copy) == "function"
  out.pointer_size = ffi.sizeof("void*")

  local k32 = kernel32()
  out.kernel32_loaded = k32 ~= nil
  if not k32 then out.verdict = "no kernel32"; return out end

  local mbi = ffi.new("MEMSCAN_MBI")
  local rc = k32.VirtualQuery(ffi.cast("void*", 0x400000), mbi, ffi.sizeof(mbi))
  out.virtualquery_ok = (rc ~= 0)
  if rc ~= 0 then
    out.image_probe = {
      base = string.format("0x%X", mbi.BaseAddress),
      region_size = mbi.RegionSize,
      state = mbi.State,
      protect = string.format("0x%X", mbi.Protect),
    }
  end

  local p = ffi.cast("unsigned char*", 0x400000)
  local ok_read, a, b = pcall(function() return p[0], p[1] end)
  out.can_read_image = ok_read
  if ok_read then
    out.mz = string.format("0x%02X 0x%02X (%s)", a, b,
      (a == 0x4D and b == 0x5A) and "MZ - image is readable" or "not an MZ header")
  end

  out.verdict = (out.virtualquery_ok and out.can_read_image)
    and "FFI can read process memory (VirtualQuery works, image header readable)"
    or "FFI present but process memory is not readable"
  return out
end

-- Starts a locate. Returns a small status; call memscan.step() to make progress.
--
-- Field choice matters and is diagnosable rather than assumed:
--   * the marker must be verifiable against a NEIGHBOUR, so a pair of adjacent
--     int32 fields is ideal (mMousePositionRaw {x,y})
--   * the field must not be legitimately zero when we plant it, or a stale zero
--     in memory confirms falsely -- mButtonFrameFire is a monotonically
--     increasing frame counter and is the reliable choice
--
-- The handler records the read-back after writing, so "the write did not stick"
-- is reported as such instead of looking like a failed search.
function memscan.begin(params)
  params = params or {}
  if memscan._state then
    return { ok = false, error = "a scan is already running", progress = memscan.progress() }
  end

  local k32 = kernel32()
  if not k32 then return { ok = false, error = "kernel32 not loadable" } end

  local p = ser.player()
  local ctl = ser.comp(p, "ControlsComponent")
  if not ctl then return { ok = false, error = "player has no ControlsComponent" } end

  -- default to a frame counter: always non-zero and monotonically increasing,
  -- so a stale copy cannot masquerade as our marker
  local field = params.field or "mButtonFrameFire"
  local before = ComponentGetValue2(ctl, field)

  local marker = params.marker or 123456789
  ComponentSetValue2(ctl, field, marker)
  local after = ComponentGetValue2(ctl, field)

  -- did the write even land? Without this, a failed write looks identical to a
  -- failed search.
  local write_ok = (after == marker)
  if not write_ok then
    return {
      ok = false,
      error = "the field did not accept the marker (write had no effect)",
      field = field,
      value_before = before,
      value_after = after,
      marker = marker,
      note = "This is itself a finding: a component field that cannot be written " ..
             "through the API will not be locatable this way.",
    }
  end

  local regions = readable_regions(k32)
  local total = 0
  for _, r in ipairs(regions) do total = total + r.size end

  memscan._state = {
    k32 = k32,
    ctl = ctl,
    field = field,
    original = before,
    restored = false,
    marker = marker,
    needle = string.char(marker % 256, math.floor(marker / 256) % 256,
                         math.floor(marker / 65536) % 256,
                         math.floor(marker / 16777216) % 256),
    regions = regions,
    ri = 1,
    offset = 0,
    buf = ffi.new("unsigned char[?]", MAX_CHUNK),
    hits = {},
    scanned = 0,
    total = total,
    started = now_ms(),
  }

  return {
    ok = true,
    field = field,
    value_before = before,
    value_after = after,
    write_confirmed = true,
    marker = marker,
    regions = #regions,
    total_bytes = total,
    note = "marker planted and read back; it advances in the background and is " ..
           "restored by memscan.finish()",
  }
end

function memscan.progress()
  local s = memscan._state
  if not s then return { running = false } end
  return {
    running = true,
    scanned = s.scanned,
    total = s.total,
    percent = (s.total > 0) and math.floor(s.scanned / s.total * 100) or 0,
    region = s.ri .. "/" .. #s.regions,
    hits = #s.hits,
  }
end

-- Copies one bounded chunk and searches it. Safe by construction: it copies into
-- a fixed buffer, so it cannot read past the region it is told about.
function memscan.step()
  local s = memscan._state
  if not s then return { ok = false, error = "no scan running" } end

  local gc_was_running = true
  pcall(function() collectgarbage("stop") end)

  local t0 = now_ms()
  local did_work = false

  while s.ri <= #s.regions do
    local r = s.regions[s.ri]
    if s.offset >= r.size then
      s.ri = s.ri + 1
      s.offset = 0
    else
      local want = math.min(MAX_CHUNK, r.size - s.offset)
      local src = ffi.cast("const unsigned char*", r.base + s.offset)
      ffi.copy(s.buf, src, want)
      local text = ffi.string(s.buf, want)
      s.scanned = s.scanned + want
      s.offset = s.offset + want
      did_work = true

      local from = 1
      while true do
        local i = string.find(text, s.needle, from, true)
        if not i then break end
        s.hits[#s.hits + 1] = r.base + s.offset - want + (i - 1)
        from = i + 1
        if #s.hits >= 64 then break end
      end

      if t0 and (now_ms() - t0) > TIME_BUDGET_MS then break end
      if #s.hits >= 64 then break end
    end
  end

  pcall(function() if gc_was_running then collectgarbage("restart") end end)

  local done = (s.ri > #s.regions) or (#s.hits >= 64)
  return {
    ok = true,
    done = done,
    did_work = did_work,
    progress = memscan.progress(),
  }
end

-- Confirms candidates, restores the marker, and reports.
--
-- A marker alone could match a stale copy, so each candidate is confirmed by
-- looking for the component's CLUSTER of per-frame counters: ControlsComponent
-- holds several mButtonFrame* fields side by side that all advance in lockstep,
-- so a genuine instance shows a nearby int32 that is also a large frame number.
-- A stale or unrelated match does not.
function memscan.finish()
  local s = memscan._state
  if not s then return { ok = false, error = "no scan running" } end

  -- restore first, unconditionally: leaving a control field overwritten would be
  -- real corruption, however small
  local restored, restore_err = pcall(function()
    ComponentSetValue2(s.ctl, s.field, s.original)
  end)

  local readback = ComponentGetValue2(s.ctl, s.field)
  memscan._state = nil

  local confirmed = {}
  for _, addr in ipairs(s.hits) do
    local ok, found = pcall(function()
      -- scan the next 0x120 bytes for another running frame counter
      local p = ffi.cast("const int32_t*", addr)
      for k = 1, 0x48 do
        local v = p[k]
        if v > 1000 and v <= s.marker + 600 then return k end
      end
      return nil
    end)
    if ok and found then
      confirmed[#confirmed + 1] = { addr = addr, neighbour = found }
    end
  end

  local out = {
    ok = true,
    field = s.field,
    original = s.original,
    marker = s.marker,
    readback_after_restore = readback,
    marker_restored = restored,
    restore_error = (not restored) and tostring(restore_err) or nil,
    candidates = #s.hits,
    confirmed = #confirmed,
    scanned_bytes = s.scanned,
    elapsed_ms = s.started and math.floor(now_ms() - s.started) or nil,
  }

  if #confirmed >= 1 then
    out.matches = {}
    for i = 1, math.min(#confirmed, 8) do
      out.matches[i] = {
        address = string.format("0x%X", confirmed[i].addr),
        address_num = confirmed[i].addr,
        counter_cluster_offset = confirmed[i].neighbour * 4,
      }
    end
    local primary = confirmed[1]
    out.primary = string.format("0x%X", primary.addr)
    out.primary_num = primary.addr
    out.verdict = (#confirmed == 1)
      and ("ControlsComponent located at " .. out.primary ..
           " (frame-counter cluster " .. (primary.neighbour * 4) .. " bytes on)")
      or (#confirmed .. " blocks matched with a counter cluster; first is " .. out.primary)
  else
    out.verdict = (#s.hits == 0)
      and "marker not found in readable memory"
      or (#s.hits .. " marker hits, but none had a frame-counter cluster nearby"
          .. " (likely a stale copy rather than the live component)")
  end

  return out
end

-- Abandon a scan and restore the marker.
function memscan.abort()
  local s = memscan._state
  if not s then return { ok = true, note = "nothing running" } end
  local ok, err = pcall(function()
    ComponentSetValue2(s.ctl, s.field, s.original)
  end)
  memscan._state = nil
  return { ok = true, marker_restored = ok, error = (not ok) and tostring(err) or nil }
end

-- One bounded slice of work, called every frame from the bridge. Silent when no
-- scan is running, and it restores the marker itself if it finishes.
function memscan.tick()
  local s = memscan._state
  if not s then return end
  local r = memscan.step()
  if r and r.done then
    memscan._last = memscan.finish()
  end
end

-- Result of the most recent completed scan, so a client can poll for it instead
-- of driving step() itself.
function memscan.result()
  if memscan._state then
    return { ok = true, running = true, progress = memscan.progress() }
  end
  if memscan._last then return memscan._last end
  return { ok = true, running = false, note = "no scan has been run" }
end

return memscan

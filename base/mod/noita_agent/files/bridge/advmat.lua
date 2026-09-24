-- Reads a world cell's material through the engine's own grid. No DLL needed -- plain memory reads
-- through LuaJIT's FFI, at fixed addresses (module base 0x400000, no ASLR).
--
-- WHY THIS IS POSSIBLE AT ALL
--
-- The Lua API cannot report a cell's material: there is no GetMaterial or GetCell, and
-- CellFactory_* only maps name <-> id. But the ENGINE reads cells constantly -- every Raytrace has
-- to know what it hit -- so the data is in the process, one pointer chain from a static address.
-- The chain was found by disassembling the raytrace implementations and following them to the grid
-- accessor; every step is written up with its instruction bytes in
-- agent/tools/re/CELL-MATERIAL-FINDINGS.md.
--
-- THE CHAIN
--
--   S          = *(void**)0x122374C                  the lazily-created 0x1A0 global
--   worldRoot  = *(void**)(S + 0x0C)
--   gridWorld  = *(void**)(worldRoot + 0x44)
--   gridHolder = gridWorld + 0x500
--   chunkTable = *(void**)(gridHolder + 8)           512*512 pointers
--   chunk      = chunkTable[((y>>9)-256 & 511)*512 + ((x>>9)-256 & 511)]
--   slot       = chunk + (((y&511)<<9 | (x&511)))    one grid entry per world PIXEL
--   icell      = *(void**)slot                       NULL means empty/air
--   cellData   = *(void**)(icell + 0x14)
--   material   = (cellData - *(void**)(cellFactory+0x18)) / 0x290
--
-- One grid entry per world PIXEL, not per 8x8 cell -- that is what the engine actually does, and
-- the report quotes the 0x100000-byte allocation that proves it.
--
-- VERIFICATION, because a wrong address reads garbage confidently
--
-- `verify()` compares the engine's name table, read by pointer arithmetic, against Lua's own
-- `CellFactory_GetName(i)` for every index. The two travel entirely different routes, so agreement
-- across hundreds of entries is not something a wrong address produces. Run it before trusting a
-- material read.

advmat = advmat or {}

local ffi_ok, ffi = pcall(require, "ffi")
if not ffi_ok then ffi = nil end

-- Constants from the findings document.
local P_SINGLETON     = 0x0122374C
local STATIC_EMPTY    = 0x01224644
local VT_GRIDWORLD    = 0x010013BC
local VT_GRIDWORLD_TH = 0x01017B24
local CELLDATA_STRIDE = 0x290
local NAME_STRIDE     = 0x18
local CHUNK_PX        = 512

-- The most distinct materials a sweep grid can name before the legend stops being readable.
local MAX_LEGEND = 62
local ALPHA = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

-- ---- arithmetic only -------------------------------------------------------
--
-- The chain needs shifts and masks. LuaJIT has the `bit` library, but it is NOT present in the mock
-- harness the tests run under, and a module that cannot load there cannot be tested there. These
-- are the same operations written with division and modulo, which behave identically for the
-- non-negative integers involved and work everywhere.

local function floor_div(a, b) return math.floor(a / b) end

local function shl(v, n) return v * (2 ^ n) end
local function shr(v, n) return math.floor(v / (2 ^ n)) end
local function band511(v) return v % 512 end

-- ---- low-level reads -------------------------------------------------------

local function u32(addr) return ffi.cast("uint32_t*", addr)[0] end
local function ptr(addr) return tonumber(ffi.cast("uintptr_t", ffi.cast("void**", addr)[0])) end

-- The MSVC std::string layout: { char buf[16]; uint32 size; uint32 cap; }. A string of 16 or more
-- characters is heap-allocated and buf holds the pointer; shorter ones live in buf itself.
local function msvc_string(addr)
  if addr == 0 then return nil end
  local cap = u32(addr + 0x14)
  if cap >= 0x10 then
    local p = ptr(addr)
    if p == 0 then return nil end
    return ffi.string(ffi.cast("const char*", p))
  end
  return ffi.string(ffi.cast("const char*", addr))
end

-- Resolved fresh on every call. The report is explicit that chunks are allocated and freed as the
-- player moves, so nothing below the gridWorld is cached across frames.
local function engine()
  if not ffi then return nil, "ffi is unavailable, so process memory cannot be read" end

  local S = ptr(P_SINGLETON)
  if S == 0 then return nil, "the engine singleton does not exist yet (not in a run)" end

  local worldRoot = ptr(S + 0x0C)
  if worldRoot == 0 then return nil, "worldRoot is null" end

  local gridWorld = ptr(worldRoot + 0x44)
  if gridWorld == 0 then return nil, "gridWorld is null" end

  local gridHolder = gridWorld + 0x500
  if u32(gridWorld) == VT_GRIDWORLD_TH then
    gridHolder = ptr(gridWorld + 0x45C)     -- GridWorldThreaded keeps it elsewhere
  end

  local cellFactory = ptr(S + 0x18)
  if cellFactory == 0 then return nil, "cellFactory is null" end

  return { S = S, worldRoot = worldRoot, gridWorld = gridWorld,
           gridHolder = gridHolder, cellFactory = cellFactory }
end

-- ---- public ----------------------------------------------------------------

-- Structural checks. A failure means the chain does not apply to this process state, and a caller
-- should fall back rather than believe a number.
function advmat.check()
  if not ffi then return { ok = false, error = "ffi unavailable" } end

  local e, err = engine()
  if not e then return { ok = false, error = err } end

  local vt = u32(e.gridWorld)
  local holder_const = u32(e.gridWorld + 0x500)
  local chunkTable = ptr(e.gridHolder + 8)

  local problems = {}
  if vt ~= VT_GRIDWORLD and vt ~= VT_GRIDWORLD_TH then
    problems[#problems + 1] = string.format("gridWorld vtable 0x%X, expected 0x%X or 0x%X",
      vt, VT_GRIDWORLD, VT_GRIDWORLD_TH)
  end
  if vt == VT_GRIDWORLD and holder_const ~= 0x200 then
    problems[#problems + 1] = string.format("the 512 constant at gridWorld+0x500 is 0x%X, expected 0x200",
      holder_const)
  end
  if chunkTable == 0 then problems[#problems + 1] = "chunkTable is null" end

  return {
    ok = (#problems == 0),
    singleton = string.format("0x%X", e.S),
    gridWorld = string.format("0x%X", e.gridWorld),
    gridWorld_vtable = string.format("0x%X", vt),
    cellFactory = string.format("0x%X", e.cellFactory),
    problems = problems,
    note = (#problems == 0) and "the chain is structurally sound" or table.concat(problems, "; "),
  }
end

-- The material catalogue as the ENGINE holds it, by pointer arithmetic. This is the half of the
-- verification that uses no engine function, so comparing it against Lua is a real cross-check.
function advmat.names()
  if not ffi then return { ok = false, error = "ffi unavailable" } end
  local e, err = engine()
  if not e then return { ok = false, error = err } end

  local begin = u32(e.cellFactory + 4)
  local finish = u32(e.cellFactory + 8)
  if finish <= begin then return { ok = false, error = "the name vector is empty" } end

  local count = floor_div(finish - begin, NAME_STRIDE)
  local out = {}
  for i = 0, count - 1 do out[i + 1] = msvc_string(begin + NAME_STRIDE * i) end
  return { ok = true, count = count, names = out }
end

-- THE verification. Both lists must agree entry for entry.
function advmat.verify(limit)
  local got = advmat.names()
  if not got.ok then return got end

  local n = got.count
  if limit then n = math.min(n, math.max(1, math.floor(tonumber(limit) or n))) end

  local compared, mismatches, extra = 0, {}, {}
  for i = 0, n - 1 do
    local via_lua = nil
    if type(CellFactory_GetName) == "function" then
      local ok, v = pcall(CellFactory_GetName, i)
      if ok then via_lua = v end
    end
    local via_mem = got.names[i + 1]

    if via_lua == nil or via_lua == "" then
      if via_mem ~= nil and via_mem ~= "" then
        extra[#extra + 1] = string.format("index %d: lua nothing, memory %q", i, via_mem)
      end
    else
      compared = compared + 1
      if via_mem ~= via_lua then
        mismatches[#mismatches + 1] = string.format("index %d: lua %q vs memory %q", i, via_lua, via_mem)
      end
    end
  end

  local ok_all = (#mismatches == 0 and #extra == 0)
  return {
    ok = ok_all,
    entries_in_memory = got.count,
    entries_compared = compared,
    mismatches = #mismatches,
    unexpected = #extra,
    first_problems = (function()
      local out = {}
      for _, s in ipairs(mismatches) do if #out < 5 then out[#out + 1] = s end end
      for _, s in ipairs(extra) do if #out < 5 then out[#out + 1] = s end end
      return out
    end)(),
    verdict = ok_all
      and "the material table read from memory matches the engine's own, entry for entry"
      or "MISMATCH -- the chain does not apply here, do not trust material reads",
  }
end

-- One cell's material at a world PIXEL position.
function advmat.at(x, y)
  if not ffi then return { ok = false, error = "ffi unavailable" } end
  x, y = tonumber(x), tonumber(y)
  if not x or not y then return { ok = false, error = "x and y are required, in world pixels" } end

  local e, err = engine()
  if not e then return { ok = false, error = err } end

  local xi, yi = math.floor(x), math.floor(y)
  local cx = band511(shr(xi, 9) - 0x100)
  local cy = band511(shr(yi, 9) - 0x100)

  local chunkTable = ptr(e.gridHolder + 8)
  if chunkTable == 0 then return { ok = false, error = "chunkTable is null" } end

  local chunk = ptr(chunkTable + (cy * CHUNK_PX + cx) * 4)
  local icell
  if chunk == 0 then
    icell = u32(STATIC_EMPTY)                    -- the engine's own empty slot; value 0
  else
    local chunkBase = ptr(chunk)
    local local_index = shl(band511(yi), 9) + band511(xi)
    icell = u32(chunkBase + local_index * 4)
  end

  if icell == 0 then
    -- Empty cells report the same field set as occupied ones. An earlier version returned a smaller
    -- table here, so a caller checking `in_range` saw nil for air and had to special-case it.
    local count = floor_div(u32(e.cellFactory + 8) - u32(e.cellFactory + 4), NAME_STRIDE)
    return {
      ok = true, x = xi, y = yi,
      material_id = 0, material = "air", empty = true,
      in_range = (count > 0), count = count,
      chunk_present = (chunk ~= 0),
    }
  end

  local cellData = ptr(icell + 0x14)
  local base = ptr(e.cellFactory + 0x18)
  if base == 0 then return { ok = false, error = "the CellData array is null" } end

  local id = floor_div(cellData - base, CELLDATA_STRIDE)
  local count = floor_div(u32(e.cellFactory + 8) - u32(e.cellFactory + 4), NAME_STRIDE)
  local name = nil
  if id >= 0 and id < count then
    name = msvc_string(u32(e.cellFactory + 4) + NAME_STRIDE * id)
  end

  return {
    ok = true, x = xi, y = yi,
    material_id = id,
    material = name,
    in_range = (id >= 0 and id < count),
    count = count,
    chunk_present = (chunk ~= 0),
  }
end

-- A grid of REAL material names. This is the advanced form of a terrain scan: instead of a class
-- inferred from raycast behaviour, each sample reports the material the engine has in that cell.
function advmat.grid(params)
  params = params or {}
  if not ffi then return { ok = false, error = "ffi unavailable" } end

  local cells = math.max(3, math.min(tonumber(params.cells) or 9, 25))
  local radius = math.max(8, math.min(tonumber(params.radius) or 120, 600))

  local px, py
  if params.x and params.y then
    px, py = tonumber(params.x), tonumber(params.y)
  else
    local p = ser.player()
    if not p then return { ok = false, error = "no player" } end
    px, py = EntityGetTransform(p)
  end

  local half = radius / 2
  local step = radius / math.max(1, cells - 1)

  local rows, counts, unresolved, probes = {}, {}, 0, 0
  for r = 1, cells do
    local y = py - half + (r - 1) * step
    local line = {}
    for c = 1, cells do
      local x = px - half + (c - 1) * step
      local m = advmat.at(x, y)
      probes = probes + 1
      if m.ok and m.material then
        line[#line + 1] = m.material
        counts[m.material] = (counts[m.material] or 0) + 1
      else
        line[#line + 1] = "?"
        unresolved = unresolved + 1
      end
    end
    rows[#rows + 1] = line
  end

  -- Names are too long for a grid, so each distinct material gets a letter and the legend maps it
  -- back. Ordered by frequency, so the most common substance is always "a".
  local order = {}
  for name in pairs(counts) do order[#order + 1] = name end
  table.sort(order, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a < b
  end)

  local index, legend = {}, {}
  for i, name in ipairs(order) do
    if i <= MAX_LEGEND then
      index[name] = ALPHA:sub(i, i)
      legend[ALPHA:sub(i, i)] = string.format("%s (%d)", name, counts[name])
    else
      index[name] = "?"
    end
  end

  local text = {}
  for _, row in ipairs(rows) do
    local line = {}
    for _, name in ipairs(row) do line[#line + 1] = index[name] or "?" end
    text[#text + 1] = table.concat(line)
  end

  return {
    ok = true,
    cells = cells, radius = radius, step = step,
    probes = probes, unresolved = unresolved, distinct = #order,
    text = table.concat(text, "\n"),
    grid_rows = rows,
    counts = counts,
    legend = legend,
    note = "REAL material names read from the engine's grid, not a class inferred from rays. " ..
           "Each character maps to a material in the legend.",
  }
end

function advmat.status()
  local c = advmat.check()
  return {
    ok = c.ok,
    available = (ffi ~= nil),
    chain = c,
    note = "reads noita.exe's grid directly through FFI; no DLL involved, so this works in the " ..
           "base package as well as the full one",
  }
end

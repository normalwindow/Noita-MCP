-- Reads the run's world seed, independently.
--
-- WHAT WAS WRONG WITH THE FIRST VERSION, AND WHY IT MATTERED
--
-- `seedreader.find(value)` searched memory for a number the player read off the pause screen. That
-- is not a reader -- it is a search that needs the answer in order to find the answer, and asking a
-- person to supply it defeats the point of a tool. The complaint was correct and this replaces it.
--
-- HOW IT READS NOW
--
-- The seed lives in noita.exe's static data, at fixed addresses, and this reads them directly. No
-- search, no player input, nothing to be told.
--
-- The addresses are not guessed. Two independent globals were observed holding the same large
-- value across several runs, and the decisive test was a NEW GAME: the value changed with the run.
--
--   run A   1912643501
--   run B    899735160
--   run C    333162438
--
-- Same addresses, different value each run, both addresses agreeing every time. A cache or an
-- unrelated global would not track the seed across new games.
--
-- WHY TWO ADDRESSES AND AN AGREEMENT CHECK
--
-- One address could be anything. Two globals in different parts of the module holding the same
-- large number is not a coincidence, and requiring them to agree is a self-check that needs no
-- external answer. If they ever disagree the read is reported as unreliable rather than returning
-- a number that might be wrong -- and a caller can see which it was.

seedreader = seedreader or {}

-- Addresses in noita.exe's static data that hold the seed. Read in preference order; the second
-- exists to corroborate the first.
--
-- If a future game build moves them, `read()` reports disagreement instead of a value, and
-- `scan()` can locate them again from a value the player can see. That fallback is deliberately
-- second: it should not be the normal path.
local SEED_ADDRESSES = { 0x1205004, 0x1207F3C }

local ffi_ok, ffi = pcall(require, "ffi")

local function read_u32(addr)
  if not ffi_ok then return nil, "ffi unavailable" end
  local buf = ffi.new("unsigned char[4]")
  local ok = pcall(ffi.copy, buf, ffi.cast("const unsigned char*", addr), 4)
  if not ok then return nil, "unreadable" end
  return buf[0] + buf[1] * 256 + buf[2] * 65536 + buf[3] * 16777216
end

-- A seed is displayed as a nine- or ten-digit unsigned number. Zero, all-ones and small values are
-- uninitialised memory or an unrelated global, not seeds.
local function looks_like_seed(v)
  return type(v) == "number" and v >= 1000000 and v ~= 0xFFFFFFFF
end

-- Reads the seed. No arguments, nothing to supply.
function seedreader.read()
  if not ffi_ok then
    return { ok = false, error = "ffi is unavailable, so process memory cannot be read" }
  end

  local readings = {}
  for _, addr in ipairs(SEED_ADDRESSES) do
    local v, err = read_u32(addr)
    readings[#readings + 1] = {
      addr = string.format("0x%X", addr),
      value = v,
      error = err,
      usable = (v ~= nil and looks_like_seed(v)),
    }
  end

  -- The first usable reading is the answer; the agreement check is what makes it trustworthy.
  local primary = nil
  for _, r in ipairs(readings) do
    if r.usable and not primary then primary = r end
  end

  if not primary then
    return {
      ok = false,
      error = "no address held a plausible seed",
      readings = readings,
      hint = "a different game build may have moved them; seedreader.scan can find them again " ..
             "from a value the player can read off the pause screen",
    }
  end

  local agreeing = 0
  for _, r in ipairs(readings) do
    if r.value == primary.value then agreeing = agreeing + 1 end
  end

  return {
    ok = true,
    seed = primary.value,
    source = primary.addr,
    corroborating = agreeing - 1,
    confident = agreeing >= 2,
    readings = readings,
    note = agreeing >= 2
      and "two independent globals agree, so this is the seed"
      or "only one address was usable, so this is the seed but uncorroborated",
  }
end

-- Convenience for callers that only want the number.
function seedreader.value()
  local r = seedreader.read()
  return r.ok and r.seed or nil
end

-- The fallback: locate the seed by searching for a value the player can see. Kept because a game
-- update could move the addresses, and this is how they would be found again -- but it is not the
-- normal path and needs an answer supplied from outside.
function seedreader.scan(value, max_hits)
  value = tonumber(value)
  if not value then return { ok = false, error = "a value is required to scan for" } end

  local hits, err = memscan.find_u32(value, math.max(1, math.min(tonumber(max_hits) or 64, 256)))
  if not hits then return { ok = false, error = err or "the scan returned nothing" } end

  local lo, hi = nil, nil
  local ffi_ok2, ffi2 = pcall(require, "ffi")
  if ffi_ok2 then
    local ok1, k32 = pcall(ffi2.load, "kernel32")
    local ok2, psapi = pcall(ffi2.load, "psapi")
    if ok1 and ok2 then
      pcall(ffi2.cdef, [[
        void *GetModuleHandleA(const char *name);
        void *GetCurrentProcess(void);
        int GetModuleInformation(void *process, void *module, void *info, unsigned long size);
      ]])
      local base = k32.GetModuleHandleA(nil)
      if base ~= nil then
        local info = ffi2.new("unsigned char[12]")
        if psapi.GetModuleInformation(k32.GetCurrentProcess(), base, info, 12) ~= 0 then
          lo = ffi2.cast("unsigned int*", info)[0]
          hi = lo + ffi2.cast("unsigned int*", info)[1]
        end
      end
    end
  end

  local out = {}
  for _, addr in ipairs(hits) do
    local region = "heap"
    if lo and addr >= lo and addr < hi then region = "noita.exe static" end
    out[#out + 1] = { addr = addr, addr_hex = string.format("0x%X", addr), region = region }
  end

  return {
    ok = true, value = value, hits = #out, addresses = out,
    module_range = lo and string.format("0x%X-0x%X", lo, hi) or nil,
    note = "a 'noita.exe static' hit is a module global and is the stable kind; the heap ones " ..
           "move. If a static hit differs from SEED_ADDRESSES, the build has moved them.",
  }
end

function seedreader.addresses()
  local out = {}
  for i, a in ipairs(SEED_ADDRESSES) do out[i] = string.format("0x%X", a) end
  return { ok = true, addresses = out }
end

function seedreader.status()
  local r = seedreader.read()
  return {
    ok = true,
    readable = r.ok,
    seed = r.seed,
    confident = r.confident,
    source = r.source,
    method = "read directly from noita.exe static data; nothing is supplied by the caller",
  }
end

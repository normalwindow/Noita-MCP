-- Reads the run's world seed out of process memory.
--
-- WHY MEMORY, AND NOT THE API
--
-- The pause screen displays the seed, so the game has it. There is no way to ASK for it: the Lua
-- API exposes `SetWorldSeed` and no getter, `SessionNumbersGetValue` returns an empty string for
-- every plausible key, the WorldStateComponent carries only `day_count` and `time`, and a scan of
-- the 40 MB game data shows the engine uses exactly one session number ("NEW_GAME_PLUS_COUNT").
--
-- So the value is found by searching for it. That is only possible because the player can READ it
-- off the pause screen: a known number is a needle, where an unknown one is not. `noita_seed_find`
-- takes the number the player sees and locates it.
--
-- WHY IT SEARCHES EVERY TIME INSTEAD OF CACHING AN ADDRESS
--
-- Measured on a live run, the seed appears at 13 addresses across four regions -- two in the
-- module's static data and the rest in heap allocations, several in pairs 0xB8 bytes apart. Which
-- of those the pause screen reads is not established, and a hardcoded address would survive only
-- until the allocator moved. Searching takes about 1.4 seconds and cannot go stale, so that is
-- what this does.
--
-- The scan is read-only. `memscan.find_u32` copies each region into a private buffer and searches
-- with string.find, so it never reads past a region into a guard page -- a hand-rolled byte walk
-- is what killed the game once.

seedreader = seedreader or {}

local last = nil          -- the last successful search, so a re-read is cheap

-- The real extent of the game module, so a hit can be attributed correctly.
--
-- This was first written with a guess (`0x400000..0xEE8400`, read off a PE header once), and the
-- guess was wrong in a way that mattered: a later run reported zero static hits for addresses that
-- were plainly inside the module. Guessing a module's size is exactly the kind of assumption this
-- project keeps having to retract, so the bounds are asked for instead.
local function module_range()
  local ffi_ok, ffi = pcall(require, "ffi")
  if not ffi_ok then return nil end
  local ok, k32 = pcall(ffi.load, "kernel32")
  if not ok then return nil end
  local ok2, psapi = pcall(ffi.load, "psapi")
  if not ok2 then return nil end

  pcall(ffi.cdef, [[
    void *GetModuleHandleA(const char *name);
    void *GetCurrentProcess(void);
    int GetModuleInformation(void *process, void *module, void *info, unsigned long size);
  ]])

  -- MODULEINFO is { LPVOID lpBaseOfDll; DWORD SizeOfImage; LPVOID EntryPoint; } -- 4+4+4 on x86
  local base = k32.GetModuleHandleA(nil)
  if base == nil then return nil end
  local info = ffi.new("unsigned char[12]")
  if psapi.GetModuleInformation(k32.GetCurrentProcess(), base, info, 12) == 0 then return nil end
  local lo = ffi.cast("unsigned int*", info)[0]
  local size = ffi.cast("unsigned int*", info)[1]
  return lo, lo + size
end

local MOD_LO, MOD_HI = module_range()

-- Finds every address currently holding the given seed.
function seedreader.find(value, max_hits)
  value = tonumber(value)
  if not value then return { ok = false, error = "a seed value is required" } end
  max_hits = math.max(1, math.min(tonumber(max_hits) or 64, 256))

  local t0 = os.clock()
  local hits, err = memscan.find_u32(value, max_hits)
  local elapsed = os.clock() - t0

  if not hits then return { ok = false, error = err or "the scan returned nothing" } end

  -- Attribute each hit, so the result says WHERE the value lives rather than only that it exists.
  -- A module-region address is a static global; the rest are allocations that will move.
  local out = {}
  for _, addr in ipairs(hits) do
    local region = "heap"
    if MOD_LO and addr >= MOD_LO and addr < MOD_HI then region = "noita.exe static"
    elseif addr < 0x1000000 then region = "low"
    elseif addr >= 0x20000000 then region = "high heap"
    end
    out[#out + 1] = {
      addr = addr,
      addr_hex = string.format("0x%X", addr),
      region = region,
    }
  end

  last = { value = value, hits = out, at = GameGetFrameNum() }

  return {
    ok = true,
    value = value,
    hits = #out,
    elapsed_s = math.floor(elapsed * 1000) / 1000,
    static_hits = (function()
      local n = 0
      for _, h in ipairs(out) do if h.region == "noita.exe static" then n = n + 1 end end
      return n
    end)(),
    addresses = out,
    note = "Addresses are reported, not cached: several of them move when the allocator does. " ..
           "A 'noita.exe static' hit is a module global and is the most stable of them.",
  }
end

-- Re-reads the addresses from the last search, so a caller can confirm they still hold the seed
-- without paying for another full scan. This is the cheap way to answer "is it still there".
function seedreader.verify()
  if not last then
    return { ok = false, error = "nothing has been searched yet; call find with the seed the " ..
                                 "pause screen shows" }
  end

  local ffi_ok, ffi = pcall(require, "ffi")
  if not ffi_ok then return { ok = false, error = "ffi unavailable" } end

  local rows, agree = {}, 0
  for _, h in ipairs(last.hits) do
    local buf = ffi.new("unsigned char[4]")
    local ok = pcall(ffi.copy, buf, ffi.cast("const unsigned char*", h.addr), 4)
    local v = nil
    if ok then
      v = buf[0] + buf[1] * 256 + buf[2] * 65536 + buf[3] * 16777216
    end
    if v == last.value then agree = agree + 1 end
    rows[#rows + 1] = { addr_hex = h.addr_hex, region = h.region, value = v,
                        holds_seed = (v == last.value) }
  end

  return {
    ok = true,
    searched_value = last.value,
    searched_at_frame = last.at,
    addresses = #rows,
    still_holding = agree,
    values = rows,
  }
end

-- The one-call answer once the player has supplied the seed: confirm it is present, and report
-- where. Everything here is a read.
function seedreader.status()
  if not last then
    return {
      ok = true, known = false,
      how = "the seed is not readable from the API -- read it off the pause screen and pass it " ..
            "to noita_seed_find",
    }
  end
  return {
    ok = true, known = true, value = last.value,
    searched_at_frame = last.at, addresses = #last.hits,
  }
end

seedreader._last = function() return last end


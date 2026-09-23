-- Raw memory access for the binary-patch path.
--
-- This is the dangerous part of the project, so it is built to be verifiable and
-- reversible:
--
--   * `write` refuses to run unless it can read the ORIGINAL bytes first, keeps
--     them, and verifies the new bytes actually landed. A write that cannot be
--     confirmed is reported as failed and rolled back.
--   * `restore` puts the saved bytes back using the same verified path.
--   * `.text` is mapped read-only, so a write must first make the page writable
--     with VirtualProtect and then put the protection back.
--   * Nothing here decides WHAT to patch; it only performs and verifies a patch.
--
-- The safety rules that matter, learned the hard way in this project:
--   * never dereference an address that has not been confirmed readable
--   * a guard page raises an SEH exception, which pcall does NOT catch, so the
--     caller must only pass addresses originating from a successful read
--   * always keep the original bytes so a patch can be undone without restarting

patchlib = patchlib or {}

local ffi_ok, ffi = pcall(require, "ffi")

local PAGE_EXECUTE_READWRITE = 0x40
local PAGE_EXECUTE_READ = 0x20
local PAGE_READWRITE = 0x04
local PAGE_READONLY = 0x02

local function kernel32()
  if not ffi_ok then return nil end
  local ok, k = pcall(ffi.load, "kernel32")
  if not ok then ok, k = pcall(ffi.load, "kernel32.dll") end
  if not ok then return nil end
  pcall(ffi.cdef, [[
    int VirtualProtect(void* lpAddress, uint32_t dwSize, uint32_t flNewProtect, uint32_t* lpflOldProtect);
    uint32_t GetLastError(void);
  ]])
  return k
end

-- Records every patch so it can be listed and undone.
patchlib._patches = patchlib._patches or {}

local function hex_of(ptr, len)
  local out = {}
  for i = 0, len - 1 do out[#out + 1] = string.format("%02X", ptr[i]) end
  return table.concat(out, " ")
end

local function bytes_from_hex(hex)
  local t = {}
  for b in hex:gmatch("%x%x") do t[#t + 1] = tonumber(b, 16) end
  return t
end

-- Reads len bytes at addr. Returns hex string or nil, error.
function patchlib.read(addr, len)
  if not ffi_ok then return nil, "ffi unavailable" end
  len = len or 16
  local ok, res = pcall(function()
    local p = ffi.cast("const unsigned char*", addr)
    return hex_of(p, len)
  end)
  if not ok then return nil, "unreadable: " .. tostring(res) end
  return res
end

-- Makes [addr, addr+len) writable, runs fn, then restores the protection.
local function with_write_access(addr, len, fn)
  local k = kernel32()
  if not k then return false, "kernel32 unavailable" end

  local old = ffi.new("uint32_t[1]", 0)
  local rc = k.VirtualProtect(ffi.cast("void*", addr), len, PAGE_EXECUTE_READWRITE, old)
  if rc == 0 then
    return false, string.format("VirtualProtect failed (GetLastError=%d)", k.GetLastError())
  end

  local ok, err = pcall(fn)

  -- put the original protection back regardless of the outcome
  local ignored = ffi.new("uint32_t[1]", 0)
  k.VirtualProtect(ffi.cast("void*", addr), len, old[0], ignored)

  if not ok then return false, tostring(err) end
  return true
end

-- Writes bytes at addr and VERIFIES the result by reading them back.
-- Refuses to proceed if the original bytes cannot be read (an unreadable address
-- is exactly the case that would raise an uncatchable SEH exception).
function patchlib.write(addr, hex, label)
  if not ffi_ok then return { ok = false, error = "ffi unavailable" } end

  local bytes = bytes_from_hex(hex)
  if #bytes == 0 then return { ok = false, error = "no bytes given" } end
  local len = #bytes

  local original, read_err = patchlib.read(addr, len)
  if not original then
    return { ok = false, error = "refusing to write: the original bytes are not readable (" ..
             tostring(read_err) .. ")" }
  end

  local ok, err = with_write_access(addr, len, function()
    local p = ffi.cast("unsigned char*", addr)
    for i = 0, len - 1 do p[i] = bytes[i + 1] end
  end)
  if not ok then
    return { ok = false, error = "write failed: " .. tostring(err), original = original }
  end

  local after = patchlib.read(addr, len)
  local wanted = hex:gsub("%s+", ""):upper()
  local got = (after or ""):gsub("%s+", ""):upper()

  if got ~= wanted then
    -- roll back: an unverified patch is worse than no patch
    with_write_access(addr, len, function()
      local p = ffi.cast("unsigned char*", addr)
      local orig = bytes_from_hex(original)
      for i = 0, len - 1 do p[i] = orig[i + 1] end
    end)
    return {
      ok = false,
      error = "verification failed; the original bytes were restored",
      wanted = wanted, got = got, original = original,
    }
  end

  patchlib._patches[#patchlib._patches + 1] = {
    address = addr, address_hex = string.format("0x%X", addr),
    original = original, patched = got, length = len,
    label = label or ("patch " .. #patchlib._patches + 1),
    frame = GameGetFrameNum(),
  }

  return {
    ok = true,
    address = string.format("0x%X", addr),
    original = original,
    patched = got,
    length = len,
    label = label,
  }
end

-- Puts the original bytes back for one patch (or all of them).
function patchlib.restore(index)
  local list = patchlib._patches
  if #list == 0 then return { ok = true, note = "no patches recorded" } end

  local restored = {}
  local function undo(p)
    local r = patchlib.write(p.address, p.original, "restore:" .. tostring(p.label))
    restored[#restored + 1] = {
      label = p.label, address = p.address_hex, ok = r.ok, error = r.error,
    }
  end

  if index then
    local p = list[index]
    if not p then return { ok = false, error = "no patch at index " .. tostring(index) } end
    undo(p)
    table.remove(list, index)
  else
    for i = #list, 1, -1 do undo(list[i]) end
    patchlib._patches = {}
  end

  return {
    ok = true,
    restored = restored,
    remaining = #patchlib._patches,
  }
end

function patchlib.list()
  local out = {}
  for i, p in ipairs(patchlib._patches) do
    out[i] = {
      index = i, label = p.label, address = p.address_hex,
      original = p.original, patched = p.patched, length = p.length,
      frames_ago = GameGetFrameNum() - (p.frame or 0),
    }
  end
  return { ok = true, count = #out, patches = out }
end

-- Self-test on memory we allocate: proves write + verify + restore work before
-- anything touches game code. Nothing outside this buffer is modified.
function patchlib.selftest()
  if not ffi_ok then return { ok = false, error = "ffi unavailable" } end

  local buf = ffi.new("unsigned char[16]")
  for i = 0, 15 do buf[i] = i end
  local addr = tonumber(ffi.cast("uintptr_t", buf))

  local before = patchlib.read(addr, 8)
  local w = patchlib.write(addr, "DE AD BE EF 01 02 03 04", "selftest")
  local after = patchlib.read(addr, 8)
  local undone = patchlib.restore(#patchlib._patches)
  local final = patchlib.read(addr, 8)

  return {
    ok = w.ok and undone.ok and (final == before),
    address = string.format("0x%X", addr),
    before = before,
    write_ok = w.ok,
    write_error = w.error,
    after_write = after,
    restore_ok = undone.ok,
    after_restore = final,
    round_trip_clean = (final == before),
    verdict = (w.ok and final == before)
      and "write + verify + restore all work on allocated memory"
      or "the patch primitives did NOT round-trip cleanly",
  }
end

return patchlib

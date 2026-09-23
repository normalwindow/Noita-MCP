-- Settings store for the control panel.
--
-- Two persistence backends, chosen at runtime:
--
--   modsetting : ModSettingGet/Set. Survives restarts, but the sandbox does not
--                always expose it, so it is probed rather than assumed.
--   globals    : GlobalsGetValue/SetValue. Always available, but only lasts for
--                the current run.
--
-- The panel shows which backend is in use so "my settings reset" is never a
-- mystery.

store = store or {}

local PREFIX = "noita_agent."
local cache = {}
local backend = nil

local function probe_modsetting()
  local get = rawget(_G, "ModSettingGet")
  local set = rawget(_G, "ModSettingSet")
  if type(get) ~= "function" or type(set) ~= "function" then return false end
  -- a real round-trip, not just a type check
  local ok = pcall(function()
    local key = PREFIX .. "__probe"
    set(key, "1")
    local v = get(key)
    if v == nil then error("read back nil") end
  end)
  return ok
end

local function backend_name()
  if backend then return backend end
  backend = probe_modsetting() and "modsetting" or "globals"
  return backend
end

function store.describe()
  local name = backend_name()
  return {
    backend = name,
    persists_across_restarts = (name == "modsetting"),
    modsetting_available = (name == "modsetting"),
    note = (name == "modsetting")
      and "settings are saved with ModSetting* and survive restarts"
      or "ModSetting* unavailable in this sandbox; settings live in Globals* and reset when the run ends",
  }
end

local function encode(v)
  local t = type(v)
  if t == "boolean" then return v and "b:1" or "b:0" end
  if t == "number" then return "n:" .. string.format("%.17g", v) end
  if t == "string" then return "s:" .. v end
  return nil
end

local function decode(s)
  if type(s) ~= "string" or s == "" then return nil end
  local kind, rest = s:sub(1, 1), s:sub(3)
  if s:sub(2, 2) ~= ":" then return nil end
  if kind == "b" then return rest == "1" end
  if kind == "n" then return tonumber(rest) end
  if kind == "s" then return rest end
  return nil
end

-- Read a setting, falling back to `default` when unset or unreadable.
function store.get(key, default)
  if cache[key] ~= nil then return cache[key] end
  local raw
  if backend_name() == "modsetting" then
    local ok, v = pcall(ModSettingGet, PREFIX .. key)
    if ok then raw = encode(v) end
  else
    local ok, v = pcall(GlobalsGetValue, PREFIX .. key, "")
    if ok then raw = v end
  end
  local decoded = decode(raw)
  if decoded == nil then
    cache[key] = default
    return default
  end
  cache[key] = decoded
  return decoded
end

function store.set(key, value)
  cache[key] = value
  local raw = encode(value)
  if not raw then return false, "unsupported value type: " .. type(value) end
  if backend_name() == "modsetting" then
    local ok, err = pcall(ModSettingSet, PREFIX .. key, value)
    return ok, err
  end
  local ok, err = pcall(GlobalsSetValue, PREFIX .. key, raw)
  return ok, err
end

function store.toggle(key, default)
  local v = not store.get(key, default)
  store.set(key, v)
  return v
end

-- Drop the memoised copy so a set from elsewhere (or a backend switch) is seen.
function store.invalidate()
  cache = {}
end

return store

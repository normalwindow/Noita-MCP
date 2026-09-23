-- Logging + the directory where the bridge keeps its runtime files.
--
-- Noita mods run inside the game process. Their working directory is the game
-- root, so relative paths such as "mods/<id>/..." resolve inside the install
-- folder. We still probe a list of candidates because a locked-down install
-- (Program Files) or a different launch cwd can make the first choice fail.
--
-- The sandbox matters here: without request_no_api_restrictions the game hands
-- mods a stripped environment where os and io can be missing entirely. Every
-- access below is existence-checked so the bridge degrades instead of erroring.

log = log or {}

local CANDIDATES = {
  "mods/noita_agent/run/",
  "noita_agent_run/",
  "mods/noita_agent/",
  "./",
  "data/temp/noita_agent/",
}

local base = nil
local base_checked = false
local lines = {}
local MAX_LINES = 4000

local function safe_tostring(v)
  local ok, s = pcall(tostring, v)
  if ok then return s end
  return "<unprintable>"
end

-- print() is always available in the Noita sandbox and lands in logger.txt,
-- which makes it the one channel that works even with no io/os at all.
local function console(line)
  pcall(print, "[noita_agent] " .. line)
end

local function io_lib()
  local t = rawget(_G, "io")
  if type(t) == "table" and type(t.open) == "function" then return t end
  return nil
end

local function try_write(path, mode, data)
  local io_ = io_lib()
  if not io_ then return false, "io unavailable" end
  local ok, err = pcall(function()
    local f = io_.open(path, mode)
    if not f then error("io.open returned nil") end
    f:write(data)
    f:flush()
    f:close()
  end)
  return ok, err
end

function log.base()
  if base_checked then return base or nil end
  base_checked = true
  for _, dir in ipairs(CANDIDATES) do
    local ok = try_write(dir .. "write_test.tmp", "wb", "ok")
    if ok then
      base = dir
      return base
    end
  end
  base = false
  return nil
end

function log.path(name)
  local b = log.base()
  if not b then return nil end
  return b .. name
end

function log.append(line)
  local stamp = ""
  local os_ = rawget(_G, "os")
  if type(os_) == "table" and type(os_.date) == "function" then
    local ok, d = pcall(os_.date, "%H:%M:%S")
    if ok and d then stamp = d .. " " end
  end
  lines[#lines + 1] = stamp .. safe_tostring(line)
  if #lines > MAX_LINES then table.remove(lines, 1) end
  console(lines[#lines])
end

function log.info(fmt, ...)
  local ok, msg = pcall(string.format, fmt, ...)
  log.append(ok and msg or safe_tostring(fmt))
end

function log.flush()
  local p = log.path("bridge.log")
  if not p then return false end
  return try_write(p, "wb", table.concat(lines, "\n") .. "\n")
end

function log.dump()
  return table.concat(lines, "\n")
end

function log.write_file(name, data)
  local p = log.path(name)
  if not p then return false, "no writable base dir" end
  return try_write(p, "wb", data)
end

-- Reports what the sandbox actually gave us. This is the first thing to look at
-- when the bridge appears dead.
function log.env_report()
  local parts = {
    "lua=" .. safe_tostring(_VERSION),
    "io=" .. type(rawget(_G, "io")),
    "os=" .. type(rawget(_G, "os")),
    "require=" .. type(rawget(_G, "require")),
    "ffi=" .. type(rawget(_G, "ffi")),
    "package=" .. type(rawget(_G, "package")),
    "dofile=" .. type(rawget(_G, "dofile")),
    "loadfile=" .. type(rawget(_G, "loadfile")),
    "loadstring=" .. type(rawget(_G, "loadstring")),
    "ModTextFileSetContent=" .. type(rawget(_G, "ModTextFileSetContent")),
    "ModTextFileGetContent=" .. type(rawget(_G, "ModTextFileGetContent")),
  }
  return table.concat(parts, " ")
end

return log

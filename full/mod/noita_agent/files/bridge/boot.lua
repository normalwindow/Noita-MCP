-- Mod-init-time sandbox report.
--
-- logger.txt from the game root is the one diagnostic channel that works before
-- any world exists, and it is the only place we can see the environment at
-- mod-init time. Noita calls init.lua's OnModPreInit/OnModInit/OnModPostInit
-- for every mod; hooking them here lets us log the sandbox without depending on
-- the rest of the bridge having loaded.

local M = {}

local function report()
  local lines = {
    "lua=" .. tostring(_VERSION),
    "io=" .. type(rawget(_G, "io")),
    "os=" .. type(rawget(_G, "os")),
    "os.time=" .. type(rawget(_G, "os") and rawget(_G, "os").time),
    "require=" .. type(rawget(_G, "require")),
    "package=" .. type(rawget(_G, "package")),
    "ffi=" .. type(rawget(_G, "ffi")),
    "dofile=" .. type(rawget(_G, "dofile")),
    "loadfile=" .. type(rawget(_G, "loadfile")),
    "loadstring=" .. type(rawget(_G, "loadstring")),
    "ModTextFileGetContent=" .. type(rawget(_G, "ModTextFileGetContent")),
    "ModTextFileSetContent=" .. type(rawget(_G, "ModTextFileSetContent")),
  }
  return "mod-init env: " .. table.concat(lines, " ")
end

local function probe_write()
  local io_ = rawget(_G, "io")
  if type(io_) ~= "table" or type(io_.open) ~= "function" then
    return "no-io"
  end
  local ok = pcall(function()
    local f = io_.open("mods/noita_agent/run/_boot_probe.tmp", "wb")
    if not f then error("open nil") end
    f:write("ok")
    f:close()
  end)
  return ok and "run/ writable" or "run/ NOT writable"
end

local announced = false
local function announce(tag)
  if announced then return end
  announced = true
  pcall(print, "[noita_agent] " .. tag .. " " .. report() .. " | " .. probe_write())
end

function M.install()
  -- replace init.lua's empty hooks with reporting ones (same table, so the
  -- later definitions in init.lua win if it also defines them)
  local g = _G
  local prev_pre, prev_init, prev_post = g.OnModPreInit, g.OnModInit, g.OnModPostInit
  g.OnModPreInit = function() announce("OnModPreInit"); if prev_pre then pcall(prev_pre) end end
  g.OnModInit = function() announce("OnModInit"); if prev_init then pcall(prev_init) end end
  g.OnModPostInit = function() announce("OnModPostInit"); if prev_post then pcall(prev_post) end end
end

return M

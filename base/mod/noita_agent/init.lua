-- Noita MCP Agent Bridge - mod entry point.
--
-- Noita calls these hooks; the bridge answers RPC requests and republishes the
-- world snapshot from OnWorldPostUpdate. OnWorldInitialized is the first hook
-- where the game reports a real world, so the bridge is armed there.
--
-- Everything here is defensive: an error raised inside a world hook can break
-- the run, and the mod sandbox may withhold io/os entirely. print() output goes
-- to logger.txt and is the one diagnostic channel that always works.

dofile_once("mods/noita_agent/files/bridge/log.lua")
dofile_once("mods/noita_agent/files/bridge/json.lua")
dofile_once("mods/noita_agent/files/bridge/serialize.lua")
dofile_once("mods/noita_agent/files/bridge/control.lua")
dofile_once("mods/noita_agent/files/bridge/lever.lua")
dofile_once("mods/noita_agent/files/bridge/sock.lua")
dofile_once("mods/noita_agent/files/bridge/memscan.lua")
dofile_once("mods/noita_agent/files/bridge/memscan2.lua")
dofile_once("mods/noita_agent/files/bridge/patchlib.lua")
dofile_once("mods/noita_agent/files/bridge/xinput.lua")
dofile_once("mods/noita_agent/files/bridge/player_ops.lua")
-- terrain depends on serialize (for the player) and on nothing else; macro depends on
-- xinput, which is loaded above it.
dofile_once("mods/noita_agent/files/bridge/terrain.lua")
dofile_once("mods/noita_agent/files/bridge/macro.lua")
dofile_once("mods/noita_agent/files/bridge/stream.lua")
dofile_once("mods/noita_agent/files/bridge/framerate.lua")
dofile_once("mods/noita_agent/files/bridge/seedreader.lua")
dofile_once("mods/noita_agent/files/bridge/advmat.lua")
dofile_once("mods/noita_agent/files/bridge/percept.lua")
dofile_once("mods/noita_agent/files/ui/panel.lua")
dofile_once("mods/noita_agent/files/bridge/rpc.lua")
local boot = dofile_once("mods/noita_agent/files/bridge/boot.lua")

local armed = false
local announced = false

local function announce()
  if announced then return end
  announced = true
  -- always visible in logger.txt, even when the bridge cannot start
  log.append("env: " .. log.env_report())
  if not log.base() then
    log.append("WARNING: no writable bridge directory; is the mod installed with its run/ folder?")
  end
end

local function arm()
  announce()
  local ok, err = pcall(rpc.init)
  if not ok then
    log.append("rpc.init failed: " .. tostring(err))
    log.flush()
    armed = false
    return
  end
  local ready_fn = rpc.is_ready
  if type(ready_fn) == "function" then
    armed = ready_fn() and true or false
  else
    armed = err and true or false   -- rpc.init's own return value
  end
end

function OnModPreInit()
end

function OnModInit()
end

function OnModPostInit()
  -- early signal so a bridge that never reaches a world is still visible
  pcall(announce)
end

function OnWorldInitialized()
  arm()
end

function OnPlayerSpawned(player)
  pcall(rpc.set_player, player)
end

function OnWorldPreUpdate()
  if not armed then return end
  local ok, err = pcall(rpc.pre_update)
  if not ok then
    log.append("pre_update failed: " .. tostring(err))
  end
end

function OnWorldPostUpdate()
  if not armed then
    -- world hooks can fire before OnWorldInitialized; arm lazily so a run that
    -- starts from a loaded save still gets a bridge.
    arm()
    if not armed then return end
  end
  local ok, err = pcall(rpc.update)
  if not ok then
    log.append("update failed: " .. tostring(err))
  end
end

-- keep the mod-init sandbox report working
if boot and type(boot.install) == "function" then pcall(boot.install) end

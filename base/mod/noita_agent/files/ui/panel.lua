-- In-game control panel for the AI bridge.
--
-- Draws a compact panel in the top-left corner and exposes the switches that
-- decide what the external AI is allowed to do. Every value goes through
-- store.lua, so it persists when the sandbox allows it and the panel says so
-- when it does not.
--
-- Rendering happens from OnWorldPostUpdate (the GUI is an overlay, so the update
-- phase does not matter for it), while the RPC side reads the same flags through
-- panel.is_allowed().

panel = panel or {}

dofile_once("mods/noita_agent/files/ui/store.lua")

local gui = nil
local next_id = 0
local log_lines = {}
local MAX_LOG = 6
local seen_events = {}

local function id()
  next_id = next_id + 1
  return next_id
end

-- ---------------------------------------------------------------- settings

local KEYS = {
  open = "panel_open",
  master = "ai_enabled",          -- the big switch: no writes reach the game when off
  read_only = "read_only",        -- allow observation, refuse every mutation
  op_spawn = "op_spawn",          -- spawn wands / spells / potions / items
  op_player = "op_player",        -- move or modify the player
  op_wands = "op_wands",          -- rewrite wand stats and decks
  op_world = "op_world",          -- generic world mutation (raw rpc writes)
  verbose = "verbose_log",
}

local DEFAULTS = {
  open = false,
  master = true,
  read_only = false,
  op_spawn = true,
  op_player = true,
  op_wands = true,
  op_world = false,
  verbose = false,
}

-- Keys that are forced back to their default at the start of every run.
--
-- The master switch is a "right now" safety control: if it were persisted, a
-- session that ended with the AI paused would start paused, and (on a build
-- with a stricter gate) the operator could be locked out of the very panel that
-- turns it back on. Re-arming each session keeps the safe default reachable.
-- The per-operation switches ARE worth persisting -- they express policy.
local SESSION_ONLY = { master = true, read_only = true }

local function flag(key)
  return store.get(KEYS[key], DEFAULTS[key])
end

local function set_flag(key, value)
  store.set(KEYS[key], value)
end

-- Called once per run from panel.init().
local function apply_session_defaults()
  for key in pairs(SESSION_ONLY) do
    set_flag(key, DEFAULTS[key])
  end
end

-- ---------------------------------------------------------------- gating

-- Methods that only read are always allowed. Everything else is checked against
-- the switches above, so the panel is a real gate and not just a status display.
local READ_METHODS = {
  ping = true, status = true, get_state = true, get_player = true, get_nearby = true,
  get_inventory = true, get_wands = true, get_held_wand = true, raycast = true,
  list_spells = true, list_materials = true, list_perks = true, get_perks = true,
  entity_info = true, inspect_component = true, probe_api = true,
  get_panel = true,
}

-- Control-plane methods: they read or write the permission switches themselves.
-- These must NEVER be gated by those switches, or turning the AI off would also
-- disable the only way to turn it back on (a self-lockout). Verified by test.
local CONTROL_METHODS = {
  get_panel = true,
  set_panel = true,
}

local OP_METHODS = {
  spawn_wand = "op_spawn", spawn_spell = "op_spawn", spawn_potion = "op_spawn",
  spawn_item = "op_spawn", get_potion = "op_spawn", set_potion = "op_spawn",
  set_player = "op_player", heal = "op_player", set_max_hp = "op_player",
  add_gold = "op_player", apply_effect = "op_player",
  -- direct control levers act on the player, so they belong to the player gate
  lever_engage = "op_player", lever_disengage = "op_player",
  lever_cancel = "op_player", lever_experiment = "op_player",
  edit_wand = "op_wands", set_wand_deck = "op_wands",
  add_spell_to_wand = "op_wands", remove_spell_from_wand = "op_wands",
  refresh_spells = "op_wands",
  -- starting/stopping the socket transport is a world-level action
  socket_control = "op_world",
  drop_item = "op_world",
}

-- Returns ok, reason. `reason` is written into the RPC error so the AI learns
-- exactly which switch to ask the human to flip.
--
-- Semantics, deliberate:
--   * reads always pass -- pausing the AI stops it acting, it does not blind it,
--     so the operator can still watch what the AI sees before re-enabling it;
--   * the master switch stops every mutation;
--   * read_only stops mutations while leaving reads on (a stricter but equally
--     observable mode, useful while inspecting the AI's plan);
--   * per-operation switches then filter by category.
function panel.is_allowed(method)
  -- the permission switches themselves are never gated by those switches
  if CONTROL_METHODS[method] then return true end
  if READ_METHODS[method] then return true end

  if not flag("master") then
    return false, "AI control is disabled in the Noita AI Agent Bridge panel (switch: ai_enabled). " ..
      "Read-only tools and the panel tools still work."
  end

  local op = OP_METHODS[method]
  if not op then
    -- unclassified methods (experiments, future additions) count as world writes
    op = "op_world"
  end

  if flag("read_only") then
    return false, "bridge is in read-only mode (switch: read_only); read methods still work"
  end
  if not flag(op) then
    return false, "operation '" .. op .. "' is disabled in the bridge panel (switch: " .. op .. ")"
  end
  return true
end

function panel.is_running()
  return flag("master")
end

-- ---------------------------------------------------------------- log view

-- The bridge logs by appending; the panel mirrors the tail so problems are
-- visible without leaving the game.
function panel.push_log(line)
  log_lines[#log_lines + 1] = tostring(line)
  while #log_lines > MAX_LOG do table.remove(log_lines, 1) end
end

-- Panel-visible event that only fires once per distinct message, so a repeating
-- error cannot flood the list.
function panel.note_once(key, line)
  if seen_events[key] then return end
  seen_events[key] = true
  panel.push_log(line)
end

-- ---------------------------------------------------------------- widgets

local function toggle(label, key, x, y)
  local on = flag(key)
  local text = string.format("%s [%s]", label, on and "X" or " ")
  if GuiButton(gui, id(), x, y, text) then
    set_flag(key, not on)
    on = not on
    panel.push_log(string.format("%s -> %s", key, on and "on" or "off"))
  end
  return on
end

local function slider(label, key, default, min, max, step, x, y, width)
  local value = tonumber(store.get(KEYS[key] or key, default)) or default
  GuiText(gui, x, y - 12, string.format("%s: %d", label, value))
  local newv = GuiSlider(gui, id(), x, y, "", value, min, max, default, 1, "%d", width)
  if newv and newv ~= value then
    store.set(KEYS[key] or key, math.floor(newv / step + 0.5) * step)
  end
end

local function status_line(label, value, x, y)
  GuiText(gui, x, y, string.format("%s %s", label, tostring(value)))
end

-- ---------------------------------------------------------------- draw

local function draw_panel(status)
  local w, h = GuiGetScreenDimensions(gui)
  local x, y = 8, 8

  -- header with the toggle
  local open = flag("open")
  if GuiButton(gui, id(), x, y, open and "[ noita_agent - ]" or "[ noita_agent + ]") then
    set_flag("open", not open)
    open = not open
  end
  if not open then return end

  local running = flag("master")
  GuiColorSetForNextWidget(gui, running and 0.4 or 0.9, running and 0.9 or 0.4, 0.4, 1)
  GuiText(gui, x + 140, y, running and "AI: ENABLED" or "AI: PAUSED")
  GuiColorSetForNextWidget(gui, 1, 1, 1, 1)

  local row = y + 18
  local col = x

  -- ---- bridge status ----
  GuiText(gui, col, row, "--- bridge ---")
  row = row + 14
  status_line("dir     :", status.base_dir or "(none)", col, row); row = row + 12
  status_line("frame   :", status.frame or 0, col, row); row = row + 12
  status_line("requests:", status.handled or 0, col, row); row = row + 12
  status_line("player  :", status.has_player and "yes" or "NO", col, row); row = row + 12

  local storeinfo = store.describe()
  status_line("settings:", storeinfo.backend, col, row); row = row + 12
  if not storeinfo.persists_across_restarts then
    GuiColorSetForNextWidget(gui, 0.9, 0.8, 0.3, 1)
    GuiText(gui, col, row, "  (resets each run)")
    GuiColorSetForNextWidget(gui, 1, 1, 1, 1)
  end
  row = row + 14

  -- ---- switches ----
  GuiText(gui, col, row, "--- switches ---")
  row = row + 14
  toggle("master", "master", col, row); row = row + 13
  toggle("read only", "read_only", col, row); row = row + 13
  toggle("spawn", "op_spawn", col, row); row = row + 13
  toggle("player", "op_player", col, row); row = row + 13
  toggle("wands", "op_wands", col, row); row = row + 13
  toggle("world/raw", "op_world", col, row); row = row + 13
  toggle("verbose", "verbose", col, row); row = row + 16

  -- ---- transport ----
  -- Which channel the AI is actually talking over, with a live switch. The socket
  -- starts by default; the file bridge always runs as the fallback, so switching
  -- cannot strand a client.
  GuiText(gui, col, row, "--- transport ---")
  row = row + 14
  local sockState = status and status.socket
  local sockUp = (sockState and sockState.started) and true or false
  local autoStart = store.get("use_socket", true)

  GuiColorSetForNextWidget(gui, sockUp and 0.4 or 0.9, sockUp and 0.9 or 0.7, 0.4, 1)
  GuiText(gui, col, row, "active : " .. (sockUp and "SOCKET" or "FILE BRIDGE"))
  GuiColorSetForNextWidget(gui, 1, 1, 1, 1)
  row = row + 12

  if sockUp then
    status_line("port   :", sockState.port or "?", col, row); row = row + 12
    status_line("requests:", sockState.requests or 0, col, row); row = row + 12
    local g = sockState.guard
    if g and g.trips and g.trips > 0 then
      GuiColorSetForNextWidget(gui, 1, 0.35, 0.35, 1)
      GuiText(gui, col, row, "WATCHDOG TRIPPED (see log)")
      GuiColorSetForNextWidget(gui, 1, 1, 1, 1)
    elseif g then
      status_line("watchdog:", string.format("ok, worst %.1fms", g.worst_op_ms or 0), col, row)
    end
    row = row + 12
  else
    local why = "not started"
    if sockState and sockState.ffi_available == false then why = "FFI unavailable" end
    status_line("reason :", why, col, row); row = row + 12
  end

  status_line("autostart:", autoStart and "socket" or "file", col, row); row = row + 14

  if sockUp then
    if GuiButton(gui, id(), col, row, "switch to FILE bridge") then
      store.set("use_socket", false)
      if rpc and type(rpc.stop_socket) == "function" then rpc.stop_socket() end
      panel.push_log("transport -> FILE bridge")
    end
  else
    if GuiButton(gui, id(), col, row, "switch to SOCKET") then
      store.set("use_socket", true)
      if rpc and type(rpc.start_socket) == "function" then
        local ok, port = rpc.start_socket(0)
        panel.push_log("transport -> SOCKET " .. tostring(ok and port or "failed"))
      end
    end
  end
  row = row + 16

  -- ---- latency ----
  -- One frame is 16.7 ms, so "poll every frame" is the floor a file transport can
  -- reach. These let the operator trade latency against file churn at runtime.
  GuiText(gui, col, row, "--- latency ---")
  row = row + 14
  local poll = tonumber(store.get("poll_interval", 1)) or 1
  local stateEvery = tonumber(store.get("state_interval", 2)) or 2
  status_line("poll  :", poll .. " frame(s)", col, row); row = row + 12
  status_line("state :", stateEvery .. " frame(s)", col, row); row = row + 12
  local lat = status and status.latency
  if lat and lat.samples and lat.samples > 0 then
    status_line("rpc   :", string.format("avg %.1fms  max %.1fms",
      lat.handled_ms_avg or 0, lat.handled_ms_max or 0), col, row)
  else
    status_line("rpc   :", "(no samples yet)", col, row)
  end
  row = row + 14
  if GuiButton(gui, id(), col, row, "poll: -1 frame") then
    store.set("poll_interval", math.max(1, poll - 1))
  end
  if GuiButton(gui, id(), col + 110, row, "poll: +1 frame") then
    store.set("poll_interval", poll + 1)
  end
  row = row + 14
  if GuiButton(gui, id(), col, row, "state: -1 frame") then
    store.set("state_interval", math.max(1, stateEvery - 1))
  end
  if GuiButton(gui, id(), col + 110, row, "state: +1 frame") then
    store.set("state_interval", stateEvery + 1)
  end
  row = row + 16

  -- ---- log ----
  GuiText(gui, col, row, "--- recent ---")
  row = row + 13
  for i = 1, #log_lines do
    GuiText(gui, col, row, "- " .. log_lines[i]:sub(1, 46))
    row = row + 11
  end
  if #log_lines == 0 then
    GuiText(gui, col, row, "- (no events yet)")
  end
end

-- ---------------------------------------------------------------- lifecycle

function panel.init()
  if gui then return true end
  -- Re-arm the session-scoped switches before anything can be refused. Order
  -- matters: drop the memoised cache FIRST, then write the defaults, otherwise
  -- invalidate() would discard the values we just wrote and the next read would
  -- pull the stale persisted ones back in.
  pcall(store.invalidate)
  pcall(apply_session_defaults)

  if type(GuiCreate) ~= "function" then
    -- no GUI in this sandbox: the gate still works, it just uses defaults
    return false
  end
  gui = GuiCreate()
  return true
end

-- Called every frame from OnWorldPostUpdate.
function panel.update(status)
  if not gui then
    if not panel.init() then return end
  end
  next_id = 0
  local ok, err = pcall(function()
    GuiStartFrame(gui)
    draw_panel(status or {})
  end)
  if not ok then
    panel.note_once("draw:" .. tostring(err), "panel error: " .. tostring(err))
  end
end

-- Snapshot for the RPC status method and for the MCP server.
function panel.state()
  return {
    open = flag("open"),
    ai_enabled = flag("master"),
    read_only = flag("read_only"),
    operations = {
      spawn = flag("op_spawn"),
      player = flag("op_player"),
      wands = flag("op_wands"),
      world = flag("op_world"),
    },
    settings_backend = store.describe(),
    recent = log_lines,
  }
end

return panel

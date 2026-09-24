-- In-game control panel for the AI bridge.
--
-- Organised by concern rather than by arrival order:
--
--   Status       what the bridge and the game are doing right now
--   Permissions  what the AI is allowed to do (the safety switches)
--   Extension    the optional input DLL: loaded? armed? and if not, WHY
--   Log          the newest messages, with severity and a level filter
--
-- ---------------------------------------------------------------------------
-- Rules this file follows, each of which came from getting it wrong first:
--
--   * ONLY functions listed in the game's own lua_api_documentation.txt are used.
--     An earlier version offset its panes with GuiTranslateSet, which does not exist;
--     the call was inside a pcall, so it failed silently and every pane drew at (0,0),
--     leaving the content area blank. Panes now take an explicit origin (ox, oy).
--
--   * No GuiBeginScrollContainer. It appeared to render nothing in-game and there was no
--     way to tell from inside Noita whether the API or the call was at fault. The log
--     shows the newest rows that fit and reports how many older ones are held back.
--
--   * The background is drawn ONLY when the panel is open. A collapsed header is a
--     single button; it does not need a box, and one there sat over the game's own HUD.
--
--   * The panel is measured from its content, then centred. A fixed 620x620 panel was
--     tried and it covered most of the screen, because a filled 9-piece decoration is
--     opaque in the middle however low its tint.
--
--   * No file IO: the sandbox may or may not allow it, and a diagnostic surface that
--     itself fails is worse than none. The log lives in memory.
--
--   * The panes declare their height from the same data they render. The frame cannot
--     know it in advance -- the extension pane grows with the number of load attempts --
--     so each pane has a `_height` companion beside it.

panel = panel or {}

dofile_once("mods/noita_agent/files/ui/store.lua")

local gui = nil
local next_id = 0

-- ---------------------------------------------------------------- layout constants

local PAD = 12              -- gap between the panel border and its contents
local PANEL_W = 500
local ROW = 13              -- one key/value line
local LINE_H = 15           -- one wrapped log block
local HEAD_H = 15           -- a section heading
local MIN_MARGIN = 24       -- minimum gap from the screen edge when centred

-- Where the collapsed strip sits: tight into the corner. It is an always-on status
-- readout, and any gap above it is screen space taken from the game for nothing.
local MARGIN_X = 2
local MARGIN_Y = 2

local PANEL_SPRITE = "data/ui_gfx/decorations/9piece0_gray.png"
local PANEL_TINT = { 0.09, 0.10, 0.13, 0.86 }

-- ---------------------------------------------------------------- settings

local KEYS = {
  open = "panel_open",
  master = "ai_enabled",
  read_only = "read_only",
  op_spawn = "op_spawn",
  op_player = "op_player",
  op_wands = "op_wands",
  op_world = "op_world",
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

-- Forced back to default at the start of every run.
--
-- The master switch is a "right now" safety control: if it persisted, a session that
-- ended paused would start paused, and on a stricter build the operator could be locked
-- out of the very panel that turns it back on. The per-operation switches ARE worth
-- persisting -- they express policy rather than a moment.
--
-- `open` is here too. It is a view preference, and persisting it means a panel left open
-- comes back open on the next launch -- over the game, before the player has asked for
-- anything. An MCP caller setting open=true for one look then permanently changed how
-- every later session starts, which is how this was found.
local SESSION_ONLY = { master = true, read_only = true, open = true }

local function flag(key)
  return store.get(KEYS[key], DEFAULTS[key])
end

local function set_flag(key, value)
  store.set(KEYS[key], value)
end

local function apply_session_defaults()
  for key in pairs(SESSION_ONLY) do
    set_flag(key, DEFAULTS[key])
  end
end

-- ---------------------------------------------------------------- log store

local LEVEL = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
local LEVEL_COLOR = {
  DEBUG = { 0.62, 0.62, 0.68 },
  INFO  = { 0.82, 0.88, 0.94 },
  WARN  = { 1.00, 0.78, 0.28 },
  ERROR = { 1.00, 0.38, 0.34 },
}
local LEVEL_TAG = { DEBUG = "dbg", INFO = "inf", WARN = "WRN", ERROR = "ERR" }

local MAX_LOG = 400
local LOG_TAIL = 14

local log_entries = {}
local log_index = {}
local log_seq = 0
local min_level = LEVEL.INFO

local function now_frame()
  return (GameGetFrameNum and GameGetFrameNum()) or 0
end

-- Wraps text to a pixel width. The original panel used string.sub(1, 46), which cut words
-- in half and discarded the rest -- and for an error message the discarded part is
-- usually the useful part.
local CHAR_W = 6
local function wrap(text, width_px)
  local max_chars = math.max(16, math.floor(width_px / CHAR_W))
  local out, line = {}, ""
  for word in tostring(text):gmatch("%S+") do
    if #line == 0 then
      line = word
    elseif #line + 1 + #word <= max_chars then
      line = line .. " " .. word
    else
      out[#out + 1] = line
      line = word
    end
    while #line > max_chars do
      out[#out + 1] = line:sub(1, max_chars)
      line = line:sub(max_chars + 1)
    end
  end
  if #line > 0 then out[#out + 1] = line end
  if #out == 0 then out[1] = "" end
  return out
end

-- Adds a message. `key` collapses repeats into one row with a counter: an error that
-- fires every frame is one problem and should look like one problem.
function panel.log(level, text, opts)
  opts = opts or {}
  level = LEVEL[level] and level or "INFO"
  local key = opts.key

  if key and log_index[key] then
    local e = log_index[key]
    e.count = (e.count or 1) + 1
    e.frame = now_frame()
    e.level = level
    return e
  end

  log_seq = log_seq + 1
  local e = {
    seq = log_seq,
    level = level,
    text = tostring(text),
    source = opts.source,
    frame = now_frame(),
    count = 1,
    key = key,
  }
  log_entries[#log_entries + 1] = e
  if key then log_index[key] = e end
  while #log_entries > MAX_LOG do
    local dropped = table.remove(log_entries, 1)
    if dropped and dropped.key and log_index[dropped.key] == dropped then
      log_index[dropped.key] = nil
    end
  end
  return e
end

function panel.debug(text, opts) panel.log("DEBUG", text, opts) end
function panel.info(text, opts)  panel.log("INFO", text, opts) end
function panel.warn(text, opts)  panel.log("WARN", text, opts) end
function panel.error(text, opts) panel.log("ERROR", text, opts) end

-- Kept because the rest of the bridge already calls these names.
function panel.push_log(line) panel.log("INFO", line) end
function panel.note_once(key, line) panel.log("WARN", line, { key = key }) end
function panel.log_entries() return log_entries end

-- ---------------------------------------------------------------- permission gate

-- Rule: EVERYTHING IS A READ UNLESS IT IS LISTED BELOW.
--
-- The first version did the opposite -- unlisted counted as a world write -- and a survey
-- found 69 of 114 methods unlisted, nearly all read-only probes. Read-only mode therefore
-- refused ordinary observation, which is what read-only mode exists to permit.
--
-- Defaulting to read is also the safer direction for a list that keeps growing: a
-- forgotten entry in the write table wrongly ALLOWS a mutation, a forgotten entry in a
-- read table wrongly BREAKS observation. The first is a safety hole, the second a visible
-- bug -- so the table that must be complete is the one that grants power, and it is small
-- enough to audit.
--
-- This gate decides what the AI is ALLOWED to do. What is POSSIBLE is a separate layer:
-- the DLL loads inert, hooks are armed explicitly, holds are bounded.

-- Always permitted, or the operator could lock themselves out of the control that would
-- fix it -- a failure this project has already hit once.
local CONTROL_METHODS = {
  get_panel = true, set_panel = true, panel_state = true,
  ping = true, status = true, capabilities = true, input_status = true,
  transport = true, latency = true, socket_stats = true,
}

local OP_METHODS = {
  spawn_item = "op_spawn", spawn_potion = "op_spawn", spawn_spell = "op_spawn",
  spawn_wand = "op_spawn", set_potion = "op_spawn",
  set_player = "op_player", add_gold = "op_player", heal = "op_player",
  apply_effect = "op_player", set_max_hp = "op_player",
  pickup = "op_player", po_pickup = "op_player", switch_item = "op_player",
  po_switch = "op_player", drop_item = "op_player", drop_all = "op_player",
  po_drop_all = "op_player", po_drop_one = "op_player",
  launch_projectile = "op_player", po_launch = "op_player",
  hold_key = "op_player", hold_mouse = "op_player", hold_release = "op_player",
  mouse_release = "op_player", push_key = "op_player",
  po_input_move = "op_player", po_input_fire = "op_player", po_input_jump = "op_player",
  poll_forge_key = "op_player", poll_forge_clear = "op_player",
  input_key = "op_player", input_fire = "op_player", input_aim = "op_player",
  input_clear = "op_player", control_push = "op_player", control_push_cancel = "op_player",
  control_restore = "op_player", control_set = "op_player", control_set_aim = "op_player",
  lever_engage = "op_player", lever_disengage = "op_player", lever_cancel = "op_player",
  lever_experiment = "op_player",
  add_spell_to_wand = "op_wands", remove_spell_from_wand = "op_wands",
  set_wand_deck = "op_wands", edit_wand = "op_wands", refresh_spells = "op_wands",
  input_load = "op_player", input_install = "op_player", input_remove = "op_player",
  input_unload = "op_player", poll_install = "op_player", poll_remove = "op_player",
  peep_install = "op_player", peep_remove = "op_player",
  -- Macros press keys, so they are player actions. macro_list and macro_status are reads
  -- and stay ungated, matching how the rest of the bridge splits the two.
  macro_start = "op_player", macro_stop = "op_player",
  -- The decision stream writes a log file and records actions. Both sit behind the player
  -- switch rather than being freely available to a paused session.
  stream_start = "op_player", stream_stop = "op_player", stream_action = "op_player",
  patchlib_restore = "op_world", patchlib_selftest = "op_world",
  socket_control = "op_world",
}

function panel.is_allowed(method)
  if CONTROL_METHODS[method] then return true end

  local op = OP_METHODS[method]
  if not op then return true end   -- unlisted means read; see the rule above

  if not flag("master") then
    return false, "AI control is disabled in the Noita AI Agent Bridge panel (switch: ai_enabled). " ..
      "Read-only tools and the panel tools still work."
  end
  if flag("read_only") then
    return false, "bridge is in read-only mode (switch: read_only); read methods still work"
  end
  if not flag(op) then
    return false, "operation '" .. op .. "' is disabled in the bridge panel (switch: " .. op .. ")"
  end
  return true
end

function panel.method_category(method)
  return OP_METHODS[method]
end

function panel.is_running()
  return flag("master")
end

-- The RPC side writes through the SAME key mapping the UI reads with.
--
-- Not cosmetic: set_panel used to call store.set(k, v) with the caller's own key name
-- while the UI reads store.get("panel_open"). So set_panel{open=true} answered ok, wrote
-- a different key, and changed nothing -- silently. The keys that happened to match
-- (ai_enabled, read_only) worked, which is what made it hard to notice.
--
-- Both naming forms are accepted, because the two halves of the project settled on
-- different ones: the panel thinks in short names (master, op_spawn) while the RPC API
-- and the MCP tools use storage names (ai_enabled, op_spawn).
function panel.storage_key(name)
  return KEYS[name] or name
end

function panel.apply_settings(params)
  params = params or {}

  local by_storage = {}
  for short, storage in pairs(KEYS) do by_storage[storage] = short end

  local applied, rejected = {}, {}
  local function set_one(name, value)
    if name == "operations" then return end
    local short = KEYS[name] and name or by_storage[name]
    if not short then
      rejected[#rejected + 1] = name
      return
    end
    store.set(KEYS[short], value)
    -- Reported under the name the caller used, so the reply matches the request.
    applied[name] = value
  end

  for k, v in pairs(params) do
    if k ~= "operations" then set_one(k, v) end
  end
  if type(params.operations) == "table" then
    for k, v in pairs(params.operations) do set_one("op_" .. k, v) end
  end
  return applied, rejected
end

-- ---------------------------------------------------------------- drawing helpers
--
-- Every helper takes the pane origin (ox, oy) first and adds it to each coordinate.
-- There is no translate call to forget: Noita's GUI API has none, and relying on one that
-- does not exist is what left the content area blank.

local function id()
  next_id = next_id + 1
  return next_id
end

local function chip(ox, oy, x, y, label, r, g, b)
  GuiColorSetForNextWidget(gui, r, g, b, 1)
  GuiText(gui, ox + x, oy + y, label)
  GuiColorSetForNextWidget(gui, 1, 1, 1, 1)
end

local function dim(ox, oy, x, y, text)
  GuiColorSetForNextWidget(gui, 0.62, 0.66, 0.72, 1)
  GuiText(gui, ox + x, oy + y, text)
  GuiColorSetForNextWidget(gui, 1, 1, 1, 1)
end

local function normal(ox, oy, x, y, text)
  GuiColorSetForNextWidget(gui, 0.88, 0.92, 0.97, 1)
  GuiText(gui, ox + x, oy + y, text)
  GuiColorSetForNextWidget(gui, 1, 1, 1, 1)
end

local function heading(ox, oy, x, y, text)
  GuiColorSetForNextWidget(gui, 0.55, 0.72, 0.95, 1)
  GuiText(gui, ox + x, oy + y, text)
  GuiColorSetForNextWidget(gui, 1, 1, 1, 1)
end

local function key_value(ox, oy, x, y, key, value, value_color)
  dim(ox, oy, x, y, key)
  if value_color then
    GuiColorSetForNextWidget(gui, value_color[1], value_color[2], value_color[3], 1)
  end
  GuiText(gui, ox + x + 96, oy + y, tostring(value))
  GuiColorSetForNextWidget(gui, 1, 1, 1, 1)
end

-- A thin filled bar, used for separators. GuiImageNinePiece with a small height is the
-- only filled-rectangle primitive the API offers.
local function rule(ox, oy, x, y, width, alpha)
  GuiColorSetForNextWidget(gui, 0.55, 0.72, 0.95, alpha or 0.35)
  GuiImageNinePiece(gui, id(), ox + x, oy + y, width, 2, 1, PANEL_SPRITE)
  GuiColorSetForNextWidget(gui, 1, 1, 1, 1)
end

-- ---------------------------------------------------------------- panes

local TABS = { "Status", "Permissions", "Extension", "Log" }
local active_tab = 1

function panel._set_tab_for_test(n)
  n = tonumber(n)
  if n and n >= 1 and n <= #TABS then active_tab = n end
  return active_tab
end

function panel._rearm_for_test()
  pcall(store.invalidate)
  pcall(apply_session_defaults)
  return true
end

-- ---- Status -----------------------------------------------------------------

local function pane_status_height()
  -- connection heading + 4 rows, then the transport chooser (caption + 2 buttons + row),
  -- engine heading + 4 rows, settings 2 rows, latency heading + 3 rows
  return HEAD_H + ROW * 4 + 8
    + HEAD_H + ROW * 2 + 26
    + HEAD_H + ROW * 4 + ROW * 2 + 8
    + HEAD_H + ROW * 3
end

local function pane_status(ox, oy, status)
  local y = 0

  heading(ox, oy, 0, y, "connection"); y = y + HEAD_H
  local sock = status.socket
  local sockUp = sock and sock.started
  key_value(ox, oy, 0, y, "active",
    sockUp and ("SOCKET on port " .. tostring(sock.port or "?")) or "FILE BRIDGE",
    sockUp and { 0.45, 0.95, 0.5 } or { 1, 0.78, 0.3 })
  y = y + ROW
  if sockUp then
    key_value(ox, oy, 0, y, "requests", tostring(sock.requests or 0)); y = y + ROW
    local g = sock.guard
    if g and (g.trips or 0) > 0 then
      key_value(ox, oy, 0, y, "watchdog", "TRIPPED " .. tostring(g.trips) .. "x", { 1, 0.38, 0.34 })
    else
      key_value(ox, oy, 0, y, "watchdog", string.format("ok, worst %.1f ms", (g and g.worst_op_ms) or 0))
    end
    y = y + ROW
  else
    local why = "not started"
    if sock and sock.ffi_available == false then why = "FFI unavailable in this sandbox" end
    key_value(ox, oy, 0, y, "reason", why, { 1, 0.78, 0.3 })
    y = y + ROW
  end
  key_value(ox, oy, 0, y, "work dir", status.base_dir or "(none)")
  y = y + ROW + 8

  -- ---- transport chooser -----------------------------------------------------
  -- This was lost when the panel was rewritten, which left no way to pick a transport
  -- from inside the game even though the bridge supports both. The file bridge always
  -- runs, so switching to the socket and back cannot strand a client: at worst a request
  -- waits one frame longer.
  heading(ox, oy, 0, y, "transport"); y = y + HEAD_H
  dim(ox, oy, 0, y, "which channel the MCP server talks over")
  y = y + ROW

  local autoStart = store.get("use_socket", true)
  if GuiButton(gui, id(), ox + 0, oy + y, sockUp and "use FILE bridge" or "start SOCKET") then
    if sockUp then
      store.set("use_socket", false)
      if rpc and type(rpc.stop_socket) == "function" then rpc.stop_socket() end
      panel.warn("transport switched to the FILE bridge", { source = "panel" })
    else
      store.set("use_socket", true)
      if rpc and type(rpc.start_socket) == "function" then
        local ok, port = rpc.start_socket(0)
        if ok then
          panel.info("transport switched to SOCKET on port " .. tostring(port), { source = "panel" })
        else
          panel.error("SOCKET failed to start: " .. tostring(port),
            { key = "sockstart", source = "panel" })
        end
      else
        panel.error("rpc.start_socket is unavailable", { key = "nosockstart", source = "panel" })
      end
    end
  end

  -- What a new session will pick, which is a separate question from what is running now.
  if GuiButton(gui, id(), ox + 158, oy + y,
      "startup: " .. (autoStart and "SOCKET" or "FILE")) then
    store.set("use_socket", not autoStart)
    panel.info("startup transport set to " .. ((not autoStart) and "SOCKET" or "FILE"),
      { source = "panel" })
  end
  y = y + 26

  heading(ox, oy, 0, y, "engine"); y = y + HEAD_H
  key_value(ox, oy, 0, y, "frame", tostring(status.frame or 0)); y = y + ROW
  key_value(ox, oy, 0, y, "requests served", tostring(status.handled or 0)); y = y + ROW
  key_value(ox, oy, 0, y, "player", status.has_player and "found" or "NOT FOUND",
    status.has_player and { 0.45, 0.95, 0.5 } or { 1, 0.38, 0.34 })
  y = y + ROW
  local lat = status.latency
  if lat and (lat.samples or 0) > 0 then
    key_value(ox, oy, 0, y, "rpc time", string.format("avg %.1f ms  max %.1f ms",
      lat.handled_ms_avg or 0, lat.handled_ms_max or 0))
  else
    key_value(ox, oy, 0, y, "rpc time", "no samples yet")
  end
  y = y + ROW + 8

  local storeinfo = store.describe()
  key_value(ox, oy, 0, y, "settings backend", tostring(storeinfo.backend or "?"))
  y = y + ROW
  if not storeinfo.persists_across_restarts then
    dim(ox, oy, 0, y, "  (switches reset each run)"); y = y + ROW
  end
  y = y + 8

  heading(ox, oy, 0, y, "latency"); y = y + HEAD_H
  local poll = tonumber(store.get("poll_interval", 1)) or 1
  local stateEvery = tonumber(store.get("state_interval", 2)) or 2
  key_value(ox, oy, 0, y, "poll every", poll .. " frame(s)"); y = y + ROW
  key_value(ox, oy, 0, y, "state write", stateEvery .. " frame(s)"); y = y + ROW
  if GuiButton(gui, id(), ox + 0, oy + y, "poll -") then
    store.set("poll_interval", math.max(1, poll - 1))
  end
  if GuiButton(gui, id(), ox + 74, oy + y, "poll +") then
    store.set("poll_interval", poll + 1)
  end
  if GuiButton(gui, id(), ox + 158, oy + y, "state -") then
    store.set("state_interval", math.max(1, stateEvery - 1))
  end
  if GuiButton(gui, id(), ox + 240, oy + y, "state +") then
    store.set("state_interval", stateEvery + 1)
  end
end

-- ---- Permissions ------------------------------------------------------------

local function pane_permissions_height()
  return (HEAD_H + ROW) + ROW + (HEAD_H + ROW) * 2
    + (HEAD_H + ROW + ROW * 4) + (HEAD_H + ROW) + (HEAD_H + ROW)
end

local function checkbox(ox, oy, x, y, label, key)
  local on = flag(key)
  GuiColorSetForNextWidget(gui, on and 0.45 or 0.70, on and 0.95 or 0.70, on and 0.5 or 0.70, 1)
  local clicked = GuiButton(gui, id(), ox + x, oy + y,
    string.format("[%s] %s", on and "x" or " ", label))
  GuiColorSetForNextWidget(gui, 1, 1, 1, 1)
  if clicked then
    set_flag(key, not on)
    panel.info(string.format("switch %s -> %s", key, (not on) and "on" or "off"), { source = "panel" })
  end
end

local function pane_permissions(ox, oy)
  local y = 0

  heading(ox, oy, 0, y, "master"); y = y + HEAD_H
  checkbox(ox, oy, 0, y, "AI control allowed", "master"); y = y + ROW + 6

  heading(ox, oy, 0, y, "mode"); y = y + HEAD_H
  checkbox(ox, oy, 0, y, "read only (observe, refuse all writes)", "read_only")
  y = y + ROW + 6

  heading(ox, oy, 0, y, "operation categories"); y = y + HEAD_H
  dim(ox, oy, 0, y, "a write is refused unless its category is on"); y = y + ROW
  checkbox(ox, oy, 0, y, "spawn items / wands / spells / potions", "op_spawn"); y = y + ROW
  checkbox(ox, oy, 0, y, "player: move, fire, heal, gold, drop", "op_player"); y = y + ROW
  checkbox(ox, oy, 0, y, "wands: decks and stats", "op_wands"); y = y + ROW
  checkbox(ox, oy, 0, y, "world / raw writes (advanced)", "op_world"); y = y + ROW + 6

  heading(ox, oy, 0, y, "logging"); y = y + HEAD_H
  checkbox(ox, oy, 0, y, "verbose (also keep DEBUG messages)", "verbose"); y = y + ROW + 6

  -- The effective state, spelled out. Working out what four switches add up to is exactly
  -- the kind of thing a panel should do instead of the operator.
  local text, col
  if not flag("master") then
    text, col = "PAUSED - observation only", { 1, 0.78, 0.3 }
  elseif flag("read_only") then
    text, col = "OBSERVE ONLY - writes refused", { 1, 0.78, 0.3 }
  else
    local on = {}
    if flag("op_spawn") then on[#on + 1] = "spawn" end
    if flag("op_player") then on[#on + 1] = "player" end
    if flag("op_wands") then on[#on + 1] = "wands" end
    if flag("op_world") then on[#on + 1] = "world" end
    if #on == 0 then
      text, col = "NO WRITES - every category is off", { 1, 0.38, 0.34 }
    else
      text, col = "WRITES ALLOWED: " .. table.concat(on, ", "), { 0.45, 0.95, 0.5 }
    end
  end
  heading(ox, oy, 0, y, "effective"); y = y + HEAD_H
  GuiColorSetForNextWidget(gui, col[1], col[2], col[3], 1)
  GuiText(gui, ox + 0, oy + y, text)
  GuiColorSetForNextWidget(gui, 1, 1, 1, 1)
end

-- ---- Extension --------------------------------------------------------------

-- "The DLL did not load" is the most confusing state this project has: the base mod works,
-- so everything looks fine until an input tool refuses. This pane answers three questions
-- in order -- loaded, armed, and if neither, which paths were tried -- and offers the
-- action inline, so the answer is also the fix.
local function pane_extension_height(status)
  local st = status and status.extension
  if type(st) ~= "table" then return HEAD_H + ROW end
  local n = HEAD_H + ROW * 3 + 8
  if st.build_id then n = n + ROW end
  if st.pid then n = n + ROW end
  if not st.loaded then
    n = n + HEAD_H + ROW + 8
    local last = status.last_load
    if type(last) == "table" and type(last.attempts) == "table" and #last.attempts > 0 then
      n = n + HEAD_H + (#last.attempts * 12) + 6
    elseif type(last) == "table" then
      n = n + ROW
    end
    n = n + ROW
  else
    n = n + HEAD_H + ROW
    if type(status.last_load) == "table" and status.last_load.path then n = n + ROW end
  end
  return n + 8 + HEAD_H + ROW + 20
end

local function pane_extension(ox, oy, status)
  local y = 0
  local st = status and status.extension
  if type(st) ~= "table" then
    heading(ox, oy, 0, y, "extension")
    dim(ox, oy, 0, y + HEAD_H, "no status reported yet")
    return
  end

  heading(ox, oy, 0, y, "state"); y = y + HEAD_H
  local loaded, armed = st.loaded, st.hooks_installed
  key_value(ox, oy, 0, y, "dll loaded", loaded and "yes" or "no",
    loaded and { 0.45, 0.95, 0.5 } or { 1, 0.78, 0.3 })
  y = y + ROW
  key_value(ox, oy, 0, y, "hooks armed", armed and "yes" or "no",
    armed and { 0.45, 0.95, 0.5 } or { 1, 0.78, 0.3 })
  y = y + ROW
  key_value(ox, oy, 0, y, "dll", tostring(st.dll or "xinput_hook.dll")); y = y + ROW
  if st.build_id then key_value(ox, oy, 0, y, "build", tostring(st.build_id)); y = y + ROW end
  if st.pid then key_value(ox, oy, 0, y, "process", tostring(st.pid)); y = y + ROW end
  y = y + 8

  if not loaded then
    heading(ox, oy, 0, y, "why not"); y = y + HEAD_H
    dim(ox, oy, 0, y, tostring(st.reason or "not loaded in this session")); y = y + ROW

    local last = status.last_load
    if type(last) == "table" and type(last.attempts) == "table" and #last.attempts > 0 then
      heading(ox, oy, 0, y, "paths tried (" .. #last.attempts .. ")"); y = y + HEAD_H
      for i = 1, #last.attempts do
        local a = last.attempts[i]
        -- A handle means LoadLibraryA succeeded; call_ok false means it raised. Those are
        -- different failures and the reader needs to tell them apart.
        local mark, col
        if a.handle then mark, col = "ok  ", { 0.45, 0.95, 0.5 }
        elseif a.call_ok then mark, col = "miss", { 1, 0.78, 0.3 }
        else mark, col = "err ", { 1, 0.38, 0.34 } end
        chip(ox, oy, 0, y, mark, col[1], col[2], col[3])
        -- Paths are long; show the tail, which is the part that differs between them.
        local p = tostring(a.path)
        if #p > 58 then p = "..." .. p:sub(-55) end
        dim(ox, oy, 40, y, p)
        y = y + 12
      end
      y = y + 6
    elseif type(last) == "table" then
      dim(ox, oy, 0, y, "last attempt: " .. tostring(last.error or "unknown")); y = y + ROW
    end
    dim(ox, oy, 0, y, "the base mod works without this; only input forging needs it")
    y = y + ROW
  else
    heading(ox, oy, 0, y, "state detail"); y = y + HEAD_H
    dim(ox, oy, 0, y, tostring(st.reason or (armed and "ready" or "loaded but inert")))
    y = y + ROW
    if type(status.last_load) == "table" and status.last_load.path then
      key_value(ox, oy, 0, y, "loaded from", tostring(status.last_load.path)); y = y + ROW
    end
  end
  y = y + 8

  heading(ox, oy, 0, y, "actions"); y = y + HEAD_H
  local xin = xinput
  if not loaded then
    if GuiButton(gui, id(), ox + 0, oy + y, "load extension DLL") then
      if xin and type(xin.load) == "function" then
        local r = xin.load({})
        if r and r.ok then
          panel.info("extension loaded from " .. tostring(r.path), { source = "panel" })
        else
          panel.error("extension failed to load: " .. tostring(r and r.error or "unknown"),
            { key = "dllload", source = "panel" })
        end
      else
        panel.error("xinput module unavailable", { key = "noxinput", source = "panel" })
      end
    end
    y = y + 20
    dim(ox, oy, 0, y, "loading is inert: nothing is hooked until you arm it")
  elseif not armed then
    if GuiButton(gui, id(), ox + 0, oy + y, "arm input hooks") then
      if xin and type(xin.poll_install) == "function" then
        local r = xin.poll_install()
        if r and r.ok then
          panel.info("input hooks armed", { source = "panel" })
        else
          panel.error("arming failed: " .. tostring(r and r.error or "unknown"),
            { key = "armfail", source = "panel" })
        end
      end
    end
    y = y + 20
    dim(ox, oy, 0, y, "arming hooks the engine's event poll so input can be forged")
  else
    if GuiButton(gui, id(), ox + 0, oy + y, "disarm hooks (restore normal input)") then
      if xin and type(xin.poll_remove) == "function" then
        xin.poll_remove()
        panel.warn("input hooks disarmed", { source = "panel" })
      end
    end
    y = y + 20
    dim(ox, oy, 0, y, "input forging is available to the AI")
  end
end

-- ---- Log --------------------------------------------------------------------

local function pane_log_height()
  local shown = 0
  for i = #log_entries, 1, -1 do
    if (LEVEL[log_entries[i].level] or 0) >= min_level then shown = shown + 1 end
    if shown >= LOG_TAIL then break end
  end
  return 20 + math.max(1, shown) * LINE_H
end

local function pane_log(ox, oy, width)
  local y = 0

  local levels = { { "all", LEVEL.DEBUG }, { "info+", LEVEL.INFO },
                   { "warn+", LEVEL.WARN }, { "errors", LEVEL.ERROR } }
  local x = 0
  for i = 1, #levels do
    local name, val = levels[i][1], levels[i][2]
    local active = (min_level == val)
    GuiColorSetForNextWidget(gui, active and 0.55 or 0.70, active and 0.85 or 0.70,
      active and 1 or 0.70, 1)
    if GuiButton(gui, id(), ox + x, oy + y, name) then min_level = val end
    GuiColorSetForNextWidget(gui, 1, 1, 1, 1)
    x = x + #name * 7 + 14
  end

  local total = 0
  for i = 1, #log_entries do
    if (LEVEL[log_entries[i].level] or 0) >= min_level then total = total + 1 end
  end
  if total > LOG_TAIL then
    dim(ox, oy, x + 6, y, "newest " .. LOG_TAIL .. " of " .. total)
  else
    dim(ox, oy, x + 6, y, total .. " shown")
  end
  y = y + 20

  if total == 0 then
    dim(ox, oy, 0, y, "(nothing logged yet)")
    return
  end

  -- Newest first, so the most recent event is always at a readable position and never
  -- below the fold.
  local rows = {}
  for i = #log_entries, 1, -1 do
    local e = log_entries[i]
    if (LEVEL[e.level] or 0) >= min_level then
      rows[#rows + 1] = e
      if #rows >= LOG_TAIL then break end
    end
  end

  for i = 1, #rows do
    local e = rows[i]
    local col = LEVEL_COLOR[e.level] or LEVEL_COLOR.INFO
    chip(ox, oy, 0, y, LEVEL_TAG[e.level] or "inf", col[1], col[2], col[3])
    local suffix = ""
    if e.source then suffix = "  {" .. e.source .. "}" end
    if (e.count or 1) > 1 then suffix = suffix .. "  x" .. e.count end
    -- Wrapped so a long message is readable in full; the pane has the width for it.
    local lines = wrap(e.text .. suffix, width - 40)
    normal(ox, oy, 40, y, lines[1])
    for k = 2, #lines do
      y = y + LINE_H
      dim(ox, oy, 40, y, lines[k])
    end
    y = y + LINE_H
  end
end

-- ---- frame ------------------------------------------------------------------

local function pane_height(status)
  if active_tab == 2 then return pane_permissions_height() end
  if active_tab == 3 then return pane_extension_height(status) end
  if active_tab == 4 then return pane_log_height() end
  return pane_status_height()
end

local function draw_pane(ox, oy, status, width)
  if active_tab == 2 then
    pane_permissions(ox, oy)
  elseif active_tab == 3 then
    pane_extension(ox, oy, status)
  elseif active_tab == 4 then
    pane_log(ox, oy, width)
  else
    pane_status(ox, oy, status)
  end
end

local function draw_panel(status)
  local w, h = GuiGetScreenDimensions(gui)
  w = tonumber(w) or 1280
  h = tonumber(h) or 720

  local open = flag("open")
  local pw = math.min(PANEL_W, w - 2 * MIN_MARGIN)
  local iw = pw - 2 * PAD

  -- Height comes from the pane that is about to be drawn, so the box always fits its
  -- contents and never more.
  local body_h = open and pane_height(status) or 0
  local ph = PAD + 22 + (open and (10 + 24 + body_h + PAD) or 10)

  -- Position depends on the state, because the two want different things.
  --
  --   collapsed: a small always-on strip, parked in the top-left corner where a status
  --              readout belongs and where it can be found without hunting. Centring it
  --              put it in the middle of the play area, in the way and far from the eye's
  --              usual resting place.
  --   open:      centred, because the panel is then a dialog being read, and the corners
  --              are where the game draws its own HUD.
  local px, py
  if open then
    px = math.floor((w - pw) / 2)
    py = math.floor((h - ph) / 2)
  else
    -- Collapsed: no padding above or left of the strip, so it hugs the corner.
    px = MARGIN_X - PAD
    py = MARGIN_Y - PAD
  end

  -- The backdrop only exists when the panel is open. A collapsed header is one button and
  -- does not need a box; one there covered part of the game's HUD for no benefit.
  if open then
    GuiColorSetForNextWidget(gui, PANEL_TINT[1], PANEL_TINT[2], PANEL_TINT[3], PANEL_TINT[4])
    GuiImageNinePiece(gui, id(), px, py, pw, ph, 1, PANEL_SPRITE)
    GuiColorSetForNextWidget(gui, 1, 1, 1, 1)
  end

  local ix, iy = px + PAD, py + PAD

  -- ---- header ------------------------------------------------------------
  -- One labelled button, not a transparent hit-box drawn over a label. The previous
  -- version paired an empty button with separate GuiText, so the visible "noita_agent -"
  -- was paint, not a control: clicking the words did nothing because the clickable area
  -- was an invisible rectangle rendered underneath them.
  local toggle_label = open and "[ - ]  noita_agent" or "[ + ]  noita_agent"
  GuiColorSetForNextWidget(gui, 0.55, 0.72, 0.95, 1)
  if GuiButton(gui, id(), ix, iy, toggle_label) then
    set_flag("open", not open)
    open = not open
  end
  GuiColorSetForNextWidget(gui, 1, 1, 1, 1)

  local cx = ix + 150
  local running = flag("master")
  chip(cx, iy, 0, 0, running and "AI ON" or "AI PAUSED",
    running and 0.45 or 1, running and 0.95 or 0.78, running and 0.5 or 0.3)
  local sock = status.socket
  local sockUp = sock and sock.started
  chip(cx + 80, iy, 0, 0, sockUp and "SOCKET" or "FILE",
    sockUp and 0.45 or 1, sockUp and 0.95 or 0.78, sockUp and 0.5 or 0.3)

  local errs = 0
  for i = 1, #log_entries do
    if log_entries[i].level == "ERROR" then errs = errs + 1 end
  end
  if errs > 0 then
    chip(ix + iw - 66, iy, 0, 0, errs .. " ERROR", 1, 0.38, 0.34)
  end

  if not open then return end

  -- ---- tabs --------------------------------------------------------------
  local ty = iy + 22
  rule(ix, ty, 0, 0, iw)
  ty = ty + 10

  local tx = 0
  for i = 1, #TABS do
    local is_active = (active_tab == i)
    GuiColorSetForNextWidget(gui, is_active and 0.55 or 0.70,
      is_active and 0.85 or 0.70, is_active and 1 or 0.70, 1)
    if GuiButton(gui, id(), ix + tx, ty, TABS[i]) then active_tab = i end
    GuiColorSetForNextWidget(gui, 1, 1, 1, 1)
    tx = tx + #TABS[i] * 7 + 20
  end
  ty = ty + 24
  rule(ix, ty - 7, 0, 0, iw, 0.18)

  -- ---- body --------------------------------------------------------------
  -- The origin is passed in, not set globally: Noita's GUI API has no translate call, and
  -- assuming one existed is what left this area blank.
  local ok, err = pcall(draw_pane, ix, ty, status, iw)
  if not ok then
    panel.error("panel error: " .. tostring(err),
      { key = "draw:" .. tostring(err), source = "panel" })
  end
end

-- ---------------------------------------------------------------- lifecycle

function panel.init()
  if gui then return true end

  -- Re-arm the session switches before anything can be refused. Order matters: drop the
  -- memoised cache FIRST, then write the defaults, or invalidate() discards the values
  -- just written and the next read pulls the stale persisted ones back in.
  pcall(store.invalidate)
  pcall(apply_session_defaults)

  if type(GuiCreate) ~= "function" then
    return false   -- no GUI in this sandbox; the gate still works, using defaults
  end
  gui = GuiCreate()
  panel.info("panel ready", { source = "panel" })
  return true
end

function panel.update(status)
  if not gui then
    if not panel.init() then return end
  end
  next_id = 0
  GuiStartFrame(gui)
  draw_panel(status or {})
end

function panel.state()
  local recent = {}
  for i = math.max(1, #log_entries - 15), #log_entries do
    local e = log_entries[i]
    if e then
      recent[#recent + 1] = string.format("[%s] %s%s", e.level, e.text,
        ((e.count or 1) > 1) and (" x" .. e.count) or "")
    end
  end
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
    recent = recent,
  }
end

return panel

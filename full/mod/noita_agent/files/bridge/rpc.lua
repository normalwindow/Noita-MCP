-- RPC layer: publishes game state to disk and executes queued commands.
--
-- Transport is a single request/response file pair. Noita's Lua sandbox has no
-- directory listing and no sockets, so a fixed pair of paths is the only
-- reliable channel. The MCP server on the other side does:
--
--   1. reads  <base>/state.json      -> {"schema":1,"frame":N,"state":{...}}
--   2. writes <base>/request.json    -> {"id":<n>,"method":"...","params":{}}
--   3. polls  <base>/response.json   -> {"id":<n>,"ok":true,"result":{...}}
--
-- The mod deletes request.json once handled and stamps its id into
-- response.json, so a stale file can never be mistaken for a fresh answer.

rpc = rpc or {}

-- Latency budget.
--
-- The MCP client's end-to-end latency is dominated by how often the game looks
-- at the request file, so polling runs EVERY frame by default: one frame is
-- 16.7 ms and that is the floor for a file-mediated transport. The cost is one
-- file-exists test per frame; the file is only OPENED when it is actually there,
-- so an idle bridge does no reads.
--
-- State is published at 30 Hz (every 2 frames) -- often enough for an AI to
-- watch, cheap enough not to matter. Both are tunable from the in-game panel via
-- store keys, so an operator can trade latency against file churn.
local DEFAULT_STATE_INTERVAL = 2
local DEFAULT_POLL_INTERVAL = 1
local STATUS_INTERVAL = 180    -- frames between status writes
local LOG_INTERVAL = 600

local function setting(key, default)
  if store and type(store.get) == "function" then
    local ok, v = pcall(store.get, key, default)
    if ok and type(v) == "number" and v >= 1 then return math.floor(v) end
  end
  return default
end

local function setting_bool(key, default)
  if store and type(store.get) == "function" then
    local ok, v = pcall(store.get, key, default)
    if ok and type(v) == "boolean" then return v end
  end
  return default
end

local frame_counter = 0
local player_entity = nil
local base_dir = nil
local ready = false
local last_request_id = nil
local handled = 0

-- Latency instrumentation, so "is it actually fast?" is answerable from data.
local last_poll_frame = nil      -- frame at which a request was picked up
local last_request_write = nil   -- mtime-ish stamp the server embedded
local latency_samples = {}
local MAX_LATENCY_SAMPLES = 60

-- The mod sandbox may hand us a stripped environment (no os, no io) unless the
-- mod requests full API access. Everything below goes through these guards so a
-- missing library degrades into "bridge unavailable" instead of a Lua error.
local function io_lib()
  local t = rawget(_G, "io")
  if type(t) == "table" and type(t.open) == "function" then return t end
  return nil
end

local function os_lib()
  local t = rawget(_G, "os")
  if type(t) == "table" then return t end
  return nil
end

local function now()
  local os_ = os_lib()
  if os_ and type(os_.time) == "function" then
    local ok, t = pcall(os_.time)
    if ok then return t end
  end
  return 0
end

-- ---------------------------------------------------------------- file utils

local CANDIDATES = {
  "mods/noita_agent/run/",
  "noita_agent_run/",
  "mods/noita_agent/",
}

local function write_file(path, data)
  local io_ = io_lib()
  if not io_ then return false, "io unavailable" end
  local ok, err = pcall(function()
    local f = io_.open(path, "wb")
    if not f then error("io.open returned nil for " .. path) end
    f:write(data)
    f:flush()
    f:close()
  end)
  return ok, err
end

local function read_file(path)
  local io_ = io_lib()
  if not io_ then return nil end
  local ok, data = pcall(function()
    local f = io_.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
  end)
  if ok then return data end
  return nil
end

-- Cheap existence check. The bridge polls every frame, so the common case is
-- "no request waiting" and that case must not open the file at all. Opening a
-- missing file per frame is pure waste; a bare open/close probe is the cheapest
-- existence test Lua's io gives us without lfs.
local function file_exists(path)
  local io_ = io_lib()
  if not io_ then return false end
  local ok, present = pcall(function()
    local f = io_.open(path, "rb")
    if not f then return false end
    f:close()
    return true
  end)
  return ok and present == true
end

local function remove_file(path)
  local os_ = os_lib()
  if os_ and type(os_.remove) == "function" then
    pcall(os_.remove, path)
  end
end

-- ---------------------------------------------------------------- handlers

local handlers = {}

handlers.ping = function()
  return { pong = true, frame = GameGetFrameNum(), time = now() }
end

handlers.status = function()
  return {
    ready = ready,
    base_dir = base_dir,
    frame = GameGetFrameNum(),
    has_player = player_entity ~= nil,
    handled_requests = handled,
    lua = _VERSION,
    io = type(rawget(_G, "io")),
    os = type(rawget(_G, "os")),
    ffi = type(rawget(_G, "ffi")),
    mod_text_api = type(rawget(_G, "ModTextFileSetContent")) == "function",
    env = log.env_report and log.env_report() or nil,
    panel = (panel and type(panel.state) == "function") and panel.state() or nil,
    latency = (type(rpc.latency) == "function") and rpc.latency() or nil,
    polling = {
      poll_interval_frames = setting("poll_interval", DEFAULT_POLL_INTERVAL),
      state_interval_frames = setting("state_interval", DEFAULT_STATE_INTERVAL),
      note = "one frame is 16.7ms; polling every frame is the floor for a file transport",
    },
    socket = (type(rpc.socket_stats) == "function") and rpc.socket_stats() or nil,
    api = (function()
      -- cheap capability summary; probe_api gives the full list
      local names = { "GuiCreate", "GuiSlider", "ModSettingSet", "InputIsKeyJustDown" }
      local out = {}
      for _, n in ipairs(names) do out[n] = type(rawget(_G, n)) end
      return out
    end)(),
    version = 1,
  }
end

handlers.get_state = function()
  local state = ser.player_state()
  state.nearby = ser.nearby(220, 24).entities
  state.wands = ser.all_wands()
  state.inventory = ser.inventory().items
  return state
end

handlers.get_player = function()
  return ser.player_state()
end

handlers.get_nearby = function(params)
  params = params or {}
  return ser.nearby(params.radius or 200, params.limit or 40, params.tag)
end

handlers.get_inventory = function()
  return ser.inventory()
end

handlers.get_wands = function()
  return { wands = ser.all_wands() }
end

handlers.get_held_wand = function()
  local wand = ser.held_wand()
  if not wand then return { ok = false, error = "no wand held" } end
  return { wand = ser.wand_info(wand) }
end

handlers.raycast = function(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end
  local px, py = EntityGetTransform(p)
  local dx, dy = params.dx, params.dy
  if params.angle then
    local rad = math.rad(params.angle)
    local dist = params.distance or 200
    dx, dy = math.cos(rad) * dist, math.sin(rad) * dist
  end
  if not dx then dx, dy = 200, 0 end
  return ser.raycast(px, py, px + dx, py + dy, params.mode)
end

handlers.set_player = function(params)
  local ok, res = ser.set_player(params or {})
  if not ok then return { ok = false, error = res } end
  return { ok = true, applied = res, player = ser.player_state() }
end

handlers.heal = function(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end
  local dm = ser.comp(p, "DamageModelComponent")
  if not dm then return { ok = false, error = "no DamageModelComponent" } end
  if params.max_hp then ComponentSetValue2(dm, "max_hp", params.max_hp) end
  local max_hp = ComponentGetValue2(dm, "max_hp")
  local hp = params.hp or (max_hp * (params.fraction or 1))
  ComponentSetValue2(dm, "hp", hp)
  return { ok = true, hp = ComponentGetValue2(dm, "hp"), max_hp = max_hp }
end

handlers.set_max_hp = function(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end
  local dm = ser.comp(p, "DamageModelComponent")
  if not dm then return { ok = false, error = "no DamageModelComponent" } end
  if params.max_hp then ComponentSetValue2(dm, "max_hp", params.max_hp) end
  if params.hp then ComponentSetValue2(dm, "hp", params.hp) end
  return { ok = true, max_hp = ComponentGetValue2(dm, "max_hp"), hp = ComponentGetValue2(dm, "hp") }
end

handlers.add_gold = function(params)
  params = params or {}
  return handlers.set_player({ money_add = params.amount or 1000 })
end

handlers.apply_effect = function(params)
  params = params or {}
  local ok, res = ser.apply_effect(params.effect, params.frames)
  if not ok then return { ok = false, error = res } end
  return { ok = true, effect = res }
end

handlers.refresh_spells = function()
  local ok, err = ser.refresh_spells()
  return { ok = ok, error = err }
end

handlers.spawn_wand = function(params)
  params = params or {}
  local wand, err = ser.spawn_wand(params)
  if not wand then return { ok = false, error = err } end
  return { ok = true, wand = ser.wand_info(wand), entity = wand }
end

handlers.edit_wand = function(params)
  params = params or {}
  local wand = params.entity or ser.held_wand()
  if not wand then return { ok = false, error = "no wand (held or given)" } end
  local attrs = params.attrs or params
  ser.apply_wand_attrs(wand, attrs)
  if params.spells then ser.set_deck(wand, params.spells) end
  return { ok = true, wand = ser.wand_info(wand) }
end

handlers.set_wand_deck = function(params)
  params = params or {}
  local wand = params.entity or ser.held_wand()
  if not wand then return { ok = false, error = "no wand (held or given)" } end
  local ok, err = ser.set_deck(wand, params.spells or {})
  if not ok then return { ok = false, error = err } end
  return { ok = true, wand = ser.wand_info(wand) }
end

handlers.add_spell_to_wand = function(params)
  params = params or {}
  local wand = params.entity or ser.held_wand()
  if not wand then return { ok = false, error = "no wand (held or given)" } end
  local info = ser.action_info(params.action_id)
  if not info then return { ok = false, error = "unknown spell " .. tostring(params.action_id) } end

  local deck = ser.deck(wand)
  local spells = {}
  local inserted = false
  local normal_index = 0
  for i = 1, #deck do
    local entry = deck[i]
    if not entry.always_cast then
      if not inserted and params.index ~= nil and params.index == normal_index then
        spells[#spells + 1] = { id = params.action_id, always_cast = false }
        inserted = true
      end
      spells[#spells + 1] = { id = entry.action_id, always_cast = false }
      normal_index = normal_index + 1
    end
  end
  if not inserted then
    spells[#spells + 1] = { id = params.action_id, always_cast = false }
  end
  for i = 1, #deck do
    if deck[i].always_cast then
      spells[#spells + 1] = { id = deck[i].action_id, always_cast = true }
    end
  end
  ser.set_deck(wand, spells)
  return { ok = true, wand = ser.wand_info(wand) }
end

handlers.remove_spell_from_wand = function(params)
  params = params or {}
  local wand = params.entity or ser.held_wand()
  if not wand then return { ok = false, error = "no wand (held or given)" } end
  local deck = ser.deck(wand)
  local spells = {}
  local removed = false
  for i = 1, #deck do
    local entry = deck[i]
    local match_index = (params.index ~= nil and (i - 1) == params.index)
    local match_id = (params.action_id ~= nil and entry.action_id == params.action_id)
    if not removed and (match_index or match_id) then
      removed = true
    else
      spells[#spells + 1] = { id = entry.action_id, always_cast = entry.always_cast }
    end
  end
  if not removed then return { ok = false, error = "no matching spell in deck" } end
  ser.set_deck(wand, spells)
  return { ok = true, wand = ser.wand_info(wand) }
end

handlers.spawn_spell = function(params)
  params = params or {}
  local info = ser.action_info(params.action_id)
  if not info then return { ok = false, error = "unknown spell " .. tostring(params.action_id) } end
  local e, err = ser.spawn_spell(params.action_id, params.x, params.y)
  if not e then return { ok = false, error = err } end
  return { ok = true, entity = e, spell = info }
end

handlers.spawn_item = function(params)
  params = params or {}
  if not params.filename then return { ok = false, error = "filename required" } end
  local e, err = ser.spawn_item(params.filename, params.x, params.y)
  if not e then return { ok = false, error = err } end
  return { ok = true, entity = e, info = ser.entity_info(e) }
end

handlers.spawn_potion = function(params)
  params = params or {}
  local potion, err = ser.spawn_potion(params)
  if not potion then return { ok = false, error = err } end
  return { ok = true, entity = potion, contents = ser.potion_contents(potion) }
end

handlers.get_potion = function(params)
  params = params or {}
  local e = params.entity or ser.held_item()
  if not e then return { ok = false, error = "no item held" } end
  return { ok = true, entity = e, contents = ser.potion_contents(e) }
end

handlers.set_potion = function(params)
  params = params or {}
  local e = params.entity or ser.held_item()
  if not e then return { ok = false, error = "no item held" } end
  local comp = ser.comp(e, "MaterialInventoryComponent")
  if not comp then return { ok = false, error = "entity has no MaterialInventoryComponent" } end
  local counts = ComponentGetValue2(comp, "count_per_material_type")
  if type(counts) == "table" then
    for i = 1, #counts do
      if counts[i] and counts[i] > 0 then
        pcall(AddMaterialInventoryMaterial, e, CellFactory_GetName(i - 1), 0)
      end
    end
  end
  local wanted = params.materials
  if type(wanted) == "string" then wanted = { { material = wanted, amount = params.amount or 1000 } } end
  if type(wanted) == "table" then
    for i = 1, #wanted do
      local m = wanted[i]
      local material = type(m) == "table" and m.material or m
      local amount = type(m) == "table" and (m.amount or 1000) or (params.amount or 1000)
      if material then pcall(AddMaterialInventoryMaterial, e, material, amount) end
    end
  end
  return { ok = true, entity = e, contents = ser.potion_contents(e) }
end

handlers.list_spells = function(params)
  params = params or {}
  local list = ser.all_actions()
  if params.filter then
    local needle = string.lower(params.filter)
    local filtered = {}
    for i = 1, #list do
      local s = list[i]
      if string.find(string.lower(s.id), needle, 1, true)
        or string.find(string.lower(s.name_human or ""), needle, 1, true) then
        filtered[#filtered + 1] = s
      end
    end
    list = filtered
  end
  return { count = #list, spells = list }
end

handlers.list_materials = function(params)
  params = params or {}
  local list = ser.material_catalog()
  if params.filter then
    local needle = string.lower(params.filter)
    local filtered = {}
    for i = 1, #list do
      if string.find(string.lower(list[i]), needle, 1, true) then
        filtered[#filtered + 1] = list[i]
      end
    end
    list = filtered
  end
  local out = {}
  local limit = math.min(#list, params.limit or 400)
  for i = 1, limit do
    out[i] = { material = list[i], name = ser.material_name(list[i]) }
  end
  return { count = #list, materials = out }
end

handlers.get_perks = function()
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end
  return { perks = ser.player_state().perks }
end

handlers.list_perks = function()
  local list = ser.perks()
  local out = {}
  for i = 1, #list do
    local perk = list[i]
    if perk and perk.id then
      local name = perk.ui_name or perk.id
      local tname = select(2, pcall(GameTextGetTranslatedOrNot, name))
      out[#out + 1] = { id = perk.id, name = tname or name }
    end
  end
  return { count = #out, perks = out }
end

handlers.entity_info = function(params)
  params = params or {}
  local e = params.entity
  if not e then return { ok = false, error = "entity required" } end
  local info = ser.entity_info(e)
  if not info then return { ok = false, error = "entity not found" } end
  return { info = info }
end

handlers.drop_item = function(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end
  local e = params.entity or ser.held_item()
  if not e then return { ok = false, error = "no item" } end
  pcall(GameKillInventoryItem, p, e)
  return { ok = true }
end

-- ------------------------------------------------ control experiments (stage 0)
-- These exist to answer "can a mod drive the player's input?" empirically.
-- They are read-only unless explicitly asked to write, and every writer has a
-- matching snapshot/restore so a test can always be undone.

handlers.probe_controls = function()
  return exp.probe_controls()
end

handlers.control_set = function(params)
  return exp.set_controls(params)
end

handlers.control_set_aim = function(params)
  return exp.set_aim(params)
end

handlers.control_snapshot = function()
  return exp.snapshot_controls()
end

handlers.control_restore = function()
  return exp.restore_controls()
end

handlers.control_push = function(params)
  return exp.push_controls(params)
end

handlers.control_push_status = function()
  return exp.push_status()
end

handlers.control_push_cancel = function()
  return exp.cancel_push()
end

-- ------------------------------------------------ direct control levers
-- The official input path cannot be forged (stage 0). These act on the state the
-- input feeds instead: velocity, transform, gravity, mass, movement gates.

handlers.lever_state = function()
  return lever.state()
end

handlers.lever_engage = function(params)
  return lever.engage(params)
end

handlers.lever_disengage = function()
  return lever.disengage()
end

handlers.lever_status = function()
  return lever.status()
end

handlers.lever_cancel = function()
  return lever.cancel()
end

handlers.lever_experiment = function(params)
  return lever.run_experiment(params)
end

handlers.lever_experiment_result = function()
  return lever.experiment_result()
end

-- Reports whether LuaJIT FFI is reachable. This is the ceiling on transport
-- options: with FFI a real socket becomes possible; without it we stay on files.
handlers.probe_ffi = function()
  local req = rawget(_G, "require")
  local out = { require = type(req), ffi_global = type(rawget(_G, "ffi")) }

  if type(req) ~= "function" then
    out.verdict = "no require(): FFI unreachable"
    return out
  end

  local ok, ffi = pcall(req, "ffi")
  out.require_ffi_ok = ok
  out.ffi_type = type(ffi)
  if not ok or type(ffi) ~= "table" then
    out.verdict = "require('ffi') failed: " .. tostring(ffi)
    return out
  end

  -- it exists; prove it can actually do something
  out.has_cdef = type(ffi.cdef) == "function"
  out.has_load = type(ffi.load) == "function"
  out.has_new = type(ffi.new) == "function"

  local ok_cdef, err_cdef = pcall(ffi.cdef, "int getpid(void);")
  out.cdef_ok = ok_cdef
  if not ok_cdef then out.cdef_error = tostring(err_cdef) end

  local ok_load, ws = pcall(ffi.load, "ws2_32")
  out.load_ws2_32 = ok_load
  if ok_load then
    out.ws2_32 = type(ws)
    -- a real syscall proves the library is usable, not merely loadable
    local ok_call, res = pcall(function() return ws.WSAStartup end)
    out.ws2_32_has_WSAStartup = ok_call and res ~= nil
  else
    out.load_error = tostring(ws)
  end

  -- LuaJIT presence is a good sanity signal
  local ok_jit, jit = pcall(req, "jit")
  out.jit = ok_jit and type(jit) == "table" and tostring(jit.version) or nil

  if out.cdef_ok and out.load_ws2_32 then
    out.verdict = "FFI USABLE: sockets are possible (ws2_32 loads)"
  elseif out.cdef_ok then
    out.verdict = "FFI usable but ws2_32 failed to load"
  else
    out.verdict = "FFI present but cdef failed"
  end
  return out
end

-- Runs a Lua file inside the game and optionally calls a named function in it.
--
-- This is the reverse-engineering / diagnostics entry point: it lets a probe be
-- developed and executed without editing the mod and reloading the game. It is
-- gated by op_world (off by default in the panel) for the obvious reason -- it
-- executes arbitrary code -- and the panel log records every use.
handlers.debug_run_lua = function(params)
  params = params or {}
  if type(params.file) ~= "string" then
    return { ok = false, error = "file required (path relative to the game root)" }
  end

  if panel and type(panel.push_log) == "function" then
    panel.push_log("debug_run_lua: " .. params.file)
  end

  local chunk, err = loadfile(params.file)
  if not chunk then
    return { ok = false, error = "loadfile failed: " .. tostring(err) }
  end

  local ok, result = pcall(chunk)
  if not ok then
    return { ok = false, error = "chunk error: " .. tostring(result) }
  end

  -- The file may return a table of functions; if a function name was given, call it.
  if params.fn then
    local target = result
    if type(target) ~= "table" then
      return { ok = false, error = "file did not return a table, cannot call " .. tostring(params.fn) }
    end
    local f = target[params.fn]
    if type(f) ~= "function" then
      local names = {}
      for k, v in pairs(target) do
        if type(v) == "function" then names[#names + 1] = k end
      end
      return {
        ok = false,
        error = "no function '" .. tostring(params.fn) .. "' in the returned table",
        available_functions = names,
      }
    end
    local called, value = pcall(f, params.args)
    if not called then
      return { ok = false, error = "call error: " .. tostring(value) }
    end
    return { ok = true, returned = value }
  end

  return { ok = true, returned = result }
end

-- Reports what the Lua API exposes about the live ControlsComponent, and whether
-- the component id is usable as a memory pointer. Read-only; the starting point
-- for locating the struct in memory.
handlers.memscan_probe = function(params)
  return memscan.probe(params)
end

-- What the FFI can actually do with process memory here. Read-only.
handlers.memscan_caps = function()
  return memscan.ffi_caps()
end

-- Memory scanning is incremental on purpose. The first version walked the whole
-- address space in one Lua loop, crossed a guard page, and took the game down
-- with a STATUS_GUARD_PAGE_VIOLATION -- an SEH exception, which pcall does NOT
-- catch. These handlers therefore only ever start, step and finish a scan; the
-- per-frame work is bounded in rpc.pre_update.
handlers.memscan_begin = function(params)
  return memscan.begin(params)
end

handlers.memscan_step = function()
  return memscan.step()
end

handlers.memscan_finish = function()
  return memscan.finish()
end

handlers.memscan_abort = function()
  return memscan.abort()
end

handlers.memscan_progress = function()
  return memscan.progress()
end

handlers.memscan_result = function()
  return memscan.result()
end

-- ------------------------------------------------ interaction capability suite
-- Each of these MEASURES a candidate mechanism and reports whether the game
-- actually changed. Nothing here is exposed as a tool until it has been shown to
-- work in a live run.

-- ------------------------------------------------ player operations (production)
-- Backed by measured results: see player_ops.lua for what each one can and
-- cannot do.

handlers.field_offsets      = function(params) return memscan.field_offsets(params) end
handlers.read_probe         = function(params) return memscan.read_probe(params) end
handlers.read_probe_check   = function(params) return memscan.read_probe_check(params) end
handlers.controls_snapshot  = function() return memscan.snapshot_controls() end
handlers.input_status        = function() return xinput.status() end
handlers.input_load          = function(params) return xinput.load(params) end
handlers.input_install       = function() return xinput.install_hooks() end
handlers.input_calls         = function() return xinput.call_counts() end
handlers.push_key            = function(params) return xinput.push_key(params and params.key, params and params.down) end
handlers.hold_key            = function(params) return xinput.hold_key(params and params.key, params and params.frames) end
handlers.po_input_fire       = function(params) return xinput.hold_key('SPACE', params and params.frames or 20) end
handlers.po_input_jump       = function(params) return xinput.hold_key('SPACE', params and params.frames or 8) end
handlers.po_input_move       = function(params) return xinput.hold_key(params and params.dir or 'D', params and params.frames or 20) end
handlers.hold_release        = function() return xinput.hold_release() end
handlers.hold_status         = function() return xinput.hold_status() end
handlers.hold_mouse          = function(params)
  params = params or {}
  return xinput.hold_mouse(params.button or 1, params.frames or 20, params.x, params.y)
end
handlers.mouse_release       = function() return xinput.mouse_release() end
handlers.push_stats          = function() return xinput.push_stats() end
handlers.peep_install        = function() return xinput.peep_install() end
handlers.peep_remove         = function() return xinput.peep_remove() end
handlers.peep_stats          = function() return xinput.peep_stats() end
handlers.poll_install        = function() return xinput.poll_install() end
handlers.poll_remove         = function() return xinput.poll_remove() end
handlers.poll_stats          = function() return xinput.poll_stats() end
handlers.poll_forge_key      = function(params) return xinput.poll_forge_key(params and params.key, params and params.frames) end
handlers.poll_forge_clear    = function() return xinput.poll_forge_clear() end
handlers.input_probe_install = function() return xinput.probe_install() end
handlers.input_probe_report  = function() return xinput.probe_report() end
handlers.input_probe_remove  = function() return xinput.probe_remove() end
handlers.input_remove        = function() return xinput.remove_hooks() end
handlers.input_unload        = function() return xinput.unload() end
handlers.input_key           = function(params) return player_ops.input_key(params) end
handlers.input_fire          = function(params) return player_ops.input_fire(params) end
handlers.input_aim           = function(params) return player_ops.input_aim(params) end
handlers.input_clear         = function() return player_ops.input_clear() end
handlers.input_scancodes     = function() return { ok = true, keys = xinput.scancodes() } end
handlers.patchlib_selftest   = function() return patchlib.selftest() end
handlers.patchlib_list       = function() return patchlib.list() end
handlers.patchlib_restore    = function(params) return patchlib.restore(params and params.index) end
handlers.patchlib_read       = function(params) return { ok = true, address = params.address, bytes = patchlib.read(tonumber(params.address), tonumber(params.length) or 16) } end
handlers.observe_start      = function(params) return memscan.observe_start(params) end
handlers.observe_sample     = function() return memscan.observe_sample() end
handlers.observe_stop       = function() return memscan.observe_stop() end
handlers.memscan_regions     = function() local r = memscan.regions() return { ok = r ~= nil, count = r and #r or 0 } end
handlers.po_capabilities = function() return player_ops.capabilities() end

-- ---------------------------------------------------------------- terrain

-- Reading terrain is observation: it looks, it does not change anything, so none of these
-- are in the write table and read-only mode keeps them available.
handlers.terrain_grid = function(params) return terrain.grid(params) end
handlers.terrain_rays = function(params) return terrain.rays(params) end
handlers.terrain_probe = function(params) return terrain.probe(params) end

-- ---------------------------------------------------------------- macros

-- Running a macro presses keys, so it is a player action. Its reads (list, status) are
-- not gated, which is the same split the rest of the bridge uses.
handlers.macro_list = function()
  local out = {}
  local names = macro.names()
  for i = 1, #names do out[i] = macro.describe(names[i]) end
  return { ok = true, count = #out, macros = out, problems = macro.problems() }
end
handlers.macro_start = function(params)
  params = params or {}
  local r = macro.start(params.name, params)
  -- Record the intent on the decision stream, so a replay knows what was asked for rather
  -- than having to infer it from a key stream.
  if r and r.ok and stream and type(stream.action) == "function" then
    stream.action("macro:" .. tostring(params.name), { frames = r.total_frames })
  end
  return r
end
handlers.macro_stop = function(params) return macro.stop((params or {}).reason) end
handlers.macro_status = function() return macro.status() end

-- ---------------------------------------------------------------- decision stream

handlers.stream_start = function(params) return stream.start(params) end
handlers.stream_stop = function(params) return stream.stop((params or {}).reason) end
handlers.stream_status = function() return stream.status() end
handlers.stream_recent = function(params) return stream.recent((params or {}).n) end
handlers.stream_action = function(params)
  params = params or {}
  return { ok = true, recorded = stream.action(params.name or "unspecified", params.detail) }
end

-- ---------------------------------------------------------------- time scale

-- Slowing or speeding the game changes how fast it runs, so it is a player action and sits
-- behind the player switch. The two reads are not gated.
handlers.time_install = function() return xinput.time_install() end
handlers.time_remove = function() return xinput.time_remove() end
handlers.time_set = function(params)
  params = params or {}
  local r = xinput.time_set(params.scale)
  -- Record it on the decision stream: a replay that does not know the game was running at a
  -- different speed cannot make sense of its own timings.
  if r and r.ok and stream and type(stream.action) == "function" then
    stream.action("time_scale", { scale = params.scale })
  end
  return r
end
handlers.time_clear = function() return xinput.time_clear() end
handlers.time_status = function() return xinput.time_status() end
handlers.time_check = function() return xinput.time_check() end
handlers.time_measure_start = function() return xinput.time_measure_start() end
handlers.time_measure_sample = function() return xinput.time_measure_sample() end
handlers.time_measure_finish = function() return xinput.time_measure_finish() end

-- ---------------------------------------------------------------- world seed

-- Reading the seed is observation. The read needs no arguments -- it reads the game's static data
-- directly. `seed_scan` is the fallback for a build that moved the addresses, and needs a value
-- supplied from outside.
handlers.seed_read = function() return seedreader.read() end
handlers.seed_scan = function(params)
  params = params or {}
  return seedreader.scan(params.value, params.max_hits)
end
handlers.seed_addresses = function() return seedreader.addresses() end
handlers.seed_status = function() return seedreader.status() end

-- ---------------------------------------------------------------- perception

-- Reading the surroundings is observation, so none of these are gated.
handlers.percept_surroundings = function(params) return percept.surroundings(params) end
handlers.percept_sweep = function(params) return percept.sweep(params) end
handlers.percept_chunk = function(params) return percept.chunk(params) end
handlers.percept_vocabulary = function() return percept.vocabulary() end
-- Advanced material reading: the engine's own grid, through FFI, no DLL involved.
handlers.material_verify = function(params)
  params = params or {}
  return advmat.verify(params.limit)
end
handlers.material_at = function(params)
  params = params or {}
  return advmat.at(params.x, params.y)
end
handlers.material_grid = function(params) return advmat.grid(params) end
handlers.material_status = function() return advmat.status() end
handlers.percept_enabled = function() return percept.enabled() end
handlers.percept_set_enabled = function(params)
  params = params or {}
  return percept.set_enabled(params.enabled)
end
handlers.percept_set_budget = function(params)
  params = params or {}
  return percept.set_budget(params.raycasts)
end

-- The angle and distance conventions, reported by a tool rather than only written in a document,
-- so an agent can ask instead of guessing. Measured, not asserted: the example numbers come from a
-- chest that was spawned and then located.
handlers.angle_conventions = function()
  return {
    ok = true,
    convention = "degrees(atan2(dy, dx)) over world-space offsets",
    directions = {
      ["0"] = "east (right)",
      ["90"] = "south (DOWN) -- angles increase clockwise on screen",
      ["180"] = "west (left)",
      ["270"] = "north (up)",
    },
    why = "Noita's world has y increasing downward, so a positive angle rotates clockwise on " ..
          "screen. This is the opposite of the mathematical convention, where 90 degrees points " ..
          "up. It is consistent across the tools below.",
    worked_example = {
      note = "a chest spawned and then located, not a constructed example",
      player = { x = -120, y = 96 },
      chest = { x = -208, y = 132 },
      dx = -88.4,
      dy = 36.4,
      reported_angle = 157.59,
      school_convention_would_be = -157.59,
      distance = 95.6,
    },
    tools = {
      noita_get_nearby = "angle is an OUTPUT, world convention",
      noita_raycast = "angle is an INPUT, world convention (0 = right, 90 = down)",
      noita_percept_sweep = "degrees labels, world convention",
      noita_percept_surroundings = "degrees labels, world convention",
      noita_input_click = "x and y are SCREEN PIXELS, not an angle -- the engine derives its aim " ..
                          "vector from the mouse, so this is a different space. Convert with the " ..
                          "camera rectangle from noita_world.",
    },
    distances = {
      unit = "world pixels; Noita cells are 8 pixels",
      noita_get_nearby = "dist is straight-line from the player, with dx/dy available",
      noita_percept_sweep = "the from/to of each band; first_contact is the nearest non-open slice",
    },
    resolution = {
      sweep_default = "16 directions (22.5 degrees apart), 8 slices over 600px = a slice every 75px",
      sweep_minimum = "8 directions",
      cost = "4 raycasts per direction regardless of samples, so raising samples is free and " ..
             "raising directions is what costs",
      finer = "directions up to 64 (5.6 degrees apart); samples up to 32",
    },
    the_sweep_does_not_detect_entities = "It reports terrain only. A chest spawned 200px away " ..
      "left the profile in that direction unchanged. Objects and creatures go through the entity " ..
      "interface -- noita_get_nearby and noita_entity_info -- which is exact, where a raytrace " ..
      "against a thin or fast-moving entity is a coin toss.",
  }
end

-- ---------------------------------------------------------------- framerate

-- Reading the engine's rate is observation, so none of these are gated. The measurement
-- itself only records; it changes nothing.
handlers.framerate_start = function(params) return framerate.start(params) end
handlers.framerate_finish = function() return framerate.finish() end
handlers.framerate_state = function() return framerate.state() end
handlers.po_world        = function(params) return player_ops.world(params) end
handlers.po_biome_at     = function(params) return player_ops.biome_at(params) end
handlers.po_inventory    = function(params) return player_ops.inventory(params) end
handlers.po_switch       = function(params) return player_ops.switch(params) end
handlers.po_pickup       = function(params) return player_ops.pickup(params) end
handlers.po_drop_all     = function(params) return player_ops.drop_all(params) end
handlers.po_drop_one     = function(params) return player_ops.drop_targeted(params) end
handlers.po_launch       = function(params) return player_ops.launch(params) end


-- Generic component inspection, for experiments and future debugging.
handlers.inspect_component = function(params)
  params = params or {}
  if not params.component then return { ok = false, error = "component required" } end
  local res, err = ser.inspect_component(
    params.entity, params.component, params.tag, params.fields or {})
  if not res then return { ok = false, error = err } end
  return res
end

-- Which GUI / settings / input globals did the sandbox actually give us? The
-- control panel needs GuiCreate + ModSetting* + InputIsKeyJustDown, and any of
-- them can be missing depending on the sandbox.
--
-- This also reports whether FFI is reachable, which is NOT the same as the
-- global `ffi` existing: LuaJIT exposes it as a module, so a mod must try
-- `require("ffi")`. The noita-ws-api project loads its DLL that way
-- (`ffi or _G.ffi or require("ffi")`), so checking only the global would report
-- a false negative.
handlers.probe_api = function(params)
  params = params or {}
  local names = params.names or {
    "GuiCreate", "GuiStartFrame", "GuiDestroy", "GuiButton", "GuiText", "GuiImage",
    "GuiSlider", "GuiIdPush", "GuiIdPop", "GuiOptionsAdd", "GuiOptionsAddForNextWidget",
    "GuiGetScreenDimensions", "GuiGetPreviousWidgetInfo", "GuiLayoutBeginVertical",
    "GuiLayoutBeginHorizontal", "GuiLayoutEnd", "GuiLayoutAddVerticalSpacing",
    "GuiBeginScrollContainer", "GuiEndScrollContainer", "GuiTooltip", "GuiColorSetForNextWidget",
    "ModSettingGet", "ModSettingSet", "ModSettingGetNextValue", "ModSettingSetNextValue",
    "ModSettingRemove", "ModSettingGetCount",
    "InputIsKeyJustDown", "InputIsKeyDown", "InputGetMousePosOnScreen",
    "InputIsMouseButtonJustDown",
    "GlobalsGetValue", "GlobalsSetValue",
    "GamePrint", "GamePrintImportant",
    "coroutine", "setfenv", "getfenv", "loadstring", "loadfile", "require", "package",
  }
  local out = {}
  local present, missing = 0, 0
  for _, n in ipairs(names) do
    local v = rawget(_G, n)
    out[n] = type(v)
    if type(v) == "function" or type(v) == "table" then present = present + 1 else missing = missing + 1 end
  end

  -- module-level capabilities: the only reliable way to ask for these
  local function try_require(mod)
    local req = rawget(_G, "require")
    if type(req) ~= "function" then return "no-require" end
    local ok, res = pcall(req, mod)
    if not ok then return "unavailable" end
    return type(res) == "table" and "table" or (type(res) == "function" and "function" or tostring(res))
  end

  return {
    present = present,
    missing = missing,
    api = out,
    modules = {
      ffi = try_require("ffi"),
      jit = try_require("jit"),
      bit = try_require("bit"),
      socket = try_require("socket"),
    },
    ffi_global = type(rawget(_G, "ffi")),
    note = "modules.* is authoritative for FFI: LuaJIT exposes it via require, not as a global",
  }
end

-- Panel state + a way to drive it from outside (used by tests and by the MCP
-- server's panel tools).
handlers.get_panel = function()
  if not panel then return { ok = false, error = "panel module not loaded" } end
  return { panel = panel.state() }
end

handlers.set_panel = function(params)
  params = params or {}
  if not panel then return { ok = false, error = "panel module not loaded" } end

  -- The panel owns the key mapping, so it applies the patch. Writing store.set(k, v)
  -- directly here was a real bug: the UI reads store.get("panel_open") while this wrote
  -- "open", so the setting reported success and changed nothing. Only the names that
  -- happened to match (ai_enabled, read_only) worked, which hid it.
  if type(panel.apply_settings) == "function" then
    local applied, rejected = panel.apply_settings(params)
    return { ok = true, applied = applied, rejected = rejected, panel = panel.state() }
  end

  -- Older builds: keep working, but say the mapping is missing rather than pretend.
  local applied = {}
  for k, v in pairs(params) do
    if k ~= "operations" then
      store.set(k, v)
      applied[k] = v
    end
  end
  if type(params.operations) == "table" then
    for k, v in pairs(params.operations) do
      store.set(k, v)
      applied["op_" .. k] = v
    end
  end
  return { ok = true, applied = applied, panel = panel.state() }
end

-- ---------------------------------------------------------------- dispatch

function rpc.dispatch(method, params)
  -- The in-game panel is the authority on what the AI may do. Reads always pass;
  -- mutations are checked against the switches and refused with a reason that
  -- names the switch, so the AI can ask the human to flip it.
  if panel and type(panel.is_allowed) == "function" then
    local allowed, why = panel.is_allowed(method)
    if not allowed then
      return { ok = false, error = why, blocked_by_panel = true }
    end
  end

  local fn = handlers[method]
  if not fn then
    return { ok = false, error = "unknown method: " .. tostring(method) }
  end
  local ok, res = pcall(fn, params)
  if not ok then
    return { ok = false, error = tostring(res) }
  end
  if type(res) ~= "table" then res = { value = res } end
  if res.ok == nil then res.ok = true end
  return res
end

local function process_request()
  local req_path = base_dir .. "request.json"

  -- Polling runs every frame, so the "nothing waiting" case must be free: only
  -- open the file when it actually exists.
  if not file_exists(req_path) then return end

  local raw = read_file(req_path)
  if not raw or #raw == 0 then return end

  local req = json.decode(raw)
  if type(req) ~= "table" then
    write_file(base_dir .. "response.json", json.encode({
      ok = false, error = "malformed request", id = 0,
    }))
    remove_file(req_path)
    return
  end

  -- idempotence: never answer the same request twice
  if req.id ~= nil and req.id == last_request_id then
    remove_file(req_path)
    return
  end
  last_request_id = req.id

  -- latency: the server stamps the wall clock it wrote the request at; the
  -- delta to now is the transport's one-way cost (file write -> our poll).
  local picked_frame = GameGetFrameNum()
  if type(req.ts) == "number" and req.ts > 0 then
    last_request_write = req.ts
  end
  local served_at = now()

  local res = rpc.dispatch(req.method, req.params)
  res.id = req.id
  res.method = req.method
  res.frame = picked_frame
  res.served_at = served_at
  res.seq = (res.seq or 0) + 1
  if last_request_write then
    res.handled_ms = math.max(0, served_at * 1000 - last_request_write)
    latency_samples[#latency_samples + 1] = res.handled_ms
    if #latency_samples > MAX_LATENCY_SAMPLES then table.remove(latency_samples, 1) end
  end
  write_file(base_dir .. "response.json", json.encode(res))
  remove_file(req_path)
  handled = handled + 1

  -- how many frames passed between the request appearing and us seeing it: the
  -- file-polling half of the latency, measured rather than assumed.
  if last_poll_frame then
    res.poll_gap_frames = picked_frame - last_poll_frame
  end
  last_poll_frame = picked_frame
end

-- Latency report for the status method / panel.
local function latency_report()
  if #latency_samples == 0 then return { samples = 0 } end
  local sum, mn, mx = 0, math.huge, 0
  for _, v in ipairs(latency_samples) do
    sum = sum + v
    if v < mn then mn = v end
    if v > mx then mx = v end
  end
  return {
    samples = #latency_samples,
    handled_ms_last = latency_samples[#latency_samples],
    handled_ms_avg = sum / #latency_samples,
    handled_ms_min = mn,
    handled_ms_max = mx,
  }
end

function rpc.latency()
  return latency_report()
end

-- ---------------------------------------------------------------- socket layer
--
-- An optional second transport. The file bridge stays authoritative for
-- bootstrap and for clients that cannot open a socket; the socket exists to
-- remove the per-frame polling floor and to let the game PUSH events instead of
-- being polled. Both share the same dispatch, so behaviour cannot diverge.

-- Body in, body out: the MCP client POSTs the same {method, params} payload the
-- file bridge accepts, and gets the same response shape back.
local function socket_body_handler(body)
  local req = json.decode(body)
  if type(req) ~= "table" then
    return json.encode({ ok = false, error = "malformed JSON body" })
  end

  -- batch support: {"calls":[{method,params},...]} answers all in one round trip
  if type(req.calls) == "table" then
    local out = { ok = true, results = {} }
    for i = 1, #req.calls do
      local c = req.calls[i] or {}
      local r = rpc.dispatch(c.method, c.params)
      r.method = c.method
      out.results[i] = r
    end
    out.frame = GameGetFrameNum()
    handled = handled + #req.calls
    return json.encode(out)
  end

  if type(req.method) ~= "string" then
    return json.encode({ ok = false, error = "method required" })
  end
  local res = rpc.dispatch(req.method, req.params)
  res.method = req.method
  res.frame = GameGetFrameNum()
  res.id = req.id
  handled = handled + 1
  return json.encode(res)
end

function rpc.start_socket(want_port)
  if not (sock and type(sock.start) == "function") then
    return false, "sock module not loaded"
  end
  if not sock.available() then
    return false, "FFI/ws2_32 unavailable"
  end
  if sock.has_handler() then
    local st = sock.stats()
    return true, st.port, "already-listening"
  end
  sock.set_handler(socket_body_handler)
  local ok, port, addr = sock.start(want_port or 0)
  if not ok then
    log.append("socket start failed: " .. tostring(port))
    return false, port
  end
  log.info("socket listening on 127.0.0.1:%s (%s)", tostring(port), tostring(addr))
  -- publish the port so the MCP server can find it without configuration
  if base_dir then
    write_file(base_dir .. "port.json", json.encode({
      schema = 1,
      port = port,
      host = "127.0.0.1",
      frame = GameGetFrameNum(),
    }))
  end
  return true, port
end

function rpc.socket_stats()
  if not (sock and type(sock.stats) == "function") then return { available = false } end
  local st = sock.stats()
  st.ffi_available = (type(sock.available) == "function") and sock.available() or false
  st.enabled_by_setting = setting_bool("use_socket", true)
  if type(sock.guard_report) == "function" then
    st.guard = sock.guard_report()
  end
  return st
end

-- Stops the listener and forgets the handler, so a later start_socket() can set
-- it up again cleanly. Used by the panel's "switch to FILE bridge" button.
function rpc.stop_socket()
  if sock and type(sock.stop) == "function" then
    pcall(sock.stop)
    return true
  end
  return false
end

-- Manual escape hatch: turn the socket on or off at runtime, so it can be
-- exercised in a controlled way without editing settings and restarting.
handlers.socket_control = function(params)
  params = params or {}
  if params.action == "start" then
    local ok, port, addr = rpc.start_socket(params.port or 0)
    return {
      ok = ok, port = port, address = addr,
      diag = (sock and type(sock.diag) == "function") and sock.diag() or nil,
      stats = rpc.socket_stats(),
    }
  elseif params.action == "stop" then
    if sock and type(sock.stop) == "function" then sock.stop() end
    return { ok = true, stopped = true, stats = rpc.socket_stats() }
  elseif params.action == "status" then
    return { ok = true, stats = rpc.socket_stats() }
  elseif params.action == "enable_setting" then
    store.set("use_socket", params.value and true or false)
    return { ok = true, use_socket = setting_bool("use_socket", true) }
  end
  return { ok = false, error = "action must be start | stop | status | enable_setting" }
end

-- Pre-update driver for control experiments.
--
-- OnWorldPreUpdate runs BEFORE the engine reads the player's input for the
-- frame, so this is the phase where synthetic input can actually reach the game.
-- OnWorldPostUpdate is too late: the engine has already consumed (and then
-- rewritten) the fields by the time it runs.
function rpc.pre_update()
  if not ready or not base_dir then return end
  pcall(exp.tick, "pre")
  pcall(lever.tick, "pre")
  -- Advance a running memory scan a little each frame. Bounded inside memscan so
  -- this can never stretch a frame; it is a no-op when no scan is running.
  pcall(memscan.tick)
  -- Feed the input extension's watchdog and expire its forge TTL. Both jobs used
  -- to depend on hooking SDL_PumpEvents, which is the suspected cause of an
  -- earlier machine-wide freeze; doing them here removes that hook entirely. The
  -- DLL removes its own hooks if this call ever stops arriving.
  pcall(xinput.tick)
  -- Push the repeat key events that make a forged key count as HELD. Runs here,
  -- outside SDL, because pushing an event while SDL holds its queue lock would
  -- deadlock.
  pcall(xinput.hold_tick)
  -- Mouse holds use the same mechanism; firing the wand is a mouse button, not a
  -- key, so this is the path that makes the player actually shoot.
  pcall(xinput.mouse_tick)
  -- Walk the running input macro. Driven from here for the same reason as the holds:
  -- events are pushed outside SDL, never from inside a hook.
  if macro and type(macro.tick) == "function" then pcall(macro.tick) end
  -- Publish a decision-stream observation if one is due. Does nothing when off.
  if stream and type(stream.tick) == "function" then pcall(stream.tick) end
  -- Feed the frame-rate measurement, if one is running. It samples from here rather than
  -- from a loop because Lua runs on the main thread: a loop waiting for the frame counter
  -- to advance would stop the engine from advancing it.
  if framerate and type(framerate.sample) == "function" then pcall(framerate.sample) end
  -- The time measurement works the same way and for the same reason.
  if xinput and type(xinput.time_measure_sample) == "function" then
    pcall(xinput.time_measure_sample)
  end
  -- service the socket from the pre-update phase so a request that arrives while
  -- the game is idle is answered before the engine's own update for that frame
  pcall(sock.poll)
end

-- The published snapshot is deliberately just the player: it is written ~6x a
-- second, and walking the inventory, every wand and the entity radius on every
-- tick is wasted work. Tools that need the full picture call get_state.
local function publish_state()
  local state = ser.player_state()
  write_file(base_dir .. "state.json", json.encode({
    schema = 1,
    ts = now(),
    frame = GameGetFrameNum(),
    state = state,
  }))
end

-- ---------------------------------------------------------------- lifecycle

function rpc.set_player(entity)
  player_entity = entity
end

function rpc.is_ready()
  return ready and base_dir ~= nil
end

function rpc.init()
  base_dir = nil
  ready = false

  if not io_lib() then
    log.append("bridge disabled: io library unavailable " ..
      "(mod.xml needs request_no_api_restrictions=\"1\")")
    log.flush()
    return false
  end

  for _, dir in ipairs(CANDIDATES) do
    local ok = write_file(dir .. "bridge_probe.tmp", "ok")
    if ok then
      base_dir = dir
      break
    end
  end

  if not base_dir then
    log.append("bridge disabled: no writable directory found")
    log.flush()
    return false
  end

  log.info("bridge base dir: %s", base_dir)
  ready = true

  -- Arm the control panel before anything can be refused: this re-applies the
  -- session-scoped switches (master / read_only) so a previous session that
  -- ended with the AI paused cannot start locked out.
  if panel and type(panel.init) == "function" then
    pcall(panel.init)
  end

  -- Socket transport: started by default.
  --
  -- It is a real socket with real non-blocking bounds (measured in-game: LuaJIT
  -- FFI is available, ws2_32 loads, and non-blocking is set via WSAEventSelect
  -- because ioctlsocket(FIONBIO) always fails in this process). The file bridge
  -- keeps running alongside it and stays the fallback for any client that cannot
  -- open a socket.
  --
  -- A watchdog shuts the socket down if any single call exceeds its time budget,
  -- so a socket problem degrades to the file bridge rather than stalling the
  -- game. Disable from the panel, over MCP (noita_socket), or by setting
  -- noita_agent.use_socket to false.
  if setting_bool("use_socket", true) then
    local sock_ok, sock_port, sock_addr = rpc.start_socket(0)
    if sock_ok then
      log.info("socket transport ready on port %s (%s)", tostring(sock_port), tostring(sock_addr))
    else
      log.append("socket transport unavailable, using the file bridge: " .. tostring(sock_port))
    end
  else
    log.append("socket transport disabled (noita_agent.use_socket=false); using the file bridge")
  end

  -- stale files from an earlier session must not be replayed
  remove_file(base_dir .. "request.json")
  remove_file(base_dir .. "response.json")
  remove_file(base_dir .. "ready.json")

  write_file(base_dir .. "status.json", json.encode(rpc.dispatch("status")))
  write_file(base_dir .. "ready.json", json.encode({
    ready = true,
    frame = GameGetFrameNum(),
    base_dir = base_dir,
    lua = _VERSION,
  }))
  log.flush()
  return true
end

function rpc.update()
  if not ready or not base_dir then return end
  if not player_entity then
    player_entity = ser.player()
  end
  frame_counter = frame_counter + 1

  -- post-phase control experiments (observation / aim vectors)
  pcall(exp.tick, "post")
  pcall(lever.tick, "post")

  -- Latency budget: read from the panel so an operator can trade latency against
  -- file churn without a rebuild. Defaults poll every frame and publish at 30 Hz.
  local poll_every = setting("poll_interval", DEFAULT_POLL_INTERVAL)
  local state_every = setting("state_interval", DEFAULT_STATE_INTERVAL)

  if frame_counter % poll_every == 0 then
    local ok, err = pcall(process_request)
    if not ok then log.append("request error: " .. tostring(err)) end
  end

  if frame_counter % state_every == 0 then
    local ok, err = pcall(publish_state)
    if not ok then log.append("state error: " .. tostring(err)) end
  end

  if frame_counter % STATUS_INTERVAL == 0 then
    local st = rpc.dispatch("status")
    st.latency = latency_report()
    write_file(base_dir .. "status.json", json.encode(st))
  end

  -- Draw the control panel. It is an overlay, so the update phase does not
  -- matter; post-update simply keeps it off the pre-update control path.
  if panel and type(panel.update) == "function" then
    -- The extension's state is gathered here rather than inside the panel so the UI
    -- stays a pure view and never calls into the DLL-loading path itself. `last_load`
    -- is what turns "not loaded" into "these paths were tried, and this is why each
    -- failed" -- the reason the panel previously could not explain a load failure.
    local ext, last_load = nil, nil
    if xinput then
      local ok_s, s = pcall(xinput.status)
      if ok_s then ext = s end
      if type(xinput.last_load) == "function" then
        local ok_l, l = pcall(xinput.last_load)
        if ok_l then last_load = l end
      end
    end

    pcall(panel.update, {
      base_dir = base_dir,
      frame = GameGetFrameNum(),
      handled = handled,
      has_player = player_entity ~= nil,
      socket = (type(rpc.socket_stats) == "function") and rpc.socket_stats() or nil,
      latency = latency_report(),
      extension = ext,
      last_load = last_load,
    })
  end

  if frame_counter % LOG_INTERVAL == 0 then
    log.flush()
  end
end

return rpc

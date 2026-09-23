-- Optional input-forging extension.
--
-- ARCHITECTURE
--
-- The base mod is pure Lua and needs nothing installed. It can drive everything
-- that acts on the state the player's input FEEDS -- motion, gear, inventory,
-- projectiles -- but it cannot forge the input itself, because the engine copies
-- the OS/SDL input state into its control fields every frame. A Lua-side binary
-- patch does not help: defeating the copy would only leave a value the engine
-- never consults.
--
-- Input forging therefore needs the input SOURCE intercepted, which means code
-- inside the process. The `extensions/input-hook` package provides that: a 32-bit
-- DLL that hooks SDL_GetKeyboardState and SDL_GetMouseState and returns forged
-- state while a forge is active, with a frame TTL so a forge can never stick.
--
-- HOW IT GETS INTO THE PROCESS
--
-- There are two ways, and the simpler one is preferred:
--
--   1. `load()`  -- this module calls LoadLibraryA through its own FFI handle.
--      The game already gives the mod FFI, so no external injector is needed at
--      all: point NOITA_XINPUT_DLL at the built DLL (or place it in the
--      extension's build folder) and call noita_input_load. This is runtime-only;
--      nothing is written to any game file.
--
--   2. An external injector, for when a player wants it loaded before the mod
--      runs. `extensions/input-hook/injector.exe` does this; it is more fragile
--      (remote-thread shellcode) and is NOT required if route 1 works.
--
-- This module never loads anything by itself. Loading is an explicit act, so
-- installing the mod alone can never surprise a player by taking over their input.

xinput = xinput or {}

local ffi_ok, ffi = pcall(require, "ffi")

-- Keep in sync with extensions/input-hook/xinput_hook.h
local DLL_NAME = "xinput_hook.dll"
local MAGIC = 0x58494E50          -- 'XINP'

local api = nil                   -- resolved exports, or false once we know it is absent
local resolve_error = nil

-- SDL scancodes, declared up here because several functions below resolve a key
-- NAME to a scancode and a `local` declared further down is simply not visible to
-- them. That mistake made poll_forge_key fail with "attempt to index global
-- SCANCODES (a nil value)" -- which looked like the forge being rejected when it
-- had not run at all.
local SCANCODES = {
  W = 26, A = 4, S = 22, D = 7, SPACE = 44, SHIFT = 225, CTRL = 224,
  E = 8, Q = 20, R = 21, F = 9,
  UP = 82, DOWN = 81, LEFT = 80, RIGHT = 79,
  NUM1 = 30, NUM2 = 31, NUM3 = 32, NUM4 = 33, NUM5 = 34,
}

local function kernel32()
  if not ffi_ok then return nil end
  local ok, k = pcall(ffi.load, "kernel32")
  if not ok then ok, k = pcall(ffi.load, "kernel32.dll") end
  if not ok then return nil end
  pcall(ffi.cdef, [[
    void* GetModuleHandleA(const char* lpModuleName);
    void* GetProcAddress(void* hModule, const char* lpProcName);
    void* LoadLibraryA(const char* lpLibFileName);
    uint32_t GetModuleFileNameA(void* hModule, char* lpFilename, uint32_t nSize);
    uint32_t GetLastError(void);
  ]])
  return k
end

-- The game's own directory, asked of the process itself.
--
-- Environment variables are unreliable here (the game does not necessarily inherit
-- NOITA_DIR), and LoadLibraryA resolves relative paths against the process working
-- directory, which is not guaranteed to be the game root. GetModuleFileNameA(NULL)
-- returns the path of the running executable, which is exactly what is needed.
local function game_dir(k)
  if not k then return nil end
  local buf = ffi.new("char[?]", 1024)
  local n = k.GetModuleFileNameA(nil, buf, 1024)
  if n == 0 then return nil end
  local full = ffi.string(buf, n)
  local dir = full:match("^(.*)[\\/][^\\/]*$")
  return dir
end

-- Resolves the extension's exports from the ALREADY LOADED module. It is never
-- loaded from here: an injected DLL appears in the process module list, and
-- ffi.load would not find it by name reliably, so GetModuleHandleA is the honest
-- way to ask "is it in this process?".
local function resolve()
  if api ~= nil then return api end

  if not ffi_ok then
    resolve_error = "ffi unavailable"
    api = false
    return api
  end

  local k = kernel32()
  if not k then
    resolve_error = "kernel32 unavailable"
    api = false
    return api
  end

  local h = k.GetModuleHandleA(DLL_NAME)
  if h == nil then
    -- not loaded yet; not an error, just absence
    resolve_error = "not loaded (module " .. DLL_NAME .. " is not in this process)"
    api = false
    return api
  end

  pcall(ffi.cdef, [[
    int  xh_ping(void);
    int  xh_install_hooks(void);
    int  xh_install_keyboard_only(void);
    int  xh_remove_hooks(void);
    int  xh_hooks_installed(void);
    void xh_heartbeat(void);
    int  xh_status(int which);
    int  xh_probe_install(void);
    int  xh_probe_remove(void);
    int  xh_probe_count(int which);
    int  xh_probe_found(int which);
    int  xh_probe_report(void);
    int  xh_install_peepevents(void);
    int  xh_remove_peepevents(void);
    int  xh_peep_calls(void);
    int  xh_peep_events(void);
    int  xh_peep_forged(void);
    int  xh_peep_real_keys(void);
    int  xh_peep_gets(void);
    int  xh_push_key(int scancode, int state);
    int  xh_push_mouse(int button, int down, int x, int y);
    int  xh_push_ok(void);
    int  xh_push_fail(void);
    int  xh_push_last(void);
    int  xh_install_pollevent(void);
    int  xh_remove_pollevent(void);
    int  xh_poll_installed(void);
    int  xh_event_calls(void);
    int  xh_event_forged(void);
    int  xh_event_real_seen(void);
    int  xh_event_forge_key(int scancode, int frames);
    void xh_event_forge_clear(void);
    void xh_set_key_forge(int scancode, int down);
    void xh_clear_forges(void);
    void xh_set_mouse_forge(int x, int y, int buttons);
    int  xh_forge_frames_left(void);
    void xh_set_ttl(int frames);
  ]])

  local function sym(name)
    return k.GetProcAddress(h, name)
  end

  local ping = sym("xh_ping")
  if ping == nil then
    resolve_error = DLL_NAME .. " is loaded but does not export xh_ping"
    api = false
    return api
  end

  api = {
    handle = h,
    ping = ffi.cast("int (*)(void)", ping),
    install = ffi.cast("int (*)(void)", sym("xh_install_hooks")),
    install_kb = ffi.cast("int (*)(void)", sym("xh_install_keyboard_only")),
    remove = ffi.cast("int (*)(void)", sym("xh_remove_hooks")),
    installed = ffi.cast("int (*)(void)", sym("xh_hooks_installed")),
    heartbeat = ffi.cast("void (*)(void)", sym("xh_heartbeat")),
    status = ffi.cast("int (*)(int)", sym("xh_status")),
    probe_install = ffi.cast("int (*)(void)", sym("xh_probe_install")),
    probe_remove = ffi.cast("int (*)(void)", sym("xh_probe_remove")),
    probe_count = ffi.cast("int (*)(int)", sym("xh_probe_count")),
    probe_found = ffi.cast("int (*)(int)", sym("xh_probe_found")),
    probe_report = ffi.cast("int (*)(void)", sym("xh_probe_report")),
    poll_install = ffi.cast("int (*)(void)", sym("xh_install_pollevent")),
    peep_install = ffi.cast("int (*)(void)", sym("xh_install_peepevents")),
    peep_remove = ffi.cast("int (*)(void)", sym("xh_remove_peepevents")),
    peep_calls = ffi.cast("int (*)(void)", sym("xh_peep_calls")),
    peep_events = ffi.cast("int (*)(void)", sym("xh_peep_events")),
    peep_forged = ffi.cast("int (*)(void)", sym("xh_peep_forged")),
    peep_real_keys = ffi.cast("int (*)(void)", sym("xh_peep_real_keys")),
    peep_gets = ffi.cast("int (*)(void)", sym("xh_peep_gets")),
    push_key = ffi.cast("int (*)(int,int)", sym("xh_push_key")),
    push_mouse = ffi.cast("int (*)(int,int,int,int)", sym("xh_push_mouse")),
    push_ok = ffi.cast("int (*)(void)", sym("xh_push_ok")),
    push_fail = ffi.cast("int (*)(void)", sym("xh_push_fail")),
    push_last = ffi.cast("int (*)(void)", sym("xh_push_last")),
    poll_remove = ffi.cast("int (*)(void)", sym("xh_remove_pollevent")),
    poll_installed = ffi.cast("int (*)(void)", sym("xh_poll_installed")),
    ev_calls = ffi.cast("int (*)(void)", sym("xh_event_calls")),
    ev_forged = ffi.cast("int (*)(void)", sym("xh_event_forged")),
    ev_real = ffi.cast("int (*)(void)", sym("xh_event_real_seen")),
    ev_forge_key = ffi.cast("int (*)(int,int)", sym("xh_event_forge_key")),
    ev_forge_clear = ffi.cast("void (*)(void)", sym("xh_event_forge_clear")),
    set_key = ffi.cast("void (*)(int,int)", sym("xh_set_key_forge")),
    clear = ffi.cast("void (*)(void)", sym("xh_clear_forges")),
    set_mouse = ffi.cast("void (*)(int,int,int)", sym("xh_set_mouse_forge")),
    frames_left = ffi.cast("int (*)(void)", sym("xh_forge_frames_left")),
    set_ttl = ffi.cast("void (*)(int)", sym("xh_set_ttl")),
    keys = {},
    mouse = nil,
    ttl = 0,
  }
  return api
end

-- ---------------------------------------------------------------- tick

-- Called once per frame from the bridge while any forge is armed.
--
-- Two jobs, both of which used to depend on hooking SDL_PumpEvents:
--
--   * prove to the DLL's watchdog that Lua is still driving it. If this stops --
--     because Lua wedged, the frame loop stalled, or nobody is watching -- the
--     DLL removes its hooks by itself after a few seconds.
--   * expire the forge. Doing it here removes the need to hook the pump at all,
--     and the pump was the suspected cause of the freeze.
function xinput.tick()
  local a = api
  if not a then return end

  if a.heartbeat then pcall(a.heartbeat) end

  if a.ttl and a.ttl > 0 then
    a.ttl = a.ttl - 1
    if a.ttl <= 0 then
      pcall(a.clear)
      a.keys = {}
      a.mouse = nil
      a.ttl = 0
    end
  end
end

-- ---------------------------------------------------------------- hooks

-- Whether the hooks are actually installed, which is NOT the same as the DLL being
-- present. The DLL deliberately loads inert: being in the process must never be
-- able to change the game's behaviour, so installing the hooks is a separate,
-- explicit act. This distinction exists because an earlier build hooked
-- SDL_PumpEvents on load and froze the machine.
function xinput.hooks_installed()
  local a = resolve()
  if not a or not a.installed then return false end
  local ok, v = pcall(a.installed)
  return ok and v == 1
end

-- Installs the hooks. All-or-nothing inside the DLL: if any of them fails, none
-- are left installed, because a partial set would mean a forge that never expires.
--
-- Defaults to the KEYBOARD + MOUSE set, which deliberately excludes
-- SDL_PumpEvents. Pass full=true to include it, but understand why it is not the
-- default: the pump runs every frame, can run on several threads, and may
-- re-enter SDL's input path, so hooking it risks unbounded recursion -- which
-- presents as the machine hanging. It is also unnecessary, because the forge TTL
-- is expired from Lua.
function xinput.install_hooks(params)
  params = params or {}
  local a = resolve()
  if not a then
    return { ok = false, error = "extension DLL is not loaded (call noita_input_load first)",
             status = xinput.status() }
  end

  local want_full = params.full == true
  local fn = want_full and a.install or a.install_kb
  if not fn then
    return { ok = false, error = "this DLL build lacks the needed install export; " ..
             "rebuild it with extensions/input-hook/build.ps1" }
  end

  local ok, v = pcall(fn)
  if not ok then return { ok = false, error = "install raised: " .. tostring(v) } end
  return {
    ok = (v == 1),
    installed = (v == 1),
    set = want_full and "keyboard+mouse+pump" or "keyboard+mouse (no pump hook)",
    heartbeat = "Lua must call xinput.tick every frame; the DLL removes its hooks " ..
                "if the heartbeat stops",
    error = (v ~= 1) and ("the DLL refused to install: a hook failed to analyse or " ..
            "install, and all of them were rolled back") or nil,
  }
end

-- Removes the hooks and restores the original bytes. Safe to call when nothing is
-- installed, and the way to back out without restarting the game.
function xinput.remove_hooks()
  local a = resolve()
  if not a or not a.remove then
    return { ok = true, note = "nothing to remove (DLL not loaded or older build)" }
  end
  local ok, v = pcall(a.remove)
  return { ok = ok and v == 1, error = (not ok) and tostring(v) or nil }
end

-- ---------------------------------------------------------------- loading

-- Loads the extension using the mod's own FFI, which avoids needing an external
-- injector entirely: the game already loaded kernel32 into this process.
--
-- `path` should be an ABSOLUTE Windows path to the built DLL. It is taken from
-- the argument, then NOITA_XINPUT_DLL, then the extension's build folder.
function xinput.load(params)
  params = params or {}
  if not ffi_ok then return { ok = false, error = "ffi unavailable" } end

  -- already in the process? then this is a no-op
  if xinput.available() then
    return { ok = true, already_loaded = true, status = xinput.status() }
  end

  local candidates = {}
  if params.path then candidates[#candidates + 1] = params.path end
  local env = os and os.getenv and os.getenv("NOITA_XINPUT_DLL")
  if env and env ~= "" then candidates[#candidates + 1] = env end

  -- An absolute path is required in practice: LoadLibraryA resolves relative paths
  -- against the process working directory, which is not reliably the game root.
  -- The game's own folder is obtained from the running executable.
  local k0 = kernel32()
  local dir = game_dir(k0)
  if dir then
    candidates[#candidates + 1] = dir .. "\\mods\\noita_agent\\extensions\\" .. DLL_NAME
    candidates[#candidates + 1] = dir .. "\\mods\\noita_agent\\" .. DLL_NAME
  end
  -- environment fallbacks, in case the exe path could not be read
  local noita_dir = (os and os.getenv and (os.getenv("NOITA_DIR") or os.getenv("NOITA_PATH"))) or nil
  if noita_dir and noita_dir ~= "" then
    local sep = noita_dir:sub(-1) == "\\" and "" or "\\"
    candidates[#candidates + 1] = noita_dir .. sep .. "mods\\noita_agent\\extensions\\" .. DLL_NAME
    candidates[#candidates + 1] = noita_dir .. sep .. "mods\\noita_agent\\" .. DLL_NAME
  end
  candidates[#candidates + 1] = "mods\\noita_agent\\extensions\\" .. DLL_NAME

  local k = kernel32()
  if not k then return { ok = false, error = "kernel32 unavailable" } end

  local attempts = {}
  for _, p in ipairs(candidates) do
    local ok, h = pcall(k.LoadLibraryA, p)
    local handle_num = (ok and h ~= nil)
      and (tonumber(ffi.cast("uintptr_t", h)) or 0) or 0
    attempts[#attempts + 1] = {
      path = p,
      call_ok = ok,
      handle = (handle_num ~= 0) and string.format("0x%X", handle_num) or nil,
    }
    -- Loading and forging-capability are DIFFERENT things: the DLL deliberately
    -- arrives inert, so a successful handle means "loaded", not "ready to forge".
    -- Conflating them made this function report failure on a load that worked.
    if ok and handle_num ~= 0 then
      api = nil
      resolve_error = nil
      local st = xinput.status()
      attempts[#attempts].loaded = st.loaded
      return {
        ok = true,
        path = p,
        handle = attempts[#attempts].handle,
        loaded = st.loaded,
        hooks_installed = st.hooks_installed,
        status = st,
        next_step = st.hooks_installed
          and "hooks are installed; input forging is ready"
          or "the DLL is loaded but inert; call noita_input_install to install the hooks",
      }
    end
  end

  return {
    ok = false,
    error = "the DLL could not be loaded from any candidate path",
    attempts = attempts,
    hint = "build it first: pwsh -File extensions/input-hook/build.ps1, then pass " ..
           "the absolute path of build/xinput_hook.dll",
  }
end

-- Unloading is deliberately NOT offered: a hook that is removed while the game
-- holds a pointer into it would crash. The honest answer is "restart the game".
function xinput.unload()
  return {
    ok = false,
    error = "unloading is not supported: the hooks point into this DLL, so removing " ..
            "it while the game runs would crash. Restart Noita to unload it.",
  }
end

-- How many times the engine has actually called each hooked function.
--
-- This is the difference between "the hook is installed" and "the hook is used".
-- If the game never calls SDL_GetKeyboardState, the hook is installed and useless,
-- and that has to be visible rather than guessed at.
function xinput.call_counts()
  local a = resolve()
  if not a or not a.status then return { available = false } end
  local function g(i)
    local ok, v = pcall(a.status, i)
    return ok and v or nil
  end
  return {
    keyboard_state_calls = g(0),
    mouse_state_calls = g(1),
    note = "counts taken since the DLL loaded; if these do not grow, the engine is " ..
           "reading input somewhere else and hooking that function cannot help",
  }
end

-- ---------------------------------------------------------------- probes

-- Installs COUNTING-ONLY hooks on every plausible input function.
--
-- These do not change behaviour: each one increments a counter and jumps straight
-- back into the original. No argument is touched, no return value is replaced.
-- So this is safe to run even though most of the candidates will be wrong -- the
-- only effect is a set of counters that reveals which function the engine
-- actually reads input through.
--
-- This was written after discovering that the real forging hooks were installed on
-- SDL_GetKeyboardState and SDL_GetMouseState and the engine never called either
-- (the counters stayed at 0 even while the player really walked).
function xinput.probe_install()
  local a = resolve()
  if not a or not a.probe_install then
    return { ok = false, error = "DLL not loaded, or an older build without probes" }
  end
  local ok, v = pcall(a.probe_install)
  if not ok then return { ok = false, error = tostring(v) } end
  return {
    ok = true,
    hooked = v,
    note = "counting-only; nothing about the game's behaviour is changed. " ..
           "Run noita_input_probe_report after some frames.",
  }
end

function xinput.probe_remove()
  local a = resolve()
  if not a or not a.probe_remove then return { ok = true, note = "nothing to remove" } end
  local ok, v = pcall(a.probe_remove)
  return { ok = ok and v == 1 }
end

-- Mirrors the candidate list in xinput_hook.c so a report is readable by name.
local PROBE_NAMES = {
  [0] = 'SDL2.dll!SDL_PollEvent',
  [1] = 'SDL2.dll!SDL_PeepEvents',
  [2] = 'SDL2.dll!SDL_WaitEvent',
  [3] = 'SDL2.dll!SDL_PumpEvents',
  [4] = 'SDL2.dll!SDL_GetGlobalMouseState',
  [5] = 'user32.dll!GetKeyboardState',
  [6] = 'user32.dll!GetAsyncKeyState',
  [7] = 'user32.dll!GetKeyState',
  [8] = 'user32.dll!GetCursorPos',
  [9] = 'user32.dll!PeekMessageA',
  [10] = 'user32.dll!GetMessageA',
  [11] = 'user32.dll!SetCursorPos',
}

function xinput.probe_names() return PROBE_NAMES end

function xinput.probe_report()
  local a = resolve()
  if not a or not a.probe_count then
    return { ok = false, error = "DLL not loaded, or an older build without probes" }
  end

  local out = { ok = true, probes = {} }
  -- the table is fixed in the DLL; 16 is its capacity
  for i = 0, 15 do
    local okf, found = pcall(a.probe_found, i)
    if not okf or found ~= 1 then
      -- not present in this process; still record the slot if it has a name
      local okc, c = pcall(a.probe_count, i)
      if okc and c and c >= 0 then
        out.probes[#out.probes + 1] = { index = i, name = PROBE_NAMES[i], found = false, count = c }
      end
    else
      local okc, c = pcall(a.probe_count, i)
      out.probes[#out.probes + 1] = {
        index = i, found = true, count = okc and c or nil,
        called = (okc and c and c > 0) or false,
      }
    end
  end

  -- write the DLL's own formatted table too, for a readable second opinion
  if a.probe_report then pcall(a.probe_report) end

  local called = {}
  for _, p in ipairs(out.probes) do
    if p.found and p.called then called[#called + 1] = p end
  end
  out.any_called = #called > 0
  out.called_probes = called
  out.note = "a probe with found=true and count=0 is a function the engine never " ..
             "calls; a non-zero count identifies the real input path"
  return out
end

-- True only when forging can actually work: the DLL is loaded AND an input hook is
-- installed. "The DLL is present" is deliberately NOT enough -- it loads inert, so
-- treating presence as capability would make every forge silently do nothing while
-- reporting success.
--
-- Either hook counts: the PollEvent hook is what the current design arms, and
-- xh_hooks_installed covers the older full set. Requiring only the legacy one made
-- a working install report mode "base", which is the same class of mistake as
-- reporting success without capability -- just in the other direction.
function xinput.available()
  local a = resolve()
  if not a then return false end
  local ok, v = pcall(a.ping)
  if not ok then
    resolve_error = "xh_ping raised: " .. tostring(v)
    return false
  end
  if v ~= MAGIC then return false end
  if xinput.hooks_installed() then return true end
  if a.poll_installed then
    local ok2, v2 = pcall(a.poll_installed)
    if ok2 and v2 == 1 then return true end
  end
  return false
end

-- ------------------------------------------------------- synthesised events

-- Puts a REAL SDL event into SDL's own queue, instead of trying to fake a poll.
--
-- Why this approach: with SDL_PollEvent hooked, the real poll returned an event on
-- essentially none of ~500 calls -- the engine drains the queue first, so there was
-- usually nothing to rewrite. Forging therefore only worked when the operator
-- happened to move the mouse. Supplying an event from the hook and returning 1
-- fixed that but FROZE the machine, because the engine's loop only ends when the
-- poll reports nothing.
--
-- SDL_PushEvent avoids both problems: the engine receives the event through its
-- normal path with SDL's own return values intact, and the struct is built and
-- validated by SDL rather than by hand-written offsets.
--
-- LOCKING: this must never be called from inside a hook. The poll hook runs while
-- SDL holds the event-queue lock, so pushing from there would deadlock. The bridge
-- calls it from the per-frame update, which runs outside SDL.
function xinput.push_key(name_or_code, down)
  local a = resolve()
  if not a or not a.push_key then
    return { ok = false, error = "DLL not loaded, or a build without event synthesis" }
  end

  local code = name_or_code
  if type(code) == "string" then
    code = SCANCODES[code:upper()]
    if not code then
      return { ok = false, error = "unknown key name: " .. tostring(name_or_code),
               known = xinput.scancodes() }
    end
  end
  code = tonumber(code)
  if not code then return { ok = false, error = "scancode required" } end

  local ok, rc = pcall(a.push_key, code, down and 1 or 0)
  if not ok then return { ok = false, error = tostring(rc) } end
  return {
    ok = (rc == 1),
    scancode = code,
    down = down and true or false,
    error = (rc ~= 1) and "SDL refused the event (queue full?)" or nil,
  }
end

-- Presses a key for N frames' worth of pushes: one key-down now, and a key-up
-- scheduled by the caller's tick. Kept explicit rather than automatic so the
-- caller can see exactly which events were queued.
function xinput.push_tap(name_or_code, hold_frames)
  local down = xinput.push_key(name_or_code, true)
  if not down.ok then return down end
  return {
    ok = true,
    scancode = down.scancode,
    hold_frames = hold_frames or 6,
    note = "key-down queued; the caller must queue the key-up (xinput.push_key(key,false))",
  }
end

-- A key HOLD, driven by pushing events rather than by intercepting anything.
--
-- A single key-down/key-up pair is a tap: measured Δx was 25px and the engine's
-- own counter moved once. A hold needs the same stream a physical keyboard
-- produces -- repeated key-downs for as long as the key is held -- so this pushes
-- one per frame from the bridge's update, then one key-up at the end.
--
-- The hold state lives here rather than in the DLL because the bridge already runs
-- every frame, and because pushing from inside a hook is what would deadlock.
local hold = nil   -- { scancode, frames_left, total }

-- Starts holding a key for N frames.
function xinput.hold_key(name_or_code, frames)
  local a = resolve()
  if not a or not a.push_key then
    return { ok = false, error = "DLL not loaded, or a build without event synthesis" }
  end

  local code = name_or_code
  if type(code) == "string" then
    code = SCANCODES[code:upper()]
    if not code then
      return { ok = false, error = "unknown key name: " .. tostring(name_or_code) }
    end
  end
  code = tonumber(code)
  if not code then return { ok = false, error = "scancode required" } end

  frames = math.max(2, math.min(tonumber(frames) or 20, 600))

  -- release whatever was held before, so two holds cannot overlap
  if hold then pcall(a.push_key, hold.scancode, 0) end

  local ok, rc = pcall(a.push_key, code, 1)
  if not ok or rc ~= 1 then
    return { ok = false, error = "SDL refused the key-down" }
  end
  hold = { scancode = code, frames_left = frames - 1, total = frames }
  return { ok = true, scancode = code, frames = frames,
           note = "held via repeated event pushes; released automatically" }
end

function xinput.hold_release()
  local a = resolve()
  if hold and a and a.push_key then
    pcall(a.push_key, hold.scancode, 0)
    local sc = hold.scancode
    hold = nil
    return { ok = true, released = sc }
  end
  hold = nil
  return { ok = true, note = "nothing held" }
end

function xinput.hold_status()
  if not hold then return { holding = false } end
  return { holding = true, scancode = hold.scancode, frames_left = hold.frames_left,
           total = hold.total }
end

-- Called every frame by the bridge. Pushes the repeat key-downs that make the
-- engine treat the key as held, and the final key-up when the hold ends.
function xinput.hold_tick()
  local a = api
  if not hold or not a or not a.push_key then return end

  if hold.frames_left <= 0 then
    pcall(a.push_key, hold.scancode, 0)
    hold = nil
    return
  end
  pcall(a.push_key, hold.scancode, 1)
  hold.frames_left = hold.frames_left - 1
end

-- Mouse counterpart of hold_key/hold_tick.
--
-- Noita fires the held wand on the LEFT MOUSE BUTTON, not on a key: SPACE is the
-- fly key, and holding it produced no shot (measured: mButtonFrameFire stayed 0).
-- So firing needs a mouse event, which this pushes the same way -- from the
-- bridge's per-frame update, never from inside SDL, because pushing while SDL
-- holds its queue lock would deadlock.
local mouse_hold = nil

function xinput.hold_mouse(button, frames, x, y)
  local a = resolve()
  if not a or not a.push_mouse then
    return { ok = false, error = "DLL not loaded, or a build without mouse synthesis" }
  end
  button = tonumber(button) or 1               -- SDL_BUTTON_LEFT
  frames = math.max(2, math.min(tonumber(frames) or 20, 600))
  x = tonumber(x) or 0
  y = tonumber(y) or 0

  if mouse_hold then pcall(a.push_mouse, mouse_hold.button, 0, mouse_hold.x, mouse_hold.y) end

  local ok, rc = pcall(a.push_mouse, button, 1, x, y)
  if not ok or rc ~= 1 then return { ok = false, error = "SDL refused the mouse-down" } end
  mouse_hold = { button = button, frames_left = frames - 1, total = frames, x = x, y = y }
  return { ok = true, button = button, frames = frames, x = x, y = y }
end

function xinput.mouse_release()
  local a = resolve()
  if mouse_hold and a and a.push_mouse then
    pcall(a.push_mouse, mouse_hold.button, 0, mouse_hold.x, mouse_hold.y)
    local b = mouse_hold.button
    mouse_hold = nil
    return { ok = true, released = b }
  end
  mouse_hold = nil
  return { ok = true, note = "nothing held" }
end

function xinput.mouse_tick()
  local a = api
  if not mouse_hold or not a or not a.push_mouse then return end
  if mouse_hold.frames_left <= 0 then
    pcall(a.push_mouse, mouse_hold.button, 0, mouse_hold.x, mouse_hold.y)
    mouse_hold = nil
    return
  end
  pcall(a.push_mouse, mouse_hold.button, 1, mouse_hold.x, mouse_hold.y)
  mouse_hold.frames_left = mouse_hold.frames_left - 1
end

function xinput.push_stats()
  local a = resolve()
  if not a or not a.push_ok then return { available = false } end
  local function g(f)
    local ok, v = pcall(f)
    return ok and v or nil
  end
  return {
    available = true,
    queued = g(a.push_ok),
    refused = g(a.push_fail),
    last_result = g(a.push_last),
    holding = hold and { scancode = hold.scancode, frames_left = hold.frames_left } or nil,
    holding_mouse = mouse_hold and { button = mouse_hold.button,
                                     frames_left = mouse_hold.frames_left } or nil,
    note = "queued counts events SDL accepted; the engine acting on them is what " ..
           "noita_get_player shows",
  }
end

-- -------------------------------------------------------------- peep hook

-- Hooks SDL_PeepEvents, which is where the engine actually DRAINS the event queue.
--
-- This supersedes the SDL_PollEvent hook below, and the reason is measured: with
-- SDL_PollEvent hooked, `with_event` stayed 0 across 405 invocations -- the engine
-- had already taken everything, so a forge had no event to rewrite. That is why
-- forging appeared to work only when the operator happened to move the mouse.
--
-- Safety by construction, which the PollEvent experiment lacked:
--   * the return value is NEVER changed, so the caller's event loop terminates
--     exactly as before. (Returning 1 for an empty queue froze the machine once.)
--   * only the CONTENTS of events the engine already received are edited.
--   * only GETs are touched; ADD and PEEK are left alone, so the queue itself is
--     never modified.
--   * only while a forge is armed.
function xinput.peep_install()
  local a = resolve()
  if not a or not a.peep_install then
    return { ok = false, error = "DLL not loaded, or a build without the PeepEvents hook" }
  end
  local ok, v = pcall(a.peep_install)
  if not ok then return { ok = false, error = tostring(v) } end
  return {
    ok = (v == 1), installed = (v == 1),
    error = (v ~= 1) and "SDL_PeepEvents could not be hooked" or nil,
    safety = "return value unchanged; only event contents are edited",
  }
end

function xinput.peep_remove()
  local a = resolve()
  if not a or not a.peep_remove then return { ok = true, note = "nothing to remove" } end
  local ok, v = pcall(a.peep_remove)
  return { ok = ok and v == 1 }
end

-- The counters that decide whether this is the right function.
--
-- `real_keys` is the one that matters: if it grows when the human types, keyboard
-- input genuinely flows through SDL_PeepEvents and forging there will work. If it
-- stays 0, this is the wrong function too and no amount of forging will help.
function xinput.peep_stats()
  local a = resolve()
  if not a or not a.peep_calls then return { available = false } end
  local function g(f)
    local ok, v = pcall(f)
    return ok and v or nil
  end
  return {
    available = true,
    calls = g(a.peep_calls),
    events = g(a.peep_events),
    gets = g(a.peep_gets),
    real_keys = g(a.peep_real_keys),
    forged = g(a.peep_forged),
    note = "real_keys must grow when the human presses a key; then forging here is " ..
           "on the engine's actual input path",
  }
end

-- ---------------------------------------------------------------- event hook

-- Installs the SDL_PollEvent hook -- the CORRECT target, identified by parsing
-- noita.exe's import table rather than by guessing.
--
-- SDL_GetKeyboardState and user32!GetKeyboardState are not imported by the game at
-- all, which is why the earlier hooks on them never counted a single call even
-- while the player was really walking. SDL_PollEvent is the engine's only route
-- for keyboard and mouse input.
--
-- It is also safe to hook, unlike SDL_PumpEvents: it runs on the main thread's
-- frame loop and does not call back into SDL, so there is no recursion risk.
function xinput.poll_install()
  local a = resolve()
  if not a or not a.poll_install then
    return { ok = false, error = "DLL not loaded, or a build without the PollEvent hook" }
  end
  local ok, v = pcall(a.poll_install)
  if not ok then return { ok = false, error = tostring(v) } end
  return {
    ok = (v == 1),
    installed = (v == 1),
    error = (v ~= 1) and "the DLL refused: SDL_PollEvent could not be hooked" or nil,
  }
end

function xinput.poll_remove()
  local a = resolve()
  if not a or not a.poll_remove then return { ok = true, note = "nothing to remove" } end
  local ok, v = pcall(a.poll_remove)
  return { ok = ok and v == 1 }
end

-- Whether the engine actually polls, and whether our events are going out.
--
-- `poll_calls` is the number that matters: hooking a function the engine never
-- calls wasted an entire cycle, so it is now always measured before anything is
-- concluded.
function xinput.poll_stats()
  local a = resolve()
  if not a or not a.ev_calls then return { available = false } end
  local function g(f)
    local ok, v = pcall(f)
    return ok and v or nil
  end
  return {
    available = true,
    poll_calls = g(a.ev_calls),
    forged_events = g(a.ev_forged),
    real_key_events = g(a.ev_real),
    note = "poll_calls must be non-zero for the hook to be on the engine's input " ..
           "path; real_key_events grows when the human presses keys",
  }
end

-- Forges a key through the event stream. The DLL reports key-down on the first
-- poll and key-up on the last, which is what a game's own input state machine
-- expects to see.
function xinput.poll_forge_key(name_or_code, frames)
  local a = resolve()
  if not a or not a.ev_forge_key then
    return { ok = false, error = "DLL not loaded, or a build without the PollEvent hook" }
  end

  local code = name_or_code
  if type(code) == "string" then
    code = SCANCODES[code:upper()]
    if not code then
      return { ok = false, error = "unknown key name: " .. tostring(name_or_code),
               known = xinput.scancodes() }
    end
  end
  code = tonumber(code)
  if not code then return { ok = false, error = "scancode required" } end

  local ok, v = pcall(a.ev_forge_key, code, math.max(1, math.min(frames or 10, 600)))
  if not ok then return { ok = false, error = tostring(v) } end
  return {
    ok = (v == 1),
    scancode = code,
    frames = frames or 10,
    note = "delivered through SDL_PollEvent; check xinput.poll_stats().forged_events",
  }
end

function xinput.poll_forge_clear()
  local a = resolve()
  if a and a.ev_forge_clear then pcall(a.ev_forge_clear) end
  return { ok = true }
end

function xinput.status()
  local a = resolve()
  if not a then
    return {
      loaded = false,
      hooks_installed = false,
      available = false,
      reason = resolve_error or "extension DLL not loaded",
      dll = DLL_NAME,
      install = "noita_input_load loads it; see extensions/input-hook/README.md. " ..
                "The base mod works without it.",
    }
  end
  local ok, v = pcall(a.ping)
  local ping_ok = ok and v == MAGIC

  -- "installed" means EITHER hook is in place: the current design arms the
  -- PollEvent hook, while xh_hooks_installed covers the older full set. Reporting
  -- only the legacy one made a working install advertise itself as inert, and
  -- noita_capabilities then said mode "base" while forging actually worked.
  local hooks = false
  local hooks_err = nil
  if ping_ok then
    if a.installed then
      local ok2, hv = pcall(a.installed)
      if ok2 and hv == 1 then hooks = true
      elseif not ok2 then hooks_err = tostring(hv) end
    end
    if not hooks and a.poll_installed then
      local ok3, pv = pcall(a.poll_installed)
      if ok3 and pv == 1 then hooks = true hooks_err = nil end
    end
  end

  local forged = 0
  for _ in pairs(a.keys) do forged = forged + 1 end

  local reason = nil
  if not ping_ok then
    reason = (not ok) and ("xh_ping raised: " .. tostring(v))
      or "xh_ping returned an unexpected value"
  elseif not hooks then
    reason = hooks_err or
      "the DLL is loaded but its hooks are NOT installed (it loads inert on purpose); " ..
      "call noita_input_install"
  end

  return {
    loaded = ping_ok,
    ping = ok and v or nil,
    expected = MAGIC,
    hooks_installed = hooks,
    available = (ping_ok and hooks),
    reason = reason,
    dll = DLL_NAME,
    forged_keys = forged,
    mouse_forge = a.mouse,
    frames_left = (function()
      if not a.frames_left then return nil end
      local ok3, f = pcall(a.frames_left)
      return ok3 and f or nil
    end)(),
  }
end

-- ---------------------------------------------------------------- forge


function xinput.scancodes()
  local out = {}
  for k, v in pairs(SCANCODES) do out[#out + 1] = { name = k, scancode = v } end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- Sets one key. `name` may be a scancode name ("W", "SPACE") or a raw number.
function xinput.set_key(name_or_code, down, ttl)
  if not xinput.available() then
    return { ok = false, error = "input extension not loaded", status = xinput.status() }
  end
  local a = resolve()

  local code = name_or_code
  if type(code) == "string" then
    code = SCANCODES[code:upper()]
    if not code then
      return { ok = false, error = "unknown key name: " .. tostring(name_or_code),
               known = xinput.scancodes() }
    end
  end
  code = tonumber(code)
  if not code or code < 0 or code > 511 then
    return { ok = false, error = "scancode out of range (0..511)" }
  end

  if ttl then
    a.ttl = math.max(1, math.min(ttl, 600))
    pcall(a.set_ttl, a.ttl)
  end

  local ok, err = pcall(a.set_key, code, down and 1 or 0)
  if not ok then return { ok = false, error = tostring(err) } end

  if down then a.keys[code] = true else a.keys[code] = nil end

  return {
    ok = true,
    scancode = code,
    down = down and true or false,
    forged_keys = (function()
      local n = 0
      for _ in pairs(a.keys) do n = n + 1 end
      return n
    end)(),
    warning = "the forge expires after its TTL; call xinput.clear() to release it now",
  }
end

-- Presses a key for `frames` frames. The TTL is what guarantees release, so a
-- caller that dies mid-sequence cannot leave the player's input hijacked.
function xinput.tap(name_or_code, frames)
  frames = math.max(1, math.min(tonumber(frames) or 6, 600))
  local down = xinput.set_key(name_or_code, true, frames)
  if not down.ok then return down end
  return {
    ok = true,
    scancode = down.scancode,
    frames = frames,
    note = "pressed for " .. frames .. " frames; the extension releases it automatically",
  }
end

-- Forges the mouse. Aiming is what this is for: the engine derives the aim vector
-- from the mouse, so forging the mouse aims the wand.
function xinput.set_mouse(x, y, buttons)
  if not xinput.available() then
    return { ok = false, error = "input extension not loaded", status = xinput.status() }
  end
  local a = resolve()
  local ok, err = pcall(a.set_mouse, tonumber(x) or -1, tonumber(y) or -1,
                        tonumber(buttons) or 0)
  if not ok then return { ok = false, error = tostring(err) } end
  a.mouse = { x = x, y = y, buttons = buttons or 0 }
  return { ok = true, x = x, y = y, buttons = buttons or 0 }
end

function xinput.clear()
  local a = resolve()
  if not a then return { ok = true, note = "extension not loaded, nothing to clear" } end
  local ok, err = pcall(a.clear)
  a.keys = {}
  a.mouse = nil
  return { ok = ok, error = (not ok) and tostring(err) or nil }
end

return xinput

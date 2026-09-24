# Contributing

The working method for this project, with the templates and checks that make it safe. Read
[ENGINE-NOTES.md](ENGINE-NOTES.md) first — it lists the engine behaviours that are not what
they look like, and most of the rules below exist because of them.

---

## The rules that matter

### 1. Verify engine behaviour in a live game, not in the mock

The mock covers Lua logic, permission gating and regressions. It does **not** model the engine:
its raytrace geometry is a simplification, its `xinput` is absent, and its GUI records calls
rather than rendering them. A check that asserts physics or input behaviour is testing the mock.

Claims about the engine go in `ENGINE-NOTES.md` only with a measurement behind them.

### 2. Check a hook is *called*, not that it *installed*

Every hook has a call counter. `SDL_GetKeyboardState` and `SDL_GetMouseState` install cleanly
and are never called once — the engine does not import them. Read the counter before building
on a hook.

### 3. `pcall` does not catch crashes

It catches Lua errors, not access violations. Memory work must copy into a private buffer and
skip guard pages (`files/bridge/memscan.lua` is the reference). A wrong write here does not
fail, it freezes the machine.

### 4. Never write non-ASCII through the shell

PowerShell's ANSI round-trip corrupted the Chinese documentation and a regex in `server.js`,
lossily. Use the file tools or Node. `tools/check_encoding.js` catches both a BOM and mojibake.

### 5. Run the checks before committing

```powershell
cd agent\tools\luacheck
node syntax.js                                  # every Lua file compiles
node mock_game_test.js                          # logic, gating, regressions
node mcp_e2e_test.js                            # the MCP server end to end
node check_game_api.js <mod files dir> <noita dir>   # every Gui* call names a real function

cd ..\..\dist\Noita-MCP
node tools\check_doc_tools.js .                 # every documented tool exists
node tools\check_encoding.js .                  # no BOM, no mojibake
node tools\compare_packages.js .                # base differs from full only by the extension
```

With a game running, `node live_smoke.js` exercises the bridge against the real thing.

---

## Templates

### A bridge module

Modules are **globals**, loaded by `dofile_once`, whose return value is discarded. A module
written as `local x = {} ... return x` loads without error and is `nil` everywhere else.

```lua
-- What this is for, and the measured facts behind its design.
--
-- If a decision here came from a measurement, record the measurement. "It seemed to work"
-- is how this file's predecessors accumulated bugs that took a live game to find.

mymodule = mymodule or {}

local SOMETHING_MEASURED = 220      -- and where that number came from

-- Reads before writes; every function says what it returns on failure.
function mymodule.do_a_thing(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end

  local value = tonumber(params.value) or SOMETHING_MEASURED
  -- clamp: an out-of-range write is worse than a refusal
  value = math.max(1, math.min(value, 1000))

  local ok, err = pcall(SomeEngineCall, value)
  if not ok then
    return { ok = false, error = "SomeEngineCall raised: " .. tostring(err) }
  end
  return { ok = true, value = value }
end

-- NO trailing `return mymodule`
```

Then add it to `init.lua` in dependency order, and to the module list in
`tools/luacheck/mock_game_test.js` so the mock proves it loads and its global exists.

### An RPC handler

```lua
handlers.my_method = function(params)
  params = params or {}
  -- delegate to the module; the handler only adapts params and records intent
  local r = mymodule.do_a_thing(params)
  -- if this is an action a replay should see, record it on the decision stream
  if r and r.ok and stream and type(stream.action) == "function" then
    stream.action("my_method", { value = r.value })
  end
  return r
end
```

Then classify it in `files/ui/panel.lua`:

- **A read** (observation only) → add nothing. Unlisted methods are reads by default, and that
  is deliberate: a forgotten entry in the write table wrongly *allows* a mutation, while a
  forgotten entry in a read table only *breaks* observation. The table that must be complete is
  the one that grants power.
- **A write** → add it to `OP_METHODS` under `op_spawn`, `op_player`, `op_wands` or `op_world`.

A test asserts this split; see the existing checks for the pattern.

### An MCP tool

```js
{
  name: 'noita_my_tool',
  description: 'What it does, what it needs, and what it measured. Say plainly if it only ' +
    'works in the full tier, and what happens if it does not (refuse, with a reason).',
  inputSchema: {
    type: 'object',
    properties: {
      value: { type: 'integer', description: 'range and default, if any' },
    },
    required: ['value'],
  },
  handler: (args) => rpc('my_method', args || {}),
},
```

Tool descriptions are read by an AI deciding what to call, so include the limits: units, the
valid range, and anything the caller would otherwise have to discover by failing.

### An in-game fixture

For anything that asserts engine behaviour. Put it in `files/bridge/` while testing, run it,
then **delete it** — `compare_packages.js` and the module list will not catch a stray file.

```lua
-- Probes <what>, because <why the answer is not obvious>.
--
-- The question that matters: <the specific thing that is unknown>. <What each outcome would
-- mean for the design.>
local fixture = {}

function fixture.run(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end

  -- measure, do not assume: report the raw values you are reasoning from, so the conclusion
  -- can be checked rather than trusted
  return { ok = true, measured = { /* ... */ } }
end

return fixture
```

Run it:

```powershell
node agent\tools\luacheck\run_fixture.js "mods/noita_agent/files/bridge/my_fixture.lua" run
# with args:  ... run '{"x":1}'
```

`run_fixture.js` passes arguments as argv so PowerShell cannot strip the quotes out of inline
JSON — which it does.

---

## Adding to the release

`agent/` is the development tree; `dist/Noita-MCP/` is what ships. They are separate copies, so
a change is not released until it is in both.

1. Edit in `agent/dist/mod_src/…` (the source of truth).
2. Copy to `agent/…/mods/noita_agent/files/bridge/` for a live test.
3. Copy into `dist/Noita-MCP/base/mod/` and `dist/Noita-MCP/full/mod/`.
4. `compare_packages.js` must still report that base and full differ **only** by `extension/`.
5. If a tool was added, update the tool counts and the groups table in the READMEs, and run
   `check_doc_tools.js`.
6. Add a `CHANGELOG.md` entry. Record the *reason*, not just the change — several entries are
   the only place a design decision is explained.

---

## What not to add

- **Engine-behaviour claims without a measurement.** If it went into `ENGINE-NOTES.md` without
  one, it should not be there.
- **A mock check for physics or input fidelity.** It tests the mock. Use a live fixture.
- **A feature the base package cannot support, placed in base.** `compare_packages.js`
  enforces the split; a tool that needs the DLL belongs in `full/`.
- **A silent fallback.** If something cannot be done, refuse and say why. A macro that cannot
  fire the wand must say so, not appear to run.
- **Inference inside the bridge.** The model belongs in its own process; that separation is what
  keeps latency attributable.
- **An unverifiable memory write.** If the only test is "does it look right", the failure mode is
  a frozen machine and there is no way to tell a correct address from a lucky one.

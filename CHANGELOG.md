# Changelog

Notable changes to Noita MCP, newest first.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project uses [semantic versioning](https://semver.org/spec/v2.0.0.html):
`MAJOR` for a break in the MCP tool interface, `MINOR` for new tools or
capabilities, `PATCH` for fixes that change no interface.

The mod carries no version number of its own. The released version is the git tag;
`<Noita>/mods/noita_agent/mod.xml` is deliberately left unversioned so an updated
copy of the folder is always accepted by the game.

---

## [1.2.0] — 2026-09-24

Movement macros now work **without** the input extension, so the base package can walk,
climb and dodge. That required fixing a bug which had been silently defeating every velocity
write in the project.

### Fixed — the velocity write went to the wrong component

The player carries **two** components with a field called `mVelocity`, and they are not the
same thing:

| Component | Shape | Measured displacement |
| --- | --- | --- |
| `CharacterDataComponent.mVelocity` | a **pair** `(0, 60)` | **171.4 px** |
| `VelocityComponent.mVelocity` | a **scalar** `0` | 0.0 px |

`lever.lua`'s write list targeted the VelocityComponent, so writing `{x, y}` landed on a
scalar field and did nothing -- quietly. Every velocity-based movement in this project was
affected, which is why direct motion control "worked" once (a measurement of 126px) and then
could not be reproduced. Both observations were correct: the working case wrote to the
character component.

Found by enumerating the components' fields rather than guessing which name carried the
vector, then measuring both paths side by side in one run with identical parameters.

### Added — macros run without the extension

Each macro step may now carry a direction as well as a key. With the extension armed the key
is used (exact, and the only way to press a button); without it, motion macros drive velocity
through `lever.lua`. Of 24 macros, **11 run in the base package** and 13 need the extension.

A macro that must be a button press **refuses** without the extension rather than appearing to
succeed: `noita_macro` returns which steps are blocked, why, and what would work instead.
Firing the wand has no physics equivalent, so pretending would be worse than failing.

- `noita_macro_list` now reports capabilities: what runs now, what needs the extension.
- Measured in a live game with the extension **not** loaded: `walk_right` moved the player
  Δx = 62.3, with velocity released when the macro ended.

### Considered and not added — time scaling

Recorded because the request was to try a more invasive approach, and the honest answer is
that it was not attempted rather than that it failed.

The Lua API has **no time-scale setter at all**. Every time-related function is read-only:
`GameGetFrameNum`, `GameGetRealWorldTimeSinceStarted`, `GameGetDateAndTimeUTC`,
`GameGetDateAndTimeLocal`, `StreamingGetVotingCycleDurationFrames`. The nearest writable
thing, `PhysicsBodyIDSetGravityScale`, affects one physics body, not the world clock.

Reaching it through memory writes was not attempted, and the reason is verifiability: a
candidate address cannot be confirmed from inside the game. The only available test is "does
the game appear to slow down", which a wrong address can also produce while corrupting
something else, and the failure mode of a wrong write there is a frozen machine. Memory
mistakes have already frozen this project's host twice, so an unverifiable write is not a
trade worth making.

### Verified at this release

| Suite | Result |
| --- | --- |
| Lua syntax | 23/23 files compile |
| Mock game | 71/72 checks |
| MCP end to end | 15/15 checks |
| Package split | base differs from full only by the extension |
| Encoding | no BOMs, no mojibake |

---

## [1.1.0] — 2026-09-24

Adds the three things a high-frequency decision loop was missing. The tool count goes from
64 to 76.

### Added — terrain (the largest gap)

Noita's Lua API cannot read a cell's material: there is no `GetMaterial` or `GetCell`, and
the `CellFactory_*` functions only go the other way (id to name). So terrain is sampled with
the four raytrace variants and reported as **reachability**, never as material names.

- `noita_terrain_grid` — a grid as text, one character per cell, with a legend. Measured in
  a live run at `cells=9, radius=120`: 32 ground, 47 open, 2 solid, 324 raycasts, 26.7px
  cells.
- `noita_terrain_probe` — clear distance in each direction plus where the ground is, which
  is the "can I walk that way" question in one call. Measured: ground 3px below, up clear
  56px, left clear 56px, right blocked at 32px.
- `noita_terrain_rays` — up to 512 arbitrary rays per call, for a custom sampling pattern.

### Added — input macros

- `noita_macro_list`, `noita_macro`, `noita_macro_status`, `noita_macro_stop`. 22 named
  intents (`jump_right`, `fire_and_retreat`, `interact`, ...) so the mapping from intent to
  key timing lives in one place and a replay can record the intent instead of a key stream.
- A macro holds each key for the frames the engine needs, releases everything when it ends,
  and refuses to start at all if the input extension is not armed. Starting a new macro
  cancels the running one cleanly rather than leaving a key down.
- Measured: `jump_right` is 2 steps / 34 frames and moved the player Δx = 23.7 with the
  expected velocity curve.

### Added — decision stream

- `noita_stream_start` publishes `(state, action, outcome)` records to
  `<run>/decisions.jsonl`, one JSON object per line, appended so an external loop can tail
  it. This removes the one-RPC-round-trip-per-decision bottleneck for a 5-10 Hz loop.
- Deliberately **transport, not inference**: the model stays in its own process, which is
  what keeps latency attributable.
- A ring of recent observations is retro-filled with their outcomes when those become known,
  so delayed-reward labelling does not need a second pass over a replay.
- `noita_stream_recent` reads the ring without touching disk, for sandboxes where `io` is
  unavailable; `noita_stream_action` records an intent so a replay does not have to infer it.

### Verified at this release

| Suite | Result |
| --- | --- |
| Lua syntax | 24/24 files compile |
| Mock game | 69/70 checks |
| MCP end to end | 15/15 checks |
| Live smoke, against a running game | 23/23 checks |
| Game API names | 61 `Gui*` call sites, all real |
| Documented tool names | all real |
| Encoding | no BOMs, no mojibake |

Terrain, macros and the decision stream were each exercised against a live game: the grid
produced a readable map, `jump_right` moved the player, and the stream wrote a 150-line
`decisions.jsonl`.

### Considered and rejected

- **Time scaling.** The request asked for slow-motion or fast-forward, flagged as "confirm
  whether this is possible first". It is not: the Lua API exposes no time-scale setter at
  all, only read-only time accessors (`GameGetFrameNum`, `GameGetRealWorldTimeSinceStarted`,
  `GameGetDateAndTimeUTC`). Reaching it through memory writing was not attempted, because
  the failure mode of a wrong write there is a frozen game.
- **Inference inside the bridge.** Explicitly not added. Keeping the model in a separate
  process is what makes latency attribution possible; mixing the two would remove that.

### Fixed during development

- `macro.lua` compared `xinput.push_key`'s return against the number 1. It returns a table
  (`{ok = true, scancode = n}`), so every macro start reported "the extension refused the
  first key-down" while the RPC path, which reads `.ok`, worked. Caught by running a macro
  in a live game -- the mock could not see it, because its `xinput` is unavailable and the
  guard above short-circuits first.

---

## [1.0.0] — 2026-09-24

First release. Two tiers that install together but stand alone:

- **base** — pure Lua, no external dependency, 67 tools.
- **full** — base plus an optional 32-bit DLL that synthesises SDL events,
  adding 9 input tools (64 total).

### Added — observation and modification

- Player state, inventory, wands and spell decks, nearby entities, world and map
  data, materials, spells, perks.
- Modification of the player (position, health, gold, status effects), spawning
  of items, potions, spells and wands, wand deck and stat editing, item switching,
  pickup, dropping, projectile launching.
- **Spell charge counters.** `uses_remaining` is read per card in a wand deck.
  Measured in a live run: FIREBALL 15/15, BLACK_HOLE 3/3, DYNAMITE 16/16,
  ROCKET 10/10, LIGHT_BULLET unlimited (`-1` in the game data means unlimited).
- **World and map reading.** Biome name and file, depth within the biome,
  parallel-world coordinates, orb counts, NG+ level, the camera rectangle, and a
  9x9 fog-of-war sample. Note for anyone reading the raw output: the biome lookup
  needs the Y axis negated relative to entity coordinates, and `_EMPTY_` means the
  lookup failed rather than a biome named empty.
- **Entity catalog.** `noita_find_entity` searches ~3030 entity definitions by
  name, tag or kind — 651 enemy, 452 projectile, 212 item, 169 building, 27 wand,
  5 chest.
- **Fact database.** `noita_db_query` answers property questions: 610 enemies
  (hp, attack interval and projectile, damaging materials, hitbox), 87 wand
  templates (capacity, fire rate, reload, mana), 153 perks, 224 materials
  (density, hazards, status effects), 150 biomes.

### Added — input control (full tier only)

- `noita_input_move`, `noita_input_key`, `noita_input_fire`, `noita_input_click`,
  `noita_input_release`, plus load/install/uninstall/status.
- **Movement verified in a live run:** holding `D` gives `vx = +56.84` and `A`
  gives `-56.81`, symmetric against a zero baseline.
- **Firing verified in a live run:** the wand fires on the LEFT MOUSE BUTTON, not
  a key — `SPACE` is the fly key and produces no shot. The engine's own
  `mButtonFrameFire` counter advances when firing is forged.
- Interact key is `E`, measured by watching `mButtonFrameInteract` while probing
  candidates.
- Events are delivered by `SDL_PushEvent` from the per-frame update, never from
  inside a hook. Every return value stays SDL's own, so the engine's event loop is
  unaffected; a version that returned 1 for an empty queue froze the machine.

### Added — in-game panel

- Four tabs: Status, Permissions, Extension, Log.
- **Status** — active transport and port, request count, watchdog state, RPC
  timings, settings backend, latency knobs, and the **transport switch**: one
  button changes the current channel, another sets which transport a new session
  starts with.
- **Permissions** — master switch, read-only mode, the four operation categories,
  verbose logging, and a line spelling out the effective state.
- **Extension** — DLL loaded and armed, and if either failed, every path that was
  tried and why each failed, with load / arm / disarm buttons.
- **Log** — recent messages coloured by level with a filter and a
  "newest M of N" readout.
- The panel is centred when open and pinned to the top-left corner when collapsed.
  A collapsed strip never paints a background, because one there sat over the
  game's own HUD.
- `ai_enabled`, `read_only` and whether the panel is open reset every run. A
  persisted "pause right now" switch would start the next session paused, and on a
  stricter build the operator could be locked out of the panel that turns it back
  on. The operation categories do persist, because they express policy.

### Added — safety design

- The DLL loads **inert**: `DllMain` only resolves pointers. Nothing is hooked
  until the hooks are armed explicitly.
- Hook installation is **all-or-nothing**. A partial set — keyboard without the
  pump, say — would leave a forge that never expires, which is worse than none.
- A **heartbeat watchdog** removes the hooks if Lua stops driving them, so a wedged
  frame loop recovers by itself.
- Holds are **bounded** and expire on their own, so a failed sequence cannot leave
  the player's input hijacked.
- `SDL_PumpEvents` is **never hooked**. It runs every frame, may run on several
  threads and may re-enter SDL's input path, so a trampoline there risks unbounded
  recursion. This was the first cause of a hang; excluding it removed the class.
- The permission gate treats any unlisted method as a **read**. A forgotten entry
  in the write table would wrongly allow a mutation; a forgotten entry in a read
  table only breaks observation. The table that has to be complete is the one that
  grants power.
- The panel tools (`get_panel`, `set_panel`) are never gated, so the AI can always
  be re-enabled.

### Notes on packaging

- **No game data is bundled.** The Noita Modding Agreement forbids distributing a
  substantial part of the game's content, so the repository ships an extracted fact
  database and a tool (`tools/build_db.py`) that rebuilds it from a copy the user
  owns. `tools/unpack-data.ps1` explains how to produce that copy; on the current
  build the game's own `-wizard_unpak` switch no longer writes the unpacked tree,
  so that script instructs rather than acts.
- The mod shows an "unsafe mod" warning and that cannot be removed: it needs
  `request_no_api_restrictions="1"` for `os` and `io`.

### Verified at release

| Suite | Result |
| --- | --- |
| Lua syntax | 19/19 files compile |
| Mock game | 58/59 checks |
| MCP end to end | 15/15 checks |
| Live smoke, against a running game | 23/23 checks |
| Game API names | 61 `Gui*` call sites, all real |
| Documented tool names | 283 references, all real |

The one failing mock check is a known stub limitation in `spawn_potion with
materials`, not a product defect.

---

## Development history

The entries below were never released separately; they are the phases this release
came through, kept because each one is the reason for a design decision that is
otherwise hard to explain.

### Input forging

**Added** — `noita_input_*`, with the safety properties above.

**Fixed** — three machine freezes. The cause was the same each time and is worth
recording: SDL2's exported input functions are **7-byte import thunks**
(`mov eax, [imm32]; jmp eax`), and the hook analysis counted 6, so `jmp eax` was
cut in half and the trampoline held a truncated instruction. The resolver now
follows the thunk to the real implementation. Hooking the thunk would have been
pointless even with the right length: it re-reads its target on every call.

**Fixed** — forging appeared to work only when the operator happened to move the
mouse. The engine drains the SDL queue itself, so by the time it polls there is
usually nothing left to rewrite; `with_event` stayed at 0 across 405 invocations.
Fixed by synthesising events into SDL's own queue rather than rewriting polled
ones.

**Changed** — an intermediate attempt supplied an event from the hook and returned
1 when the queue was empty. That froze the machine: the engine's loop is
`while (SDL_PollEvent(&e))`, and a poll that never returns 0 never ends. It was
replaced by the push-based design, which cannot alter a return value.

**Removed** — a hook on `SDL_PeepEvents`. Instrumentation showed the engine never
calls it, so it could not have been the keyboard path.

### The panel

**Fixed** — the content area was blank. Panes were offset with `GuiTranslateSet`,
which is **not in Noita's GUI API**. It sat inside a `pcall`, so it failed silently
and every pane drew at `(0,0)`. Panes now take an explicit origin parameter, which
cannot silently no-op, and `tools/check_game_api.js` verifies every `Gui*` call
site against the game's own `lua_api_documentation.txt`.

**Fixed** — the collapsed header could not be clicked. It paired an empty button
with a separate text label, so the visible `noita_agent -` was paint and the hit
area was an invisible rectangle underneath it.

**Fixed** — there was no way to choose a transport. The chooser had been lost in a
panel rewrite.

**Fixed** — a fixed 620x620 panel covered most of the screen. A 9-piece decoration
is opaque in the middle however low its tint, so the panel now measures its height
from the pane it is about to draw.

**Removed** — `GuiBeginScrollContainer` for the log. It appeared to render nothing
and there was no way to tell from inside the game whether the API or the call was
at fault. The log now shows the newest rows that fit and reports what it holds back.

**Fixed** — `set_panel` wrote the caller's key names while the UI read its own, so
`set_panel{open=true}` reported success and changed nothing. Only the names that
happened to match (`ai_enabled`, `read_only`) worked, which hid it.

**Fixed** — the permission table left 69 of 114 RPC methods unclassified, so
read-only mode refused ordinary observation such as `get_inventory`.

**Fixed** — the panel had no test coverage at all: there were no GUI stubs, so the
draw path threw and its own `pcall` swallowed it. The mock now records GUI calls,
and 14 panel checks cover backdrop placement, centring, the toggle click, transport
choices and log bounding.

### Tooling

**Added** — `tools/check_game_api.js`, `tools/check_doc_tools.js`,
`tools/check_encoding.js`, `tools/fix_corruption.js`, `tools/strip_bom.js`,
`tools/build_db.py`, `tools/build_index.py`, `tools/unpack-data.ps1`,
`tools/verify.ps1`.

**Fixed** — documentation that referenced tools nobody had implemented, and a
PowerShell round-trip that corrupted non-ASCII text. That damage is lossy and was
not reversible; the affected files were rewritten, and the rule now is that no
shell command writes them. Two corruption sites survived that fix and are repaired
in this release:

- The English READMEs had every em dash replaced by a two-character mojibake
  sequence.
- `server.js`'s `parseSimWarnings` had its regex prefix corrupted, so it never
  matched the wand simulator's warning and the cross-check that tells you when a
  spell exists in the game but not in the simulator's table **silently never
  fired**. Restored to match the literal prefix the simulator writes, and verified
  against its real output.

`tools/check_encoding.js` now guards both failure modes: a UTF-8 BOM, and
mojibake, across every text file.

---

[1.0.0]: https://github.com/normalwindow/Noita-MCP/releases/tag/v1.0.0

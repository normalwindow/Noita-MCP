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

## [2.2.0] — 2026-09-24

Chunked material perception, and the material catalogue from the unpacked game data. 87 tools.

### Added — perception by chunk, which is the shape this needed

An agent does not need a pixel map. It needs to know, per region, roughly what the terrain is made
of and how far away that stuff is. So `noita_percept_surroundings` samples in **rings**: a set of
directions at each of several distances, reporting for every band the fraction that is open air
versus matter.

A grid is uniform in space and says nothing about reach. Rings answer "what is near me, what is at
arm's length, what is far" directly, at a cost that scales with the number of rings rather than the
area — 4 raytrace variants x 12 directions x 4 bands is 192 raycasts for four depth layers that each
mean something.

- `noita_percept_surroundings` — what is around the player, per distance band
- `noita_percept_chunk` — the rough composition of a rectangle
- `noita_percept_vocabulary` — what each class means, and what cannot be known

### Two mistakes, both caught by measuring

**The raytrace return value was read backwards.** A raytrace returns `(did_it_stop, x, y)`; `true`
means IT STOPPED. The first version read `true` as "the path was clear" and therefore reported a
solid rock face as **"standable 100%"** at every distance. Firing the four variants by hand showed
all four returning true, which is what exposed it.

**That measurement then revealed a real limit, not just a bug.** From inside solid matter all four
variants stop at the ray's own start and are indistinguishable:

| position | the same downward probe |
| --- | --- |
| open air (227,-79) | all four variants `hit=false` |
| solid rock (0,3000) | all four variants `hit=true`, stopped at the start |

A solid cell's material therefore cannot be recovered by raycasting, and the honest output is
`solid_or_liquid` — occupied, not identifiable — rather than a guess between rock and sand that the
engine gives no signal for. The tool says so in its own result: a caller reading "standable 100%"
inside a rock face would be badly misled.

### Added — the material catalogue, from the unpacked game data

`tools/extract_materials.js` reads the game's own `materials.xml` and produces
`materials_full.json`: **469 materials** with their class and properties.

| cell_type | count |
| --- | --- |
| liquid | 155 |
| solid | 42 |
| gas | 21 |
| fire | 4 |

Dangerous ones are flagged: 22 by fire, 6 by radiation, 1 by poison. The file is parsed line-by-line
because it is **not** a tree of elements — each material is a run of `key="value"` lines inside one
wrapper, which is why a tag-level scan found zero definitions in a file that plainly contained them.

This is the other half of perception: the catalogue says what a named material MEANS, the perception
layer says WHERE matter is and roughly what kind. Neither can name the material of one particular
cell.

### Recorded — a rule that cost a run to learn

**Set invincibility before teleporting.** Exploring for terrain moved the player into enemies without
protection and ended the run the user was playing. Teleporting is not a read-only act.

The procedure is now in `ENGINE-NOTES.md`: `noita_set_player` with `hp`, `max_hp` and
`invincibility_frames` **first**, then move. All three — large `hp` alone still lets a hit land, and
frames without health still end in a death if they lapse.

### Verified at this release

| Check | Result |
| --- | --- |
| Perception, live | 4 bands, 192 raycasts, composition per band |
| Raycast semantics | measured both ways — open air vs solid rock |
| Material catalogue | 469 materials from materials.xml, 106 KB |
| Lua syntax / mock / MCP end to end | 23/23, 80/81, 15/15 |
| Encoding | no BOMs, no mojibake |

---

## [2.1.0] — 2026-09-24

Three gaps found in a review of what the bridge can see. 87 tools.

### Added — the world seed, read out of memory

The pause screen shows the seed, so the game has it. There was no way to **ask** for it: the Lua
API exposes `SetWorldSeed` and no getter, `SessionNumbersGetValue` returns an empty string for
every plausible key, the `WorldStateComponent` carries only `day_count` and `time`, and a scan of
the 40 MB game data shows the engine itself uses exactly one session number
(`NEW_GAME_PLUS_COUNT`).

So it is found by searching for it — which is only possible because the player can **read it off
the pause screen**. A known number is a needle; an unknown one is not.

- `noita_seed_find` takes the seed the player sees and reports every address holding it, with the
  region each falls in. Measured: **2 hits in 1.2 s** on one run, 13 in 1.4 s on another.
- `noita_seed_verify` re-reads those addresses, which is cheap and answers "is that still true".
- **Addresses are found fresh every time and never cached.** They move: one run's hits were two
  module-static globals plus heap allocations, another's were three heap addresses and no static
  one at all. A cached address would survive exactly until the allocator moved.
- **No DLL needed** — the scan uses LuaJIT's FFI, which is part of the base mod. Verified with the
  input extension not loaded: 2 hits, 1.2 s, game unaffected. The tool description says so.

### Fixed — `noita_controls_snapshot` reported 8 of the 19 buttons

The button set was enumerated in a live game rather than taken from the documentation, because the
component **schema does not list these fields at all** — it declares only config variables like
`enabled` and the gamepad options. There are **19 buttons, each with a `Down` and a `Frame`
field**; `LastFrame` exists for `Fire` alone.

The old snapshot covered 8. The gap was invisible until the kick work needed `mButtonFrameKick`
and found it missing, and the review then found `Fire2`, `DropItem` and `Action` missing as well.
The snapshot now reports all 19 in a `buttons` map, keeps the old flat keys so existing callers do
not break, and says in its own output that the `Frame` fields are **frame numbers, not counts**.

### Fixed — nearby entities had no way to say what species they are

`noita_get_nearby` returned `kind` (`creature` / `item` / `prop`), which does not distinguish a rat
from a bat. Entity entries now carry **`species`**, taken from the source definition path — the
only reliable classifier the engine offers, since entity names are localisation keys
(`$animal_fish`) and are absent on many props.

Measured in a live run, which is also what proves it works: `species: "rat"` (洛塔, hp 0.2),
`species: "bat"` (勒巴可, hp 0.5), `species: "fish"` (伊瓦卡斯, hp 0.1) — three distinct creatures
told apart by species, each with its own hp. The same field is what distinguishes one explosive
prop from another (`physics_box_explosive` vs `temple_lantern`).

Worth knowing: for the player's own carried items this reads `player` or `action`, because those
entities are loaded from generic files. That is the field reporting what the source path says, not
a wrong answer.

### Verified at this release

| Check | Result |
| --- | --- |
| Buttons enumerated, live | 19 down + 19 frame + 1 last-frame |
| Seed scan, extension not loaded | 2 hits, 1.2 s, game alive |
| Species, live | rat / bat / fish distinguished, with hp |
| Lua syntax / mock / MCP end to end | 22/22, 80/81, 15/15 |
| Encoding | no BOMs, no mojibake |

---

## [2.0.2] — 2026-09-24

The kick — the F-key action that shoves objects away from the player's feet — is confirmed to
work through `noita_macro`, and a caller can now verify it rather than take it on trust.

### Answered — yes, `noita_macro kick` performs a real kick

It was already in the macro set as `kick = { { key = "F", frames = 8 } }`, but "the macro
returned ok" only means the extension handed an F key-down to SDL. That is not the same as the
game acting on it, and this project has had to retract an unverified claim before.

So it was measured, against real input as the control:

| step | result |
| --- | --- |
| extension armed, no input | every control field reads 0 |
| a human presses F | `mButtonFrameKick` and `mButtonDownKick` move |
| `noita_macro kick` | the same signature, **4 runs out of 4, at a frame gap of 0** |

`noita_macro kick` is the tool; `noita_controls_snapshot` is how to check it.

### Added — `noita_controls_snapshot` reports `mButtonFrameKick` and `mButtonDownKick`

Previously absent, which made a kick impossible to confirm from outside. The reason the field
was added is written where it is read, so the next person does not have to rediscover why.

### Fixed — three wrong measurements of the same field, and what it actually is

`mButtonFrameKick` **is a frame number, not a count of kicks**. The name reads like a counter and
is not one, and three successive attempts to test with it produced confident nonsense:

1. Comparing raw differences across the macro called a **2405-frame gap a pass** — that gap was
   just elapsed time.
2. Treating the same number as a count called it a **failure**, for the same reason.
3. The passing version checks **how old** the kick frame is: a kick that just happened has a gap
   of a few frames, and time passing cannot make a gap small. Measured at 0.

The check also verifies the field is **still** before running the macro, so someone else pressing
F cannot be credited to it. That guard was added after a run reported three passes with jumps of
4351, 205 and 206 — a human, not the macro.

### Verified at this release

| Check | Result |
| --- | --- |
| `noita_macro kick` | 4/4 runs, kick frame gap 0 |
| Field still when idle | yes, over 32-frame windows |
| Mock / MCP end to end | 80/81, 15/15 |
| Encoding | no BOMs, no mojibake |

---

## [2.0.1] — 2026-09-24

Renamed to **Noita MCP Agent Bridge** for consistency with the repository, and the release
archives are now assembled separately from the repository: they ship the finished product and no
build inputs. No behaviour changed.

### Changed — the name

`mod.xml` already said "Noita MCP Agent Bridge"; the prose across 15 files still said "Noita AI
Agent Bridge". All 23 occurrences are unified. The mod's **directory stays `noita_agent`**: that
is its identity to the game, it appears in every `mods/noita_agent/...` path in the Lua, and
renaming it would break every installed copy for no benefit the player can see.

### Added — downloadable archives, built from a whitelist

`tools/build_release.js` assembles two zips from an explicit list of files, and
`tools/verify_release.js` then opens the finished archives and checks what a user will actually
receive — because a whitelist can be wrong in the same way it can be right.

The archives contain the mod, the MCP server, the fact database, the agent skill, the licence and
the docs. They do **not** contain `xinput_hook.c`, `build.ps1` or `injector.c`: a player who wants
the full tier should get a DLL, not a C file and a linker invocation. The repository keeps all of
it — it is an Apache-2.0 project, the C is the honest record of how the hooks work, and repo size
and download size are different questions.

The verifier asserts, on the finished files rather than on the builder's intent:

- neither archive contains build inputs (`.c`, `build/`, `build.ps1`, the layout notes, the injector)
- `base` contains **no** DLL — a DLL there would mean the tier split had been broken
- `full` contains **exactly one** DLL, at `extension/xinput_hook.dll`, which is the path
  `install.ps1` probes first
- that DLL is **byte-identical** to the one in the repository, so the release cannot ship a stale
  build (sha `7dd868d254d1`, 103,936 bytes)

### Fixed — three bugs in the installers, all found by unpacking an archive and running it

Every one of these was invisible from inside the repository, where the development layout held:

1. **The skill was searched for one level up.** `install.ps1` looked for `..\mcp-skill\SKILL.md`
   — correct in the development tree, wrong in an archive, where the skill sits beside the
   script. An unpacked archive reported "skill not found" **while the file was sitting right
   there**.
2. **The skill's destination pointed outside the archive.** Joining `..\..` from the archive root
   resolves to the parent of wherever the user unpacked. The installer wrote the skill twice
   inside the folder and twice into somebody's Temp directory. Writing outside the folder a user
   unpacked is not a thing an installer should do. The layout is now **detected once** and only
   that layout's destinations are used.
3. **`verify_release.js` compared forward-slash paths against an archive that stores
   backslashes**, so it reported every required file as missing. The archives were fine and the
   check was wrong. It now normalises, and prints what it actually found when a check fails —
   which is what made the mistake obvious instead of mysterious.

### Verified at this release

| Check | Result |
| --- | --- |
| Build inputs in either archive | none |
| DLL in `base` | none, as intended |
| DLL in `full` | byte-identical to the repository build |
| `install.ps1` from an unpacked `full` archive | mod copied, DLL installed, skill installed inside the archive, nothing written outside it |
| `install.ps1` from an unpacked `base` archive | same, with no DLL step |
| Live run from the archive-installed copy | bridge answered, input extension loaded, clock mapping sound, 0.4x measured as 0.4118, restored to 1.0, game alive |
| Lua syntax / mock / MCP end to end | 21/21, 80/81, 15/15 |
| Encoding | no BOMs, no mojibake |

---

## [2.0.0] — 2026-09-24

**Time scaling works.** Slow motion and fast forward, verified in a live game in both
directions. 87 tools.

This replaces the 1.4.1 conclusion that it was not feasible. That conclusion was wrong, and the
reason is worth recording: the search was for Noita's own time variable, and **there is no such
variable**. The engine does not keep a time scale. It asks Windows what time it is, every frame,
and integrates the answer — so what you change is the ANSWER, not a variable. That is Cheat
Engine's technique, and it was the user who pointed at it.

### Added — `noita_time_scale`, `noita_time_measure`, `noita_time_status`

The clock is intercepted in the DLL. `noita.exe` imports `QueryPerformanceCounter` and
`QueryPerformanceFrequency` **directly from KERNEL32**, not through SDL — confirmed from the
import tables — so hooking kernel32's function covers every caller in the process, including
SDL, where hooking an SDL export would have missed the engine entirely.

Measured in a live run:

| requested | measured ratio | frames/sec | mean frame |
| --- | --- | --- | --- |
| 1.0 | — | 59.98 | 16.67 ms |
| 0.5 | **0.514** | — | — |
| 2.0 | **2.0** | 107.89 | 9.26 ms |
| 4.0 | **4.0** | **122.24** | 8.18 ms |

### The frame ceiling, now with numbers

The user reported that acceleration has a frame-rate ceiling, so it cannot be measured by frame
rate. That is exactly right, and the table shows why: at 4x the engine is still only at 122 fps,
up from 108 at 2x. **The size of an acceleration cannot be read from the frame rate at all.**

So the measurement is independent of it: `noita_time_measure` compares elapsed game time against
elapsed real time, reading both in-process through `xh_qpc_raw` (a copy of the real function the
hook does not intercept) and `xh_qpc_scaled`. It reported 2.0 and 4.0 exactly. It samples across
frames rather than waiting in a loop, because Lua runs on the game's main thread and a wait loop
would stall the engine it is measuring.

### Fixed — a freeze, and the two bugs behind it

The first version **wedged the game**. Setting a scale left the anchor at zero, so the counter
the engine saw jumped backwards by roughly 10^13 ticks. The engine paces its frames off that
counter, so it waited for a deadline it had already passed.

Two fixes, and the second was found by the first one's own diagnostic:

1. **Anchor on the raw value, and store raw and scaled together.** The mapping is
   `scaled = scaled_anchor + (raw - raw_anchor) * scale`, which is continuous at the moment the
   scale changes — at `raw == raw_anchor` it yields exactly `scaled_anchor`. Re-anchoring happens
   where the scale changes, which is the only place the invariant can break.
2. **No clamp in the hot path.** The first fix added a high-water-mark clamp to guarantee
   monotonicity. It was both unnecessary — with a constant scale a strictly increasing input
   gives a strictly increasing output, by construction — and wrong: the engine reads this clock
   from several threads, so the last writer to the marker is not the reader with the largest raw
   value, and the clamp fired **2,858 times** while the mapping was in fact monotonic. The scaled
   value is now a pure function of the raw one, and continuity across scale changes is handled
   solely in `xh_time_scale_set`.

A fast path skips the lock entirely when scaling is off or the scale is exactly 1.0, because the
engine reads this clock around 800 times per frame — measured at **3,012,117 calls** a few
seconds into a run. Locking every one of those would have turned a timing change into a stutter.

### Added — `noita_time_check`, the pre-flight safety check

Runs with the scale untouched and reports whether the mapping is sound: the raw counter
advances, the mapped value never steps backwards, the mapping is the identity at 1.0, and at
other scales the measured ratio matches the request. **Run it before setting a scale.**

Its first version was misleading and had to be fixed: it compared anchor fields, and
`last_scaled` cannot change while scaling is off, so a healthy disabled hook reported a stale
zero and the check declared the mapping unsound. A check that measures the wrong thing is worse
than no check, because it teaches you to ignore it. It now reads the raw and mapped values
together through `xh_qpc_both`.

### Verified at this release

| Suite | Result |
| --- | --- |
| Lua syntax | 21/21 files compile |
| Mock game | 80/81 checks |
| MCP end to end | 15/15 checks |
| Time scaling, live | 0.514 / 2.0 / 4.0 measured against 0.5 / 2 / 4 requested |
| Frame ceiling, live | 108 fps at 2x, 122 fps at 4x |
| Restoration | scale 1.0 restores the true clock; removal leaves the game running |
| Encoding | no BOMs, no mojibake |

---

## [1.4.1] — 2026-09-24

Time-scale investigation: recorded as **not feasible**, with the attempts and their results, so
it does not get retried from scratch.

### What was tried

**Static analysis first** (`tools/find_timescale.py`, `tools/find_frame_counter.py`):

- The engine keeps time with `QueryPerformanceCounter` / `QueryPerformanceFrequency`. There is
  no `timeGetTime`, and SDL is not the clock.
- **No string in either binary names the concept** — no `timescale`, `time_scale`, `slowmo`,
  `game_speed`, `timestep`, `fixed_dt`. This is the decisive finding: there is no time-scale
  *variable* to find, because the engine has no time-scale concept. "Scaling time" would mean
  editing whichever dt values are used across the frame, wherever they happen to be.
- `1/60` appears as a real constant in 9 places in `.rdata`. The 151 hits in `.text` are
  instruction bytes matching the pattern.
- `GameGetFrameNum`'s name appears twice; the candidate implementations found by following the
  registration pushes and by scanning for `mov reg, [absolute]` near a `ret` are not simple
  getters — one turned out to be a stack-canary check (`xor eax, esp` with the security cookie
  at `0x1152000`). A heuristic that ranks "busiest global" finds security plumbing, not clocks.

**Runtime search:** reading the eight busiest candidate globals and comparing against
`GameGetFrameNum` produced **no match** — the values were 0, 1, and unrelated constants, not
the frame number. A `memscan` over live memory for the frame value reached **92% of 921 MB with
2 hits** and was aborted; at that rate the value has advanced past the needle before the scan
finishes, so a whole-memory search for a moving counter cannot converge.

### Why it stops here

Not because it is dangerous — the risk was accepted — but because it is **not verifiable**:

- A candidate address cannot be confirmed from inside the game. The only available test is
  "does the game advance differently", which a wrong write also produces, while corrupting
  something else.
- The one instrument that could measure a change, `noita_framerate`, **stops when the engine
  stops** — it samples from the bridge's per-frame update, which runs inside the engine's frame
  loop. Verified: pressing ESC froze `state.json` and made `ping` time out six times running.
  So the moment a wrong write freezes the game, the instrument that would report it goes with
  it.
- Reading the counter out-of-band from the DLL's worker thread would fix that, and the attempt
  to locate the counter is recorded above. It did not succeed.

A write that cannot be confirmed and cannot be measured is not a feature, so no time-scale
control is offered. The measurement tool stays, because it answers a different real question:
telling a stopped engine from a stopped bridge.

---

## [1.4.0] — 2026-09-24

Adds the instrument needed before any time-scale work, plus the static analysis behind it.
No behaviour changed. 77 tools.

### Added — `noita_framerate`

Measures the engine's frame acceptance rate against wall-clock time. Two uses:

- **Diagnosis.** "The bridge stopped answering" and "the engine stopped advancing" look
  identical from outside — and measurably are: pressing ESC to open the menu stops the engine,
  and because the bridge runs inside the engine's frame loop it stops too, so `ping` times out
  and no measurement can be read. This tool is the only way to tell the two apart from outside.
- **Acceptance testing for anything that changes how fast the game runs.** The engine keeps
  time with `QueryPerformanceCounter`, so a frame's dt comes from real elapsed time, and a
  change to the effective dt shows up as a divergence between real frames per second and game
  frames per second. Under normal play the two are equal.

Calibrated in a live run: **60 game frames per real second, mean 16.66 ms between frames,
worst 18 ms** over 192 samples. That is the reference any candidate change has to be compared
against, and it is a number rather than an impression — "does the game feel slower" cannot
distinguish a correct write from one that merely stutters, and a wrong write is the failure
mode here.

It samples from the bridge's per-frame update. Its first version used a wait loop, which
cannot work: Lua runs on the game's main thread, so a loop waiting for the frame counter to
advance stops the engine from advancing it.

### Added — `tools/find_timescale.py`

Static analysis, run before any memory write. What it found:

- The engine keeps time with `QueryPerformanceCounter` / `QueryPerformanceFrequency`. There is
  no `timeGetTime`, and SDL is not the clock.
- **No string anywhere names the concept** — no `timescale`, `time_scale`, `slowmo`,
  `game_speed`, `timestep` or `fixed_dt`. That absence is itself the finding: the engine has no
  notion of a time scale, so "scale time" would mean editing whichever dt values are used
  across the frame, not flipping a switch.
- `1/60` appears as a real constant in only **9** places in `.rdata`. The 151 hits in `.text`
  are instruction encodings that happen to match the byte pattern, which is why the script
  reports sections separately instead of dumping one list.

It deliberately produces no candidate address. An xref to a float constant is where a value is
read, not where an authoritative clock lives, and treating one as the other is how a wrong
write gets made.

### Fixed

`ESCAPE` and `ESC` were missing from the scancode table, so any call pressing escape failed
with "unknown key name". SDL scancodes are HID usage codes, not ASCII — A is 4 and ESC is 41 —
and deriving them from the characters is how a wrong one ships unnoticed. The table now says so.

### Verified at this release

| Suite | Result |
| --- | --- |
| Lua syntax | 21/21 files compile |
| Mock game | 75/76 checks |
| MCP end to end | 15/15 checks |
| Frame rate calibration | 60 fps, mean 16.66 ms, worst 18 ms |
| Encoding | no BOMs, no mojibake |

---

## [1.3.0] — 2026-09-24

Documentation for whoever changes this next, including a future version of the author. No
behaviour changed.

### Added — `ENGINE-NOTES.md`

The measured engine facts, each with what it broke and how to avoid it. Every entry is a trap
that looks like something else, and each one cost hours to find:

- SDL2's exported input functions are **7-byte thunks**; a 6-byte prologue analysis puts a
  truncated instruction in the trampoline. Three freezes came from this.
- **`mVelocity` exists on two components.** `CharacterDataComponent.mVelocity` is the pair the
  engine integrates; `VelocityComponent.mVelocity` is a scalar, and writing a pair to it does
  nothing at all. This defeated every velocity-based movement in the project's history and made
  one real measurement impossible to reproduce.
- **`GuiTranslateSet` does not exist.** Inside a `pcall` it failed silently and every pane drew
  at `(0, 0)`, leaving the panel's content area blank.
- The engine **drains the SDL event queue** before a poll sees it, so rewriting polled events
  only works by accident; and returning 1 for an empty queue freezes the machine.
- `ControlsComponent` fields **mirror** input rather than driving it, so patching their reset
  would leave a value the engine never consults.
- Modules are **globals**; `dofile_once` discards return values, so a `local x = {} ... return x`
  module is `nil` everywhere else.
- **`pcall` does not catch access violations** — a bad memory read kills the process, and a
  guard-page walk killed the game once.
- PowerShell's ANSI round-trip **lossily corrupts** non-ASCII text, which is how the Chinese
  documentation and a regex in `server.js` were damaged.
- A hook that installs is not a hook that is called; and a mock's fidelity is part of the test,
  not a given.

### Added — `CONTRIBUTING.md`

The working method: copyable templates for a bridge module, an RPC handler, an MCP tool and an
in-game fixture; the check list to run before committing; the release procedure across the two
copies of the tree; and an explicit list of what not to add — engine claims without a
measurement, mock checks for physics fidelity, silent fallbacks, inference inside the bridge,
and unverifiable memory writes.

### Changed

- The Skill (`mcp-skill/SKILL.md`) now opens with the `ENGINE-NOTES.md` summary, so an agent
  changing the code sees the traps before it starts rather than after.
- Both main READMEs point at the two new documents first.

### Verified at this release

| Suite | Result |
| --- | --- |
| Lua syntax | 20/20 files compile |
| Mock game | 71/72 checks |
| MCP end to end | 15/15 checks |
| Documented tool names | all real |
| Package split | base differs from full only by the extension |
| Encoding | no BOMs, no mojibake |

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

- **base** — pure Lua, no external dependency, 71 tools.
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

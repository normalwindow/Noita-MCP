# Engine notes — measured facts, and the traps they set

Everything here was measured in a running game. None of it is inferred from documentation,
and several entries contradict what the documentation, the naming, or common sense suggests.

This file exists because these are the things that cost the most time to learn, and every one
of them is a trap that looks like something else. Read it before changing anything that
touches input, motion, the GUI or the module system.

Each entry says what was measured, what it broke, and how to avoid it.

---

## Input

### SDL2's exported input functions are 7-byte thunks, not functions

Disassembling `SDL2.dll` shows every exported input function is an import thunk:

```
SDL_PollEvent thunk @ 0x6C75B720:      real implementation @ 0x6C7550F0:
  mov eax, [0x6C80F314]   (5 bytes)      push ebx
  jmp eax                 (2 bytes)      mov ebx, [esp + 8]
  mov esi, esi  <- padding               call ...
```

**The prologue is 7 bytes, not 6.** Hook analysis that counts 6 copies a truncated
instruction into the trampoline, and jumping into it wedges or crashes the process. This
caused three separate freezes before it was found.

**Do:** resolve the IAT slot inside the thunk and hook the real implementation
(`XhResolveRealTarget` in `extension/xinput_hook.c`). Its prologue has clean instruction
boundaries.
**Do not:** hook the address `GetProcAddress` returns. It re-reads its target on every call,
so patching it is both wrong and pointless.

### The engine drains the SDL event queue itself

Measured: `SDL_PollEvent` is called ~100 times/second, but the real poll returned an event on
essentially none of them — `with_event` stayed at 0 across 405 invocations. The engine imports
`SDL_PeepEvents` and takes the queue before the poll sees it.

**Consequence:** a forge that rewrites a *polled* event only ever works by accident, when
something unrelated (a mouse move) happens to be in the queue. That is exactly the reported
symptom: "it works when I move the mouse into the window and not otherwise".

**Do:** synthesise events with `SDL_PushEvent` from the bridge's per-frame update.
**Do not:** rely on rewriting what `SDL_PollEvent` returns.

### Never change a poll's return value

An intermediate attempt supplied an event and returned 1 when the queue was empty. **It froze
the machine.** The engine's loop is:

```c
while (SDL_PollEvent(&e)) { handle(e); }
```

A poll that never returns 0 is a loop that never ends.

**Do:** let SDL compute the return value. Push events instead, which leaves every return value
untouched.

### Never call `SDL_PushEvent` from inside a hook

The poll hook runs while SDL holds the event-queue lock. Pushing from there re-acquires it and
deadlocks.

**Do:** push from the bridge's update, which runs outside SDL entirely.

### Never hook `SDL_PumpEvents`

It runs every frame, may run on several threads, and may re-enter SDL's input path. A
trampoline hook there risks unbounded recursion. This was the first cause of a hang.

### A key hold is a stream, not an edge

Three delivery strategies were tried before one worked:

| Strategy | Result |
| --- | --- |
| one key-down | ignored; the engine advanced no input state |
| one edge pair (down, then up) | ignored |
| **one key-down per frame, with `repeat` set** | **works** |

A physical keyboard behaves the third way, because the OS repeats key-down while a key is
held. Mirror that.

### `ControlsComponent` fields are a mirror of input, not a driver

Writing `mButtonDownFire = true` reads back as true in the same Lua call and reverts across a
frame; holding it for 60 frames leaves `mButtonFrameFire` at 0 and casts no shot. Patching the
engine's reset does not help either — it would leave a value the engine never consults.

**Do not** spend time trying to drive the player by writing control fields.

### The keyboard does not go through `SDL_PollEvent`

Measured with a hook on the real `SDL_PollEvent`: it is called every frame, and
`real_key_events` stayed 0 **while a human physically pressed keys** and the engine's own
`mButtonFrameFire` advanced. Check the counter before forging; if it does not grow when a
human types, the hook is on the wrong function.

### Interact is `E`, fire is the left mouse button

`E` is the interact key — confirmed by watching `mButtonFrameInteract` while probing
candidates; every other candidate left it unchanged. **`SPACE` is the fly key and produces no
shot.** Firing is the left mouse button, which is why the input tools synthesise mouse events.

---

## Motion

### `mVelocity` exists on TWO components, and only one is a vector

This is the single most expensive trap in this file.

| Component | Shape | Writing `{x, y}` moves the player? |
| --- | --- | --- |
| `CharacterDataComponent.mVelocity` | a **pair** `(0, 60)` | **yes** — measured 171.4 px |
| `VelocityComponent.mVelocity` | a **scalar** `0` | **no** — measured 0.0 px, silently |

Same field name, different components, and writing a pair into the scalar one does nothing at
all — no error, no warning.

**Do:** write motion to `CharacterDataComponent.mVelocity`.
**Do not** trust a field name to identify a component. Enumerate the fields of each candidate
component and check the shape before writing:

```lua
local ok, a, b = pcall(ComponentGetValue2, comp, "mVelocity")
-- b ~= nil means it is a pair; b == nil means it is a scalar and a pair write will not work
```

This bug defeated every velocity-based movement in this project for its whole history and made
one earlier measurement (126px, real) impossible to reproduce. Both were correct; they wrote to
different components.

### Velocity writes are respected, position writes are teleports

30 frames of `vx = 250` displaced the player 126.3px — that is 250/60 px per frame, a movement
speed, not a jump. A large write is a teleport that skips collisions.

**Do:** use a modest magnitude (~220) and let the engine integrate it.
**Do not:** write a large velocity to "get there faster".

---

## GUI

### There is no translate call

`GuiTranslateSet` **does not exist** in Noita's GUI API. Using it inside a `pcall` fails
silently, and every pane drew at `(0, 0)` — the visible content area was simply empty. This was
an invented function.

**Do:** pass an origin to the drawing code and add it to every coordinate. The compiler cannot
catch a call to a function that does not exist, but a name check can:
`tools/check_game_api.js` verifies every `Gui*` call site against the game's own
`tools_modding/lua_api_documentation.txt`.

Run it after touching any GUI code.

### `GuiImageNinePiece` fills its rectangle

The 9-piece decoration has an **opaque centre**. A low tint does not make it transparent, so a
panel sized 620x620 covered most of the screen. Size the backdrop to the content, not to the
screen.

### `GuiBeginScrollContainer` may render nothing

It was tried for the log pane and appeared to draw no content, with no way to tell from inside
the game whether the API or the call was at fault. The pane now draws the newest rows that fit
and reports how many it is holding back — fewer rows, but never a blank page.

If you need it, verify with `tools/check_game_api.js` that the call exists, then test what it
actually renders before building on it.

### A button needs its own label

An empty `GuiButton` with a separate `GuiText` label painted over it produces a visible label
that **is not clickable** — the hit area is an invisible rectangle underneath the text.

**Do:** one `GuiButton` whose argument is the visible text.

---

## Lua modules

### Modules are globals, not returned values

Every module in `files/bridge/` follows the same shape:

```lua
macro = macro or {}      -- global
function macro.start() ... end
```

`init.lua` loads them with `dofile_once`, which **discards the return value**. A module written
as `local terrain = {} ... return terrain` loads without error and is then `nil` everywhere else
— every call to `terrain.grid()` fails as "attempt to index a nil value (global 'terrain')".

**Do:** declare the module as a global with the `x = x or {}` guard, and no trailing `return`.

### `dofile_once` ignores the return value

Corollary of the above: do not try to capture anything from it.

---

## Memory

### `pcall` does not catch access violations

A hand-written memory scanner walked into a guard page and the game died with
`STATUS_GUARD_PAGE_VIOLATION (0x80000001)`. `pcall` catches Lua errors, not SEH.

**Do:** copy the region into a private buffer with `ffi.copy` and search that, incrementally,
with a per-frame time budget. `files/bridge/memscan.lua` does this and skips guard and
no-access pages.

### The module base is 0x400000 and there is no ASLR

Static addresses in `noita.exe` were verified byte-for-byte at runtime. This makes static
analysis reliable — and makes a wrong write reliably fatal.

---

## Tooling

### PowerShell 5.1 corrupts non-ASCII text

`Set-Content -Encoding utf8` writes a BOM, and a `Get-Content`/`Set-Content` round-trip on a
UTF-8 file read as ANSI (CP936 on this machine) turns Chinese into mojibake. That damage is
**lossy and was not reversible** — the affected files had to be rewritten from scratch.

It also hit `server.js`: a regex prefix in `parseSimWarnings` was corrupted, so it never matched
the wand simulator's warning and a cross-check silently never fired. Git history had the same
damage, so there was no clean copy to restore.

**Do:** use the file tools, or Node, for any file containing non-ASCII text.
**Do not** pipe non-ASCII through `Set-Content` or a here-string.

`tools/check_encoding.js` fails on both a BOM and mojibake. Run it before committing
documentation.

### Verify which build is actually running

The same test passing and then failing with no code change is a deployment problem, not a logic
problem. `xh_build_id()` exists for this. Check it before debugging behaviour.

### A hook that installs is not a hook that is called

Two cycles were lost to hooks that installed cleanly on `SDL_GetKeyboardState` and
`SDL_GetMouseState` and were never called once — the engine does not import those functions at
all. Every hook now has a call counter, and the counters are what disproved `SDL_PollEvent` as
the keyboard path.

**Do:** measure "is it called", not "is it installed".

### A mock's fidelity is part of the test

Two terrain checks were written, failed, and removed rather than debugged. They asserted wall
and liquid classification against a mock ray model, and making that model match the real one
became more work than the checks were worth — the real `Raytrace` works at cell granularity, so
a ray ending "inside" a wall and one crossing it are the same event to the engine and different
events to the mock. Those assertions were testing the mock, not the code.

**Do:** verify engine-behaviour claims against a live game. Use the mock for logic, gating and
regressions, not for physics fidelity.

### The mock cannot pass table arguments (fixed, but worth knowing)

The harness converted table arguments to `undefined`, so any mock helper taking a table saw no
argument at all — which read as "the store is broken" rather than "the harness cannot pass
tables". If a mock helper receives nothing when you passed a table, check the harness first.

---

### `mButtonFrameKick` is a FRAME NUMBER, not a counter

The name reads like a count and is not one. It holds the frame the kick last happened on, so
the way to test "did a kick just happen" is whether the value is close to `GameGetFrameNum()`,
not whether it went up.

Both wrong readings were tried and both produced confident nonsense: comparing raw differences
called a 2405-frame gap a pass, and treating the same gap as a count called it a failure. Neither
was measuring anything. Sampled immediately after a kick: `frame 8757, kick 8757, down true` —
a gap of zero; the field then freezes while the gap grows.

Measured this way, `noita_macro kick` produces the signature real input does, four runs out of
four, at a gap of 0. The macro's own `ok` is not evidence of that: it means the extension handed
an F key-down to SDL, and a pushed key is not an executed action.

### The kick button is confirmed against real input, not assumed

With the extension armed and no input, every control field reads 0. A human pressing F moves
`mButtonFrameKick` and `mButtonDownKick`. `mButtonFrameKick` is now reported by
`noita_controls_snapshot` for exactly this reason — so a caller can confirm a kick reached the
game instead of trusting that a key was pushed.

The field is `Kick`, not `Throw`. Both were watched together; a physical kick moves only the
first, and `mButtonDownAction`/`mButtonFrameAction` do not exist on this component at all.

## Things that are NOT possible, verified

- **Driving the player through control fields.** They mirror input; the engine overwrites them.
- **Reading a cell's material.** There is no `GetMaterial` or `GetCell`; `CellFactory_*` only
  goes id → name. Terrain must be inferred from raytraces, so it reports reachability and never
  material names.
- **Time scaling.** It works, but not by finding a time variable — see below. The Lua API has no
  setter; the clock has to be intercepted in the DLL.
- **Firing the wand without the input extension.** Nothing in the physics state is a button
  press. `noita_macro` refuses such a macro rather than appearing to run it.

### Time scaling: how it works, and the two ways the first attempt wedged the game

**The engine has no time-scale variable. It asks Windows what time it is, every frame, and
integrates the answer.** An earlier attempt to find a variable was searching for something that
does not exist. What you change is the answer.

`noita.exe` imports `QueryPerformanceCounter` and `QueryPerformanceFrequency` **directly from
KERNEL32**, not through SDL. That decides where to hook: kernel32's function is called by every
caller in the process, including SDL. Hooking an SDL export would miss the engine's own calls
entirely. Both were read from the import tables rather than assumed.

Two mistakes, both of which froze the game, and both worth not repeating:

1. **An anchor of zero makes the clock jump backwards.** The first version stored only a scaled
   origin and set it lazily, so the first value after enabling a 0.25x scale was
   `raw * 0.25` — the counter fell by about 10^13 ticks at the moment the scale was applied.
   The engine paces frames off this counter, so it waited for a deadline it had already passed.
   Store the **raw** anchor alongside the scaled one and map as
   `scaled_anchor + (raw - raw_anchor) * scale`; that is continuous at the instant the scale
   changes, and re-anchoring belongs where the scale changes and nowhere else.
2. **Do not clamp a clock against a shared high-water mark.** Guaranteeing monotonicity with a
   global "last value" is wrong when several threads read the clock: the last writer is not the
   reader with the largest raw value. It fired **2,858 times** on a mapping that was in fact
   monotonic. With a constant scale the formula is monotonic by construction, so the clamp was
   never needed.

Also: this clock is read roughly **800 times per frame** (3,012,117 calls a few seconds into a
run), so a hook that takes a lock on every call turns a timing change into a stutter. Skip the
lock unless a scale other than 1.0 is actually active.

And a per-frame counter is not how you measure a speed-up: the engine has a **frame-rate
ceiling**. Measured — 2x gave 108 fps, 4x gave 122 fps, while the true ratio was 2.0 and 4.0.
Compare elapsed game time against elapsed real time instead, reading both through the hook
(`xh_qpc_raw` bypasses it).

### Why time scaling was not pursued further, and what would change that

Recorded so it is not retried from scratch. The full account is in `CHANGELOG.md` under 1.4.1.

The static analysis found **no string anywhere naming the concept** — no `timescale`,
`time_scale`, `slowmo`, `game_speed`, `timestep`, `fixed_dt`. That absence is the finding:
there is no time-scale *variable* to locate, because the engine has no time-scale concept.
`1/60` exists as a real constant in 9 places in `.rdata`, and "scaling time" would mean editing
whichever of those the frame happens to use.

Two further attempts and their results:

- Following `GameGetFrameNum`'s registration pushes, and scanning for `mov reg, [absolute]`
  near a `ret`, produced candidates that are not simple getters. The busiest candidate global
  (`0x1152000`) is the **stack canary** — the code around it is `xor eax, esp`, the
  `/GS` cookie check. A heuristic of "the most-read global" finds security plumbing, not clocks.
- Reading the eight busiest candidates and comparing against `GameGetFrameNum` gave **no
  match** (values 0, 1, and unrelated constants). A `memscan` for the live frame value reached
  **92% of 921 MB with 2 hits** before being aborted: the counter advances past the needle
  before the scan finishes, so a whole-memory search for a moving counter cannot converge.

**What would change the conclusion:** finding the counter's address by another route — for
instance from a debugger with symbols, or by pattern-matching the frame-advance code rather than
the getter — so that `noita_framerate` could read it from the DLL's worker thread instead of from
the engine's frame loop. That is the actual blocker: the measuring instrument currently stops
when the engine stops, so a wrong write freezes the game *and* the instrument that would report
it. Fix that first, and a careful attempt becomes worth making.

Two things are needed before a write is acceptable, and neither is in place:

1. **An out-of-band counter read**, so a frozen engine can still be measured.
2. **A write that can be undone**, so a wrong guess costs a restart rather than the run.

A write that cannot be confirmed and cannot be measured is not a feature.

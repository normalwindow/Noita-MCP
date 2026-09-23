# Input Hook — the optional extension that unlocks input control

This is the **extension** half of the mod. The base mod is pure Lua and works without
it; this adds the one capability pure Lua cannot have: **forging the player's input**,
so the AI can move, jump, and fire the wand.

## What it adds

| Capability | MCP tool | Verified |
| --- | --- | --- |
| Hold a movement key | `noita_input_move` | `vx = ±56.6` (symmetric left/right) |
| Press any key (jump, interact, hotbar) | `noita_input_key` | works via the same path |
| **Fire the held wand** | `noita_input_fire` | engine's own `mButtonFrameFire` advances |
| Release everything | `noita_input_release` | — |

Measured end-to-end: baseline `vx = 0.00`, forged right `+56.69`, forged left `-56.69`,
and the engine's own `mButtonFrameFire` moved when a mouse click was forged.

## How it works, and why this way

SDL2's exported input functions are **not the real functions**. Every one is a 7-byte
import thunk:

```
SDL_PollEvent thunk @ 0x6C75B720:      real implementation @ 0x6C7550F0:
  mov eax, [0x6C80F314]   (5 bytes)      push ebx
  jmp eax                 (2 bytes)      mov ebx, [esp + 8]
  mov esi, esi  <- padding               call ...
```

The prologue is **7 bytes, not 6**. Hooking the thunk with a 6-byte analysis cut
`jmp eax` in half and put a truncated instruction in the trampoline, which hangs or
crashes the process. `XhResolveRealTarget()` reads the IAT slot inside the thunk and
hooks the real implementation instead.

**Forging is done by synthesis, not by interception:**

```
bridge frame update  →  xh_push_key / xh_push_mouse  →  SDL_PushEvent  →  SDL's queue
                                                                            ↓
engine's next poll  ←──────────────  a normal event, from the normal path
```

This design is what makes it safe, and it took several failed approaches to reach:

| Approach | Result |
| --- | --- |
| Rewrite a polled event | Only worked when the operator happened to move the mouse: the engine drains the queue first, so `with_event` was 0 across 405 calls |
| Supply an event from the hook and return 1 | **Froze the machine.** The engine's loop is `while (SDL_PollEvent(&e))`; a poll that never returns 0 never ends |
| Hook `SDL_PeepEvents` | Zero calls — the engine does not import it into its input path |
| **Push real events into SDL's queue** | **Works.** Return values are SDL's own, so the deadlock cannot occur, and the struct is built by SDL so there are no hand-written offsets to get wrong |

### The locking rule (not optional)

`SDL_PushEvent` **must not be called from inside a hook.** The poll hook runs while
SDL holds the event-queue lock, so pushing from there would re-acquire it and
deadlock. The bridge therefore pushes from its per-frame update, which runs outside
SDL entirely.

## Install

```powershell
# 1. build (needs the 32-bit MSVC toolchain; build.ps1 calls vcvars32 itself)
cd agent\extensions\input-hook
.\build.ps1                 # prints BUILD OK and verifies the DLL is 32-bit

# 2. make it available to the mod
copy build\xinput_hook.dll "<Noita>\mods\noita_agent\extensions\"

# 3. in a running game, load and arm it
node dist\mcp_server\server.js --call noita_input_load
node dist\mcp_server\server.js --call noita_input_install
```

Then `noita_capabilities` reports `mode: "full (input extension loaded)"`.

## Safety properties

* **Loading is inert.** `DllMain` only resolves pointers; nothing is hooked until
  `xh_install_hooks` / `xh_install_keyboard_only` is called explicitly. Simply having
  the DLL in the folder cannot change the game's behaviour.
* **All-or-nothing install.** If any hook fails to analyse or install, all of them are
  rolled back. A partial set would be worse than none.
* **Heartbeat watchdog.** Once hooks are installed, a background thread removes them
  if Lua stops calling `xh_heartbeat` every frame. A wedged frame loop therefore
  recovers by itself after a few seconds instead of leaving input hijacked.
* **Holds are bounded.** A key or mouse hold expires on its own after its frame
  count; `noita_input_release` ends it early.
* **Nothing is written to disk** except small status markers next to the DLL. Remove
  the DLL, or restart the game, and everything is gone.
* **`SDL_PumpEvents` is deliberately never hooked.** It runs every frame, may run on
  several threads, and may re-enter SDL's input path, so a trampoline hook there risks
  unbounded recursion. This was the first cause of a hang; excluding it removed the
  whole class.

## When something looks wrong

Read the markers next to the DLL first — they exist so behaviour is not guessed at:

| File | Tells you |
| --- | --- |
| `xh_status.txt` | build id, whether hooks are installed |
| `xh_loaded.txt` | the resolved hook target and its prologue length |
| `xh_watchdog_fired.txt` | the watchdog removed the hooks because Lua stopped |

`xh_build_id()` answers "which build is actually running" — the same test passing and
then failing with no code change is a deployment problem, not a logic one.

Call counters distinguish "installed" from "actually used":
`xh_event_calls`, `xh_peep_calls`, `xh_push_ok`, `xh_push_fail`, and
`xh_event_real_seen` (which must grow when a human presses a key).

## Uninstall

Delete `xinput_hook.dll` from `mods\noita_agent\extensions\` and restart. Nothing else
was modified; the game files are untouched.

## Known limits

* Only keyboard and mouse-button events are synthesised. Analog sticks are not.
* Aiming is done by choosing the click coordinate on the mouse event, which the engine
  derives its aim vector from. That has been exercised for firing but not yet
  validated against a specific target.
* The DLL is unsigned, so an antivirus may flag it. It is rebuilt locally from
  `xinput_hook.c` in this folder; read the source rather than trusting the binary.
* A game update could move the thunk layout. The resolution is signature-based (it
  follows the `mov eax, [imm32]; jmp eax` form), so it should survive, but re-verify
  with the counters if input stops working.

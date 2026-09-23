# Noita MCP 鈥?full version (base + input extension)

The full tier is everything in the [base version](../base/README.en.md) plus
`xinput_hook.dll`, a 32-bit Windows DLL that is loaded into the game process by the mod itself
and synthesises SDL keyboard and mouse events. It brings the tool count to **64**: the base
tier's 55 tools plus 9 `noita_input_*` tools. With it, the AI can move, jump, press interact,
and fire the held wand; without it, none of those are possible 鈥?see the base readme for why.

Chinese documentation: [README.md](README.md). Main readme: [../README.en.md](../README.en.md).

## Requirements

Everything the base tier requires, plus:

| Requirement | Notes |
| --- | --- |
| 32-bit MSVC toolchain | The DLL must match the 32-bit game process. `build.ps1` calls `vcvars32` itself. |
| Windows PowerShell 5.1 or PowerShell 7+ | Both are supported; the build script avoids PS7-only syntax. |

Only the DLL needs the toolchain. Once built, the DLL can be copied to another machine.

## Build the DLL

```powershell
cd <repo>\full\extension
.\build.ps1
```

The output is `full\extension\build\xinput_hook.dll`. The script reads back the PE COFF header
of the artefact and asserts `Machine == 0x014C` (32-bit), so a wrong-architecture build fails
loudly instead of producing a DLL the game cannot load.

| Switch | Effect |
| --- | --- |
| `-Clean` | Delete build output first |
| `-DllOnly` | Build the DLL, skip the standalone injector |
| `-DebugBuild` | `/Od /Zi` instead of `/O2` (the switch is not `-Debug`, which is reserved) |

`injector.c` is also built by default. It is a standalone 32-bit injector and is **not** used by
the normal install: the mod loads the DLL through its own LuaJIT FFI, so no external injector is
needed.

## Install and arm it

1. Copy the DLL where the mod can find it:

   ```text
   full\extension\build\xinput_hook.dll   ->   <Noita>\mods\noita_agent\extensions\
   ```

   `<Noita>` is the folder containing `noita.exe`.

2. Keep the base install unchanged: mod enabled, MCP server configured, a **run in progress**.

3. Load, then arm, using the MCP tools in this order:

   ```text
   noita_input_load      # maps the DLL into the game process. INERT.
   noita_input_install   # installs the hooks and enables forging
   ```

   **Loading is inert.** `DllMain` only resolves pointers; nothing is hooked until
   `noita_input_install` is called. Merely having the DLL in the folder cannot change the game's
   behaviour. `noita_input_load` is safe to call again when it is already loaded.

4. Verify:

   ```text
   noita_capabilities   ->  mode: "full (input extension loaded)"
   noita_input_status   ->  loaded / armed state, event counters, current holds
   ```

When the status is wrong, read the marker files the extension writes next to the DLL:
`xh_status.txt`, `xh_loaded.txt`, `xh_watchdog_fired.txt`. They exist so behaviour is not
guessed at. The call counters distinguish "installed" from "actually used"
(`xh_event_calls`, `xh_peep_calls`, `xh_push_ok`, `xh_push_fail`, `xh_event_real_seen`).

## The 9 tools it adds

| Tool | Purpose |
| --- | --- |
| `noita_input_move`, `noita_input_key` | Hold a movement direction; press a key (jump `SPACE`, interact `E`, hotbar numbers) |
| `noita_input_fire`, `noita_input_click` | Fire the held wand; click at a coordinate the engine derives its aim from |
| `noita_input_release` | Release every current hold |
| `noita_input_status` | Extension state, event counters, active holds |
| `noita_input_load`, `noita_input_install`, `noita_input_uninstall` | Load the DLL (inert), arm the hooks, disarm them |

## Verified input results

Measured end-to-end in a live game:

| Action | Method | Measured result |
| --- | --- | --- |
| Move right | Hold `D` | `vx = +56.84` |
| Move left | Hold `A` | `vx = -56.81` |
| Fire the held wand | Hold the **left mouse button** | The engine's own `mButtonFrameFire` counter advances |
| Fly | `SPACE` | Key event delivered through the same path |
| Interact | `E` | Key event delivered through the same path |

The two movement results are symmetric against a zero baseline. Firing is on the left mouse
button because that is what Noita fires on; `SPACE` is the fly key, and pressing it does not
fire. Confirming that the engine's own `mButtonFrameFire` counter advances is what separates
"an event was queued" from "the game reacted to it".

## How it works

The extension does not intercept input. It **synthesises** events into SDL's own queue from the
bridge's per-frame update, so the engine receives a normal event through the normal path:

```text
bridge frame update  ->  xh_push_key / xh_push_mouse  ->  SDL_PushEvent  ->  SDL's queue
                                                                                  |
engine's next poll   <-----------------  a normal event, from the normal path ----+
```

SDL2's exported input functions are 7-byte import thunks (`mov eax, [imm32]; jmp eax`), not the
real implementations, so the extension resolves the real target inside the thunk and hooks that
instead. `SDL_PushEvent` is never called from inside a hook: the poll hook runs while SDL holds
the event-queue lock, and pushing from there would re-enter it; the push happens from the frame
update, outside SDL entirely.

## Safety design

| Property | Detail |
| --- | --- |
| Inert loading | `DllMain` resolves pointers only. Nothing is hooked until `noita_input_install`. |
| All-or-nothing install | If any hook fails to analyse or install, every hook is rolled back. A partial set would be worse than none. |
| Heartbeat watchdog | A background thread removes the hooks if Lua stops calling `xh_heartbeat` every frame, so a wedged frame loop recovers by itself after a few seconds instead of leaving input hijacked. |
| Bounded holds | Every key and mouse hold expires on its own after its frame count; `noita_input_release` ends it early. |
| `SDL_PumpEvents` never hooked | It runs every frame, may run on several threads, and may re-enter SDL's input path; a trampoline there risks unbounded recursion. It is excluded deliberately. |
| No disk persistence | Nothing is written to disk except small status markers next to the DLL. Remove the DLL or restart the game and everything is gone. |
| Game files untouched | No game binary is modified. The hook lives in the loaded process only. |

## Uninstall

1. Call `noita_input_uninstall` to remove the hooks and disarm. The game keeps running.
2. Delete `xinput_hook.dll` from `<Noita>\mods\noita_agent\extensions\`.
3. Restart the game for a clean state.

A game restart alone is also sufficient: the DLL is never persisted into the game's files, so
nothing survives the process. To remove the whole bridge, follow the uninstall steps in the
[base readme](../base/README.en.md).

## Known limitations

- Only keyboard and mouse-button events are synthesised. Analog sticks are not.
- Aiming is done by choosing the click coordinate on the mouse event, which the engine derives its aim vector from. This has been exercised for firing but not validated against a specific target.
- The DLL is unsigned, so antivirus software may flag it. It is built locally from `xinput_hook.c` in this folder; read the source rather than trusting the binary.
- A game update could move the thunk layout. Target resolution is signature-based (it follows the `mov eax, [imm32]; jmp eax` form) and should survive, but re-verify with the counters if input stops working.
- Input only affects a live run. The bridge and the extension both do nothing in the main menu.

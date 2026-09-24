# Noita MCP

An MCP (Model Context Protocol) server plus a Noita mod that lets an AI observe and control a
**running** Noita game over a local bridge.

Chinese documentation: [README.md](README.md)

The AI talks MCP over stdio to a Node.js server, which talks to a mod inside the game; the mod
executes the request in Lua and returns the result. Nothing leaves the machine: the bridge
listens on `127.0.0.1` only.

## What it is

Two pieces, always installed together:

- **The mod** (`noita_agent`, "Noita MCP Agent Bridge") —runs inside Noita, is the only thing that can touch the game, and exposes a small local RPC surface: player, inventory, wands, spell decks, entities, world/map data, and the permission switches.
- **The MCP server** (`mcp_server/server.js`) —a stdio MCP server that translates `noita_*` tool calls into bridge RPCs and returns structured JSON. It also has a CLI for humans (`--status`, `--list`, `--call`).

Because the game only updates while a run is active, the bridge only answers inside a run.
Nothing works from the main menu.

## Two tiers

| | Base | Full |
| --- | --- | --- |
| Contents | Pure Lua, no DLL | Base + input extension DLL |
| MCP tools | 76 (all registered; the 9 input tools refuse without the extension) | 76 |
| External dependencies | None | Built DLL (x86) |
| Observe the game | Yes | Yes |
| Modify player, items, wands, world | Yes | Yes |
| Forge input (move, jump, fire) | **No** —impossible from Lua | Yes |
| Build toolchain needed | None | 32-bit MSVC (for the DLL only) |

**Base** uses the mod's own LuaJIT FFI to open a socket on `127.0.0.1`, with a file-based bridge
as a fallback when sockets are unavailable. It needs nothing but Node.js and the game. **Full**
adds `xinput_hook.dll`, a 32-bit Windows DLL the mod loads into the game process through that
same FFI —no external injector is needed —and which synthesises SDL keyboard and mouse events
so the AI can move, jump, and fire.

## Which tier to use

- Start with **base** to see and change state: read the run, inspect wands and spells, spawn items, edit decks, teleport, heal, read the map.
- Add **full** when the AI must actually *play*: hold a movement key, jump, press interact, fire the held wand.
- Base cannot forge input at all —Noita's C++ cannot be modded from Lua, which is exactly why the extension DLL exists.
- Base can still write the player's velocity directly (`noita_lever_*`); that is a physics lever, not input. See [base/README.en.md](base/README.en.md).

## Requirements

| Requirement | Notes |
| --- | --- |
| Windows | The game and the bridge are Windows-only |
| Noita (Steam) | Any current version; the mod folder must be writable |
| Node.js 18 or newer | Runs the MCP server; no npm packages are installed |
| MCP client | Any client that can launch a stdio server |
| 32-bit MSVC toolchain | **Full tier only**, to build the DLL; `build.ps1` calls `vcvars32` itself |
| Unpacked game data | **Optional**, only for `noita_entity_blueprint` and index rebuilding |

## Install —base tier

1. Copy the mod into the game's mod folder:

   ```text
   base\mod\noita_agent   ->   <Noita>\mods\noita_agent
   ```

   `<Noita>` is the folder containing `noita.exe` (for example
   `D:\Sware\Steam\steamapps\common\Noita`).

2. Start Noita, open **Mods**, and enable **Noita MCP Agent Bridge**.

3. Point your MCP client at the server. Use absolute paths, and escape backslashes for JSON:

   ```json
   {"type":"stdio","command":"node","args":["<abs path>/base/mcp_server/server.js"],"env":{"NOITA_DIR":"D:\\Sware\\Steam\\steamapps\\common\\Noita"}}
   ```

   `NOITA_DIR` must be the folder that contains `noita.exe`. With it set, the server finds the
   mod's `run\` folder and the fallback transport on its own.

4. Start or continue a run, then check the bridge:

   ```powershell
   node "<abs path>\base\mcp_server\server.js" --status
   ```

   `bridge_live: true` means the game is answering.

`base\install.ps1` is a helper that performs the copy and enables the mod in
`mod_config.xml`. The manual steps above are the authoritative path and always work.

## Install —full tier

Do everything above, then build and arm the extension.

1. Build the DLL (it calls `vcvars32` itself, so run it from a normal shell):

   ```powershell
   cd <repo>\full\extension
   .\build.ps1
   ```

   Output: `full\extension\build\xinput_hook.dll`. The script asserts the artefact is 32-bit.

2. Copy it where the mod can load it:

   ```text
   full\extension\build\xinput_hook.dll   ->   <Noita>\mods\noita_agent\extensions\
   ```

3. With a run in progress, call two MCP tools, in this order:

   ```text
   noita_input_load      # maps the DLL into the game process; INERT, hooks nothing
   noita_input_install   # arms it: installs the SDL hooks
   ```

   Loading alone changes nothing; only `noita_input_install` makes forging possible, and `noita_input_uninstall` removes it again.

4. Confirm the mode:

   ```text
   noita_capabilities  ->  mode: "full (input extension loaded)"
   ```

Details, safety design, and verified measurements: [full/README.en.md](full/README.en.md).

## Verified capabilities

Everything below was measured against a live game, not inferred from the API surface.

### Observation and modification

Read the player (position, velocity, hp, mana, perks, effects, biome), the inventory and held
item, wands and spell decks, nearby entities, materials, spells and perks. Modify the player's
position, health and attributes, add gold, apply status effects, spawn items, potions, spells
and wands, edit wand decks and wand stats, switch the held item, pick items up, drop items and
launch projectiles.

### Input forging (full tier only)

| Action | How it is done | Measured result |
| --- | --- | --- |
| Move right | Hold `D` | `vx = +56.84` |
| Move left | Hold `A` | `vx = -56.81` |
| Fire the held wand | Hold the **left mouse button** | The engine's own `mButtonFrameFire` counter advances |
| Fly | `SPACE` | Key event delivered through the same path |
| Interact | `E` | Key event delivered through the same path |

The left/right results are symmetric against a zero baseline. Firing is on the left mouse
button because that is what Noita fires on; `SPACE` is the fly key, not the fire key.

### World and map

- Biome name, the biome's file path, and depth within the biome.
- Parallel-world coordinates, orb counts, NG+ level.
- Camera rectangle, and a 9x9 fog-of-war sample.

### Entity catalog

About 3030 entity definitions, searchable by name, tag and kind: 651 enemy, 452 projectile, 212
item, 169 building, 27 wand, 5 chest (the remainder are other kinds). `noita_find_entity`
searches the index; `noita_entity_blueprint` reads one entity's components and their values from
the unpacked game data —that is where enemy stats live.

### Spell charges

`uses_remaining` is readable per card in a wand deck. Measured: FIREBALL 15/15, BLACK_HOLE 3/3,
DYNAMITE 16/16, ROCKET 10/10, LIGHT_BULLET unlimited. In the game data `-1` means unlimited.

## Game data and licensing

The game's `data\` folder does **not** ship the individual entity XML files. They are packed
inside `data\data.wak` (40.5 MB). `noita_entity_blueprint` therefore needs the game data
unpacked locally; without it, that one tool reports that unpacked data was not found and the
rest of the server keeps working.

`tools\unpack-data.ps1` unpacks it using the game's own supported switch:

```powershell
.\tools\unpack-data.ps1 -NoitaDir "D:\Sware\Steam\steamapps\common\Noita"
# runs:  noita.exe -wizard_unpak
```

**This repository deliberately does not bundle the game data.** The Noita Modding Agreement
forbids distributing "a substantial part of our copyrightable code, content, assets", and the
unpacked definitions are exactly that. Instead the data is produced locally, from a copy the
user already owns, by the game's own unpack mode.

Two consequences worth knowing:

- Point the server at your unpacked data with `NOITA_REF_DATA=<Noita>\data` if it does not find it automatically through `NOITA_DIR`.
- `tools\build_index.py` regenerates `entity_index.json` from **your own** unpacked data. The shipped index is a build artefact of that script; search (`noita_find_entity`) works from it with no unpacked data at all, blueprint reads do not.

## Known limitations

| Limitation | Detail |
| --- | --- |
| "Unsafe mod" warning | The mod needs `request_no_api_restrictions="1"` to use `os` and `io` for sockets and files, so Noita shows its sandbox warning. This is inherent to the approach and cannot be removed. |
| Base cannot forge input | Noita's C++ cannot be modded from Lua: writes to the game's control fields are overwritten by the engine every frame. The extension DLL exists for this reason. |
| Keyboard and mouse buttons only | The extension synthesises key and mouse-button events, not analog sticks. |
| Unsigned DLL | Antivirus software may flag `xinput_hook.dll`. It is built locally from the included `xinput_hook.c`; read the source rather than trusting the binary. |
| Bridge lives only inside a run | In the main menu, in menus, or in a paused game the bridge does not answer. Start or continue a run first. |
| One frame per call | The mod answers once per game frame (about 16.7 ms). Batch independent calls with `noita_batch` when latency matters. |
| Aiming | Mouse aiming is done by choosing the click coordinate; it has been exercised for firing but not validated against a specific target. |

## Verification

The project ships four test suites:

| Suite | Result |
| --- | --- |
| Lua syntax | 18/18 files compile |
| Mock game | 41/42 checks |
| MCP end-to-end | 15/15 |
| Live smoke test against a running game | 23/23 |

The mock-game suite has one known failing check; it is reported as such rather than excluded.

## Repository layout

```text
Noita-MCP/
  README.md            main readme (Chinese; links to README.en.md)
  README.en.md         this file
  base/                pure-Lua version
    README.md  README.en.md
    install.ps1
    mod/noita_agent/...        the mod, copied into <Noita>/mods/
    mcp_server/server.js       MCP stdio server
    mcp_server/entity_index.json
  full/                base + input extension
    README.md  README.en.md
    install.ps1
    extension/xinput_hook.c, injector.c, build.ps1, build/xinput_hook.dll
    mod/...  mcp_server/...
  mcp-skill/           the agent Skill (SKILL.md) + README
  tools/               unpack-data.ps1, verify.ps1, build_index.py, search_entities.js, entity_index.json
```

`full\extension\injector.c` builds a standalone 32-bit injector. The normal install does not
use it: the mod loads the DLL itself through FFI.

## Documentation

**Start with these two if you are going to change anything:**

- [ENGINE-NOTES.md](ENGINE-NOTES.md) — measured engine facts and the traps they set. SDL2's
  exports are 7-byte thunks; `mVelocity` exists on two components and only one of them is a
  vector; `GuiTranslateSet` does not exist; modules are globals, not returned values. Each entry
  says what was measured, what it broke, and how to avoid it.
- [CONTRIBUTING.md](CONTRIBUTING.md) — the working method, with templates for a bridge module,
  an RPC handler, an MCP tool and an in-game fixture, plus the check list to run before
  committing.

Then:

- [base/README.en.md](base/README.en.md) — base tier: install, tool groups, limits, troubleshooting
- [full/README.en.md](full/README.en.md) — full tier: building and arming the DLL, safety design, uninstall
- [mcp-skill/README.en.md](mcp-skill/README.en.md) — the agent Skill and how to install it
- [README.md](README.md) — Chinese main readme
- [CHANGELOG.md](CHANGELOG.md) — what changed in each release
- [LICENSE](LICENSE) — Apache License 2.0
- [NOTICE](NOTICE) — third-party notices

## License

**The code in this repository is licensed under the [Apache License 2.0](LICENSE).**

```
Copyright 2026 normalwindow

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

### About Noita

This is an **unofficial, non-commercial fan work**. Noita and all of its content belong to
**Nolla Games Oy**. This project is not affiliated with, endorsed by, or sponsored by Nolla Games.

The Apache license covers **this repository's code only**. It grants no rights to Noita itself and
does not override or replace the Noita Modding Agreement
(`tools_modding/Noita-ModdingAgreement-v100.rtf` in the game install), which also applies to anyone
using this mod.

That agreement forbids distributing "a substantial part of our copyrightable code, content, assets",
which is why **this repository contains no unpacked game data** — only facts (identifiers, numbers,
relationships) extracted from a copy the user owns. See `tools/build_db.py` and
`tools/unpack-data.ps1`.

Full third-party notices are in [NOTICE](NOTICE).

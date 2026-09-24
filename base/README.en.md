# Noita MCP —base version (pure Lua)

The base tier is the mod plus the MCP server, with **no DLL and no external dependency**. It
lets an AI read a running Noita game and change its state: the player, inventory, wands, spell
decks, items, and world/map data, through **67 MCP tools**.

It cannot forge input. That limit is not a setting: Noita's C++ cannot be modded from Lua, so
button presses are impossible from the base tier. See
[../full/README.en.md](../full/README.en.md) for the optional extension that changes this.

Chinese documentation: [README.md](README.md). Main readme: [../README.en.md](../README.en.md).

## Requirements

| Requirement | Notes |
| --- | --- |
| Windows | The game and the bridge are Windows-only |
| Noita | With a **run in progress**; the bridge does not answer in the main menu |
| Node.js 18 or newer | Runs `mcp_server/server.js`; no npm install step |
| MCP client | Any client that can launch a stdio server |

## Install

1. Copy the mod into the game's mod folder. `<Noita>` is the folder containing `noita.exe`,
   for example `D:\Sware\Steam\steamapps\common\Noita`:

   ```text
   base\mod\noita_agent   ->   <Noita>\mods\noita_agent
   ```

2. Start Noita, open **Mods**, and enable **Noita MCP Agent Bridge**. Expect the game's
   "unsafe mod" warning here; see Troubleshooting below.

3. Add the server to your MCP client configuration. Use an absolute path and escape
   backslashes for JSON:

   ```json
   {"type":"stdio","command":"node","args":["<abs path>/base/mcp_server/server.js"],"env":{"NOITA_DIR":"D:\\Sware\\Steam\\steamapps\\common\\Noita"}}
   ```

`base\install.ps1` is a helper that performs the copy and enables the mod in
`mod_config.xml`. The manual steps above are the authoritative path.

## Verify the install

The server has a CLI for humans, so the bridge can be checked without an MCP client:

```powershell
node "<abs path>\base\mcp_server\server.js" --status        # bridge health
node "<abs path>\base\mcp_server\server.js" --list          # list tools
node "<abs path>\base\mcp_server\server.js" --call noita_bridge_status
```

`--status` prints `mod_present`, `bridge_live`, `state_age_ms`, and the last bridge log lines.
`bridge_live: true` means the game is running a session and answering.

## Configuration

All configuration is through environment variables, set in the MCP client's `env` block or in
the shell that starts the server.

| Variable | Purpose |
| --- | --- |
| `NOITA_DIR` | Folder containing `noita.exe`. Required in practice: the server derives the mod's `run\` folder from it. |
| `NOITA_REF_DATA` | Folder of unpacked game data, for `noita_entity_blueprint`. |
| `NOITA_ENTITY_INDEX` | Override the entity index file used by `noita_find_entity`. |
| `NOITA_AGENT_RUN_DIR` | Override the bridge `run\` folder. Intended for test harnesses. |
| `NOITA_PYTHON` | Python executable for wand simulation (`noita_simulate_wand`). |
| `NOITA_WAND_SIM` | Path to the wand simulator entry point. |

## Transport

The mod opens a socket on `127.0.0.1` and writes the chosen port to
`<Noita>\mods\noita_agent\run\port.json`. The server prefers it and falls back to the file
bridge (`state.json`, `request.json`, `response.json` in the same folder) automatically on any
socket problem, so a firewall or blocked `os` API degrades the bridge instead of killing it.
`noita_transport` reports which channel is in use; socket wins only for batched calls.

## The in-game panel

Click the **`[ + ] noita_agent`** label in the top-left corner of the game to expand the panel.
Collapsed, it stays in that corner as a small strip; expanded, it is centred, because it is then
a dialog being read and the corners are where the game draws its own HUD.

Four tabs, switched by clicking:

| Tab | Contents |
| --- | --- |
| **Status** | Active transport and port, request count, watchdog state, frame number, whether the player was found, RPC timings, the settings backend, latency knobs, and the **transport switch** |
| **Permissions** | Master switch (`ai_enabled`), read-only mode, the four operation categories (spawn / player / wands / world), verbose logging, and a line spelling out the **effective** state |
| **Extension** | The input DLL: loaded, armed, and if either failed, **every path that was tried and why each failed**, with load / arm / disarm buttons |
| **Log** | Recent messages, coloured by level (dbg / inf / WRN / ERR), with a level filter (all / info+ / warn+ / errors) and a "newest M of N" readout |

### Switching transport from the panel

The Status tab has two buttons:

- The left one switches the **current** channel between SOCKET and the FILE bridge.
- The right one sets which transport a **new session** starts with (`startup: SOCKET` or
  `startup: FILE`).

The file bridge always runs, so switching cannot strand a client — at worst a request waits one
frame longer. Both can also be set from the MCP side with `noita_set_panel`.

### What persists and what does not

`ai_enabled`, `read_only` and whether the panel is open **reset to their defaults every run**.
That is deliberate: a "pause right now" safety switch that persisted would start the next session
paused, and on a stricter build the operator could be locked out of the very panel that turns it
back on. The operation category switches (spawn / player / wands / world) **do** persist, because
they express policy rather than a moment.

## Tool groups

71 tools in the base tier, grouped by what they do:

| Group | Count | Tools |
| --- | --- | --- |
| Bridge and diagnostics | 5 | `noita_bridge_status`, `noita_capabilities`, `noita_transport`, `noita_latency`, `noita_socket` |
| Observation | 12 | `noita_get_state`, `noita_get_player`, `noita_get_nearby`, `noita_raycast`, `noita_get_inventory`, `noita_get_wands`, `noita_world`, `noita_biome_at`, `noita_list_spells`, `noita_list_materials`, `noita_list_perks`, `noita_refresh_spells` |
| Entity catalog | 3 | `noita_find_entity`, `noita_entity_info`, `noita_entity_blueprint` |
| Player modification | 4 | `noita_set_player`, `noita_heal`, `noita_add_gold`, `noita_apply_effect` |
| Items and held gear | 7 | `noita_inventory`, `noita_switch_item`, `noita_pickup`, `noita_drop_item`, `noita_drop_all`, `noita_launch_projectile`, `noita_spawn_item` |
| Potions | 3 | `noita_get_potion`, `noita_set_potion`, `noita_spawn_potion` |
| Wands and spells | 7 | `noita_spawn_wand`, `noita_edit_wand`, `noita_set_wand_deck`, `noita_add_spell_to_wand`, `noita_remove_spell_from_wand`, `noita_spawn_spell`, `noita_simulate_wand` |
| Direct motion lever | 5 | `noita_lever_state`, `noita_lever_experiment`, `noita_lever_engage`, `noita_lever_disengage`, `noita_lever_status` |
| Permission panel | 2 | `noita_get_panel`, `noita_set_panel` |
| Probes | 4 | `noita_probe_api`, `noita_probe_controls`, `noita_probe_ffi`, `noita_inspect_component` |
| Batching and escape hatch | 2 | `noita_batch`, `noita_raw_rpc` |

The nine `noita_input_*` tools belong to the full tier. They refuse in base mode with a message
saying the extension is missing and how to load it —they are not a hidden way to press keys.

## What the base version cannot do

| Wanted | Why not |
| --- | --- |
| Press keys or mouse buttons | The engine rewrites its control fields from real input every frame. A synthetic value is neither consulted nor retained. |
| Fire the held wand by writing `mButtonDownFire` | Measured: the write is accepted, but `mButtonFrameFire` stays 0 while it is held. `noita_launch_projectile` puts a projectile in the world; that is not the wand. |
| Aim the wand | `mAimingVector` is writable and is recomputed before anything reads it. Same root cause. |
| Read terrain or take a screenshot | Lua has no cell or pixel read API. Use `noita_raycast` and `noita_get_nearby`. |
| Use an item (drink a potion, read a spell) | There is no engine function to trigger a use. Spawn a fresh one or set its contents instead. |
| The engine's own throw | `mThrowItem` is only a request; the throw still needs the button. `noita_drop_item` releases the item with real physics. |

**What does work for movement:** `noita_lever_*` writes the player's physics directly
(velocity, gravity, mass, movement gates). Measured: a 30-frame test with `vx = 250` displaced
the player 126.3 px, matching the write. That is a lever on the physics, not a button press.
Read `noita_lever_state` first, treat it as heavy machinery, and always finish with
`noita_lever_disengage`.

## Permissions

The mod has an in-game panel with a master `ai_enabled` switch, a `read_only` switch, and
per-category switches for spawn, player, wands and world operations. A refused call returns
`ok: false` with `blocked_by_panel: true` and names the switch to flip. Reads always work.
`ai_enabled` and `read_only` reset to their defaults at the start of each run; the
per-operation switches persist.

## Troubleshooting

| Symptom | Cause and action |
| --- | --- |
| Mod does not appear in the Mods menu | The mod folder must be `<Noita>\mods\noita_agent` and contain `mod.xml`. Check for a nested `noita_agent\noita_agent` from a bad copy. |
| "Unsafe mod" / sandbox warning | Expected and unavoidable. The mod sets `request_no_api_restrictions="1"` because it needs `os` and `io` for sockets and files. Accept it to continue. |
| `bridge_live: false` with the game running | The bridge only lives **inside a run**. Start or continue a run. |
| `bridge_live: false`, `mod_present: false` | `NOITA_DIR` is wrong or unset. It must point at the folder containing `noita.exe`. |
| Calls time out while the player is in-game | The game is paused because the window is unfocused. Noita pauses on alt-tab by default; turn `application_pause_when_unfocused` off, or run `install.ps1 -PauseOnUnfocus` to toggle it. |
| `state_age_ms` grows steadily | Same cause as above: the game is not updating, so the mod is not answering. |
| `noita_entity_blueprint` reports missing data | The game's entity XML is packed in `data\data.wak`. Run `tools\unpack-data.ps1` and set `NOITA_REF_DATA`. See the licensing note in [../README.en.md](../README.en.md). |
| A call returns `ok: false` instead of an MCP error | Normal: `ok: false` is a structured answer from the bridge, not a broken tool. Read `error`, and `blocked_by_panel` if present. |
| Socket unavailable, bridge still works | The file fallback is in use. `noita_transport` shows the effective channel. |

## Uninstall

1. Remove `<Noita>\mods\noita_agent`.
2. Remove the server entry from your MCP client configuration.

The game's own files are never modified. `base\install.ps1 -Uninstall` performs the folder
removal and disables the mod in `mod_config.xml`.

## License

The code in this repository is licensed under the [Apache License 2.0](../LICENSE). The full text is in [LICENSE](../LICENSE) at the repository root; third-party notices are in [NOTICE](../NOTICE).

This is an unofficial, non-commercial fan work. Noita and all of its content belong to Nolla Games Oy, and this project is not affiliated with them. The Apache license covers this repository's code only; it grants no rights to Noita itself and does not alter the Noita Modding Agreement.

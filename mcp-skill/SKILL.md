---
name: noita-mcp
description: Drive a running Noita game through the Noita AI Agent Bridge MCP server - observe the player, nearby entities, inventory, wands and spell decks, and modify the player, wands, spells and potions. Use when the user asks about their Noita run, wants the AI to see or change something in Noita, or mentions noita_* tools.
whenToUse: The user is playing Noita, asks about their run, their wands or spells, or asks the AI to look at or change something in Noita, and the noita_* tools are available.
---

# Driving Noita through MCP

You control a **running** Noita game via the `noita_*` tools. The game exposes itself
through an in-game mod; a bridge process translates tool calls into game actions.

## If you are going to change this mod's code, read `ENGINE-NOTES.md` first

It is in the repository root and it is not optional reading: every entry is a trap that looks
like something else, and each one cost hours. The short version, so you know what is in there:

- SDL2's exported input functions are **7-byte thunks**. Hook analysis that counts 6 puts a
  truncated instruction in the trampoline and freezes the machine.
- **`mVelocity` exists on two components** — `CharacterDataComponent` (a pair, the real vector)
  and `VelocityComponent` (a scalar). Writing a pair to the scalar one does nothing, silently.
- **`GuiTranslateSet` does not exist.** Calling it inside a `pcall` fails silently and every
  pane draws at `(0, 0)`.
- Modules are **globals**; `dofile_once` discards return values, so `local x = {} ... return x`
  is `nil` everywhere else.
- **`pcall` does not catch access violations.** A bad memory read kills the process.
- PowerShell's ANSI round-trip **lossily corrupts** non-ASCII text.

`CONTRIBUTING.md` has the templates and the check list to run before committing.

## Start every session like this

1. `noita_bridge_status` — if `bridge_live` is false, **stop and tell the user to start
   Noita and begin/continue a run**. The bridge only exists inside a run, and the mod only
   loads when the game starts. Nothing else will work; do not retry blindly.
2. `noita_capabilities` — **this tells you which mode you are in and therefore what you may
   promise.** See "Two modes" below.
3. `noita_get_panel` — read the permission switches. If a later call is refused, this tells
   you which switch to ask the human to flip.
4. `noita_get_state` — the full picture (player, nearby, wands, inventory).

## Two modes — check before promising anything

The mod ships in two forms, and `noita_capabilities` reports which one is active. **Never
assume you can forge input; ask first.**

| `mode` | What it means |
| --- | --- |
| `base (pure Lua)` | The default. Everything that acts on the state the input *feeds* works. Input cannot be forged. |
| `full (input extension loaded)` | A DLL is loaded into the process and armed, so events can be fed to the game. The `noita_input_*` tools work. |

In **base** mode the input tools refuse and tell you the extension is missing and how to load
it (`noita_input_load`, then `noita_input_install`). Do not retry them and do not improvise a
substitute while claiming it does the same thing — `noita_launch_projectile` is **not** the
wand firing.

In **full** mode the blocked list in `noita_capabilities` shrinks automatically and
`unlocked_by_extension` lists what became possible. Call `noita_input_release` when a sequence
ends; holds expire on their own, but releasing explicitly is better.

## Hard rules

**Do not claim a player action you did not verify.** Two different things hide behind
"move the player", and they have different answers:

- **Button input cannot be forged.** Writing the game's control fields (fire, left, jump,
  interact) has no effect — the engine rewrites them from real input every frame. That was
  measured, with attribution.
- **Motion CAN be commanded, and has been measured.** Writing `mVelocity` moves the player:
  a 30-frame test with `vx=250` displaced the player 126.3px — exactly the 250/60 px per
  frame the write implies — and the engine was observed reading the value, not fighting it.
  See `noita_lever_*` below.

So never say "the player pressed W" (impossible) when you mean "the player moved" (possible).
Verify with `noita_lever_experiment` on a new setup before relying on it, and report the
measured result rather than the expectation.

**Read the refusal, do not work around it.** A blocked call returns
`{"ok": false, "blocked_by_panel": true, "error": "... (switch: <name>)"}`. Tell the user
which switch to enable. Do not try another method to achieve the same write — the gate
classifies unregistered methods as `op_world` and will refuse them too.

**`ok: false` is a normal result, not a tool failure.** The bridge answers with a structured
payload; only MCP-level `isError` means the tool itself broke.

**Confirm destructive intent before doing it.** Spawning items into someone's run, editing
their wands or teleporting them can ruin a run they care about. For anything beyond reading,
say what you are about to do. Wand edits are reversible, teleporting the player is not
always.

**Resolve ids before using them.** Spell and material ids are not guessable. Call
`noita_list_spells` / `noita_list_materials` first and use exact ids from the result.

**Direct control is a lever, not a steering wheel.** `noita_lever_*` can act on the player's
physics (velocity, gravity, mass, movement gates) instead of the input. Treat it as heavy
machinery: read `noita_lever_state` first, always finish with `noita_lever_disengage`, and
tell the user what you are about to do before the player starts moving on its own.

**Speed is measured, not assumed.** `noita_latency` reports real round-trip times. If a plan
needs tight timing (input sequences, dodging), check the number first instead of promising
responsiveness the transport cannot deliver.

## Moving the player directly (aggressive control)

The input path cannot be forged, so `noita_lever_*` operates on what the input feeds. Use it
when the user explicitly wants the AI to move or hold the player.

1. `noita_lever_state` — see what is available. Key fields:
   - `mVelocity` — the player's velocity; writing it every frame is the main motion lever
   - `gravity` — set `0` to stop the player falling mid-maneuver
   - `dont_update_velocity_and_xform` — stop the engine from integrating velocity/position, so
     our writes are not fought over (and only ground detection keeps running)
   - `mFlyingTimeLeft` / `fly_time_max` — flying energy
2. `noita_lever_experiment` — **do this first on a new machine/session.** It writes a horizontal
   velocity for a second and reports how far the player drifted. Horizontal input is absent
   during the test, so any drift is attributable to us; if there is none, direct motion does not
   work here and you must say so rather than act as if it did.
3. `noita_lever_engage` — hold a set of fields for N frames. Values are captured first.
4. `noita_lever_disengage` — **always finish with this.** It restores the captured values. If
   you skip it, the player keeps whatever the last written frame left behind.

Never leave an engagement running when you hand control back, and never engage without
`frames` — a time box is the only thing that guarantees the player gets released.

## Interacting with the player's gear

Run `noita_capabilities` first: it reports what is drivable and the measured reason for
anything blocked. The mechanisms below were each verified in a live run.

### Read and change what is held
- `noita_inventory` — every carried item, whether it is pack gear or worn equipment, and
  which one is in hand.
- `noita_switch_item` — put a carried item in the player's hand. Verified: all four engine
  views of "held" follow the write. Select by `entity` or by `kind` (`wand` / `potion`).

### Pick things up
- `noita_pickup` — take an entity into the inventory. **Only items carrying an
  `AbilityComponent`** can be taken this way (potions, wands, spell items). Auto-pickup items
  like hearts and gold are collected by proximity and will be refused with that reason.
  This is measured, not a guess: `potion.xml` goes in, `heart.xml` and `goldnugget.xml` do not.

### Put things down
- `noita_drop_item` — release ONE item into the world with velocity. **This is a physics
  release, not the engine's throw**: the item genuinely flies and can hit things, but there is
  no throw animation and engine-side on-throw effects may not fire. Say that when it matters.
- `noita_drop_all` — empty the pack. Worn equipment (body parts, cape) stays on the player.

### Launch something
- `noita_launch_projectile` — fire a projectile from the player toward a point, or an angle
  plus distance. **This is the AI launching something, not the player firing their wand.**
  Never describe it as "the player shot their wand".

### Forge input — the extension's tools
These need the input extension. `noita_capabilities` reports `mode`, so check that first; in
`base (pure Lua)` mode they refuse and tell you why.

- `noita_input_move` — hold a direction (`D` right, `A` left, `W` up/fly, `S` down).
  **Verified:** holding `D` gives `vx = +56.84` and `A` gives `-56.81`, symmetric against a
  zero baseline, without the operator touching anything.
- `noita_input_key` — hold any key: `SPACE` (fly), `E` (interact), `SHIFT`, `NUM1`..`NUM5`
  (hotbar). The hold releases itself when its frames run out.
- `noita_input_fire` — **fire the held wand.** This holds the LEFT MOUSE BUTTON, which is
  what Noita actually fires on — `SPACE` is the fly key and produces no shot. Verified by the
  engine's own `mButtonFrameFire` advancing.
- `noita_input_click` — hold a mouse button at a screen position; the engine derives its aim
  vector from the mouse, so this is how aim is controlled.
- `noita_input_release` — release everything now. Holds also expire on their own, so a failed
  sequence cannot leave the player's input hijacked.

Routine for "shoot that thing": `noita_input_click` toward it, `noita_input_fire`, then
`noita_input_release`. For "walk right": `noita_input_move {"dir":"D","frames":40}` (about
0.7 s of holding). Sequence several calls rather than holding one key for a long time.

### Managing the extension
- `noita_input_status` — whether it is loaded, armed, and how many events SDL accepted.
  `queued` must grow for input to be reaching the game; this is how to tell "installed" from
  "working".
- `noita_input_load` — load the DLL through the mod's own FFI. Loading is **inert**: nothing is
  hooked until the next call. No external injector is needed.
- `noita_input_install` — arm the hooks.
- `noita_input_uninstall` — restore the game's original behaviour without restarting.

### Read the terrain (pathfinding input)
Noita's Lua API **cannot read a cell's material** — there is no `GetMaterial` or `GetCell`.
Everything here is inferred from the four raytrace variants, so the grid reports
reachability (`ground` / `solid` / `liquid` / `open`), **never** "this cell is coal".

- `noita_terrain_grid` — a grid as text, one character per cell, with its legend. Measured
  in a live run at `cells=9, radius=120`: 32 ground, 47 open, 2 solid, 324 raycasts, cell
  size 26.7px. Rows are constant-y (north at the top), columns constant-x.
- `noita_terrain_probe` — how far the player can move in each direction before something
  blocks, plus where the ground is. This is the "can I walk that way" call. Measured:
  ground 3px below, up clear 56px, left clear 56px, right blocked at 32px.
- `noita_terrain_rays` — a batch of arbitrary rays, up to 512, for a custom sampling
  pattern. Variants: `any`, `surfaces` (ignores gas and fire), `liquiform` (also passes
  liquids), `platforms` (only standable cells).

### Use macros instead of assembling key timings
- `noita_macro_list` — 22 named macros with the exact key sequence each sends.
- `noita_macro` — run one (`jump_right`, `fire_and_retreat`, `interact`, ...). Returns
  immediately; the bridge advances it one step per frame and **releases every key when it
  ends**, so a macro cannot leave the player walking. Only one runs at a time; starting a
  new one cancels the current one cleanly. Requires the input extension.
- `noita_macro_status`, `noita_macro_stop`.

Measured: `jump_right` is 2 steps / 34 frames and moved the player Δx = 23.7 with the
expected velocity curve — jump, accelerate to +52, decelerate to 0 after release.

### The decision stream, for a fast loop
- `noita_stream_start` — publishes `(state, action, outcome)` records to
  `<run>/decisions.jsonl`, one JSON object per line, appended so a reader can tail it while
  the game runs. `interval` defaults to 6 frames (10 Hz at 60 fps), which replaces one RPC
  round trip per decision. **This is transport, not inference** — the model stays in its
  own process, which is what keeps latency attributable.
- `noita_stream_recent` — the in-memory ring, newest first, without touching disk.
- `noita_stream_action` — attach an intent to the newest observation, so a replay does not
  have to infer it from a key stream. Call it around anything the stream cannot see by
  itself (a direct state write, a wand edit).
- `noita_stream_status`, `noita_stream_stop`.

### Know what exists before spawning
The mod can only see entities near the player. The game defines ~3000, and these read the
unpacked game data, so use them instead of guessing a path:

- `noita_find_entity` — search the catalog by `query` (substring on path/file/tags/name; all
  space-separated terms must match) and/or `kind`. Kinds and their sizes:
  `enemy` 651, `misc` 577, `projectile` 452, `prop` 217, `item` 212, `building` 169,
  `wand` 27, `vegetation` 15, `player` 5, `chest` 5, `potion` 1.
  Examples that work: `chest`, `spell_refresh` (the spell refresher),
  `perk`, `altar`, `shop`, `heart`, `boss`.
- `noita_entity_blueprint` — read one definition: its components and values. **This is where
  enemy stats live** (`DamageModelComponent` hp, `AnimalAIComponent` attack ranges and
  projectile files, `AbilityComponent`), plus wand templates and chest contents.
  Use `components` to trim the output.
- `noita_entity_info` — the LIVE counterpart: components and values of a real entity in the
  world, by id. Use it for "what is this thing right now"; use the blueprint for "what is
  this kind of thing".

Chests and similar are one interaction away: `data/entities/items/pickup/chest_random_super.xml`
is the big treasure chest, and it opens on PICKUP (its `custom_pickup_string` is
`$itempickup_open`). So: `noita_spawn_item` with that path, then `noita_input_key` with `E`.

### Read the world and the map
- `noita_world` — biome name, the biome's file, depth within the biome, parallel-world
  coordinates (world_x 0 = normal, ±1 = east/west; world_y <0 sky, >0 hell), orb counts,
  NG+ level, the camera rectangle (needed to convert world to screen for aiming), and a 9x9
  fog-of-war sample showing what is explored.
- `noita_biome_at` — the biome name at any world position without moving the player, plus its
  vertical position inside that biome and its sky visibility.

Note when reading raw biome output: `_EMPTY_` means the lookup failed, not a biome called
empty. The API needs Y **negated** relative to entity coordinates, and the tools handle that
and report which form worked (`biome_lookup`).

### The game's own catalogs
- `noita_list_spells` — 422 spells the mod can see, with their parameters.
- `noita_list_materials` — 314 materials.
- `noita_list_perks` — 106 perks.
- `noita_simulate_wand` — step a deck through the cast model before you edit it.

## Standard workflows

### Look around
- `noita_get_state` — one call for player + nearby + wands + inventory. Prefer this over
  four separate calls.
- `noita_get_nearby` — widen/narrow with `radius` (default 200) and `limit`. Entries carry
  `kind` (`creature` / `wand` / `potion` / `spell` / `item` / `prop`), `label`, `dist`, `angle`
  and `hp` when present.
- `noita_raycast` — `{angle, distance}` (degrees, 0 = right) to test line of sight.
- `noita_inspect_component` — when you need a component field no dedicated tool exposes.

### Read the player's gear
- `noita_get_wands` — every carried wand with stats and its spell deck **in slot order**.
  Deck entries have `action_id`, `slot`, `always_cast`.
- `noita_get_inventory` — everything carried, with `active` marking the held item.
- `noita_get_potion` — a potion's contents (material + amount + localized name).

### Give the player something
- `noita_spawn_wand` — the powerful one. Example, a fast non-shuffle 3-cast wand:
  ```json
  {"mana_max": 2000, "mana": 2000, "mana_charge_speed": 2000,
   "deck_capacity": 8, "actions_per_round": 3, "reload_time": 5,
   "fire_rate_wait": 1, "spread_degrees": 0, "shuffle": false,
   "spells": ["LIGHT_BULLET", "HOMING", {"id": "DAMAGE", "always_cast": true}]}
  ```
  `always_cast: true` attaches a permanent card. `deck_capacity` counts always-casts too.
- `noita_spawn_spell` / `noita_spawn_item` / `noita_spawn_potion`
  (`materials: ["water"]` or `[{"material":"acid","amount":800}]`).

### Rewrite a wand
- `noita_set_wand_deck` — replace the whole layout; **array order is wand order**.
- `noita_add_spell_to_wand` / `noita_remove_spell_from_wand` — single edits, by `action_id`
  or 0-based `index`.
- `noita_edit_wand` — stats only, or stats + deck together. Omit `entity` to edit the held
  wand.
- `noita_refresh_spells` — call if the HUD looks stale after a heavy edit.

### Predict a wand before you build it
`noita_simulate_wand` runs the deck model and returns casts/second, mana/second, per-round
charge and per-cast detail. Call it with no arguments to simulate the held wand, or pass
`spells` to test a design that does not exist yet.

Use it **before** `noita_spawn_wand` when the user wants a wand that actually performs
(e.g. a machine gun), and to explain why a wand underperforms. Two cautions:

- Read `unknown_spells` in the result. The simulator's spell table only covers the common
  spells (~30 of the game's 422). Anything it does not know is treated as a **neutral
  projectile** — 0 mana, no cast-delay change — so a prediction containing unknown spells
  looks plausible but is wrong. Say so rather than quoting its numbers as fact.
- It reasons about the deck, not about terrain, enemies or your aim. Rate of fire and mana
  budget are reliable; "will this kill X" is not something it answers.

### Move / heal / buff
- `noita_set_player` — teleport (`x`,`y`), `hp`, `max_hp`, `invincibility_frames`, `money`
  or `money_add`, `vx`/`vy`, `air`. Only the fields you pass change.
- `noita_heal` (`fraction`, default full), `noita_add_gold`, `noita_apply_effect`
  (e.g. `PROTECTION_ALL`, `REGENERATION`, `WET`).

## What is NOT possible (verified in a live run)

| Wanted | Why not | Do instead |
| --- | --- | --- |
| Make the player walk / jump with a button press | control fields are rewritten from real input every frame | `noita_lever_engage` writes velocity directly — **this works** — or `noita_set_player` teleports |
| Make the player fire the held wand | `mButtonDownFire` accepts the write but the engine overwrites it before reading; measured: `mButtonFrameFire` stays 0 while held | `noita_launch_projectile` puts a projectile in the world — but that is **not** the wand, and must not be called that |
| Aim the player's wand | `mAimingVector` accepts the write and is recomputed before anything reads it (same root cause) | nothing confirmed. Report what is in range instead |
| The engine's own throw | `mThrowItem` is only a request; the throw still needs the button | `noita_drop_item` releases the item with real physics |
| Use an item (drink a potion, read a spell) | there is no engine function to trigger a use | `noita_spawn_potion` to make a fresh one, or set its contents |
| Press interact / pick up by pretending to press E | no button simulation exists | `noita_pickup` takes ability items directly |
| Read world terrain or take a screenshot | Lua has no cell/pixel read API | `noita_raycast`, `noita_get_nearby` |

Also absent: `EntityGetVelocity`, `HasPerk`, `GameGetAllActions`, engine messaging.

**All four blocked rows share ONE root cause:** the control fields are a **mirror** of real
input, not a driver. The engine copies the OS/SDL input state into them each frame, so a
synthetic value is neither consulted nor retained. Measured directly: writing
`mAimingVector = (1,0)` and reading it back *in the same Lua call* returns `(1,0)` — the field
is writable — yet it reverts across a frame, and holding `mButtonDownFire = true` for 60 frames
produces no reaction at all (`mButtonFrameFire` stays 0, no shot is cast).

**Patching the game binary does not fix this, and claiming otherwise would be wrong.** Patching
from Lua is technically possible — the module base is fixed at `0x400000` with no ASLR, static
addresses were verified valid at runtime byte-for-byte, and `VirtualProtect` plus a verified,
reversible write work from Lua. But defeating the reset would only leave a value the engine
never consults. Forging input means intercepting the input *source* (SDL's keyboard state or
the engine's read of it), which requires a DLL/ASI hook loaded into the process — outside what
a mod can do.

**Reporting rule for motion:** "the player pressed W" is impossible; "the player moves right"
is possible and measured (`noita_lever_*`). Never conflate them, and never claim the wand
fired or that the player aimed.

### What the engine exposes about its own controls

`noita_inspect_component` on the player's `ControlsComponent` reads (all 18 fields verified
readable): `mButtonFrameFire`, `mButtonDownFire`, `mButtonFrameLeft/Right/Up/Down/Run/Fly/
Interact`, `mAimingVector`, `mAimingVectorNormalized`, `mAimingVectorNonZeroLatest`,
`mMousePosition`, `mMousePositionRaw`. These are **observations**, not levers — the button
and frame fields are the engine's record of what the human did, so reading them tells you
what the player is actually doing. Do not try to write them to make something happen.

## Panel and permissions

`noita_get_panel` returns the switches and the settings backend. `noita_set_panel` changes
them, but **prefer asking the human** to change permissions in the in-game panel unless they
explicitly told you to manage it yourself — the switches exist so a person can stop you.

Switches: `ai_enabled` (master, blocks all writes), `read_only`, and per-category
`operations.{spawn, player, wands, world}`. Reads always work, even when paused.
`ai_enabled` and `read_only` reset to their defaults at the start of each run; the
per-operation switches persist.

## Troubleshooting

| Symptom | Meaning / action |
| --- | --- |
| `bridge_live: false` | game not running, or no run started. Ask the user. |
| `Timed out ... waiting for the game` | game paused, in a menu, or in the main menu. Ask them to be in-game. |
| `state_age_ms` growing while the user is playing | the game window is unfocused and Noita is paused. The installer turns pause-on-unfocus off; if it was restored, `install.ps1 -PauseOnUnfocus` toggles it, or the user can change it in game options. |
| refusal naming a switch | ask the human to flip that switch in the in-game panel |
| `noita_probe_api` shows a missing API | the sandbox is stricter than expected; report it with the probe output |
| `noita_probe_ffi` says FFI is unusable | the bridge is file-only; do not propose socket/DLL-based approaches |
| `noita_lever_experiment` reports no displacement | direct motion does not work in this setup — stop trying to move the player and say so |

The MCP server also ships a CLI for the human: `node server.js --status`, `--list`,
`--call <tool> '<json>'`.

## Answering style

Report what the game actually returned. When a value is unknown or a request is refused,
say so instead of filling the gap. If the user asks for something in the "not possible"
table, correct the expectation first — do not silently substitute a different action.

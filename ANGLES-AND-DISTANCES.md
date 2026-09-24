# Angles, distances and material perception

Every angle in this bridge means the same thing, but "the same thing" is not the convention most
people assume. Read this before mixing an angle from one tool with a coordinate from another.

- [The angle convention](#the-angle-convention)
- [Which tools use it](#which-tools-use-it)
- [Distances](#distances)
- [Resolution, and how to change it](#resolution-and-how-to-change-it)
- [What the sweep says about material](#what-the-sweep-says-about-material)
- [What the sweep does NOT detect](#what-the-sweep-does-not-detect)
- [A ray into unloaded terrain returns "open", and that is wrong](#a-ray-into-unloaded-terrain-returns-open-and-that-is-wrong)
- [A bug this convention caught](#a-bug-this-convention-caught)

---

## The angle convention

```
angle = degrees( atan2(dy, dx) )      where dx, dy are world-space offsets
```

| angle | direction |
| --- | --- |
| 0 | east (right) |
| 90 | **south (down)** |
| 180 | west (left) |
| 270 or -90 | north (up) |

**Angles increase CLOCKWISE on screen, because Noita's world has y increasing downward.** This is
the opposite of the mathematical convention, where the positive direction is counter-clockwise and
90 degrees points up. Nothing here is wrong; it is the convention that follows from the game's own
axes, and it is consistent everywhere.

Measured rather than asserted — a chest spawned and then located:

```
player (-120, 96)    chest (-208, 132)
dx = -88.4   dy = +36.4            (left and down: south-west on screen)

atan2(dy, dx)  =  157.59   <- what noita_get_nearby reports
atan2(-dy, dx) = -157.59   <- the school convention, NOT used here
```

## Which tools use it

| tool | field | convention |
| --- | --- | --- |
| `noita_get_nearby` | `angle` (output) | world, `atan2(dy, dx)` |
| `noita_raycast` | `angle` (input) | world — 0 = right, 90 = down |
| `noita_percept_sweep` | `degrees` (labels) | world |
| `noita_percept_surroundings` | `degrees` (labels) | world |
| `noita_input_click` | `x`, `y` | **screen pixels**, not an angle |

The first four agree, so an angle read from `noita_get_nearby` can be handed straight to
`noita_raycast` and points at the same thing. That agreement is why this is worth writing down: it
is convenient and entirely invisible until it breaks.

`noita_input_click` is the exception and not a conflict — it takes screen coordinates because that
is what the engine's aim vector is derived from. Converting a world angle to a click position needs
the camera rectangle, which `noita_world` reports as `camera {x, y, w, h}`.

## Distances

All distances are **world pixels** — not cells, not screen pixels. Noita's cells are 8 pixels.

| tool | field | meaning |
| --- | --- | --- |
| `noita_get_nearby` | `dist` | straight-line distance from the player |
| `noita_get_nearby` | `dx`, `dy` | the components, so a caller can do its own maths |
| `noita_percept_sweep` | band `from`/`to` | distance bands along that direction |
| `noita_percept_sweep` | `first_contact` | how far the nearest non-open slice is |
| `noita_terrain_probe` | `clear_distance` | how far movement is unobstructed |
| `noita_raycast` | `distance` (input) | ray length |

## Resolution, and how to change it

`noita_percept_sweep` defaults to **16 directions** (22.5 degrees apart) and **8 slices** over
**600 px** — a slice every 75 px. The minimum is 8 directions.

| parameter | default | range | effect |
| --- | --- | --- | --- |
| `directions` | 16 | 8–64 | angular resolution; 64 gives 5.6 degrees |
| `reach` | 600 | 32–4000 | how far out to look |
| `samples` | 8 | 2–32 | radial resolution |

The cost is **4 raycasts per direction regardless of `samples`** — a profile comes from where four
raytrace variants stop, not from a probe per slice. So raising `samples` is free and raising
`directions` is what costs: 16 directions is 64 raycasts, 64 directions is 256.

Measured: the same view profiled at 8 slices and at 32 **found no material the coarse one missed**.
Finer slices locate the same boundaries more precisely; they do not reveal new substance.

**Does the default need strengthening?**

- **Radial: no.** It is free, and 8 slices already says roughly where a boundary lies.
- **Angular: yes, if precision is wanted.** A 1-cell gap is 8 px; at 400 px away that subtends about
  1.1 degrees, and rays 22.5 degrees apart step straight over it. `directions: 32` or `64` is the
  fix.

The default stays at 16 because a sweep runs whenever perception is asked for, and 64 directions
costs 256 raycasts — a price the caller should choose knowingly rather than one paid silently.

A raycast budget (`noita_percept_disable {raycasts: N}`) trims a sweep that would exceed it, and
says so in `trimmed_to_budget`.

## What the sweep says about material

Its glyphs **are** material classes, read from raycast behaviour:

| glyph | class | how it is known |
| --- | --- | --- |
| `#` | standable solid | `RaytracePlatforms` stops there and nothing stricter does |
| `%` | solid | `RaytraceSurfacesAndLiquiform` stops there |
| `~` | liquid | `RaytraceSurfaces` stops there but `Liquiform` passes through |
| `^` | gas or fire | only the permissive `Raytrace` stops there |
| `.` | open | nothing stops |

**Measured in a live game, in both directions of the inference:**

```
gas, confirmed        315 deg   any=50  surfaces=none  liquiform=none  platforms=none
                                the sweep reports  ^  in that direction, as it should

inside matter         every deg  any=Y  surfaces=Y  liquiform=Y  platforms=Y
                                all four stop at the ray's start, so nothing is classifiable
```

`%` and `#` are distinguished by where the stop is: `%` means the ray **began** inside matter, `#`
means it stopped at a surface that can be stood on.

**Rock, coal, sand and steel are all `%` or `#`; water, acid, oil and lava are all `~`.** A ray that
stops cannot report what stopped it, and there is no `GetMaterial`/`GetCell` to ask instead. The
game's own material catalogue — 469 materials with their `cell_type` — is the other half of the
answer: it says what a named material MEANS, not which one is at a particular cell.

## What the sweep does NOT detect

**Entities.** The sweep reports terrain — cells, and therefore reachability — and a chest or an
enemy standing in front of the player does not change its output. Measured: a chest was spawned
200 px away and the profile in that direction was identical afterwards.

Objects and creatures are found through the **entity interface**, not through rays:

- `noita_get_nearby` — entities within a radius, with `species`, `kind`, `dist`, `angle`, `hp`
- `noita_entity_info` — one entity by id, in full

A live coal mine, radius 4000:

```
miner_weak 8   shotgunner_weak 4   tree_entity 14   coalmine_i_structure 4
lantern_small 1   verlet_vine 2   prop 44   potion 2   spell 2   wand 2
by tag:  enemy 23   mortal 52   hittable 38
```

This is a deliberate division: **rays answer "what is the terrain like out there", the entity
interface answers "what is standing there".** A raytrace against a thin or fast-moving entity is a
coin toss; the entity interface is exact.

## A ray into unloaded terrain returns "open", and that is wrong

Measured with the player at (0, 2500):

| ray | result |
| --- | --- |
| from the player downward 300 px | hit at y=2512 — correct |
| at x=0 from y=-400 downward 1200 px | **hit nothing** — that area was not streamed in |

So `hit = false` means "nothing was found", which is **not** the same as "there is nothing there".
Cast rays near the player, where the world is loaded. A survey that casts far away reports open
space that does not exist, and the mistake is invisible in the output — it looks exactly like a
genuine opening.

This also means a player who is **inside** a medium (rock, or a lake) has no usable profile: every
ray starts inside matter, all four variants agree, and nothing can be classified. Move out of the
medium to perceive it.

## A bug this convention caught

Writing this file is what exposed the bug. `player_ops.lua` had **three places** written with a
negated sine:

```lua
vy = -math.sin(math.rad(ang)) * speed      -- velocity
ty = py - math.sin(a) * dist               -- projectile target
ty = py - math.sin(a) * dist               -- calibrated target
```

That is the screen convention, and it flipped every angle vertically on those paths — the
documented "90 = down" went **up**. `percept.lua` and `rpc.lua` were already correct, so the same
angle meant different directions depending on which tool received it.

Two checks now guard it, and **both were verified by putting the bug back**:

- no negated sine appears anywhere in the Lua — in a y-down system there is no legitimate use for
  one when building an offset
- every angle-to-vector line has both components with a positive sine

### And a check that did not work the first time

The first version of that test required `math.cos` on the same line, on the theory that an
angle-to-vector line always has both. It **missed** `vy = -math.sin(...) * speed` — a velocity
component with no cosine — so the check passed while the bug was present. Putting the bug back is
what revealed it. A regression test that has never failed is not evidence that it works.

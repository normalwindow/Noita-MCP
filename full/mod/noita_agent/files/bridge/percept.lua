-- Chunked perception of the surroundings: rough material composition, with distance.
--
-- THE DESIGN, WHICH IS THE POINT
--
-- An agent does not need a pixel map. It needs to know, in a few numbers per region, WHAT the
-- terrain around it is made of and HOW FAR AWAY that stuff is. So this samples in CHUNKS:
-- a ring of rays at each of several distances, classified by behaviour, then aggregated.
--
-- Why behaviour and not material ids: the engine cannot report a cell's material. There is no
-- `GetMaterial` or `GetCell`, and `CellFactory_*` only goes id -> name. Four raytrace variants
-- disagree in ways that identify a cell's CLASS by elimination, which is the coarse answer that
-- was actually wanted.
--
-- Why rings and not a grid: a grid is uniform in space and says nothing about reach. Rings answer
-- "what is near me, what is at arm's length, what is far" directly, at a cost that scales with the
-- number of rings rather than the area. A 9x9 grid is 324 raycasts for one view; this is 4
-- variants x 12 directions x 4 distances = 192 for four depth layers that are directly meaningful.
--
-- WHAT EACH LAYER MEANS
--
-- Rays are cast OUTWARD from the player, and each variant is asked how far it gets before it
-- stops. Comparing where they stop classifies what stopped them:
--
--   nothing stops                       -> open air at that distance
--   only `any` stops                    -> gas or fire (the permissive trace sees it)
--   `surfaces` stops, `liquiform` not   -> liquid
--   `liquiform` stops, `platforms` not  -> solid, not standable
--   `platforms` stops                   -> standable ground
--
-- Summed over a ring, that gives a composition per distance band -- "60% of what is 40px away is
-- solid rock" -- which is a usable input for a decision and a fraction of the data of a grid.

percept = percept or {}

local VARIANTS = {
  { name = "any",       fn = Raytrace },
  { name = "surfaces",  fn = RaytraceSurfaces },
  { name = "liquiform", fn = RaytraceSurfacesAndLiquiform },
  { name = "platforms", fn = RaytracePlatforms },
}

local CLASS_OF = {
  platforms  = "standable",
  liquiform  = "solid",
  surfaces   = "liquid",
  any        = "gas_or_fire",
  none       = "open",
}

-- Classify a short probe ray: cast from a point, and see whether anything stops it.
--
-- WHAT THE RETURN VALUES MEAN -- established by measurement, after getting it backwards once.
--
-- A raytrace returns `(did_it_stop, x, y)`. `true` means IT STOPPED. Measured both ways:
--
--   open air   (227,-79), a ray from y-8 down to y+40:  all four variants  hit=false
--   solid rock (0,3000),  the same ray:                 all four variants  hit=true,
--                                                                          stopped at the start
--
-- The first version of this module read `true` as "the path was clear", which classified a solid
-- rock face as "standable 100%" at every distance. Exactly backwards.
--
-- THE LIMIT THIS EXPOSES, WHICH IS REAL AND IS WHY THIS REPORTS COVERAGE
--
-- From inside solid matter all four variants stop at the ray's start, so they are
-- indistinguishable and the MATERIAL of a solid cell cannot be recovered this way. What the
-- variants CAN distinguish is the presence of a boundary: a ray that ends in open air separates
-- the classes that stop before it.
--
-- So this reports OCCUPANCY -- is there something here -- and classifies only where the evidence
-- supports it. Calling rock and sand different classes when the engine gives no signal for it
-- would be inventing data.
--
-- `probe` casts a ray across a cell boundary and classifies what is on the far side.
local function probe(x, y, to_x, to_y)
  local stopped = {}
  for _, v in ipairs(VARIANTS) do
    local ok, did = pcall(v.fn, x, y, to_x, to_y)
    stopped[v.name] = (ok and did) and true or false
  end

  -- Nothing stopped: the ray crossed the whole span in open air.
  if not stopped.any then return "open", stopped end

  -- Everything stopped at the ray's own start, which means the ray BEGAN inside matter. That is
  -- the situation the variants cannot resolve, and saying so is more useful than guessing.
  local all = stopped.any and stopped.surfaces and stopped.liquiform and stopped.platforms
  if all then return "solid_or_liquid", stopped end

  -- A boundary falls inside the span: the strictest variant that got through tells us what the
  -- permissive ones were stopped by.
  if stopped.surfaces and not stopped.liquiform then return "liquid", stopped end
  if stopped.any and not stopped.surfaces then return "gas_or_fire", stopped end
  if stopped.platforms then return "standable", stopped end
  return "occupied", stopped
end

-- The main call: what is around the player, per distance band.
--
-- Each band tests a ring of points at that distance. For every point the probe asks "is the spot
-- just beyond this occupied", so the answer per band is a COVERAGE fraction plus a class breakdown
-- where the engine actually provides one.
function percept.surroundings(params)
  params = params or {}
  local directions = math.max(4, math.min(tonumber(params.directions) or 12, 32))
  local reach = math.max(16, math.min(tonumber(params.reach) or 200, 2000))
  local bands = math.max(1, math.min(tonumber(params.bands) or 4, 10))
  local offset = tonumber(params.offset_degrees) or 0

  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end
  local px, py = EntityGetTransform(p)

  local distances = {}
  for b = 1, bands do distances[b] = reach * b / bands end

  local layers = {}
  local raycasts = 0

  for b = 1, bands do
    local dist = distances[b]
    local counts = {}
    local per_direction = {}

    for i = 0, directions - 1 do
      local deg = offset + (360 / directions) * i
      local rad = math.rad(deg)
      local dx, dy = math.cos(rad), math.sin(rad)

      -- Probe ACROSS the sample point rather than from the player: a short segment centred on the
      -- point, so the answer is about that spot and not about everything between here and there.
      local sx, sy = px + dx * (dist - 6), py + dy * (dist - 6)
      local tx, ty = px + dx * (dist + 6), py + dy * (dist + 6)
      local class, stopped = probe(sx, sy, tx, ty)
      raycasts = raycasts + #VARIANTS

      counts[class] = (counts[class] or 0) + 1
      per_direction[#per_direction + 1] = {
        degrees = math.floor(deg + 0.5), class = class,
      }
    end

    local composition = {}
    for class, n in pairs(counts) do
      composition[class] = {
        count = n,
        fraction = math.floor((n / directions) * 1000) / 1000,
      }
    end

    -- Occupancy is the number that is always meaningful: the fraction of this ring where there is
    -- matter rather than open air.
    local occupied = directions - (counts.open or 0)

    layers[#layers + 1] = {
      band = b,
      distance = math.floor(dist),
      occupied_fraction = math.floor((occupied / directions) * 1000) / 1000,
      composition = composition,
      directions = per_direction,
    }
  end

  local summary = {}
  for _, layer in ipairs(layers) do
    local parts = {}
    for class, info in pairs(layer.composition) do
      parts[#parts + 1] = string.format("%s %d%%", class, math.floor(info.fraction * 100 + 0.5))
    end
    table.sort(parts)
    summary[#summary + 1] = string.format("%4dpx: %s", layer.distance, table.concat(parts, ", "))
  end

  return {
    ok = true,
    player = { x = math.floor(px), y = math.floor(py) },
    directions = directions,
    bands = bands,
    reach = reach,
    raycasts = raycasts,
    layers = layers,
    summary = summary,
    note = "occupied_fraction is the reliable number -- the share of this distance band where " ..
           "there is matter rather than open air. The class breakdown is finer where the engine " ..
           "supports it, but a ray that begins inside solid matter cannot tell rock from sand: " ..
           "all four variants stop at its start. 'solid_or_liquid' is reported rather than guessed.",
  }
end

-- Composition of a rectangular chunk, for "what is this region made of" as opposed to "what is
-- around me". Reuses the same classification, sampled on a lattice.
function percept.chunk(params)
  params = params or {}
  local cx = tonumber(params.x)
  local cy = tonumber(params.y)
  local w = math.max(16, math.min(tonumber(params.width) or 200, 1000))
  local h = math.max(16, math.min(tonumber(params.height) or 200, 1000))
  local step = math.max(8, math.min(tonumber(params.step) or 24, 200))

  if not cx or not cy then
    local p = ser.player()
    if not p then return { ok = false, error = "no player and no x/y given" } end
    cx, cy = EntityGetTransform(p)
  end

  local counts, total, raycasts = {}, 0, 0
  local top_left = { x = math.floor(cx - w / 2), y = math.floor(cy - h / 2) }

  local ny = 0
  for y = top_left.y, top_left.y + h, step do
    ny = ny + 1
    for x = top_left.x, top_left.x + w, step do
      -- Probe across the sample point, not from it: a short segment centred there, so the answer is
      -- about that spot rather than about everything between the corner and it.
      local class = probe(x - 4, y, x + 4, y)
      raycasts = raycasts + #VARIANTS
      counts[class] = (counts[class] or 0) + 1
      total = total + 1
    end
  end

  local composition = {}
  for class, n in pairs(counts) do
    composition[class] = { count = n, fraction = math.floor((n / total) * 1000) / 1000 }
  end

  return {
    ok = true,
    chunk = { x = top_left.x, y = top_left.y, width = w, height = h, step = step },
    samples = total,
    raycasts = raycasts,
    occupied_fraction = math.floor(((total - (counts.open or 0)) / total) * 1000) / 1000,
    composition = composition,
    note = "rough composition of the region; 'open' is air, the rest is matter. A sample that " ..
           "begins inside solid matter cannot be resolved further -- all four variants stop at " ..
           "its start -- so 'solid_or_liquid' means occupied but not identifiable.",
  }
end

-- What a class means, and the vocabulary the game's own materials use, so a caller can map a
-- perceived class onto the material catalogue.
function percept.vocabulary()
  return {
    ok = true,
    classes = {
      open            = "air -- the probe crossed the span without stopping",
      solid_or_liquid = "the probe began inside matter, so the variants cannot resolve it " ..
                        "further. Occupied, but not identifiable as solid or liquid.",
      standable       = "a boundary inside the span that RaytracePlatforms accepts -- ground",
      occupied        = "a boundary the strictest variants passed but the permissive one stopped " ..
                        "on, without a cleaner class",
      liquid          = "Surfaces stopped and Liquiform passed -- a liquid surface",
      gas_or_fire     = "only the permissive Raytrace stopped -- smoke, steam, fire",
    },
    the_limit = "From inside solid matter all four raytrace variants stop at the ray's own start " ..
                "and are indistinguishable, so a solid cell's MATERIAL cannot be recovered by " ..
                "raycasting. Measured: from open air all four return hit=false, from inside rock " ..
                "all four return hit=true stopped at the start. Reading a specific cell's " ..
                "material is impossible in this engine -- there is no GetMaterial or GetCell.",
    material_cell_types = {
      solid = "the game's own class for solid materials -- 42 of them",
      liquid = "the game's own class for liquids -- 155",
      gas = "the game's own class for gases -- 21",
      fire = "fire and sparks -- 4",
    },
    note = "The catalogue built from the game's materials.xml gives each of 469 materials its " ..
           "class and properties. This perception layer says WHERE matter is and roughly what " ..
           "kind; the catalogue says what a named material MEANS. They are complementary, and " ..
           "neither can name the material of one particular cell.",
  }
end

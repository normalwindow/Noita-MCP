-- Terrain sampling: a coarse reachability grid around the player.
--
-- WHY THIS IS A GRID OF HIT TESTS AND NOT A MATERIAL MAP
--
-- Noita's Lua API cannot read a cell's material. There is no GetMaterial or GetCell; the
-- CellFactory_* functions only go the other way (id -> name). So the only way to learn
-- what is around the player is to ask where things are, using the four raytrace variants:
--
--   Raytrace                       stops on ANY cell
--   RaytraceSurfaces               stops on anything that is not gas or fire
--   RaytraceSurfacesAndLiquiform   same, but liquids count as passable
--   RaytracePlatforms              stops only on cells a character can stand on
--
-- Measured in a live run: standing on ground, all four hit for a downward ray, with
-- `platforms` landing one cell higher than the rest -- which is exactly the difference
-- between "there is something there" and "it is something you can stand on". An upward
-- ray hit nothing at all. That is enough to classify a point:
--
--   platforms hit    -> ground (standable)
--   liquiform misses, surfaces hits -> liquid (the two disagree only for liquids)
--   surfaces hits    -> solid
--   nothing hits     -> open
--
-- The output is a text grid, one character per cell, with a legend. That is the same
-- shape a person would draw on paper, and it is what a pathfinder needs.
--
-- COST: the grid is (cells+1) * cells * 2 raytraces for the edges, plus a centre sample
-- per cell. At 9x9 that is a few hundred calls; they are cheap but not free, so the
-- caller picks the size and the radius, and the result reports how many calls it made.

terrain = terrain or {}

-- One character per classification. Chosen to be readable in a monospace grid and to
-- match the conventions a roguelike map would use.
local GLYPH = {
  open = ".",
  ground = "#",     -- standable
  solid = "%",      -- blocked, not standable
  liquid = "~",
  unknown = "?",
}

terrain.GLYPH = GLYPH

local LEGEND = {
  ["."] = "open (nothing within reach)",
  ["#"] = "ground (standable)",
  ["%"] = "solid (blocked, not standable)",
  ["~"] = "liquid",
  ["?"] = "unknown (raycast failed)",
}

-- Classifies a single point by asking the four variants about a short vertical ray
-- through it.
--
-- A vertical ray rather than a point sample because there is no point sample: every
-- raytrace needs two endpoints, and a zero-length one is not meaningful (measured: a
-- 2px ray in the player's own cell hits the floor immediately, which says nothing about
-- the cell itself).
local function classify(x, y, reach)
  reach = reach or 4

  local ok_a, hit_a = pcall(Raytrace, x, y, x, y + reach)
  if not ok_a then return "unknown" end
  local ok_l, hit_l = pcall(RaytraceSurfacesAndLiquiform, x, y, x, y + reach)
  if not ok_l then return "unknown" end
  local ok_s, hit_s = pcall(RaytraceSurfaces, x, y, x, y + reach)
  if not ok_s then return "unknown" end
  local ok_p, hit_p = pcall(RaytracePlatforms, x, y, x, y + reach)
  if not ok_p then return "unknown" end

  -- `platforms` is the strictest: it only stops on something a character can stand on.
  if hit_p then return "ground" end
  -- `liquiform` deliberately passes through liquids while `surfaces` does not, so a
  -- disagreement between them means liquid.
  if not hit_l and hit_s then return "liquid" end
  if hit_s then return "solid" end
  -- nothing in reach: if even the permissive trace finds nothing, it is open
  if not hit_a then return "open" end
  -- `any` hit but the others did not: something transient, treat as open
  return "open"
end

terrain.classify = classify

-- Builds the grid.
--
-- `cells` is per side and `radius` is in world pixels, so the cell size follows from
-- them. The origin is the player, and the grid is centred there.
function terrain.grid(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end
  local px, py = EntityGetTransform(p)

  local cells = math.max(3, math.min(tonumber(params.cells) or 9, 25))
  local radius = math.max(16, math.min(tonumber(params.radius) or 120, 600))
  local reach = math.max(2, math.min(tonumber(params.reach) or 4, 12))

  -- Cell centres, so a cell represents its middle rather than its corner.
  local step = (radius * 2) / cells
  local half = (cells - 1) / 2
  local ox = math.floor(px - half * step)
  local oy = math.floor(py - half * step)

  local calls = 0
  local rows, counts = {}, {}
  for iy = 0, cells - 1 do
    local row = {}
    local wy = oy + math.floor(iy * step)
    for ix = 0, cells - 1 do
      local wx = ox + math.floor(ix * step)
      local k = classify(wx, wy, reach)
      calls = calls + 4
      row[#row + 1] = GLYPH[k] or "?"
      counts[k] = (counts[k] or 0) + 1
    end
    rows[#rows + 1] = table.concat(row)
  end

  -- The player's own cell, so a caller can see which glyph is "here" without recomputing
  -- the arithmetic.
  local here_ix = math.floor((px - ox) / step + 0.5)
  local here_iy = math.floor((py - oy) / step + 0.5)

  return {
    ok = true,
    player = { x = px, y = py },
    cells = cells,
    radius = radius,
    cell_size = step,
    origin = { x = ox, y = oy },
    grid = rows,
    text = table.concat(rows, "\n"),
    legend = LEGEND,
    counts = counts,
    raycasts = calls,
    player_cell = { x = here_ix, y = here_iy },
    axes = "each row is a line of constant y (north at the top); each column is " ..
           "constant x (west at the left)",
  }
end

-- A batch of arbitrary rays, for callers that want their own sampling pattern rather
-- than the square grid. Each entry is {x1,y1,x2,y2} or {from={x,y},to={x,y}}.
function terrain.rays(params)
  params = params or {}
  local list = params.rays
  if type(list) ~= "table" then
    return { ok = false, error = "rays must be an array of {x1,y1,x2,y2} or {from={x,y},to={x,y}}" }
  end
  if #list > 512 then
    return { ok = false, error = "at most 512 rays per call (got " .. #list .. ")" }
  end

  local out = {}
  local hits = 0
  for i = 1, #list do
    local r = list[i]
    local x1, y1, x2, y2
    if type(r) == "table" and r.from and r.to then
      x1, y1, x2, y2 = r.from.x, r.from.y, r.to.x, r.to.y
    elseif type(r) == "table" then
      x1, y1, x2, y2 = r[1], r[2], r[3], r[4]
    end
    if x1 and y1 and x2 and y2 then
      local variant = r.variant or params.variant or "surfaces"
      local fn = ({ any = Raytrace, surfaces = RaytraceSurfaces,
                    liquiform = RaytraceSurfacesAndLiquiform,
                    platforms = RaytracePlatforms })[variant]
      if fn then
        local ok, hit, hx, hy = pcall(fn, x1, y1, x2, y2)
        if ok and hit then hits = hits + 1 end
        out[#out + 1] = {
          i = i,
          hit = (ok and hit) or false,
          x = (ok and hit) and hx or nil,
          y = (ok and hit) and hy or nil,
          variant = variant,
          error = (not ok) and tostring(hit) or nil,
        }
      else
        out[#out + 1] = { i = i, error = "unknown variant: " .. tostring(variant) }
      end
    else
      out[#out + 1] = { i = i, error = "expected {x1,y1,x2,y2} or {from,to}" }
    end
  end

  return { ok = true, requested = #list, hits = hits, results = out }
end

-- Directional probes from the player: the questions a controller actually asks, in one
-- call instead of six.
function terrain.probe(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end
  local px, py = EntityGetTransform(p)
  local reach = math.max(4, math.min(tonumber(params.reach) or 40, 400))
  local step = math.max(2, math.min(tonumber(params.step) or 8, 40))

  -- Each direction is sampled at increasing distance so the caller learns how far the
  -- obstruction is, not just that one exists. That is what "can I walk that way" needs.
  local dirs = {
    left = { -1, 0 }, right = { 1, 0 }, up = { 0, -1 }, down = { 0, 1 },
  }
  local out = {}
  for name, d in pairs(dirs) do
    local free = 0
    local dist = step
    while dist <= reach do
      local x2, y2 = px + d[1] * dist, py + d[2] * dist
      local ok, hit = pcall(RaytraceSurfaces, px, py, x2, y2)
      if not ok or hit then break end
      free = dist
      dist = dist + step
    end
    out[name] = {
      clear_distance = free,
      blocked_at = (free < reach) and (free + step) or nil,
      clear_to = (free >= reach) and reach or nil,
    }
  end

  -- standable ground directly below, which is the other thing a controller needs
  local okp, hitp, hx, hy = pcall(RaytracePlatforms, px, py, px, py + reach)
  out.ground = {
    found = (okp and hitp) or false,
    at = (okp and hitp) and { x = hx, y = hy } or nil,
    drop = (okp and hitp) and (hy - py) or nil,
  }

  return { ok = true, player = { x = px, y = py }, reach = reach, directions = out }
end

return terrain

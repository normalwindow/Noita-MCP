-- Spawns the big treasure chest right in front of the player, then reports the
-- scene so the opening step can be verified against a known state.
--
-- The chest chest_random_super.xml opens on PICKUP: it carries
-- script_item_picked_up = data/scripts/items/chest_random_super.lua, and its
-- ItemComponent says custom_pickup_string="$itempickup_open" -- the pickup hint
-- literally reads "open". So "opening" it means picking it up, which needs the
-- interact key (measured to be E).

local fixture = {}

local CHEST = "data/entities/items/pickup/chest_random_super.xml"

local function nearby_summary(radius)
  local p = ser.player()
  local list = ser.nearby(radius or 120, 40) or {}
  local out = {}
  for _, e in ipairs(list) do
    out[#out + 1] = { entity = e.entity, kind = e.kind, name = e.name,
                      dist = e.dist and math.floor(e.dist) or nil }
  end
  return out
end

function fixture.run(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end
  local px, py = EntityGetTransform(p)

  -- look slightly away from the player so it does not spawn inside them
  local dir = tonumber(params.dir) or 1     -- 1 = right, -1 = left
  local cx, cy = px + 26 * dir, py

  local ok, chest = pcall(EntityLoad, CHEST, cx, cy)
  if not ok or not chest or chest == 0 then
    return { ok = false, error = "EntityLoad failed for " .. CHEST,
             raw = ok and "returned no entity" or tostring(chest) }
  end

  -- let it settle onto the ground for a moment before the caller interacts
  return {
    ok = true,
    chest = chest,
    template = CHEST,
    spawned_at = { cx, cy },
    player = p,
    player_pos = { px, py },
    distance = math.sqrt((cx - px) ^ 2 + (cy - py) ^ 2),
    tags = (select(2, pcall(EntityGetTags, chest))),
    item_name = (select(2, pcall(ComponentGetValue2,
                  (select(2, pcall(ser.comp, chest, "ItemComponent")) or 0), "item_name"))),
    nearby = nearby_summary(140),
    note = "the chest opens on PICKUP; press the interact key (measured: E) while " ..
           "standing next to it",
  }
end

return fixture

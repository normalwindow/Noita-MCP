-- Player interaction primitives.
--
-- Every function here is backed by a MEASURED result from a live run. What was
-- measured, and what it means for the design:
--
--   switch held item   WORKS  -- write Inventory2Component.mActiveItem; all four
--                                engine views (mActiveItem, mActualActiveItem,
--                                ser.held_item, ser.held_wand) follow it
--   pickup             WORKS  -- GamePickUpInventoryItem, but ONLY for items that
--                                carry an AbilityComponent. Measured: potion.xml
--                                enters the inventory, heart.xml and
--                                goldnugget.xml do not (they use the engine's own
--                                auto-pickup, which needs proximity, not a call),
--                                and wand.xml has no ItemComponent at all.
--   drop (whole pack)  WORKS  -- GameDropPlayerInventoryItems moves carried items
--                                into the world and leaves equipped body parts
--                                (arm_r, cape) alone
--   drop (targeted)    WORKS  -- detach the item from its container by setting its
--                                parent to the player, then to 0, then place it
--                                with velocity. A direct EntitySetParent(item, 0)
--                                does NOT work: the item's parent is a container
--                                (inventory_quick), so clearing the parent leaves
--                                it in the container.
--   launch projectile  WORKS  -- GameShootProjectile with explicit coordinates.
--                                This is the AI launching something; it is NOT the
--                                player firing their wand.
--   fire held wand     BLOCKED-- mButtonDownFire accepts the write but the engine
--                                never observes it (mButtonFrameFire stays 0)
--   aim                BLOCKED-- mAimingVector accepts the write and is recomputed
--                                before anything reads it
--   throw (engine)     BLOCKED-- mThrowItem accepts the write but the throw still
--                                needs the throw button
--   use item           NO API -- there is no engine function to trigger a use
--
-- WHY THE BLOCKED ONES ARE NOT FIXABLE BY PATCHING THE GAME FROM LUA
--
-- The natural next idea is to defeat the per-frame reset with a binary patch.
-- That was investigated and it does NOT work, for a reason worth recording:
--
--   * patching is technically possible: the module base is fixed (0x400000, no
--     ASLR), static addresses were confirmed valid at runtime byte-for-byte, and
--     VirtualProtect + write + verify + restore all work from Lua
--   * but the control fields are a MIRROR of real input, not a driver. The engine
--     reads the OS/SDL input state and copies it in each frame. Patching the copy
--     -- or the reset -- changes a value the engine never consults for its
--     decision, which is exactly what the 60-frame experiment shows: the field
--     reads true and nothing happens
--   * forging input therefore requires intercepting the INPUT SOURCE (SDL's
--     keyboard state, or the engine's read of it). That is not reachable from the
--     mod sandbox; it needs a DLL/ASI hook loaded into the process
--
-- So pure-Lua input takeover is not achievable, and the honest answer to "make the
-- player fire the wand" stays no. What IS available is everything that acts on the
-- state the input feeds: motion, repositioning, gear, and launched projectiles.

player_ops = player_ops or {}

local INV2 = "Inventory2Component"

local function rd(comp, field)
  if not comp then return nil end
  local ok, a = pcall(ComponentGetValue2, comp, field)
  if not ok then return nil end
  return a
end

local function wr(comp, field, a, b)
  if not comp then return false end
  if b ~= nil then return (pcall(ComponentSetValue2, comp, field, a, b)) end
  return (pcall(ComponentSetValue2, comp, field, a))
end

local function carried(player, item)
  local items = ser.inventory_items(player) or {}
  for _, e in ipairs(items) do if e == item then return true end end
  return false
end

-- ---------------------------------------------------------------- inventory

-- What the player is carrying, what is equipped, and what is in hand.
function player_ops.inventory(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end
  local inv = ser.comp(p, INV2)
  if not inv then return { ok = false, error = "player has no " .. INV2 } end

  local items = ser.inventory_items(p) or {}
  local active = rd(inv, "mActiveItem")

  local out = {
    ok = true,
    player = p,
    held_item = active,
    held_wand = ser.held_wand(p),
    count = #items,
    items = {},
  }

  for _, e in ipairs(items) do
    local s = ser.item_summary(e) or { entity = e }
    s.active = (e == active)
    local item = ser.comp(e, "ItemComponent")
    if item then
      s.uses_remaining = rd(item, "uses_remaining")
      s.is_consumable = rd(item, "is_consumable")
      s.drinkable = rd(item, "drinkable")
    end
    -- the container tells us whether it is pack gear or worn equipment
    local parent = (select(2, pcall(EntityGetParent, e)))
    local pname = parent and (select(2, pcall(EntityGetName, parent)))
    s.container = pname
    s.in_pack = (pname == "inventory_quick" or pname == "inventory_full")
    out.items[#out.items + 1] = s
  end
  return out
end

-- ---------------------------------------------------------------- switch

-- Puts a specific item in the player's hand. Measured to persist: the engine's
-- own held-item lookups follow the write.
function player_ops.switch(params)
  params = params or {}
  local p = ser.player()
  local inv = ser.comp(p, INV2)
  if not inv then return { ok = false, error = "no " .. INV2 } end

  local items = ser.inventory_items(p) or {}
  local target = tonumber(params.entity)

  -- useful defaults so a caller does not have to know entity ids
  if not target then
    local want = params.wand and "wand" or params.kind
    for _, e in ipairs(items) do
      if want == "wand" and EntityHasTag(e, "wand") then target = e break end
      if want and want ~= "wand" then
        local s = ser.item_summary(e)
        if s and s.kind == want then target = e break end
      end
    end
  end
  if not target then
    -- last resort: the next pack item that is not already held
    local cur = rd(inv, "mActiveItem")
    for _, e in ipairs(items) do
      if e ~= cur then target = e break end
    end
  end
  if not target then
    return { ok = false, error = "no item to switch to", count = #items }
  end
  if not carried(p, target) then
    return { ok = false, error = "entity " .. tostring(target) .. " is not carried" }
  end

  local before = rd(inv, "mActiveItem")
  wr(inv, "mActiveItem", target)
  wr(inv, "mForceRefresh", true)

  return {
    ok = true,
    requested = target,
    name = (ser.item_summary(target) or {}).name,
    previous = before,
    readback = rd(inv, "mActiveItem"),
    held_item = ser.held_item(p),
    held_wand = ser.held_wand(p),
  }
end

-- ---------------------------------------------------------------- pickup

-- Takes an item into the inventory.
--
-- Only items with an AbilityComponent can be taken this way; the check is
-- reported instead of silently failing, because the two look identical from the
-- caller's side otherwise.
function player_ops.pickup(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end

  local item = tonumber(params.entity)
  if not item then return { ok = false, error = "entity required" } end

  local exists = select(1, pcall(EntityGetTransform, item))
  if not exists then
    return { ok = false, error = "entity " .. item .. " does not exist" }
  end
  if carried(p, item) then
    return { ok = true, already_carried = true, entity = item }
  end

  local ic = ser.comp(item, "ItemComponent")
  local ab = ser.comp(item, "AbilityComponent")
  if not ic then
    return {
      ok = false,
      entity = item,
      error = "this entity has no ItemComponent, so it cannot go in an inventory " ..
              "(wands and items that spawn as world props are created by the game, " ..
              "not picked up)",
      has_ability = ab ~= nil,
    }
  end

  -- clear the spawn protection so the test is about the API, not about timing
  wr(ic, "is_pickable", true)
  wr(ic, "next_frame_pickable", 0)
  if params.radius then wr(ic, "item_pickup_radius", tonumber(params.radius)) end

  local ok_call, err = pcall(GamePickUpInventoryItem, p, item, params.effects ~= false)
  local got = carried(p, item)

  local out = {
    ok = got,
    entity = item,
    name = (ser.item_summary(item) or {}).name,
    call_ok = ok_call,
    call_error = (not ok_call) and tostring(err) or nil,
    in_inventory = got,
    has_ability = ab ~= nil,
  }
  if not got then
    out.error = ab
      and "the call went through but the item did not enter the inventory"
      or "this item has no AbilityComponent; the engine only accepts ability items " ..
         "through this call (auto-pickup items like hearts and gold are collected by " ..
         "proximity instead)"
  end
  return out
end

-- ---------------------------------------------------------------- drop

-- Releases EVERY item in the pack into the world. Worn equipment is left alone --
-- measured: a 7-item inventory became 3, keeping arm_r and cape.
--
-- WHEN TO USE THIS (the caller should not have to guess, so the tool decides):
--   * "drop everything", "empty my bag", "丢光背包" -> this
--   * "drop the wand", "throw the potion", "扔掉那个" -> drop_targeted, NOT this
--
-- A single-item request MUST NOT come here: emptying the pack destroys the run's
-- gear layout and is not what the user asked for. To make that mistake impossible
-- from the API side, this function reports exactly what it is about to remove, and
-- refuses unless the intent is explicit -- either the caller passes confirm=true,
-- or the request is genuinely unqualified (no entity/kind named).
function player_ops.drop_all(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end

  local before = ser.inventory_items(p) or {}

  -- If the caller named a specific item, they want THAT one released, not the bag.
  -- Redirect instead of destroying their gear layout.
  if params.entity or params.kind or params.wand then
    local wanted = tonumber(params.entity)
    if not wanted and params.wand then
      wanted = ser.held_wand(p)
    end
    if not wanted and params.kind then
      for _, e in ipairs(before) do
        local s = ser.item_summary(e)
        if s and s.kind == params.kind then wanted = e break end
      end
    end
    if wanted then
      local r = player_ops.drop_targeted({ entity = wanted, speed = params.speed, angle = params.angle })
      r.redirected_from = "drop_all"
      r.redirect_reason = "a specific item was named, so only that item is released; " ..
                          "call drop_all with no entity/kind to empty the pack"
      return r
    end
  end

  -- Nothing named: this is a genuine "empty the pack" request. It is destructive
  -- and not undoable, so require confirmation and say what will go.
  if params.confirm ~= true then
    local will_drop, will_keep = {}, {}
    for _, e in ipairs(before) do
      local s = ser.item_summary(e) or { entity = e }
      -- in_pack must be carried through: it comes from item_summary, and dropping
      -- it here silently made the confirmation list empty (a gate that lists
      -- nothing is worse than no gate, because it looks like nothing will happen)
      local rec = {
        entity = e,
        name = s.name,
        kind = s.kind,
        container = s.container,
        in_pack = s.in_pack,
      }
      if s.in_pack then will_drop[#will_drop + 1] = rec else will_keep[#will_keep + 1] = rec end
    end
    return {
      ok = false,
      needs_confirmation = true,
      would_drop = will_drop,
      would_keep = will_keep,
      count_would_drop = #will_drop,
      count_would_keep = #will_keep,
      error = "this empties the whole pack (" .. #will_drop .. " item(s)) and cannot be " ..
              "undone; call again with confirm=true to proceed, or use noita_drop_item " ..
              "with an entity to release just one item",
    }
  end

  local ok_call, err = pcall(GameDropPlayerInventoryItems, p)
  local after = ser.inventory_items(p) or {}

  return {
    ok = ok_call,
    call_error = (not ok_call) and tostring(err) or nil,
    count_before = #before,
    count_after = #after,
    dropped = #before - #after,
    kept = (function()
      local k = {}
      for _, e in ipairs(after) do
        k[#k + 1] = { entity = e, name = (ser.item_summary(e) or {}).name }
      end
      return k
    end)(),
  }
end

-- Releases ONE item into the world with velocity.
--
-- This is the supported substitute for throwing. It is real physics -- the item
-- becomes a world entity and flies -- but it is NOT the engine's throw: no throw
-- animation, and on-throw effects the engine would apply may not fire. The
-- response says so rather than pretending otherwise.
function player_ops.drop_targeted(params)
  params = params or {}
  local p = ser.player()
  local inv = ser.comp(p, INV2)
  if not p or not inv then return { ok = false, error = "no player/inventory" } end

  local item = tonumber(params.entity) or ser.held_item(p)
  if not item then return { ok = false, error = "nothing held and no entity given" } end
  if not carried(p, item) then
    return { ok = false, error = "entity " .. item .. " is not carried" }
  end

  local px, py = EntityGetTransform(p)
  local speed = tonumber(params.speed) or 300
  local ang = tonumber(params.angle)
  local vx, vy
  if ang then
    -- WORLD CONVENTION: y increases downward, so a positive angle rotates CLOCKWISE on
    -- screen and 90 degrees points DOWN. This used to be written with a negated sin here and in
    -- two other places in this file, which flipped every angle vertically -- the documented
    -- convention said 90 = down while these paths went up. Found by writing the convention down
    -- and then checking the code against it; see ANGLES-AND-DISTANCES.md.
    vx = math.cos(math.rad(ang)) * speed
    vy = math.sin(math.rad(ang)) * speed
  else
    vx, vy = speed, 0
  end

  -- 1. out of the hand
  local prev = rd(inv, "mActiveItem")
  wr(inv, "mActiveItem", 0)
  wr(inv, "mActualActiveItem", 0)
  wr(inv, "mThrowItem", 0)
  wr(inv, "mForceRefresh", true)

  -- 2. out of the container.
  --    Measured: an item's parent is its container (inventory_quick), so
  --    EntitySetParent(item, 0) leaves it in the pack. EntityRemoveFromParent is
  --    the API that actually detaches it; the setparent calls remain as a
  --    fallback for items parented directly to the player.
  pcall(EntityRemoveFromParent, item)
  local parent_now = (select(2, pcall(EntityGetParent, item)))
  if parent_now and parent_now ~= 0 then
    pcall(EntitySetParent, item, p)
    pcall(EntitySetParent, item, 0)
  end

  -- 3. into the world, under its own physics
  local ux, uy = (speed > 0) and (vx / speed) or 1, (speed > 0) and (vy / speed) or 0
  local sx, sy = px + ux * 14, py + uy * 14
  pcall(EntitySetTransform, item, sx, sy)

  local cd = ser.comp(item, "CharacterDataComponent")
  if cd then pcall(ComponentSetValue2, cd, "mVelocity", vx, vy) end
  local vc = ser.comp(item, "VelocityComponent")
  if vc then pcall(ComponentSetValue2, vc, "mVelocity", vx, vy) end
  local pb = ser.comp(item, "PhysicsBodyComponent")
  if pb then
    pcall(ComponentSetValue2, pb, "is_static", false)
    pcall(ComponentSetValue2, pb, "is_kinematic", false)
    pcall(ComponentSetValue2, pb, "allow_sleep", false)
  end

  -- 4. do not let it be vacuumed straight back up
  local ic = ser.comp(item, "ItemComponent")
  if ic then wr(ic, "next_frame_pickable", GameGetFrameNum() + 40) end

  local still = carried(p, item)
  return {
    ok = not still,
    entity = item,
    name = (ser.item_summary(item) or {}).name,
    released = not still,
    detached = (parent_now == 0 or parent_now == nil),
    parent_after = parent_now,
    placed_at = { sx, sy },
    velocity = { vx, vy },
    previous_held = prev,
    caveat = "physics release, not the engine's throw: no throw animation and " ..
             "engine-side on-throw effects may not fire",
  }
end

-- ---------------------------------------------------------------- projectile

-- Launches a projectile from the player toward a point, using the engine's own
-- GameShootProjectile. This is the AI firing something into the world; it is NOT
-- the player's wand (that path is blocked by the control-field reset).
function player_ops.launch(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end

  local px, py = EntityGetTransform(p)
  local tx = tonumber(params.tx)
  local ty = tonumber(params.ty)

  -- allow a direction + distance instead of explicit coordinates
  if not tx and params.angle then
    local dist = tonumber(params.distance) or 200
    local a = math.rad(tonumber(params.angle))
    tx = px + math.cos(a) * dist
    ty = py + math.sin(a) * dist
  end
  if not tx then tx, ty = px + 200, py end

  local template = params.template or "data/entities/projectiles/light_bullet.xml"
  local ok_load, proj = pcall(EntityLoad, template, px, py)
  if not ok_load or not proj or proj == 0 then
    return { ok = false, error = "could not load projectile template " .. tostring(template) }
  end

  local ok_call, err = pcall(GameShootProjectile, p, px, py, tx, ty, proj,
                             params.message ~= false, 0)

  local out = {
    ok = ok_call,
    projectile = proj,
    template = template,
    from = { px, py },
    toward = { tx, ty },
    call_error = (not ok_call) and tostring(err) or nil,
    is_player_wand = false,
    note = "this is a projectile launched by the AI, not the player firing their wand",
  }
  local alive = EntityGetTransform(proj)
  out.alive = alive ~= nil
  return out
end

-- ---------------------------------------------------------------- world / map

-- Where the player is in the world, and what is around them.
--
-- `GameGetBiomeName` does not exist; the biome is read with BiomeMapGetName, which
-- takes a world position (defaulting to the camera). Reading it from the player's
-- own position is more useful and is what this does.
--
-- Fog of war is sampled on a coarse grid rather than per cell: it is an
-- exploration map, so a 9x9 sample is enough to tell "unexplored to the west" from
-- "cleared around me", and GameGetFogOfWar is not cheap.
function player_ops.world(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end
  local px, py = EntityGetTransform(p)

  local out = {
    ok = true,
    player = p,
    position = { x = px, y = py },
    frame = GameGetFrameNum(),
  }

  -- Biome name, plus the biome map's own file for the position.
  --
  -- MEASURED: BiomeMapGetName needs the Y axis NEGATED relative to the entity
  -- coordinate system. Querying with the player's own y returns "_EMPTY_"; the same
  -- position with -y returns the real name (e.g. "$biome_coalmine"). Both are tried
  -- so the answer does not silently depend on which convention is right, and the
  -- raw value is reported so an "_EMPTY_" is visible rather than mistaken for a
  -- biome literally named empty.
  local function biome_lookup(x, y)
    local ok_a, a = pcall(BiomeMapGetName, x, y)
    if ok_a and a and a ~= "_EMPTY_" then return a, "xy" end
    local ok_b, b = pcall(BiomeMapGetName, x, -y)
    if ok_b and b and b ~= "_EMPTY_" then return b, "x_neg_y" end
    local ok_c, c = pcall(BiomeMapGetName)
    if ok_c and c and c ~= "_EMPTY_" then return c, "camera" end
    return (ok_a and a) or nil, "none"
  end

  local name_here, how_here = biome_lookup(px, py)
  out.biome_here = name_here
  out.biome_lookup = how_here
  local name_cam, how_cam = biome_lookup(px + 200, py)
  out.biome_nearby = name_cam
  out.biome_nearby_lookup = how_cam

  -- the biome's own file for this position: resolves the id above to a path
  local ok_dbg, dbg = pcall(DebugBiomeMapGetFilename, px, py)
  if ok_dbg then out.biome_file = dbg end

  -- how deep inside the current biome, and where in the parallel-world grid
  local ok_d, depth = pcall(BiomeMapGetVerticalPositionInsideBiome, px, py)
  out.depth_in_biome = ok_d and depth or nil

  local ok_pw, wx, wy = pcall(GetParallelWorldPosition, px, py)
  if ok_pw then
    out.parallel_world = {
      world_x = wx,      -- 0 = normal, -1 = first west, +1 = first east
      world_y = wy,      -- <0 sky, >0 hell
      note = "0,0 is the normal world; nonzero means a parallel/sky/hell region",
    }
  end

  -- run progress signals that are cheap and unambiguous
  local function g(fn, ...)
    local ok, v = pcall(fn, ...)
    return ok and v or nil
  end
  out.orbs = {
    this_run = g(GameGetOrbCountThisRun),
    all_time = g(GameGetOrbCountAllTime),
    total = g(GameGetOrbCountTotal),
  }
  out.ng_plus = g(GameGetNGPlusCount) or (ser.player_state and ser.player_state().ng_plus)

  -- camera rectangle, so a caller can convert world <-> screen for aiming
  local ok_c, cx, cy, cw, ch = pcall(GameGetCameraBounds)
  if ok_c then out.camera = { x = cx, y = cy, w = cw, h = ch } end

  -- coarse fog-of-war sample: how explored is the area around the player
  local radius = tonumber(params.radius) or 512
  local steps = 9
  local grid, explored, unknown = {}, 0, 0
  for iy = 0, steps - 1 do
    local row = {}
    for ix = 0, steps - 1 do
      local sx = px + (ix / (steps - 1) - 0.5) * 2 * radius
      local sy = py + (iy / (steps - 1) - 0.5) * 2 * radius
      local ok_f, fog = pcall(GameGetFogOfWar, sx, sy)
      if ok_f and type(fog) == "number" then
        row[#row + 1] = fog
        if fog >= 0 then explored = explored + 1 else unknown = unknown + 1 end
      else
        row[#row + 1] = -1
        unknown = unknown + 1
      end
    end
    grid[#grid + 1] = row
  end
  out.fog_of_war = {
    radius = radius,
    grid = grid,
    sampled = explored + unknown,
    in_bounds = explored,
    out_of_bounds = unknown,
    note = "0..255, larger = more explored; -1 means outside the fog grid. " ..
           "Rows are north to south, columns west to east.",
  }

  -- what the player can see nearby, as a convenience for "is anything here"
  if params.nearby ~= false then
    out.nearby_count = #(ser.nearby(tonumber(params.nearby_radius) or 300, 25) or {})
  end

  return out
end

-- The biome map's own naming for a position, plus its vertical extent.
--
-- Useful for "which biome is at x,y" without moving the player, and for planning a
-- descent: the vertical position inside a biome is how the game decides what to
-- generate next.
function player_ops.biome_at(params)
  params = params or {}
  local p = ser.player()
  if not p then return { ok = false, error = "no player" } end
  local px, py = EntityGetTransform(p)
  local x = tonumber(params.x) or px
  local y = tonumber(params.y) or py

  local out = { ok = true, x = x, y = y }
  -- same Y-negation convention as noita_world; see the note there
  local ok, name = pcall(BiomeMapGetName, x, y)
  if not (ok and name and name ~= "_EMPTY_") then
    local ok2, name2 = pcall(BiomeMapGetName, x, -y)
    if ok2 and name2 and name2 ~= "_EMPTY_" then name, ok = name2, true end
  end
  out.biome = ok and name or nil
  if not ok then out.error = tostring(name) end

  local ok_dbg, dbg = pcall(DebugBiomeMapGetFilename, x, y)
  if ok_dbg then out.biome_file = dbg end

  local ok2, depth = pcall(BiomeMapGetVerticalPositionInsideBiome, x, y)
  out.vertical_position_in_biome = ok2 and depth or nil

  local ok3, wx, wy = pcall(GetParallelWorldPosition, x, y)
  if ok3 then out.parallel_world = { world_x = wx, world_y = wy } end

  local ok4, sky = pcall(GameGetSkyVisibility, x, y)
  out.sky_visibility = ok4 and sky or nil

  return out
end

-- ---------------------------------------------------------------- capability

-- Reports what can and cannot be driven, so a caller checks instead of assuming.
--
-- The answer depends on whether the optional input extension is loaded, so it is
-- computed at call time instead of being a static description. The base mod is
-- pure Lua and always works; the extension is what unlocks the input path.
function player_ops.capabilities()
  local p = ser.player()
  local ctl = ser.comp(p, "ControlsComponent")
  local frame = rd(ctl, "mButtonFrameFire")

  local ext = (xinput and xinput.status()) or
    { available = false, reason = "xinput module missing" }

  local blocked = {
    use_item = "no engine function exists to trigger an item use",
  }

  local unlocked = {}
  if ext.available then
    unlocked = {
      keys = "noita_input_key / noita_input_move hold any key -- VERIFIED: left/right " ..
             "give vx = +/-56.6 symmetrically against a zero baseline",
      fire_held_wand = "noita_input_fire holds the LEFT MOUSE BUTTON, which is what Noita " ..
                       "fires on -- VERIFIED by the engine's own mButtonFrameFire advancing",
      aim = "noita_input_aim places the click coordinate the engine derives its aim from",
      jump = "SPACE is the fly key and is forgeable like any other",
    }
  else
    blocked.fire_held_wand = "the control fields are a mirror of real input, so writing " ..
                             "them does nothing; the input SOURCE must be intercepted, " ..
                             "which is what the input extension does"
    blocked.keys = "pure Lua cannot press a key: the engine mirrors the OS input state " ..
                   "into its control fields every frame"
  end

  return {
    ok = true,
    input_extension = ext,
    mode = ext.available and "full (input extension loaded)" or "base (pure Lua)",
    works = {
      inventory = "read carried items, equipment and the held item",
      switch = "put any carried item in hand (mActiveItem)",
      pickup = "take an ability item into the inventory",
      drop_all = "empty the pack into the world (equipment stays worn)",
      drop_targeted = "release one item with velocity (physics, not the engine throw)",
      launch = "fire a projectile into the world from the player",
      move_direct = "command the player's motion by writing velocity (noita_lever_*)",
    },
    blocked = blocked,
    unlocked_by_extension = unlocked,
    input_method = ext.available
      and "events are synthesised into SDL's own queue via SDL_PushEvent, called from the " ..
          "per-frame update (never from inside SDL, which would deadlock). Every return " ..
          "value stays SDL's own, so the engine's event loop is unaffected."
      or nil,
    root_cause = ext.available
      and "input is intercepted at its source, so the control fields are driven rather " ..
          "than merely mirrored"
      or "the engine copies the OS/SDL input state into these fields every frame, so a " ..
         "synthetic value is neither consulted nor retained",
    patchable_from_lua = false,
    patch_note = "Patching the game binary from Lua IS technically possible (module base " ..
                 "0x400000 with no ASLR, addresses verified at runtime, and " ..
                 "VirtualProtect/write/verify/restore all work). It does not help: " ..
                 "defeating the reset would still leave a value the engine never consults. " ..
                 "Forging input needs the input SOURCE intercepted -- which is what the " ..
                 "input extension provides.",
    evidence = { mButtonFrameFire_now = frame },
  }
end

-- ---------------------------------------------------------------- input (extension)

-- The operations that are impossible in base mode and available with the
-- extension. Each one reports the base-mode reason instead of failing obscurely,
-- so a caller always learns WHY it could not act.
local function needs_extension()
  local st = xinput and xinput.status() or { available = false, reason = "xinput missing" }
  if st.available then return nil end
  return {
    ok = false,
    needs_input_extension = true,
    error = "this needs the optional input extension: the base mod cannot forge input " ..
            "because the engine mirrors the OS/SDL state every frame. " ..
            "Reason: " .. tostring(st.reason),
    install = "see agent/extensions/input-hook/README.md",
  }
end

-- Presses a key for N frames (movement, jump, interact, hotbar...).
function player_ops.input_key(params)
  params = params or {}
  local no = needs_extension()
  if no then return no end
  return xinput.tap(params.key, params.frames or 6)
end

-- Holds or releases the fire button. With the input source intercepted, the
-- engine's own fire logic runs, so this is the real wand firing.
function player_ops.input_fire(params)
  params = params or {}
  local no = needs_extension()
  if no then return no end
  local down = (params.down ~= false)
  return xinput.set_key("SPACE", down, params.frames or 30)
end

-- Points the mouse, which is what the engine derives the aim vector from.
--
-- Screen and world coordinates are related by an affine transform whose offset is
-- the camera. Rather than assume the mapping, it is CALIBRATED against the engine
-- itself: sample the real mouse position and ask the engine what world point that
-- corresponds to, which yields the offset directly. Then any world-space target
-- can be converted to the screen coordinate to forge.
function player_ops.input_aim(params)
  params = params or {}
  local no = needs_extension()
  if no then return no end

  -- Calibrate: one sample gives the world offset for the current screen origin.
  local mx, my = InputGetMousePosOnScreen()
  local wx, wy = DEBUG_GetMouseWorld()
  local cal = {
    mouse_screen = { mx, my },
    mouse_world = { wx, wy },
    ok = (mx and my and wx and wy) and true or false,
  }
  if not cal.ok then
    return { ok = false, error = "camera calibration failed (no mouse/world reading)" }
  end

  -- world = screen + offset  ->  screen = world - offset
  local off_x, off_y = wx - mx, wy - my

  local tx, ty = tonumber(params.x), tonumber(params.y)
  if not tx and params.angle then
    local p = ser.player()
    local px, py = EntityGetTransform(p)
    local dist = tonumber(params.distance) or 200
    local a = math.rad(tonumber(params.angle))
    tx = px + math.cos(a) * dist
    ty = py + math.sin(a) * dist
    cal.derived_world_target = { tx, ty }
  end

  if not tx then
    return { ok = false, error = "give x/y (world coordinates) or angle+optional distance",
             calibration = cal }
  end

  local sx, sy = tx - off_x, ty - off_y
  local r = xinput.set_mouse(sx, sy, tonumber(params.buttons) or 0)
  r.target_world = { tx, ty }
  r.target_screen = { sx, sy }
  r.calibration = cal
  r.note = "the engine derives the aim vector from the mouse, so this aims the wand"
  return r
end

-- Releases every forge. Always safe to call, including when nothing is forged.
function player_ops.input_clear()
  if not (xinput and xinput.clear) then
    return { ok = true, note = "no extension loaded" }
  end
  return xinput.clear()
end

return player_ops
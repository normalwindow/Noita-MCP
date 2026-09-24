-- Game-side read/write helpers for the Noita MCP Agent Bridge.
--
-- Everything that touches Noita components lives here so the RPC layer stays
-- thin. All read paths are defensive: a missing component or entity must never
-- throw, because an error inside OnWorldPostUpdate can break the run.

ser = ser or {}

dofile_once("data/scripts/gun/gun_enums.lua")
dofile_once("data/scripts/gun/procedural/gun_action_utils.lua")

local cached_actions = nil
local cached_perks = nil
local spell_by_id = nil

-- ---------------------------------------------------------------- basics

function ser.player()
  local p = EntityGetWithTag("player_unit")[1]
  if p and p ~= 0 then return p end
  p = EntityGetWithTag("polymorphed_player")[1]
  if p and p ~= 0 then return p end
  return nil
end

function ser.comp(entity, kind, tag)
  if not entity or entity == 0 then return nil end
  local c
  if tag then
    c = EntityGetFirstComponentIncludingDisabled(entity, kind, tag)
  else
    c = EntityGetFirstComponentIncludingDisabled(entity, kind)
  end
  if c == 0 then return nil end
  return c
end

function ser.field(entity, kind, field, tag)
  local c = ser.comp(entity, kind, tag)
  if not c then return nil end
  local ok, v = pcall(ComponentGetValue2, c, field)
  if ok then return v end
  return nil
end

function ser.set_field(entity, kind, field, value, tag)
  local c = ser.comp(entity, kind, tag)
  if not c then return false, "no component " .. kind end
  local ok, err = pcall(ComponentSetValue2, c, field, value)
  return ok, err
end

function ser.gun(entity, field)
  local c = ser.comp(entity, "AbilityComponent")
  if not c then return nil end
  local ok, v = pcall(ComponentObjectGetValue2, c, "gun_config", field)
  if ok then return v end
  return nil
end

function ser.set_gun(entity, field, value)
  local c = ser.comp(entity, "AbilityComponent")
  if not c then return false, "no AbilityComponent" end
  local ok, err = pcall(ComponentObjectSetValue2, c, "gun_config", field, value)
  return ok, err
end

-- Interpret a gun_config bool member across every representation the engine may
-- hand back. shuffle_deck_when_empty is declared `bool` in ConfigGun, but the
-- runtime stores and returns it as the strings "0"/"1" (that is what vanilla
-- writes via ComponentObjectSetValue), while Lua-side tables use numbers or
-- real booleans. Enumerating only 1/true made shuffled wands read as unshuffled.
local function tobool_gun(v)
  if v == true then return true end
  if v == 1 then return true end
  if v == "1" or v == "true" then return true end
  return false
end

-- Encode a gun_config bool member for ComponentObjectSetValue2.
--
-- MEASURED, after an earlier assumption here turned out to be wrong. The engine
-- stores this member as a real boolean and accepts a real boolean. The previous
-- version passed the strings "1"/"0" on the theory that they were accepted; the
-- game logged "'boolean' expected for 'shuffle_deck_when_empty' but 'string'
-- given", and worse, "0" is TRUTHY in Lua, so a wand could never be set back to
-- non-shuffling through this path.
--
-- What a live probe found (write, then read the stored value back):
--   boolean true  -> stored true    (accepted)
--   boolean false -> stored false   (accepted, and this is the one that matters)
--   number 1      -> stored true    (accepted)
--   number 0      -> stored true    (NOT accepted: silently ignored)
--   string "1"    -> stored true
--   string "0"    -> stored true    (NOT accepted: "0" is truthy in Lua)
--
-- So: pass a boolean, and keep the tolerant decoder for reading.
local function encode_gun_bool(v)
  if v == true or v == 1 or v == "1" or v == "true" then return true end
  if v == false or v == 0 or v == "0" or v == "false" then return false end
  return v and true or false
end

-- Exposed for tests: the encoding rule above is exactly the kind of thing that
-- silently regresses, and it is not reachable through any public entry point.
encode_gun_bool_probe = encode_gun_bool

function ser.gunaction(entity, field)
  local c = ser.comp(entity, "AbilityComponent")
  if not c then return nil end
  local ok, v = pcall(ComponentObjectGetValue2, c, "gunaction_config", field)
  if ok then return v end
  return nil
end

function ser.set_gunaction(entity, field, value)
  local c = ser.comp(entity, "AbilityComponent")
  if not c then return false, "no AbilityComponent" end
  local ok, err = pcall(ComponentObjectSetValue2, c, "gunaction_config", field, value)
  return ok, err
end

function ser.kill(entity)
  if not entity or entity == 0 then return end
  pcall(EntityRemoveFromParent, entity)
  pcall(EntityKill, entity)
end

-- ---------------------------------------------------------------- catalogs

function ser.actions()
  if cached_actions then return cached_actions end
  local ok = pcall(dofile_once, "data/scripts/gun/gun_actions.lua")
  if not ok or type(actions) ~= "table" then
    cached_actions = {}
    return cached_actions
  end
  cached_actions = actions
  spell_by_id = {}
  for i = 1, #actions do
    local a = actions[i]
    if a and a.id then spell_by_id[a.id] = a end
  end
  return cached_actions
end

local TYPE_NAMES = {
  [0] = "projectile",
  [1] = "static_projectile",
  [2] = "modifier",
  [3] = "draw_many",
  [4] = "material",
  [5] = "other",
  [6] = "utility",
  [7] = "passive",
}

function ser.action_info(id)
  ser.actions()
  local a = spell_by_id and spell_by_id[id]
  if not a then return nil end
  local name = a.name or id
  local ok, translated = pcall(GameTextGetTranslatedOrNot, name)
  return {
    id = a.id,
    name = name,
    name_human = ok and translated or name,
    description = a.description,
    type = TYPE_NAMES[a.type] or tostring(a.type),
    type_id = a.type,
    mana = a.mana,
    max_uses = a.max_uses,
    price = a.price,
    sprite = a.sprite,
    spawn_level = a.spawn_level,
  }
end

function ser.all_actions()
  local list = {}
  local a = ser.actions()
  for i = 1, #a do
    local item = a[i]
    if item and item.id then
      local info = ser.action_info(item.id)
      if info then list[#list + 1] = info end
    end
  end
  return list
end

function ser.perks()
  if cached_perks then return cached_perks end
  pcall(dofile_once, "data/scripts/perks/perk_list.lua")
  if type(perk_list) ~= "table" then
    cached_perks = {}
    return cached_perks
  end
  cached_perks = perk_list
  return cached_perks
end

-- ---------------------------------------------------------------- player read

function ser.player_state()
  local p = ser.player()
  if not p then return { valid = false, reason = "no player entity" } end

  local x, y, rot = EntityGetTransform(p)
  local state = {
    valid = true,
    entity = p,
    x = x,
    y = y,
    rotation = rot,
    frame = GameGetFrameNum(),
    world_seed = nil,
    ng_plus = tonumber(SessionNumbersGetValue("NEW_GAME_PLUS_COUNT") or "0") or 0,
  }

  local dm = ser.comp(p, "DamageModelComponent")
  if dm then
    state.hp = ComponentGetValue2(dm, "hp")
    state.max_hp = ComponentGetValue2(dm, "max_hp")
    state.hp_percent = state.max_hp and state.max_hp > 0 and (state.hp / state.max_hp) or 0
    state.invincibility_frames = ComponentGetValue2(dm, "invincibility_frames")
    state.air = ComponentGetValue2(dm, "air_in_lungs")
    state.air_max = ComponentGetValue2(dm, "air_in_lungs_max")
    state.on_fire = ComponentGetValue2(dm, "is_on_fire")
    state.max_hp_cap = ComponentGetValue2(dm, "max_hp_cap")
  end

  local wallet = ser.comp(p, "WalletComponent")
  if wallet then
    state.money = ComponentGetValue2(wallet, "money")
    state.money_infinite = ComponentGetValue2(wallet, "mHasReachedInf")
  end

  local cd = ser.comp(p, "CharacterDataComponent")
  if cd then
    local vx, vy = ComponentGetValue2(cd, "mVelocity")
    -- multi-value fields come back as several return values, but a table
    -- shows up when the engine packs them; accept both shapes
    if type(vx) == "table" then vx, vy = vx[1], vx[2] end
    state.vx = vx
    state.vy = vy
    state.on_ground = ComponentGetValue2(cd, "mOnGround")
    state.fly_time = ComponentGetValue2(cd, "mFlyingTimeLeft")
  else
    local ok, vx, vy = pcall(GameGetVelocityCompVelocity, p)
    if ok then state.vx, state.vy = vx, vy end
  end

  -- Status effects are loaded as separate child ENTITIES (for example
  -- data/entities/misc/effect_protection_all.xml), each carrying a
  -- GameEffectComponent and an "effect_*" tag. Reading components off the player
  -- itself therefore always comes back empty -- verified in a live run.
  local effects = {}
  local children = EntityGetAllChildren(p) or {}
  for i = 1, #children do
    local c = children[i]
    local ec = ser.comp(c, "GameEffectComponent")
    if ec then
      -- entity name looks like ".../effect_wet.xml" -> "WET"
      local id = nil
      local ok_name, ename = pcall(EntityGetName, c)
      if ok_name and ename and ename ~= "" then
        id = string.upper(ename)
      end
      local ok_file, file = pcall(EntityGetFilename, c)
      if (not id or id == "") and ok_file and file then
        id = string.upper(file:match("([^/\\]+)%.xml$") or file)
      end
      if id then id = id:gsub("^EFFECT_", "") end

      -- a friendly name (the game has translations for many effects)
      local label = id
      local ui = ser.field(c, "UIIconComponent", "ui_name")
      if type(ui) == "string" and ui ~= "" then
        local ok_t, t = pcall(GameTextGetTranslatedOrNot, ui)
        if ok_t and t then label = t end
      end

      effects[#effects + 1] = {
        effect = id,
        name = label,
        entity = c,
        frames = ComponentGetValue2(ec, "frames"),
      }
    end
  end
  state.effects = effects
  state.effect_count = #effects

  -- perks: run flags written when a perk is picked
  local perks = {}
  local list = ser.perks()
  for i = 1, #list do
    local perk = list[i]
    if perk and perk.id then
      local flag = "PERK_PICKED_" .. string.upper(perk.id)
      local ok, has = pcall(GameHasFlagRun, flag)
      if ok and has then
        local name = perk.ui_name or perk.id
        local tname = select(2, pcall(GameTextGetTranslatedOrNot, name))
        perks[#perks + 1] = { id = perk.id, name = tname or name }
      end
    end
  end
  state.perks = perks

  -- biome / position context
  local ok_b, biome = pcall(BiomeMapGetName, x, y)
  if ok_b then state.biome = biome end

  return state
end

-- ---------------------------------------------------------------- inventory

-- Noita nests carried items under child entities named "inventory_quick" and
-- "inventory_full". We walk the whole subtree and treat any entity without
-- children of its own as a carried item, skipping the container entities.
function ser.inventory_items(player, recursive)
  local out = {}
  local seen = {}
  local containers = { inventory_quick = true, inventory_full = true, inventory_stash = true }

  local function is_container(e)
    local ok, name = pcall(EntityGetName, e)
    if ok and name and containers[name] then return true end
    -- inventory components give it away too
    local inv = ser.comp(e, "Inventory2Component")
    return inv ~= nil
  end

  local function walk(e, depth)
    if not e or e == 0 or seen[e] or depth > 4 then return end
    seen[e] = true
    local children = EntityGetAllChildren(e)
    if not children then return end
    for i = 1, #children do
      local c = children[i]
      if is_container(c) then
        if recursive ~= false then walk(c, depth + 1) end
      else
        out[#out + 1] = c
        -- an item can itself hold cards (a wand full of spells): do not report
        -- those as separate carried items
      end
    end
  end
  walk(player, 0)
  return out
end

-- Best-effort human/AI readable name for an entity, or nil when the engine has
-- nothing useful. Returning nil matters: streaming placeholders such as
-- "??SAV/player.xml" and debug-only entities have no display name at all, and
-- passing those through would fill the AI's view with noise.
local function item_readable_name(entity)
  local ab = ser.comp(entity, "AbilityComponent")
  if ab then
    local n = ComponentGetValue2(ab, "ui_name")
    if type(n) == "string" and n ~= "" and n ~= "[NOT_SET]" then
      local ok, t = pcall(GameTextGetTranslatedOrNot, n)
      return ok and t or n
    end
  end
  local item = ser.comp(entity, "ItemComponent")
  if item then
    local n = ComponentGetValue2(item, "item_name")
    if type(n) == "string" and n ~= "" and n ~= "[NOT_SET]" then
      local ok, t = pcall(GameTextGetTranslatedOrNot, n)
      return ok and t or n
    end
  end
  local ok, name = pcall(EntityGetName, entity)
  if ok and type(name) == "string" and name ~= "" then
    -- reject streaming placeholders and raw debug names (plain find: "?" is a
    -- Lua pattern quantifier and would match anything)
    local placeholder = string.find(name, "??", 1, true)
    local debug_name = string.find(name, "DEBUG_NAME", 1, true) == 1
    if not placeholder and not debug_name then
      local ok2, t = pcall(GameTextGetTranslatedOrNot, name)
      return ok2 and t or name
    end
  end
  return nil
end

-- Streaming placeholders ("??SAV/player.xml"), debug-only entities and the
-- status-effect children of the player are not part of the observable world.
--
-- NOTE: these checks use PLAIN text find (4th arg true). In a Lua pattern "?"
-- is a quantifier, so string.find(s, "??") matches EVERY string.
local function is_internal_entity(entity)
  local ok, path = pcall(EntityGetFilename, entity)
  if ok and type(path) == "string" and string.find(path, "??", 1, true) then
    return true
  end
  local ok2, name = pcall(EntityGetName, entity)
  if ok2 and type(name) == "string" and string.find(name, "DEBUG_NAME", 1, true) == 1 then
    return true
  end
  if ser.comp(entity, "GameEffectComponent") then
    -- only hide our own effect entities; another creature's effect is real info
    local ok3, parent = pcall(EntityGetParent, entity)
    if ok3 and type(parent) == "number" and parent ~= 0 and parent == ser.player() then
      return true
    end
  end
  return false
end

-- The container names the engine uses for the player's pack, as opposed to worn
-- equipment which is parented straight to the player (arm_r, cape).
local PACK_CONTAINERS = {
  inventory_quick = true,
  inventory_full = true,
  inventory_stash = true,
}

-- How many spell cards the inventory lays out per row. The engine stores a card's
-- position as an (x,y) pair, so a linear deck index has to be folded into it.
local DECK_ROW_WIDTH = 8

-- A compact description of one carried item.
--
-- `container` and `in_pack` belong HERE rather than in each caller: the pack-vs-
-- worn distinction was previously computed ad hoc in one place and forgotten in
-- another, which silently produced an empty "what will be dropped" list.
function ser.item_summary(entity)
  local kind = "other"
  if EntityHasTag(entity, "wand") then
    kind = "wand"
  elseif ser.comp(entity, "MaterialInventoryComponent") then
    kind = "potion"
  elseif ser.comp(entity, "ItemActionComponent") then
    kind = "spell"
  end
  local slot = ser.field(entity, "ItemComponent", "inventory_slot")
  local parent = select(2, pcall(EntityGetParent, entity))
  local container = parent and parent ~= 0 and select(2, pcall(EntityGetName, parent)) or nil
  return {
    entity = entity,
    name = item_readable_name(entity),
    kind = kind,
    slot = slot,
    container = container,
    in_pack = (container ~= nil) and (PACK_CONTAINERS[container] == true) or false,
    filename = select(2, pcall(EntityGetFilename, entity)),
  }
end

function ser.inventory()
  local p = ser.player()
  if not p then return { valid = false, reason = "no player entity" } end
  local active = ser.held_item(p)
  local items = {}
  local list = ser.inventory_items(p)
  for i = 1, #list do
    local s = ser.item_summary(list[i])
    s.active = (list[i] == active)
    items[#items + 1] = s
  end
  return { valid = true, count = #items, items = items }
end

function ser.held_item(player)
  player = player or ser.player()
  if not player then return nil end
  local inv = ser.comp(player, "Inventory2Component")
  if not inv then return nil end
  local active = ComponentGetValue2(inv, "mActiveItem")
  if active and active ~= 0 then return active end
  return nil
end

function ser.held_wand(player)
  player = player or ser.player()
  if not player then return nil end
  local ok, wand = pcall(find_the_wand_held, player)
  if ok and wand and wand ~= 0 then return wand end
  local active = ser.held_item(player)
  if active and EntityHasTag(active, "wand") then return active end
  return nil
end

-- ---------------------------------------------------------------- wands

-- Deck children sorted by their inventory slot so the AI sees the real order.
-- Always-cast ("permanently attached") cards are listed last.
function ser.deck(wand)
  local out = {}
  if not wand then return out end
  local children = EntityGetAllChildren(wand) or {}
  for i = 1, #children do
    local c = children[i]
    if ser.comp(c, "ItemActionComponent") then
      local action_id = ser.field(c, "ItemActionComponent", "action_id")
      local slot = ser.field(c, "ItemComponent", "inventory_slot")
      slot = math.floor((tonumber(slot) or (i - 1)) + 0.5)
      local permanently = ser.field(c, "ItemComponent", "permanently_attached")
      local info = ser.action_info(action_id) or {}

      -- Remaining charges for this spell. `max_uses` above is the STATIC limit from
      -- gun_actions.lua, so on its own it never changes -- it says how many charges a
      -- spell has when full, not how many are left. The live counter lives on the
      -- card entity itself as ItemActionComponent.uses_remaining, and it is what tells
      -- you a limited spell (black hole, healing, circle spells) is about to run out.
      --
      -- Convention in the game data: -1 means unlimited, not "none left".
      local remaining = ser.field(c, "ItemActionComponent", "uses_remaining")
      remaining = tonumber(remaining)
      if remaining == nil then remaining = tonumber(info.max_uses) end

      out[#out + 1] = {
        entity = c,
        slot = slot,
        action_id = action_id,
        name = info.name_human or action_id,
        type = info.type,
        mana = info.mana,
        max_uses = info.max_uses,
        uses_remaining = remaining,
        unlimited = (remaining == nil) or (remaining < 0) or nil,
        always_cast = permanently and true or false,
      }
    end
  end
  table.sort(out, function(a, b)
    local pa = a.always_cast and 1 or 0
    local pb = b.always_cast and 1 or 0
    if pa ~= pb then return pa < pb end
    return a.slot < b.slot
  end)
  return out
end

function ser.wand_info(wand)
  if not wand or wand == 0 then return nil end
  local ab = ser.comp(wand, "AbilityComponent")
  if not ab then return nil end
  return {
    entity = wand,
    name = item_readable_name(wand),
    mana = ComponentGetValue2(ab, "mana"),
    mana_max = ComponentGetValue2(ab, "mana_max"),
    mana_charge_speed = ComponentGetValue2(ab, "mana_charge_speed"),
    actions_per_round = ser.gun(wand, "actions_per_round"),
    deck_capacity = ser.gun(wand, "deck_capacity"),
    reload_time = ser.gun(wand, "reload_time"),
    -- The engine stores this gun_config member as a string ("0"/"1"), which is
    -- what vanilla's own perk scripts write and read (see perk_list.lua). A
    -- numeric compare silently reports false for every shuffled wand, so test
    -- the truthy forms instead of enumerating them.
    shuffle = tobool_gun(ser.gun(wand, "shuffle_deck_when_empty")),
    fire_rate_wait = ser.gunaction(wand, "fire_rate_wait"),
    spread_degrees = ser.gunaction(wand, "spread_degrees"),
    speed_multiplier = ser.gunaction(wand, "speed_multiplier"),
    gun_level = ComponentGetValue2(ab, "gun_level"),
    sprite_file = ComponentGetValue2(ab, "sprite_file"),
    deck = ser.deck(wand),
  }
end

function ser.all_wands(player)
  player = player or ser.player()
  if not player then return {} end
  local ok, wands = pcall(find_all_wands_held, player)
  if not ok or type(wands) ~= "table" then wands = {} end
  local active = ser.held_wand(player)
  local out = {}
  for i = 1, #wands do
    local info = ser.wand_info(wands[i])
    if info then
      info.active = (wands[i] == active)
      out[#out + 1] = info
    end
  end
  return out
end

-- Build a brand new wand from the bundled blank template and apply every
-- supported attribute. Returns the wand entity id.
function ser.spawn_wand(opts)
  opts = opts or {}
  local player = ser.player()
  local px, py = 0, 0
  if player then px, py = EntityGetTransform(player) end
  local x = opts.x or px
  local y = opts.y or py

  local wand = EntityLoad("mods/noita_agent/files/entities/agent_wand.xml", x, y)
  if type(wand) ~= "number" or wand == 0 then
    return nil, "failed to load wand template (got " .. tostring(wand) .. ")"
  end

  -- vanilla helper sets the sprite and hotspot; fall back to a plain sprite.
  if opts.sprite then
    local ab = ser.comp(wand, "AbilityComponent")
    pcall(SetWandSprite, wand, ab, opts.sprite, 0, 0, 16, 0)
  end
  if opts.sprite_random ~= false and not opts.sprite then
    local ok_w, wands_table = pcall(dofile_once, "data/scripts/gun/procedural/wands.lua")
    if ok_w and type(wands) == "table" and #wands > 0 then
      local w = wands[math.random(1, #wands)]
      local ab = ser.comp(wand, "AbilityComponent")
      pcall(SetWandSprite, wand, ab, w.file, w.grip_x, w.grip_y,
        (w.tip_x - w.grip_x), (w.tip_y - w.grip_y))
      if w.name then pcall(ser.set_field, wand, "AbilityComponent", "ui_name", w.name) end
    end
  end

  ser.apply_wand_attrs(wand, opts)
  if opts.name then
    pcall(ser.set_field, wand, "AbilityComponent", "ui_name", opts.name)
  end

  if type(opts.spells) == "table" then
    ser.set_deck(wand, opts.spells)
  end
  return wand
end

-- Apply scalar attributes to an existing wand. Unknown keys are ignored.
function ser.apply_wand_attrs(wand, opts)
  if not wand or not opts then return end
  local direct = {
    "mana_max", "mana", "mana_charge_speed", "gun_level", "ui_name",
    "sprite_file", "item_recoil_recovery_speed", "item_recoil_max",
    "item_recoil_offset_coeff", "item_recoil_rotation_coeff",
    "click_to_use", "throw_as_item", "fast_projectile",
    "rotate_in_hand", "rotate_in_hand_amount", "rotate_hand_amount",
    "swim_propel_amount", "use_gun_script", "is_petris_gun",
    "max_charged_actions", "charge_wait_frames", "cooldown_frames",
    "never_reload", "reload_time_frames",
  }
  for _, key in ipairs(direct) do
    if opts[key] ~= nil then
      pcall(ser.set_field, wand, "AbilityComponent", key, opts[key])
    end
  end

  local gun = {
    "actions_per_round", "deck_capacity", "reload_time", "shuffle_deck_when_empty",
  }
  for _, key in ipairs(gun) do
    if opts[key] ~= nil then
      local v = opts[key]
      if key == "shuffle_deck_when_empty" then
        v = encode_gun_bool(v)
      end
      pcall(ser.set_gun, wand, key, v)
    end
  end

  if opts.shuffle ~= nil then
    pcall(ser.set_gun, wand, "shuffle_deck_when_empty", encode_gun_bool(opts.shuffle))
  end

  local gunaction = {
    "fire_rate_wait", "spread_degrees", "speed_multiplier", "screenshake",
    "recoil", "damage_critical_chance", "damage_critical_multiplier",
    "explosion_radius", "burst_count", "burst_delay", "projectile_count",
    "lifetime_add", "damage_projectile_add",
  }
  for _, key in ipairs(gunaction) do
    if opts[key] ~= nil then
      pcall(ser.set_gunaction, wand, key, opts[key])
    end
  end

  -- keep mana consistent if only mana_max was supplied
  if opts.mana == nil and opts.mana_max ~= nil then
    pcall(ser.set_field, wand, "AbilityComponent", "mana", opts.mana_max)
  end
end

-- Rewrite the whole deck. `spells` is an array of action ids ("" or a table
-- with {id=..., always_cast=true} to attach a permanent card).
function ser.set_deck(wand, spells)
  if not wand then return false, "no wand" end
  -- clear existing cards
  local children = EntityGetAllChildren(wand) or {}
  for i = 1, #children do
    local c = children[i]
    if ser.comp(c, "ItemActionComponent") then
      ser.kill(c)
    end
  end

  local always = 0
  local slot_failures = 0
  for i = 1, #spells do
    local entry = spells[i]
    local id, permanent
    if type(entry) == "table" then
      id = entry.id or entry.action_id
      permanent = entry.always_cast
    else
      id = entry
    end
    if id and id ~= "" then
      local card = CreateItemActionEntity(id)
      if card and card ~= 0 then
        EntityAddChild(wand, card)
        pcall(EntitySetComponentsWithTagEnabled, card, "enabled_in_world", false)

        -- inventory_slot is an ivec2 (a preferred (x,y) in the inventory), NOT a
        -- scalar. Passing one number made ComponentSetValue2 reject the write
        -- ("4 parameters expected"), and because it sat inside a pcall the deck
        -- order silently never applied. Measured from the component docs:
        --   ivec2 inventory_slot - "our preferred slot (x,y) in the inventory"
        local idx = i - 1
        local ok_slot = ser.set_field(card, "ItemComponent", "inventory_slot",
                                      idx % DECK_ROW_WIDTH, math.floor(idx / DECK_ROW_WIDTH))
        if not ok_slot then slot_failures = slot_failures + 1 end

        if permanent then
          pcall(ser.set_field, card, "ItemComponent", "permanently_attached", true)
          always = always + 1
        end
      end
    end
  end

  -- never leave capacity below what is actually in the wand
  local non_permanent = #spells - always
  local capacity = ser.gun(wand, "deck_capacity") or 0
  if capacity < non_permanent then
    pcall(ser.set_gun, wand, "deck_capacity", non_permanent)
  end
  -- A slot write that failed means the visual order will not match the deck, so say
  -- so rather than returning a bare success. This is exactly how the ivec2 bug hid.
  if slot_failures > 0 then
    return false, slot_failures .. " of " .. #spells ..
      " spell slots could not be written (the deck order may not match)"
  end
  return true
end

-- ---------------------------------------------------------------- potions

local LIQUID_CACHE = nil

function ser.material_catalog()
  if LIQUID_CACHE then return LIQUID_CACHE end
  local list = {}
  local seen = {}
  local function collect(getter)
    local ok, mats = pcall(getter, false, false)
    if ok and type(mats) == "table" then
      for i = 1, #mats do
        local name = mats[i]
        if name and not seen[name] then
          seen[name] = true
          list[#list + 1] = name
        end
      end
    end
  end
  collect(CellFactory_GetAllLiquids)
  collect(CellFactory_GetAllSands)
  collect(CellFactory_GetAllGases)
  collect(CellFactory_GetAllSolids)
  table.sort(list)
  LIQUID_CACHE = list
  return list
end

function ser.material_name(id)
  local ok, t = pcall(CellFactory_GetType, id)
  if not ok or type(t) ~= "number" then return tostring(id) end
  local ok2, ui = pcall(CellFactory_GetUIName, t)
  if ok2 and type(ui) == "string" and ui ~= "" then
    local ok3, translated = pcall(GameTextGetTranslatedOrNot, ui)
    if ok3 and type(translated) == "string" then return translated end
    return ui
  end
  return tostring(id)
end

function ser.potion_contents(entity)
  local comp = ser.comp(entity, "MaterialInventoryComponent")
  if not comp then return nil end
  local counts = ComponentGetValue2(comp, "count_per_material_type")
  if type(counts) ~= "table" then return {} end
  local out = {}
  for i = 1, #counts do
    local amount = counts[i]
    if amount and amount > 0 then
      local material = CellFactory_GetName(i - 1)
      out[#out + 1] = {
        material = material,
        name = ser.material_name(material),
        amount = amount,
      }
    end
  end
  return out
end

function ser.spawn_potion(opts)
  opts = opts or {}
  local player = ser.player()
  local px, py = 0, 0
  if player then px, py = EntityGetTransform(player) end
  -- potion_empty.xml is the blank bottle; potion.xml rolls a random liquid
  local path = "data/entities/items/pickup/potion_empty.xml"
  local potion = EntityLoad(path, opts.x or px, opts.y or py)
  if type(potion) ~= "number" or potion == 0 then
    return nil, "failed to load potion (got " .. tostring(potion) .. ")"
  end

  -- empty it first: potion_empty still ships with a random fill in some builds
  local comp = ser.comp(potion, "MaterialInventoryComponent")
  if comp then
    local counts = ComponentGetValue2(comp, "count_per_material_type")
    if type(counts) == "table" then
      for i = 1, #counts do
        if counts[i] and counts[i] > 0 then
          pcall(AddMaterialInventoryMaterial, potion, CellFactory_GetName(i - 1), 0)
        end
      end
    end
  end

  local wanted = opts.materials
  if type(wanted) == "string" then
    wanted = { { material = wanted, amount = opts.amount or 1000 } }
  end
  if type(wanted) == "table" then
    for i = 1, #wanted do
      local m = wanted[i]
      local material, amount
      if type(m) == "table" then
        material = m.material
        amount = m.amount or 1000
      else
        material = m
        amount = opts.amount or 1000
      end
      if material then
        pcall(AddMaterialInventoryMaterial, potion, material, amount)
      end
    end
  end

  if opts.name then
    -- potion naming goes through the potion component's custom name support
    pcall(ser.set_field, potion, "ItemComponent", "item_name", opts.name)
  end
  return potion
end

-- ---------------------------------------------------------------- entities

-- LuaJIT exposes math.atan2; stock Lua 5.3+ renamed it to math.atan(y, x).
local function atan2(y, x)
  if math.atan2 then return math.atan2(y, x) end
  return math.atan(y, x)
end

-- Spell pickups all share the same file (data/entities/items/pickup/action.xml),
-- so their useful identity is the action id on the ItemActionComponent. Map that
-- through the spell catalog to get a readable name.
local function action_label(entity)
  local action_id = ser.field(entity, "ItemActionComponent", "action_id")
  if type(action_id) ~= "string" or action_id == "" then return nil end
  local info = ser.action_info(action_id)
  if info and info.name_human then return info.name_human end
  return action_id
end

function ser.entity_info(entity, origin_x, origin_y)
  if not entity or entity == 0 then return nil end
  local x, y = EntityGetTransform(entity)
  local filename = select(2, pcall(EntityGetFilename, entity))

  local name = item_readable_name(entity)
  -- spells: the file is generic, the action id is the real name
  if ser.comp(entity, "ItemActionComponent") then
    local spell = action_label(entity)
    if spell then name = spell end
  end

  local info = {
    entity = entity,
    -- `name` is the engine's own name (may be nil); `label` is always usable
    name = name,
    label = name or (type(filename) == "string" and filename:match("([^/\\]+)$") or "unknown"),
    filename = filename,
    -- `species` is the identity of the KIND of thing this is, which `kind` alone does not give:
    -- `kind` says "creature", `species` says "fish" or "miner_weak". Taken from the source
    -- definition path, which is the only reliable classifier the engine offers -- entity names
    -- are localisation keys ("$animal_fish") and are absent on many props.
    --
    -- Measured on a live run: data/entities/animals/fish.xml -> "fish",
    -- data/entities/props/physics_box_explosive.xml -> "physics_box_explosive",
    -- data/entities/props/physics/temple_lantern.xml -> "temple_lantern".
    species = (type(filename) == "string" and filename ~= "")
      and (filename:match("([^/\\]+)%.xml$") or filename:match("([^/\\]+)$"))
      or nil,
    file = filename,
    x = x,
    y = y,
  }
  if origin_x then
    local dx, dy = x - origin_x, y - origin_y
    info.dx = dx
    info.dy = dy
    info.dist = math.sqrt(dx * dx + dy * dy)
    info.angle = math.deg(atan2(dy, dx))
  end

  local dm = ser.comp(entity, "DamageModelComponent")
  if dm then
    info.hp = ComponentGetValue2(dm, "hp")
    info.max_hp = ComponentGetValue2(dm, "max_hp")
    info.alive = (info.hp or 0) > 0
  end

  local ai = ser.comp(entity, "AnimalAIComponent")
  local ai2 = ser.comp(entity, "AIComponent")
  local gen = ser.comp(entity, "GenomeDataComponent")
  if ai or ai2 or gen then
    info.kind = "creature"
  elseif EntityHasTag(entity, "wand") then
    info.kind = "wand"
  elseif ser.comp(entity, "MaterialInventoryComponent") then
    info.kind = "potion"
  elseif ser.comp(entity, "ItemActionComponent") then
    info.kind = "spell"
  elseif ser.comp(entity, "ItemComponent") then
    info.kind = "item"
  else
    info.kind = "prop"
  end

  local tags = {}
  local ok_t, tag_list = pcall(EntityGetTags, entity)
  if ok_t and type(tag_list) == "string" then
    for t in tag_list:gmatch("[^,]+") do tags[#tags + 1] = t end
  end
  info.tags = tags
  return info
end

function ser.nearby(radius, limit, filter_tag)
  local p = ser.player()
  if not p then return { valid = false, reason = "no player entity" } end
  local px, py = EntityGetTransform(p)
  radius = radius or 200
  limit = limit or 40

  local ents
  if filter_tag then
    ents = EntityGetInRadiusWithTag(px, py, radius, filter_tag)
  else
    ents = EntityGetInRadius(px, py, radius)
  end
  if type(ents) ~= "table" then return { valid = true, count = 0, entities = {} } end

  local out = {}
  local skipped = 0
  for i = 1, #ents do
    local e = ents[i]
    if e ~= p then
      if is_internal_entity(e) then
        skipped = skipped + 1
      else
        local info = ser.entity_info(e, px, py)
        if info then
          info.dist2 = (info.dx or 0) ^ 2 + (info.dy or 0) ^ 2
          out[#out + 1] = info
        end
      end
    end
  end
  table.sort(out, function(a, b) return (a.dist2 or 1e18) < (b.dist2 or 1e18) end)
  local trimmed = {}
  for i = 1, math.min(#out, limit) do
    out[i].dist2 = nil
    trimmed[i] = out[i]
  end
  return {
    valid = true,
    radius = radius,
    count = #out,
    entities = trimmed,
    truncated = #out > limit,
    skipped_internal = skipped,
  }
end

function ser.spawn_item(filename, x, y)
  local p = ser.player()
  if not p then return nil, "no player" end
  if type(filename) ~= "string" or filename == "" then return nil, "filename required" end
  if not x or not y then x, y = EntityGetTransform(p) end
  local e = EntityLoad(filename, x, y)
  if type(e) ~= "number" or e == 0 then
    return nil, "EntityLoad failed for " .. tostring(filename) .. " (got " .. tostring(e) .. ")"
  end
  return e
end

function ser.spawn_spell(action_id, x, y)
  local p = ser.player()
  if not p then return nil, "no player" end
  if type(action_id) ~= "string" or action_id == "" then return nil, "action_id required" end
  if not x or not y then x, y = EntityGetTransform(p) end
  local e = CreateItemActionEntity(action_id, x, y)
  if type(e) ~= "number" or e == 0 then
    return nil, "CreateItemActionEntity failed for " .. tostring(action_id)
  end
  return e
end

-- Raycast helper: uses the engine raytrace so the AI can test line of sight
-- and terrain without reading the cell grid (which Lua cannot access).
-- Documented signature: fn(x1,y1,x2,y2) -> did_hit, hit_x, hit_y
function ser.raycast(x1, y1, x2, y2, mode)
  local fns = {
    surfaces = RaytraceSurfaces,
    platforms = RaytracePlatforms,
    surfaces_and_liquiform = RaytraceSurfacesAndLiquiform,
    all = Raytrace,
  }
  local fn = fns[mode or "surfaces"] or RaytraceSurfaces
  local ok, hit, hx, hy = pcall(fn, x1, y1, x2, y2)
  if not ok then return { ok = false, error = tostring(hit) } end
  return {
    ok = true,
    hit = hit and true or false,
    x = hx,
    y = hy,
    from = { x = x1, y = y1 },
    to = { x = x2, y = y2 },
  }
end

-- ---------------------------------------------------------------- mutations

function ser.set_player(opts)
  local p = ser.player()
  if not p then return false, "no player entity" end
  local applied = {}

  if opts.x or opts.y then
    local x, y = EntityGetTransform(p)
    local nx = opts.x or x
    local ny = opts.y or y
    local rot = opts.rotation
    if rot then
      EntitySetTransform(p, nx, ny, rot)
    else
      EntitySetTransform(p, nx, ny)
    end
    applied.position = true
  elseif opts.rotation then
    local x, y = EntityGetTransform(p)
    EntitySetTransform(p, x, y, opts.rotation)
    applied.position = true
  end

  if opts.hp or opts.max_hp or opts.invincibility_frames then
    local dm = ser.comp(p, "DamageModelComponent")
    if dm then
      if opts.max_hp then ComponentSetValue2(dm, "max_hp", opts.max_hp) end
      if opts.hp then ComponentSetValue2(dm, "hp", opts.hp) end
      if opts.invincibility_frames then
        ComponentSetValue2(dm, "invincibility_frames", opts.invincibility_frames)
      end
      applied.damage_model = true
    end
  end

  if opts.money then
    local wallet = ser.comp(p, "WalletComponent")
    if wallet then
      ComponentSetValue2(wallet, "money", opts.money)
      applied.money = true
    end
  end

  if opts.money_add then
    local wallet = ser.comp(p, "WalletComponent")
    if wallet then
      local cur = ComponentGetValue2(wallet, "money") or 0
      ComponentSetValue2(wallet, "money", cur + opts.money_add)
      applied.money = true
    end
  end

  if opts.infinite_money ~= nil then
    local wallet = ser.comp(p, "WalletComponent")
    if wallet then
      ComponentSetValue2(wallet, "mHasReachedInf", opts.infinite_money and true or false)
      if opts.infinite_money then
        ComponentSetValue2(wallet, "money", 2147483647)
      end
      applied.money = true
    end
  end

  if opts.vx or opts.vy then
    local cd = ser.comp(p, "CharacterDataComponent")
    if cd then
      local vx, vy = ComponentGetValue2(cd, "mVelocity")
      if type(vx) == "table" then vx, vy = vx[1], vx[2] end
      ComponentSetValue2(cd, "mVelocity", opts.vx or vx or 0, opts.vy or vy or 0)
      applied.velocity = true
    end
  end

  if opts.air then
    local dm = ser.comp(p, "DamageModelComponent")
    if dm then
      ComponentSetValue2(dm, "air_in_lungs", opts.air)
      applied.air = true
    end
  end

  if opts.max_hp_cap then
    local dm = ser.comp(p, "DamageModelComponent")
    if dm then
      ComponentSetValue2(dm, "max_hp_cap", opts.max_hp_cap)
      applied.max_hp_cap = true
    end
  end

  return true, applied
end

-- Applies a status effect. The game loads effects as child ENTITIES, so this
-- returns the effect entity id; ser.player_state() reads them back from the
-- player's children.
function ser.apply_effect(effect_name, frames)
  local p = ser.player()
  if not p then return false, "no player" end
  if type(effect_name) ~= "string" or effect_name == "" then
    return false, "effect name required"
  end
  frames = tonumber(frames) or 600
  local ok, effect, entity = pcall(GetGameEffectLoadTo, p, effect_name, true)
  if not ok or not effect or effect == 0 then
    return false, "could not apply effect " .. tostring(effect_name)
  end
  pcall(ComponentSetValue2, effect, "frames", frames)
  return true, {
    effect = string.upper(effect_name),
    frames = frames,
    entity = entity,
    component = effect,
  }
end

function ser.refresh_spells()
  local p = ser.player()
  if not p then return false, "no player" end
  pcall(GameRegenItemActionsInPlayer, p)
  return true
end

-- Generic component inspector. Not used by gameplay tools; it exists so the
-- stage-0 experiments (and future debugging) can read engine state that the
-- typed helpers above do not cover, without adding a new method each time.
function ser.inspect_component(entity, component_type, tag, fields)
  entity = entity or ser.player()
  if not entity or entity == 0 then return nil, "no entity" end
  local comp = ser.comp(entity, component_type, tag)
  if not comp then return nil, "no " .. tostring(component_type) .. " on entity " .. tostring(entity) end

  local out = { entity = entity, component_type = component_type, component = comp, fields = {} }
  for _, f in ipairs(fields or {}) do
    local ok, a, b = pcall(ComponentGetValue2, comp, f)
    if not ok or a == nil then
      out.fields[f] = { readable = false, error = ok and "nil" or tostring(a) }
    elseif type(a) == "table" then
      out.fields[f] = { readable = true, shape = "table", value = a, x = a[1], y = a[2] }
    elseif b ~= nil then
      out.fields[f] = { readable = true, shape = "two-values", x = a, y = b }
    else
      out.fields[f] = { readable = true, shape = "scalar", value = a }
    end
  end
  return out
end

return ser

"""Build the Noita fact database from unpacked game data.

Why a database and not the files
--------------------------------
The game keeps its definitions packed in data/data.wak. Unpacked, they are ~10 MB of
XML and Lua, and the Noita Modding Agreement forbids a mod from distributing "a
substantial part of our copyrightable code, content, assets". Copying that tree into
a repository would be exactly that.

So this reads the tree and writes out the FACTS an agent needs -- identifiers,
numbers, enum values and relationships -- as one compact JSON database. The game's
source files are not reproduced: no XML, no Lua, no art. What comes out is the kind
of thing a wiki would list (an enemy's hp, a spell's mana cost and charge count),
which is the part that is actually useful for deciding what to do in-game.

The result is also far more useful than raw files: inheritance is resolved, so an
enemy's real hp and damage are in one place instead of spread across <Base> chains,
and it can be queried by property rather than by grepping.

Usage
-----
  python build_db.py                        # autodetect the game data
  python build_db.py --data "D:\\Noita\\data"
  python build_db.py --out ../mcp_server/noita_db.json
"""

import os, re, json, sys, argparse
from collections import Counter, defaultdict

# ---------------------------------------------------------------- discovery

def autodetect():
    cands = []
    if os.environ.get("NOITA_REF_DATA"):
        cands.append(os.environ["NOITA_REF_DATA"])
    if os.environ.get("NOITA_DIR"):
        cands.append(os.path.join(os.environ["NOITA_DIR"], "data"))
    drives = [d + ":" for d in "CDEF" if os.path.exists(d + ":\\")]
    for d in drives:
        for sub in (r"Program Files (x86)\Steam\steamapps\common\Noita",
                    r"Program Files\Steam\steamapps\common\Noita",
                    r"Steam\steamapps\common\Noita",
                    r"SteamLibrary\steamapps\common\Noita",
                    r"Games\Steam\steamapps\common\Noita",
                    r"Sware\Steam\steamapps\common\Noita"):
            cands.append(os.path.join(d + "\\", sub, "data"))
    for c in cands:
        if c and os.path.isdir(os.path.join(c, "entities")):
            return os.path.abspath(c)
    return None


ap = argparse.ArgumentParser(description="Build the Noita fact database")
ap.add_argument("--data", help="path to the unpacked data folder")
ap.add_argument("--out", help="output json path")
args = ap.parse_args()

REF = args.data or autodetect()
if not REF or not os.path.isdir(os.path.join(REF, "entities")):
    sys.exit("Could not find unpacked game data with an 'entities' folder.\n"
             "Run tools/unpack-data.ps1 for instructions, or pass --data <path>.\n"
             "This is the only tool that needs the unpacked data.")
OUT = os.path.abspath(args.out) if args.out else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "noita_db.json")

print(f"data : {REF}")
print(f"out  : {OUT}")

ENTS_DIR = os.path.join(REF, "entities")

# ---------------------------------------------------------------- xml reading

ENTITY_HEAD = re.compile(r"<Entity\b([^>]*)>", re.S)
COMPONENT = re.compile(r"<([A-Za-z_]\w*)\b([^>]*?)(/?)>", re.S)
ATTR = re.compile(r'([\w.]+)\s*=\s*"([^"]*)"')


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except Exception:
        return ""


def parse_entity(path):
    """Returns (tags, components, base_path) for one entity file."""
    xml = read_text(path)
    m = ENTITY_HEAD.search(xml)
    if not m:
        return None

    # The <Entity ...> tag is often written across several lines, and tags may sit on
    # a continuation line, so the attribute block is read to the END of that tag
    # rather than to the first ">". Reading only to the first ">" silently produced
    # empty tag sets, which is why wand detection found nothing at first.
    head = m.group(0)
    tags = ""
    tm = re.search(r'tags\s*=\s*"([^"]*)"', head, re.S)
    if tm:
        tags = tm.group(1)
    else:
        # tolerate a tag whose attributes continue past the first ">"
        wider = xml[: m.start() + 400]
        tm2 = re.search(r'tags\s*=\s*"([^"]*)"', wider, re.S)
        if tm2:
            tags = tm2.group(1)

    comps = {}
    base = None
    for cm in COMPONENT.finditer(xml):
        name, attrs_raw = cm.group(1), cm.group(2)
        if name == "Entity":
            continue
        attrs = {}
        for am in ATTR.finditer(attrs_raw):
            attrs[am.group(1)] = am.group(2)
        if name == "Base":
            base = attrs.get("file")
            continue
        # keep the first occurrence; later ones are usually overrides.
        # Nested self-closing elements such as <gun_config ... /> are kept too: the
        # COMPONENT pattern matches any element, and wand stats live inside
        # AbilityComponent rather than on it.
        comps.setdefault(name, attrs)
    return tags, comps, base


def num(v):
    if v is None:
        return None
    try:
        f = float(v)
        return int(f) if f == int(f) else f
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------- collect

print("scanning entities ...")
raw = {}
for root, _dirs, files in os.walk(ENTS_DIR):
    for fn in files:
        if not fn.endswith(".xml"):
            continue
        p = os.path.join(root, fn)
        rel = os.path.relpath(p, REF).replace("\\", "/")
        key = "data/" + rel
        parsed = parse_entity(p)
        if parsed:
            raw[key] = parsed
print(f"  {len(raw)} entity files")

# resolve <Base> inheritance so inherited stats are visible in one place
resolved = {}


def resolve(key, depth=0):
    if key in resolved:
        return resolved[key]
    if depth > 12 or key not in raw:
        return (set(), {})
    tags, comps, base = raw[key]
    tagset = set(t.strip() for t in tags.split(",") if t.strip())
    merged = dict(comps)
    if base:
        bkey = base if base.startswith("data/") else "data/" + base.lstrip("/")
        btags, bcomps = resolve(bkey, depth + 1)
        tagset |= btags
        for k, v in bcomps.items():
            if k not in merged:
                merged[k] = v
    resolved[key] = (tagset, merged)
    return resolved[key]


def kind_of(key, tags, comps):
    if "chest" in tags:
        return "chest"
    if "wand" in tags and "item_pickup" in tags:
        return "wand"
    if "potion" in tags:
        return "potion"
    if "player_unit" in tags:
        return "player"
    if "mortal" in tags and "hittable" in tags:
        return "enemy"
    if "item_pickup" in tags or "item" in tags:
        return "item"
    top = key.split("/")[2] if key.count("/") >= 2 else ""
    return {"animals": "enemy", "buildings": "building", "props": "prop",
            "projectiles": "projectile", "items": "item", "misc": "misc",
            "vegetation": "vegetation", "particles": "effect"}.get(top, "other")


# ---------------------------------------------------------------- extract

print("extracting facts ...")
entities = []
enemy_stats = []
wands = []
chests = []
progress = 0

for key in sorted(raw):
    tags, comps = resolve(key)
    if not comps and not tags:
        continue
    kind = kind_of(key, tags, comps)

    rec = {
        "path": key,
        "file": key.rsplit("/", 1)[-1],
        "kind": kind,
        "tags": sorted(tags),
    }

    ui = comps.get("UIInfoComponent") or {}
    if ui.get("name"):
        rec["name_key"] = ui["name"]

    ic = comps.get("ItemComponent") or {}
    if ic.get("item_name"):
        rec["item_name_key"] = ic["item_name"]

    iac = comps.get("ItemActionComponent") or {}
    if iac.get("action_id"):
        rec["action_id"] = iac["action_id"]
        if iac.get("uses_remaining") is not None:
            rec["uses_remaining"] = num(iac["uses_remaining"])
        if iac.get("mana") is not None:
            rec["mana"] = num(iac["mana"])

    entities.append(rec)

    # ---- enemy parameters: the numbers a player actually needs
    if kind == "enemy":
        dm = comps.get("DamageModelComponent") or {}
        ai = comps.get("AnimalAIComponent") or {}
        ab = comps.get("AbilityComponent") or {}
        lm = comps.get("LuaComponent") or {}
        hc = comps.get("HitboxComponent") or {}
        bc = comps.get("PhysicsBodyComponent") or {}

        st = {
            "path": key,
            "hp": num(dm.get("hp")),
            "fire_damage": num(dm.get("fire_damage")),
            "fire_damage_amount": num(dm.get("fire_damage_amount")),
            "materials_that_damage": [x for x in (dm.get("materials_that_damage") or "").split(",") if x],
            "blood_material": dm.get("blood_material"),
            "ragdoll_material": dm.get("ragdoll_material"),
            "attack_melee_damage": num(dm.get("attack_melee_damage")),
            "attack_ranged_projectile": ai.get("attack_ranged_entity_file"),
            "attack_ranged_frames_between": num(ai.get("attack_ranged_frames_between")),
            "attack_ranged_state_duration": num(ai.get("attack_ranged_state_duration_frames")),
            "attack_dash_enabled": ai.get("attack_dash_enabled") == "1",
            "attack_knockback_enabled": ai.get("attack_knockback_enabled") == "1",
            "attack_ranged_enabled": ai.get("attack_ranged_enabled") == "1",
            "abilities": sorted(k for k in ab.keys() if k != "_tags"),
            "ai_script": lm.get("script_ai"),
            "hitbox_radius": num(hc.get("aabb_max_x") or hc.get("radius")),
            "physics_mass": num(bc.get("mass")),
            "physics_is_static": bc.get("is_static") == "1",
        }
        st = {k: v for k, v in st.items() if v not in (None, [], False) or k in ("path", "attack_dash_enabled")}
        if len(st) > 1:
            enemy_stats.append(st)

    # ---- wands: the properties a player compares
    #
    # The wand stats are NOT attributes of AbilityComponent. They live in a NESTED
    # <gun_config> / <gunaction_config> element inside it:
    #
    #   <AbilityComponent ...>
    #     <gun_config actions_per_round="1" deck_capacity="7" reload_time="27" ... />
    #     <gunaction_config fire_rate_wait="2" ... />
    #   </AbilityComponent>
    #
    # A flat component scan sees gun_config as its own component and finds no
    # deck_capacity at all, which is why an earlier version reported zero wands.
    # Wands are therefore detected by tag and their stats read from those children.
    if "wand" in tags:
        gun = comps.get("gun_config") or {}
        ga2 = comps.get("gunaction_config") or {}
        if not gun:
            # tolerate the child element being missed: look for it directly
            gm = re.search(r"<gun_config\b([^>]*?)/?>", read_text(
                os.path.join(REF, key[len("data/"):].replace("/", os.sep))), re.S)
            if gm:
                gun = dict(ATTR.findall(gm.group(1)))
        wands.append({
            "path": key,
            "deck_capacity": num(gun.get("deck_capacity")),
            "actions_per_round": num(gun.get("actions_per_round")),
            "reload_time": num(gun.get("reload_time")),
            "fire_rate_wait": num(ga2.get("fire_rate_wait")),
            "spread_degrees": num(gun.get("spread_degrees")),
            "speed_multiplier": num(gun.get("speed_multiplier")),
            "shuffle_deck_when_empty": gun.get("shuffle_deck_when_empty") == "1",
            "mana_max": num((comps.get("AbilityComponent") or {}).get("mana_max")),
            "mana_charge_speed": num((comps.get("AbilityComponent") or {}).get("mana_charge_speed")),
            "sprite": (comps.get("SpriteComponent") or {}).get("image_file"),
            "is_template": "/wands/" in key,
        })

    # ---- chests: what they are and how to open them
    if "chest" in tags:
        chests.append({
            "path": key,
            "pickup_string_key": ic.get("custom_pickup_string"),
            "sprite": (comps.get("PhysicsImageShapeComponent") or {}).get("image_file"),
            "loot_script": (comps.get("LuaComponent") or {}).get("script_item_picked_up"),
            "super": "super" in key,
        })

    progress += 1
    if progress % 500 == 0:
        print(f"  {progress}/{len(raw)}")

# ---------------------------------------------------------------- perks

perks = []
perk_file = os.path.join(REF, "scripts", "perks", "perk_list.lua")
if os.path.isfile(perk_file):
    txt = read_text(perk_file)
    # entries look like:  { id = "PROTECTION_FIRE", ... ui_name = "...", ... }
    for m in re.finditer(r"\{\s*id\s*=\s*\"([A-Z0-9_]+)\"(.*?)\n\s*\}", txt, re.S):
        pid, body = m.group(1), m.group(2)
        def field(name):
            fm = re.search(name + r"\s*=\s*\"([^\"]*)\"", body)
            return fm.group(1) if fm else None
        perks.append({
            "id": pid,
            "ui_name_key": field("ui_name"),
            "ui_description_key": field("ui_description"),
            "stackable": "stackable" in body,
        })

# ---------------------------------------------------------------- materials

materials = []
mat_file = os.path.join(REF, "materials.xml")
if os.path.isfile(mat_file):
    txt = read_text(mat_file)
    # The values are attributes of <CellData> itself, not of nested <Fire>/<Acid>
    # elements -- an earlier version looked for those and produced all-null hazards.
    # The element is also multi-line, so the attribute block is read to the tag's end.
    for m in re.finditer(r"<CellData\b([^>]*?)/?>", txt, re.S):
        attrs = dict(ATTR.findall(m.group(1)))
        name = attrs.get("name")
        if not name:
            continue
        tags = [t.strip("[]") for t in (attrs.get("tags") or "").split(",") if t.strip()]
        materials.append({
            "id": name,
            "ui_name_key": attrs.get("ui_name"),
            "cell_type": attrs.get("cell_type"),
            "tags": tags,
            "liquid": attrs.get("cell_type") == "liquid",
            "burnable": num(attrs.get("burnable")),
            "density": num(attrs.get("density")),
            "danger_fire": num(attrs.get("danger_fire")),
            "danger_acid": num(attrs.get("danger_acid")),
            "danger_radioactive": num(attrs.get("danger_radioactive")),
            "danger_poison": num(attrs.get("danger_poison")),
            "always_ignites_damagemodel": attrs.get("always_ignites_damagemodel") == "1",
            "status_effects": [s for s in (attrs.get("status_effects") or "").split(",") if s],
            "temperature_of_fire": num(attrs.get("temperature_of_fire")),
            "wang_color": attrs.get("wang_color"),
            "freezes_to": attrs.get("cold_freezes_to_material"),
        })

# ---------------------------------------------------------------- biomes

biomes = []
biome_dir = os.path.join(REF, "biome")
if os.path.isdir(biome_dir):
    for fn in sorted(os.listdir(biome_dir)):
        if not fn.endswith(".xml"):
            continue
        txt = read_text(os.path.join(biome_dir, fn))
        name_key = None
        nm = re.search(r'name\s*=\s*"(\$[^"]+)"', txt)
        if nm:
            name_key = nm.group(1)
        biomes.append({
            "file": "data/biome/" + fn,
            "id": fn[:-4],
            "name_key": name_key,
            "has_wang": "<Wang" in txt,
        })

# ---------------------------------------------------------------- spells

# The spell catalogue is read live by the mod (noita_list_spells); only the parts
# that are pure data and useful offline are captured here.
spells = []
ga = os.path.join(REF, "scripts", "gun", "gun_actions.lua")
if os.path.isfile(ga):
    txt = read_text(ga)
    for m in re.finditer(r"\{([^{}]*?action\s*=\s*\(\s*function.*?)(?=\n\s*\{|\Z)", txt, re.S):
        pass  # the file is Lua code; the live mod already exposes the parsed list

db = {
    "schema": 1,
    "source": {
        "note": "Facts extracted from unpacked Noita game data by tools/build_db.py. The "
                "game's own files are not reproduced: this holds identifiers, numbers, "
                "enum values and relationships only -- the kind of thing a wiki lists -- "
                "which is what the Noita Modding Agreement permits a mod to ship.",
        "generator": "tools/build_db.py",
        "unpacked_from": os.path.basename(os.path.dirname(REF.rstrip("\\/"))) or "game data",
    },
    "counts": {
        "entities": len(entities),
        "enemies": len(enemy_stats),
        "wands": len(wands),
        "chests": len(chests),
        "perks": len(perks),
        "materials": len(materials),
        "biomes": len(biomes),
    },
    "kinds": dict(Counter(e["kind"] for e in entities).most_common()),
    "entities": entities,
    "enemy_stats": enemy_stats,
    "wands": wands,
    "chests": chests,
    "perks": perks,
    "materials": materials,
    "biomes": biomes,
}

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(db, f, ensure_ascii=False, separators=(",", ":"))

size = os.path.getsize(OUT)
print("")
print(f"wrote {OUT}  ({size/1024:.0f} KB)")
for k, v in db["counts"].items():
    print(f"  {k:<12} {v}")

"""Builds entity_index.json from an unpacked Noita data folder.

The index is path + tags + localisation key per entity -- factual identifiers, not
game content -- so it is small enough to ship. The definitions it points at are not
included, because the Noita Modding Agreement forbids redistributing the game's
content; run tools/unpak.ps1 to produce those locally.

Where to find the data, in order:
  1. --data <path> on the command line
  2. $NOITA_REF_DATA
  3. $NOITA_DIR/data
  4. a few usual install locations

Usage:
  python build_index.py                    # autodetect
  python build_index.py --data "D:\\Noita\\data"
  python build_index.py --out ./entity_index.json
"""
import os, re, json, sys, argparse

def autodetect():
    cands = []
    if os.environ.get("NOITA_REF_DATA"):
        cands.append(os.environ["NOITA_REF_DATA"])
    if os.environ.get("NOITA_DIR"):
        cands.append(os.path.join(os.environ["NOITA_DIR"], "data"))
    for drive in ("C", "D", "E", "F"):
        for sub in (r"Program Files (x86)\Steam\steamapps\common\Noita",
                    r"Steam\steamapps\common\Noita",
                    r"SteamLibrary\steamapps\common\Noita",
                    r"Games\Steam\steamapps\common\Noita"):
            cands.append(os.path.join(f"{drive}:\\", sub, "data"))
    # this repository's own unpacked copy, if someone keeps one around
    here = os.path.dirname(os.path.abspath(__file__))
    cands.append(os.path.join(here, "..", "..", "..", "archive", "ref-orin-data"))

    for c in cands:
        if c and os.path.isdir(os.path.join(c, "entities")):
            return os.path.abspath(c)
    return None

ap = argparse.ArgumentParser(description="Build entity_index.json from unpacked Noita data")
ap.add_argument("--data", help="path to the unpacked data folder (contains entities/)")
ap.add_argument("--out", help="output file, default entity_index.json next to this script")
args = ap.parse_args()

REF = args.data or autodetect()
if not REF:
    sys.exit("Could not find unpacked game data. Run tools/unpak.ps1 first, or pass --data <path>.\n"
             "Expected a folder containing an 'entities' subfolder.")
if not os.path.isdir(os.path.join(REF, "entities")):
    sys.exit(f"{REF} does not contain an 'entities' folder -- is that the unpacked data root?")

OUT = os.path.dirname(os.path.abspath(args.out)) if args.out else os.path.dirname(os.path.abspath(__file__))
OUTFILE = os.path.abspath(args.out) if args.out else os.path.join(OUT, "entity_index.json")
print(f"data : {REF}")
print(f"out  : {OUTFILE}")

ENTS = os.path.join(REF, "entities")

def tags_of(path):
    """Read the root <Entity tags="..."> and the UIInfoComponent name."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            head = f.read(6000)
    except Exception:
        return None, None
    m = re.search(r'<Entity[^>]*\btags="([^"]*)"', head)
    tags = m.group(1) if m else ""
    n = re.search(r'name="(\$[^"]+)"', head)
    name = n.group(1) if n else ""
    return tags, name

rows = []
for root, dirs, files in os.walk(ENTS):
    for fn in files:
        if not fn.endswith(".xml"):
            continue
        p = os.path.join(root, fn)
        rel = os.path.relpath(p, REF).replace("\\", "/")
        tags, name = tags_of(p)
        if tags is None:
            continue
        row = {
            "path": "data/" + rel,
            "file": fn,
            "dir": os.path.relpath(root, ENTS).replace("\\", "/"),
            "tags": tags,
            "name": name,
            "size": os.path.getsize(p),
        }
        rows.append(row)

# classify by the meaningful tags
def kind_of(r):
    t = set(x.strip() for x in (r["tags"] or "").split(","))
    d = r["dir"]
    if "chest" in t: return "chest"
    if "wand" in t: return "wand"
    if "potion" in t or "liquid" in t: return "potion"
    if "player_unit" in t: return "player"
    if "mortal" in t and "hittable" in t: return "enemy"
    if "item_pickup" in t or "item" in t: return "item"
    if d.startswith("animals"): return "enemy"
    if d.startswith("buildings"): return "building"
    if d.startswith("props"): return "prop"
    if d.startswith("projectiles"): return "projectile"
    if d.startswith("items"): return "item"
    if d.startswith("misc"): return "misc"
    if d.startswith("vegetation"): return "vegetation"
    return "other"

for r in rows:
    r["kind"] = kind_of(r)

idx = {
    "source": "noita archive ref-orin-data (unpacked game data)",
    "total": len(rows),
    "kinds": {},
    "entities": rows,
}
from collections import Counter
c = Counter(r["kind"] for r in rows)
idx["kinds"] = dict(c.most_common())

os.makedirs(OUT, exist_ok=True)
dst = OUTFILE
with open(dst, "w", encoding="utf-8") as f:
    json.dump(idx, f, ensure_ascii=False, indent=1)

print("wrote", dst)
print("total entities:", idx["total"])
for k, v in idx["kinds"].items():
    print(f"   {k:<12} {v}")

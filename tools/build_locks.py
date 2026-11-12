"""Build ProfScan/RecipeLocks.lua: what limits each recipe besides skill.

Usage:
    python build_locks.py [--build 1.60.1.70888] [--csv-dir DIR]

For every recipe in RecipeData.lua it records
    cd        cooldown in seconds (transmutes, Mooncloth, ...)
    station   object you must stand next to (Anvil, Forge, Black Anvil, Loom, ...)
    tools     tools you must carry (Blacksmith Hammer, Philosopher's Stone, ...)
    spec      specialization needed to learn it (Armorsmith, Gnomish Engineer, ...)
    rep       reputation needed to buy/learn it (faction, standing)

Sources:
  * The game's own tables for this build (cooldowns, stations, tools, and the
    recipe items' required specialization and reputation), downloaded as CSV
    from wago.tools and cached in tools/.db2cache/<build>/. --csv-dir reads
    already downloaded CSV files instead. The build defaults to the one in
    World of Warcraft/.build.info for WoW Forever (product wowf).
  * AtlasLoot Continued (GPL v2): which item teaches which recipe
    (Data/Recipe.lua), and reputation rewards by standing (Factions/data*.lua)
    for recipe items the client tables don't include.
  * TRAINER_SPECS below: Gnomish/Goblin recipes taught by specialization
    trainers. Trainers aren't in the client tables, so this list is from
    Classic and may differ in Forever.
Run it again after a game patch.
"""
import argparse
import csv
import io
import re
import sys
import urllib.request
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
ADDON_DIR = HERE.parent
ADDONS = ADDON_DIR.parent
GAME_ROOT = ADDON_DIR.parents[3]  # World of Warcraft/

TABLES = ["SpellName", "SpellCooldowns", "SpellCastingRequirements", "SpellFocusObject",
          "SpellTotems", "TotemCategory", "ItemSparse", "Faction"]

# Recipes only specialization trainers teach (Classic). spell name -> specialization spell
GNOMISH, GOBLIN = 20219, 20222
TRAINER_SPECS = {
    "Gnomish Battle Chicken": GNOMISH, "Gnomish Death Ray": GNOMISH, "Gnomish Goggles": GNOMISH,
    "Gnomish Harm Prevention Belt": GNOMISH, "Gnomish Mind Control Cap": GNOMISH,
    "Gnomish Net-o-Matic Projector": GNOMISH, "Gnomish Rocket Boots": GNOMISH, "Gnomish Shrink Ray": GNOMISH,
    "Ultrasafe Transporter: Gadgetzan": GNOMISH,
    "Goblin Bomb Dispenser": GOBLIN, "Goblin Construction Helmet": GOBLIN, "Goblin Dragon Gun": GOBLIN,
    "Goblin Mining Helmet": GOBLIN, "Goblin Rocket Boots": GOBLIN, "Goblin Rocket Helmet": GOBLIN,
    "The Big One": GOBLIN, "Goblin Sapper Charge": GOBLIN, "Dimensional Ripper - Everlook": GOBLIN,
}
STANDINGS = {"Friendly": 5, "Honored": 6, "Revered": 7, "Exalted": 8}  # the game's standingID


def game_build():
    info = GAME_ROOT / ".build.info"
    if not info.exists():
        return None
    lines = info.read_text(encoding="utf-8").splitlines()
    head = [h.split("!")[0] for h in lines[0].split("|")]
    for line in lines[1:]:
        row = dict(zip(head, line.split("|")))
        if row.get("Product") == "wowf" and row.get("Version"):
            return row["Version"]
    return None


def load_tables(build, csv_dir):
    if csv_dir:
        folder = Path(csv_dir)
    else:
        folder = HERE / ".db2cache" / build
        folder.mkdir(parents=True, exist_ok=True)
    tables = {}
    for name in TABLES:
        path = folder / f"{name}.csv"
        if not path.exists():
            if csv_dir:
                raise SystemExit(f"{path} is missing")
            url = f"https://wago.tools/db2/{name}/csv?build={build}"
            print(f"downloading {url}")
            req = urllib.request.Request(url, headers={"User-Agent": "ProfScan-build-locks"})
            with urllib.request.urlopen(req, timeout=120) as resp:
                path.write_bytes(resp.read())
        with open(path, encoding="utf-8", newline="") as f:
            tables[name] = list(csv.DictReader(f))
    return tables


def recipe_spells():
    spells = {}
    text = (ADDON_DIR / "RecipeData.lua").read_text(encoding="utf-8")
    for spell, name in re.findall(r'\{ (\d+), \d+, \d+, \{[^}]*\}, [\d.]+, "((?:[^"\\]|\\.)*)" \}', text):
        spells[int(spell)] = name
    return spells


def teaching_items():
    """spell -> recipe items that teach it (AtlasLoot)."""
    teach = defaultdict(set)
    path = ADDONS / "AtlasLootContinued" / "Data" / "Recipe.lua"
    for item, spell in re.findall(r"\[(\d+)\]\s*=\s*\{\s*\d+\s*,\s*\d+\s*,\s*(\d+)\s*\}",
                                  path.read_text(encoding="utf-8")):
        teach[int(spell)].add(int(item))
    return teach


def faction_rewards():
    """item -> (factionID, standingID) from AtlasLoot's faction reward lists."""
    rewards = {}
    folder = ADDONS / "AtlasLootContinued_Factions"
    for path in sorted(folder.glob("data*.lua")):
        if path.name not in ("data.lua", "data-forever.lua"):
            continue
        faction = standing = None
        for line in path.read_text(encoding="utf-8").splitlines():
            m = re.match(r'\s*FactionID\s*=\s*(\d+)', line)
            if m:
                faction, standing = int(m.group(1)), None
            m = re.search(r'name\s*=\s*ALIL\["(\w+)"\]', line)
            if m:
                standing = STANDINGS.get(m.group(1))
            m = re.match(r'\s*\{\s*\d+\s*,\s*(\d+)\s*\}', line)
            if m and faction and standing:
                rewards.setdefault(int(m.group(1)), (faction, standing))
    return rewards


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    p = argparse.ArgumentParser(description="Build RecipeLocks.lua")
    p.add_argument("--build", help="game build, e.g. 1.60.1.70888 (default: installed WoW Forever)")
    p.add_argument("--csv-dir", help="folder with the CSV tables already downloaded")
    args = p.parse_args()
    build = args.build or game_build()
    if not build and not args.csv_dir:
        raise SystemExit("Couldn't read the game build from .build.info; pass --build")
    t = load_tables(build or "local", args.csv_dir)

    recipes = recipe_spells()
    by_name = {name: spell for spell, name in recipes.items()}
    spell_name = {int(r["ID"]): r["Name_lang"] for r in t["SpellName"]}
    faction_name = {int(r["ID"]): r["Name_lang"] for r in t["Faction"]}
    focus_name = {int(r["ID"]): r["Name_lang"] for r in t["SpellFocusObject"]}
    totem_name = {int(r["ID"]): r["Name_lang"] for r in t["TotemCategory"]}
    items = {int(r["ID"]): r for r in t["ItemSparse"]}
    locks = defaultdict(dict)

    for r in t["SpellCooldowns"]:
        s = int(r["SpellID"])
        cd = max(int(r["RecoveryTime"]), int(r["CategoryRecoveryTime"])) // 1000
        if s in recipes and cd > 0:
            locks[s]["cd"] = cd
    for r in t["SpellCastingRequirements"]:
        s = int(r["SpellID"])
        if s in recipes and int(r["RequiresSpellFocus"]):
            locks[s]["station"] = focus_name.get(int(r["RequiresSpellFocus"]), "?")
    for r in t["SpellTotems"]:
        s = int(r["SpellID"])
        if s in recipes:
            names = [totem_name.get(int(r[k])) for k in ("RequiredTotemCategoryID_0", "RequiredTotemCategoryID_1")
                     if int(r[k])]
            names += [items[int(r[k])]["Display_lang"] for k in ("Totem_0", "Totem_1")
                      if int(r[k]) and int(r[k]) in items]
            if any(names):
                locks[s]["tools"] = ", ".join(n for n in names if n)

    # learning: specialization / reputation of the recipe items. A requirement
    # counts only if every known item teaching the recipe has it (the easiest one).
    rewards = faction_rewards()
    for s, teaching in teaching_items().items():
        if s not in recipes:
            continue
        specs, reps, unlocked = set(), [], False
        for it in teaching:
            row = items.get(it)
            if row:
                spec = int(row["RequiredAbility"])
                rep = (int(row["MinFactionID"]), int(row["MinReputation"]) + 1) if int(row["MinFactionID"]) else None
            elif it in rewards:
                spec, rep = 0, rewards[it]
            else:
                continue  # item unknown to both sources (often a later-expansion copy)
            if not spec and not rep:
                unlocked = True
            if spec:
                specs.add(spec)
            if rep:
                reps.append(rep)
        if unlocked:
            continue
        if len(specs) == 1:
            spec = specs.pop()
            locks[s]["spec"], locks[s]["specSpell"] = spell_name.get(spec, str(spec)), spec
        if reps:
            faction, standing = min(reps, key=lambda x: x[1])
            locks[s]["rep"], locks[s]["repID"], locks[s]["standing"] = faction_name.get(faction, str(faction)), faction, standing
    for name, spec in TRAINER_SPECS.items():
        s = by_name.get(name)
        if s and "spec" not in locks[s]:
            locks[s]["spec"], locks[s]["specSpell"], locks[s]["trainer"] = spell_name.get(spec, str(spec)), spec, True

    out = [
        "-- Generated by tools/build_locks.py from the game's tables (build %s, via wago.tools)" % (build or "?"),
        "-- and AtlasLoot Continued (GPL v2). Do not edit by hand; run the script again instead.",
        "local _, ns = ...",
        "",
        "-- [spellID] = { cd = cooldown seconds, station = object to stand at, tools = carried tools,",
        "--   spec = specialization needed to learn it, specSpell, trainer = taught by a specialization",
        "--   trainer (Classic list), rep = faction to buy it from, repID, standing (5 Friendly .. 8 Exalted) }",
        "ns.RECIPE_LOCKS = {",
    ]
    order = ("cd", "station", "tools", "spec", "specSpell", "trainer", "rep", "repID", "standing")
    for s in sorted(locks):
        fields = []
        for k in order:
            if k in locks[s]:
                v = locks[s][k]
                fields.append(f"{k} = " + (lua_str(v) if isinstance(v, str) else ("true" if v is True else str(v))))
        if fields:
            out.append(f"  [{s}] = {{ {', '.join(fields)} }}, -- {recipes[s]}")
    out += ["}", ""]
    path = ADDON_DIR / "RecipeLocks.lua"
    path.write_text("\n".join(out), encoding="utf-8")
    count = defaultdict(int)
    for v in locks.values():
        for k in ("cd", "station", "tools", "spec", "rep"):
            if k in v:
                count[k] += 1
    print(f"{path}: {len(locks)} recipes, " + ", ".join(f"{k} {n}" for k, n in count.items()))


if __name__ == "__main__":
    main()

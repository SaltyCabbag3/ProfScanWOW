"""Build ProfScan/RecipeData.lua from AtlasLoot Continued's crafting data.

Usage:
    python build_recipes.py [path to Interface/AddOns, or -] [game build, default 1.60.1.70888]

Reads (default: the AddOns folder this script sits in):
    AtlasLootContinued/Data/Profession.lua         spell -> crafted item, skill, reagents
    AtlasLootContinued/Data/Recipe.lua             recipe item -> the spell it teaches
    AtlasLootContinued_Crafting/data-forever.lua   which recipes exist in Forever, by profession and category
and writes ../RecipeData.lua. Run it again after AtlasLoot updates. AtlasLoot is
GPL v2, so the generated file carries that licence.

Required skill: AtlasLoot has Classic's, and Forever lowered most of them
(and the skill-up colours with them, usually by 20-25 points). See
forever_skills() for where Forever's values come from: the game's tables
(tools/.db2cache, downloaded from wago.tools like build_locks.py does) and the
warcraft.wiki.gg "Forever ... recipes" tables (cached in tools/.wikicache;
delete that folder to fetch them again).

How each recipe is learned (trainer, vendor, drop, quest, with the recipe
item's binding and the reputation or instance): see forever_sources(); it
uses the same wiki tables, the game's ItemSparse / ItemEffect / Faction tables,
and AtlasLootContinued_Data/source-forever.lua for instance drops.

ProfScan also reads your own profession windows in game (Recipes.lua), which
adds recipes missing here and marks the ones you know.
"""
import csv
import json
import re
import sys
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path

PROFESSION_ROW = re.compile(
    r"^\s*\[(\d+)\]\s*=\s*\{\s*(nil|\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*\d+\s*,\s*\d+\s*,"
    r"\s*\{([^}]*)\}\s*,\s*\{([^}]*)\}(?:\s*,\s*(\d+))?", re.M)  # optional 8th field: items made per craft
TABLE_START = re.compile(r'^data\["(\w+)Forever"\]\s*=\s*\{', re.M)
TABLE_FIELD = re.compile(r"^\s*(name|TableType)\s*=\s*(.+?),?\s*$")
SECTION_NAME = re.compile(r"^\t\t\tname\s*=\s*(.+?),?\s*$")
ENTRY = re.compile(r"^\s*\{\s*\d+\s*,\s*(\d+)\s*\}\s*,?\s*(?:--\s*(.*))?$")
LOCALE = re.compile(r'AL(?:IL)?\["([^"]+)"\]')


def lua_label(expr):
    """AL["Weapons"].." - "..ALIL["Daggers"] -> Weapons - Daggers"""
    expr = LOCALE.sub(lambda m: m.group(1), expr)
    return expr.replace('"', "").replace("..", "").strip()


def ints(text):
    return [int(x) for x in re.findall(r"\d+", text)]


# Profession.lua has one table per game version (CLASSIC, BCC, WRATH); later
# ones restate many recipes with their changed reagents. Forever's recipes
# match the Classic table (checked against recipes read in game), so Classic
# wins and later tables only fill in spells it does not have.
VERSION_TABLE = re.compile(r"PROFESSION_DATA\.(\w+)\s*=\s*\{")
VERSION_ORDER = ("CLASSIC", "BCC", "WRATH")


def load_professions(path):
    text = path.read_text(encoding="utf-8")
    marks = [(m.start(), m.group(1)) for m in VERSION_TABLE.finditer(text)]
    sections = {name: text[pos:(marks[i + 1][0] if i + 1 < len(marks) else len(text))]
                for i, (pos, name) in enumerate(marks)}
    order = [v for v in VERSION_ORDER if v in sections] + [v for v in sections if v not in VERSION_ORDER]
    spells = {}
    for version in order:
        for spell, created, _prof, skill, reagents, counts, made in PROFESSION_ROW.findall(sections[version]):
            spells.setdefault(int(spell), {
                "created": None if created == "nil" else int(created),
                "skill": int(skill),
                "reagents": list(zip(ints(reagents), ints(counts))),
                "made": int(made) if made else 1,
            })
    return spells


def load_forever_tables(path):
    tables, table, section = [], None, None
    for line in path.read_text(encoding="utf-8").splitlines():
        if m := TABLE_START.match(line):
            table = {"key": m.group(1), "name": m.group(1), "items": False, "sections": []}
            tables.append(table)
            continue
        if table is None:
            continue
        if line.startswith("\t") and not line.startswith("\t\t") and (m := TABLE_FIELD.match(line)):
            if m.group(1) == "name":
                label = lua_label(m.group(2))
                # a computed name (e.g. the class-coloured Rogue one): use the table key, "RoguePoisons" -> "Rogue Poisons"
                table["name"] = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", table["key"]) if "(" in label else label
            else:
                table["items"] = "NORMAL_ITTYPE" in m.group(2)
        elif m := SECTION_NAME.match(line):
            section = {"name": lua_label(m.group(1)), "entries": []}
            table["sections"].append(section)
        elif section is not None and (m := ENTRY.match(line)):
            comment = (m.group(2) or "").split(" / ")[0].strip()
            section["entries"].append((int(m.group(1)), comment))
    return tables


# Forever changes AtlasLoot doesn't have yet, checked against the game's own data
# (wago.tools DB2 SkillLineAbility / SpellReagents / SpellEffect, build 1.60.1.70888).
# Healing potions moved from Alchemy to First Aid: the Alchemy spells there create
# nothing and take no reagents, and new First Aid spells make the same potions
# with spices in place of the second herb. Required skill keeps the Alchemy
# value; the skill-up colours (trivial ranks) are unchanged.
FOREVER_REMOVED = {2330, 2337, 3447, 7181, 11457, 17556}
FOREVER_ADDED = {
    "First Aid": [("Healing Potions", [
        # spell, item, skill, reagents, made, name
        (1244436, 13446, 275, [(8925, 1), (3713, 3), (13464, 1)], 1, "Major Healing Potion"),
        (1244435, 3928, 215, [(8925, 1), (3713, 1), (8838, 1)], 1, "Superior Healing Potion"),
        (1244434, 1710, 155, [(3372, 1), (2692, 3), (3357, 1)], 1, "Greater Healing Potion"),
        (1244433, 929, 110, [(3372, 1), (2692, 1), (2453, 1)], 1, "Healing Potion"),
        (1244432, 858, 80, [(3371, 1), (2678, 2), (2450, 1)], 1, "Lesser Healing Potion"),
        (1244431, 118, 1, [(3371, 1), (2678, 1), (2447, 1)], 1, "Minor Healing Potion"),
    ])],
}


def apply_forever_changes(tables, spells):
    for table in tables:
        for section in table["sections"]:
            section["entries"] = [e for e in section["entries"] if e[0] not in FOREVER_REMOVED]
    for profession, sections in FOREVER_ADDED.items():
        table = next(t for t in tables if t["name"] == profession)
        listed = {e[0] for section in table["sections"] for e in section["entries"]}
        for name, rows in sections:
            entries = []
            for spell, item, skill, reagents, made, label in rows:
                spells[spell] = {"created": item, "skill": skill, "reagents": reagents, "made": made, "fixed": True}
                if spell not in listed:  # newer AtlasLoot versions list them already
                    entries.append((spell, label))
            if entries:
                table["sections"].append({"name": name, "entries": entries})


def fill_reagents(spells, game):
    """Recipes AtlasLoot lists without reagents (some new Forever enchants): the game's SpellReagents."""
    filled = 0
    for r in game["SpellReagents"]:
        info = spells.get(int(r["SpellID"]))
        if info is not None and not info["reagents"]:
            info["reagents"] = [(int(r[f"Reagent_{i}"]), int(r[f"ReagentCount_{i}"])) for i in range(8)
                                if int(r[f"Reagent_{i}"]) > 0]
            filled += bool(info["reagents"])
    return filled


# Forever's required skill ------------------------------------------------------

SKILL_LINES = {"Alchemy": 171, "Blacksmithing": 164, "Enchanting": 333, "Engineering": 202,
               "Tailoring": 197, "Leatherworking": 165, "Mining": 186, "Cooking": 185,
               "First Aid": 129, "Rogue Poisons": 40}
WIKI_PAGES = {"Alchemy": "Forever alchemy recipes", "Blacksmithing": "Forever blacksmithing plans",
              "Enchanting": "Forever enchanting formulas", "Engineering": "Forever engineering schematics",
              "Tailoring": "Forever tailoring patterns", "Leatherworking": "Forever leatherworking patterns",
              "Cooking": "Forever cooking recipes", "First Aid": "Forever first aid recipes"}
WIKI_LINK = re.compile(r"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]")
HERE = Path(__file__).resolve().parent


def game_tables(build, names):
    folder = HERE / ".db2cache" / build
    folder.mkdir(parents=True, exist_ok=True)
    out = {}
    for name in names:
        path = folder / f"{name}.csv"
        if not path.exists():
            url = f"https://wago.tools/db2/{name}/csv?build={build}"
            print(f"downloading {url}")
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (ProfScan build_recipes)"})
            with urllib.request.urlopen(req, timeout=120) as resp:
                path.write_bytes(resp.read())
        with open(path, encoding="utf-8", newline="") as f:
            out[name] = list(csv.DictReader(f))
    return out


def wiki_skills(profession):
    """recipe name -> [(skill, source), ...] from the wiki's Forever recipe table."""
    page = WIKI_PAGES.get(profession)
    if not page:
        return {}
    folder = HERE / ".wikicache"
    folder.mkdir(exist_ok=True)
    path = folder / (page.replace(" ", "_") + ".wiki")
    if not path.exists():
        url = ("https://warcraft.wiki.gg/api.php?action=parse&prop=wikitext&format=json&redirects=1&page="
               + urllib.parse.quote(page))
        print(f"downloading {url}")
        req = urllib.request.Request(url, headers={"User-Agent": "ProfScan build_recipes"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read())
        if "parse" not in data:
            print(f"  no wiki page {page!r}")
            return {}
        path.write_text(data["parse"]["wikitext"]["*"], encoding="utf-8")
    rows = defaultdict(list)
    for block in path.read_text(encoding="utf-8").split("\n|-"):
        cells = [c.strip() for c in block.strip().lstrip("|").split("||")]
        if len(cells) < 4 or cells[0].startswith("!"):
            continue
        link, skill = WIKI_LINK.search(cells[0]), re.match(r"\d+", cells[1])
        if link and skill:
            source = cells[-1].split("\n")[0].strip()
            # [[Rage Potion#Forever|...]], [[Alchemist's Stone (Forever)]]: anchor and note are not part of the name
            name = re.sub(r"\s*\([^)]*\)$", "", (link.group(2) or link.group(1)).split("#")[0]).strip()
            rows[name].append((int(skill.group()), source))
    return rows


def forever_skills(tables, spells, game, addons):
    """Sets each recipe's "skill" to Forever's requirement, best source first:
      item     the item that teaches it (pattern, plans, ...): the game's own
               ItemSparse RequiredSkillRank, exact;
      wiki     the wiki's Forever table, for trainer recipes (rows with an unknown
               source "?" are mostly the yellow skill copied in, and skipped);
               where it can be checked against the items it agrees ~98% of the time;
      shifted  Classic's value moved by as much as Forever moved the recipe's
               yellow skill (SkillLineAbility), which is what Forever did for
               most recipes (345 of 447 recipe items checked; 83 kept Classic's);
      classic  Classic's value, when nothing else is known.
    Returns {profession: {source: count}}."""
    names ={int(r["ID"]): r["Name_lang"] for r in game["SpellName"]}
    yellow = {}  # (skill line, spell) -> Forever's yellow skill
    for r in game["SkillLineAbility"]:
        if int(r["TrivialSkillLineRankLow"]) > 0:
            yellow[(int(r["SkillLine"]), int(r["Spell"]))] = int(r["TrivialSkillLineRankLow"])
    item_req, by_name = {}, {}
    for r in game["ItemSparse"]:
        title = r["Display_lang"]
        if r["RequiredSkill"] != "0" and not re.search(r"\bOLD\b|^Deprecated|^zz", title):
            line, rank = int(r["RequiredSkill"]), int(r["RequiredSkillRank"])
            item_req[int(r["ID"])] = (line, rank)
            if ": " in title:  # "Pattern: Wild Leather Cloak" -> (165, "Wild Leather Cloak")
                by_name.setdefault((line, title.split(": ", 1)[1]), rank)
    teach = defaultdict(set)
    text = (addons / "AtlasLootContinued" / "Data" / "Recipe.lua").read_text(encoding="utf-8")
    for item, spell in re.findall(r"\[(\d+)\]\s*=\s*\{\s*\d+\s*,\s*\d+\s*,\s*(\d+)\s*\}", text):
        teach[int(spell)].add(int(item))
    classic_yellow = {}
    text = (addons / "AtlasLootContinued" / "Data" / "Profession.lua").read_text(encoding="utf-8")
    for spell, low in re.findall(r"^\s*\[(\d+)\]\s*=\s*\{\s*(?:nil|\d+)\s*,\s*\d+\s*,\s*\d+\s*,\s*(\d+)", text, re.M):
        classic_yellow.setdefault(int(spell), int(low))

    used = defaultdict(lambda: defaultdict(int))
    for table in tables:
        line = SKILL_LINES.get(table["name"])
        if not line or table["items"]:
            continue
        wiki = wiki_skills(table["name"])
        for section in table["sections"]:
            for spell, comment in section["entries"]:
                info = spells.get(spell)
                if not info or info.get("fixed"):
                    continue
                name = names.get(spell) or comment
                top = yellow.get((line, spell))
                skill = source = None
                # the pattern named after the recipe first, else any item AtlasLoot says teaches it
                ranks = [by_name[(line, name)]] if (line, name) in by_name else \
                    [item_req[i][1] for i in teach.get(spell, ()) if item_req.get(i, (0,))[0] == line]
                if ranks:
                    skill, source = min(ranks), "item"
                if skill is None:
                    # by the game's name and AtlasLoot's, which can each be another recipe's on the
                    # wiki: 11450 is "Elixir of Defense" in game (the wiki's is 3177, at 130) and
                    # "Elixir of Greater Defense" in AtlasLoot (195); 2167 is "Gray Leather Boots"
                    # in game (75) and "Dark Leather Boots" in AtlasLoot (a new recipe, at 35).
                    # The value nearest the yellow skill wins, as for names listed twice.
                    rows = [s for k in {name, comment} - {None, ""} for s, src in wiki.get(k, ())
                            if src not in ("?", "")]
                    if len(set(rows)) > 1 and top:  # same name twice (old and new version): the one nearest yellow
                        rows = [min(rows, key=lambda s: abs(top - 20 - s))]
                    if rows:
                        skill, source = rows[0], "wiki"
                if skill is None and top and classic_yellow.get(spell):
                    skill, source = info["skill"] + top - classic_yellow[spell], "shifted"
                if skill is None:
                    skill, source = info["skill"], "classic"
                skill = max(1, skill)
                if skill != info["skill"]:
                    used[table["name"]]["(changed)"] += 1
                info["skill"], info["fixed"] = skill, True
                used[table["name"]][source] += 1
    return used


# How each recipe is learned ------------------------------------------------------

BIND = {"0": "BoE", "2": "BoE", "1": "BoP", "3": "BoU", "4": "quest item"}  # ItemSparse.Bonding (0 = never binds)
STANDING = {"3": "Neutral", "4": "Friendly", "5": "Honored", "6": "Revered", "7": "Exalted"}  # ItemSparse.MinReputation
WIKI_KINDS = {"Vendor": "Vendor", "Drop": "Drop", "Trainer": "Trainer", "Quest": "Quest", "Automatic": "Automatic",
              "Special trainer": "Special trainer", "Crafted": "Crafted"}
INSTANCE_NAMES = {"TheRuinsofAhnQiraj": "Ruins of Ahn'Qiraj", "TheTempleofAhnQiraj": "Temple of Ahn'Qiraj",
                  "TheTempleOfAtal'Hakkar": "Sunken Temple", "WorldBosses": "world boss", "Zul'Gurub": "Zul'Gurub",
                  "Zul'Farrak": "Zul'Farrak", "TheDeadmines": "Deadmines", "TheStockade": "Stockade",
                  "ScarletMonasteryGraveyard": "SM Graveyard", "ScarletMonasteryLibrary": "SM Library",
                  "ScarletMonasteryArmory": "SM Armory", "ScarletMonasteryCathedral": "SM Cathedral"}


def wiki_kind(cell):
    """The wiki table's Source cell -> (kind, detail), or (None, None) when it doesn't say."""
    cost = re.search(r"mfvr=(\d+)", cell)
    if cost:  # new Forever recipes, sold for Merchant's Favor by the ACA / DS&L quartermasters
        standing = re.search(r"\{\{text\|\w+\|(\w+)\}\}", cell)
        return "Vendor", f"{cost.group(1)} Merchant's Favor" + (f", {standing.group(1)}" if standing else "")
    return WIKI_KINDS.get(cell.split(";")[0].strip()), None


def instance_drops(addons):
    """item ID -> instances it drops in, from AtlasLoot's Forever loot sources (bosses of dungeons and raids)."""
    path = addons / "AtlasLootContinued_Data" / "source-forever.lua"
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    ids = re.findall(r'^"([^"]+)"', text.split('["ItemData"]')[0], re.M)
    out = defaultdict(set)
    for item, value in re.findall(r"^\[(\d+)\] = (\{.*\}),?$", text, re.M):
        for ini, _boss, kind in re.findall(r"\{(\d+),(\d+),(\d+)\}", value):
            if kind == "1" and 0 < int(ini) <= len(ids):
                key = re.sub(r"\d+$", "", ids[int(ini) - 1])  # BlackfathomDeeps2 (SoD's) -> BlackfathomDeeps
                out[int(item)].add(INSTANCE_NAMES.get(key) or re.sub(r"(?<=[a-z])(?=[A-Z])", " ", key))
    return out


def forever_sources(tables, spells, game, addons):
    """Sets each recipe's "source", how it is learned, e.g. "Drop (BoP), Blackrock Depths":
      kind     the wiki's Forever table (Vendor, Drop, Quest, Trainer, ...); where it
               doesn't say, Trainer when no item teaches the recipe, Drop when
               AtlasLoot has the item in a loot table, Vendor when the item needs
               a reputation, else unknown;
      binding  of the item that teaches it (the game's ItemSparse, linked to the
               recipe by ItemEffect "learn spell"): BoE (or never binds), BoP, BoU;
      detail   the Merchant's Favor price, the reputation the item needs, the
               instances it drops in.
    Returns {profession: {kind: count}}."""
    names = {int(r["ID"]): r["Name_lang"] for r in game["SpellName"]}
    factions = {r["ID"]: r["Name_lang"] for r in game["Faction"]}
    item_names = {int(r["ID"]): r["Display_lang"] for r in game["ItemSparse"]}
    recipe_items = {r["ID"]: r for r in game["ItemSparse"]
                    if r["RequiredSkill"] != "0" and not re.search(r"\bOLD\b|^Deprecated|^zz", r["Display_lang"])}
    learns = {r["ID"]: int(r["SpellID"]) for r in game["ItemEffect"] if r["TriggerType"] == "6"}
    teaches = defaultdict(list)  # spell -> ItemSparse rows of the items that teach it
    for r in game["ItemXItemEffect"]:
        spell, item = learns.get(r["ItemEffectID"]), recipe_items.get(r["ItemID"])
        if spell and item:
            teaches[spell].append(item)
    drops = instance_drops(addons)
    anywhere = defaultdict(list)  # the wiki sometimes lists a recipe on another profession's page
    for prof in WIKI_PAGES:
        for name, rows in wiki_skills(prof).items():
            anywhere[name].extend(rows)

    used = defaultdict(lambda: defaultdict(int))
    for table in tables:
        if table["items"]:
            continue
        wiki = wiki_skills(table["name"])
        for section in table["sections"]:
            for spell, comment in section["entries"]:
                info = spells.get(spell)
                if not info or "source" in info:
                    continue
                # AtlasLoot's name (Classic's, as on the wiki: Forever renamed a few, 11472 Elixir of Giants
                # is "Elixir of Greater Strength" in game), the game's, the product's (the wiki's "Major
                # Troll's Blood Elixir" for the recipe AtlasLoot calls "Major Troll")
                keys = [k for k in (comment, names.get(spell), item_names.get(info["created"] or 0)) if k]
                rows = [r for k in keys for r in wiki.get(k, ())] + [r for k in keys for r in anywhere.get(k, ())]
                # same name twice (old and new version): the row with this recipe's skill
                rows = [src for s, src in rows if s == info["skill"]] or [src for _, src in rows]
                kind, detail = next((k for k in map(wiki_kind, rows) if k[0]), (None, None))
                items = teaches.get(spell, [])
                places = sorted({p for i in items for p in drops.get(int(i["ID"]), ())})
                rep = next((i for i in items if i["MinFactionID"] != "0"), None)
                if kind is None:
                    kind = "Trainer" if not items else "Drop" if places else "Vendor" if rep else None
                parts = []
                if items and kind not in ("Trainer", "Automatic", "Special trainer"):
                    binds = "/".join(sorted({BIND.get(i["Bonding"], "?") for i in items}))
                    parts.append(f"{kind or 'Unknown source'} ({binds})")
                    if detail:
                        parts.append(detail)
                    if rep:
                        parts.append(f"{STANDING.get(rep['MinReputation'], '?')} with "
                                     f"{factions.get(rep['MinFactionID'], 'a faction')}")
                    if places:
                        parts.append(", ".join(places[:3]) + (", ..." if len(places) > 3 else ""))
                else:
                    parts.append(kind or "Unknown source")
                    if detail:
                        parts.append(detail)
                info["source"] = ", ".join(parts)
                used[table["name"]][kind or "unknown"] += 1
    return used


def lua_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    addons = Path(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] != "-" else Path(__file__).resolve().parents[2]
    build = sys.argv[2] if len(sys.argv) > 2 else "1.60.1.70888"
    spells = load_professions(addons / "AtlasLootContinued" / "Data" / "Profession.lua")
    tables = load_forever_tables(addons / "AtlasLootContinued_Crafting" / "data-forever.lua")
    apply_forever_changes(tables, spells)
    game = game_tables(build, ["SkillLineAbility", "SpellName", "SpellReagents", "ItemSparse",
                               "ItemEffect", "ItemXItemEffect", "Faction"])
    print(f"{fill_reagents(spells, game)} recipes without reagents in AtlasLoot took them from the game's tables")
    for prof, counts in forever_skills(tables, spells, game, addons).items():
        print(f"{prof:15} skill: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    for prof, counts in forever_sources(tables, spells, game, addons).items():
        print(f"{prof:15} source: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))

    out = [
        "-- Generated by tools/build_recipes.py from AtlasLoot Continued's crafting data (GPL v2).",
        "-- Do not edit by hand; run the script again instead.",
        "local _, ns = ...",
        "",
        "-- { profession = name, categories = { { name =, recipes = { recipe, ... } | items = { itemID, ... } } } }",
        "-- recipe = { spellID, craftedItemID or 0, requiredSkill, { reagentID, count, reagentID, count, ... }, itemsPerCraft, name, source }",
        "ns.RECIPE_DB = {",
    ]
    recipes = missing = items = 0
    for table in tables:
        out.append(f"  {{ profession = {lua_string(table['name'])}, categories = {{")
        for section in table["sections"]:
            if not section["entries"]:
                continue
            if table["items"]:
                ids = ", ".join(str(i) for i, _ in section["entries"])
                out.append(f"    {{ name = {lua_string(section['name'])}, items = {{ {ids} }} }},")
                items += len(section["entries"])
                continue
            rows = []
            for spell, comment in section["entries"]:
                info = spells.get(spell)
                if not info:
                    missing += 1
                    continue
                reagents = ", ".join(f"{r}, {c}" for r, c in info["reagents"])
                # "Formula: Enchant Bracer - Agility" (named after the recipe item) -> the spell's name
                comment = re.sub(r"^(?:Formula|Pattern|Plans|Schematic|Recipe|Manual): ", "", comment)
                name = lua_string(comment) if comment else "nil"
                source = f", {lua_string(info['source'])}" if info.get("source") else ""
                rows.append(f"      {{ {spell}, {info['created'] or 0}, {info['skill']}, {{ {reagents} }}, {info['made']}, "
                            f"{name}{source} }},")
            if rows:
                out.append(f"    {{ name = {lua_string(section['name'])}, recipes = {{")
                out.extend(rows)
                out.append("    } },")
                recipes += len(rows)
        out.append("  } },")
    out.append("}")
    target = Path(__file__).resolve().parents[1] / "RecipeData.lua"
    target.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"{len(tables)} professions, {recipes} recipes, {items} gathered items -> {target}")
    if missing:
        print(f"{missing} recipes listed for Forever had no reagent data in Profession.lua and were skipped")


if __name__ == "__main__":
    main()

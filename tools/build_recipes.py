"""Build ProfScan/RecipeData.lua from AtlasLoot Continued's crafting data.

Usage:
    python build_recipes.py [path to Interface/AddOns]

Reads (default: the AddOns folder this script sits in):
    AtlasLootContinued/Data/Profession.lua         spell -> crafted item, skill, reagents
    AtlasLootContinued_Crafting/data-forever.lua   which recipes exist in Forever, by profession and category
and writes ../RecipeData.lua. Run it again after AtlasLoot updates. AtlasLoot is
GPL v2, so the generated file carries that licence.

ProfScan also reads your own profession windows in game (Recipes.lua), which
adds recipes missing here and marks the ones you know.
"""
import re
import sys
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
        for name, rows in sections:
            entries = []
            for spell, item, skill, reagents, made, label in rows:
                spells[spell] = {"created": item, "skill": skill, "reagents": reagents, "made": made}
                entries.append((spell, label))
            table["sections"].append({"name": name, "entries": entries})


def lua_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    addons = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
    spells = load_professions(addons / "AtlasLootContinued" / "Data" / "Profession.lua")
    tables = load_forever_tables(addons / "AtlasLootContinued_Crafting" / "data-forever.lua")
    apply_forever_changes(tables, spells)

    out = [
        "-- Generated by tools/build_recipes.py from AtlasLoot Continued's crafting data (GPL v2).",
        "-- Do not edit by hand; run the script again instead.",
        "local _, ns = ...",
        "",
        "-- { profession = name, categories = { { name =, recipes = { recipe, ... } | items = { itemID, ... } } } }",
        "-- recipe = { spellID, craftedItemID or 0, requiredSkill, { reagentID, count, reagentID, count, ... }, itemsPerCraft, name }",
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
                name = f", {lua_string(comment)}" if comment else ""
                rows.append(f"      {{ {spell}, {info['created'] or 0}, {info['skill']}, {{ {reagents} }}, {info['made']}{name} }},")
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

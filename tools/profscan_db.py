"""ProfScan's permanent database (SQLite), built from the addon's SavedVariables.

    python profscan_db.py [--db FILE] import [ProfScan.lua ...]
    python profscan_db.py [--db FILE] info
    python profscan_db.py [--db FILE] report [--days 7]
    python profscan_db.py [--db FILE] trim (--older-than DAYS | --before YYYY-MM-DD) [--dry-run] [--yes]
    python profscan_db.py [--db FILE] merge OTHER.db [--dry-run]
    python profscan_db.py [--db FILE] export FOLDER [--tables scans,daily,...]
    python profscan_db.py [--db FILE] api-setup
    python profscan_db.py [--db FILE] api-houses [--match [--apply]]
    python profscan_db.py [--db FILE] api-map HOUSE_ID "Realm-Faction"
    python profscan_db.py [--db FILE] api-fetch [--loop MINUTES] [--all-items]
    python profscan_db.py [--db FILE] addon-export [--ah "Realm-Faction"] [--hours 24] [--days 30]

The database (default: Documents/ProfScan/profscan.db, or $PROFSCAN_DB) holds
everything in one file; the tables are described in SCHEMA below.

import   Reads ProfScan.lua (by default every account's file in this game's WTF
         folder) and adds what is new. Safe to repeat: rows are keyed by
         auction house, item and time, so nothing is duplicated. Watch-mode
         polls are replayed here into order books and inferred events (same
         rules as Watch.lua). Daily summaries made by the in-game trim are
         taken only for days the database has no raw data for.
trim     Folds raw rows older than the cutoff into one `daily` row per
         auction house, item and day (price range and median, average
         quantity, scans, watched time, purchases, units bought/listed/removed),
         then deletes the raw rows. Asks first unless --yes. Later imports
         skip raw data from before the cutoff, so it is not re-added.
merge    Adds another ProfScan database (e.g. a friend's, or one from another
         PC). Rows already here win; the other database's raw rows from before
         this one's trim cutoff are folded into daily rows for days missing here.
export   Writes CSV files, one per table, with readable times and item names.
report   Cheapest items against their median, watch-mode results, and the
         Blizzard API's sold estimates.

Blizzard API (blizzard.py): Blizzard publishes every Forever auction house
about once an hour.
api-setup     Asks for a Battle.net API client ID and secret (create one at
              https://develop.battle.net/access/clients) and saves them next to
              the database as blizzard_api.json.
api-houses    Lists the API's auction houses and which of your auction houses
              ("Realm-Faction", as ProfScan names them in game) each one is.
              --match downloads every house once and compares its prices with
              your in-game scans to find out; --apply saves clear matches.
api-map       Sets that by hand.
api-fetch     Downloads the mapped houses and stores, per item, the lowest
              price, quantity and cheapest price levels as scans (source 'api'),
              and compares listings with the previous snapshot (api_activity):
              listings that shrank were bought; listings that vanished early
              were bought or cancelled, and those priced at or below the
              cheapest listing that stayed are counted as probably bought.
              --loop repeats every N minutes (unchanged snapshots are skipped).
addon-export  Writes ImportedPrices.lua into the addon so ProfScan in game shows
              the API prices, history and sold estimates (after /reload).
"""
import argparse
import csv
import os
import sqlite3
import statistics
import sys
import time
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

import luadata

SCHEMA_VERSION = 3  # 2: recipes.yield_min / yield_max; 3: scans.source, daily.api_sold_est, api_* tables
DAY = 86400
EXPIRY_MARGIN = 60   # seconds; same as Watch.lua
MAX_POLL_GAP = 900   # polls further apart are not compared (pauses, AH closed)
TOOLS_DIR = Path(__file__).resolve().parent
ADDON_DIR = TOOLS_DIR.parent

SCHEMA = """
-- Settings: schema_version, trimmed_before (unix time; raw data before it was folded into daily).
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);

CREATE TABLE IF NOT EXISTS items (item_id INTEGER PRIMARY KEY, name TEXT);

-- Quick and deep scans: lowest price (per unit, copper) and quantity listed.
-- source: NULL = in-game scan, 'api' = Blizzard API snapshot.
CREATE TABLE IF NOT EXISTS scans (
    ah TEXT, t INTEGER, item_id INTEGER, min_price INTEGER, quantity INTEGER, deep INTEGER, source TEXT,
    PRIMARY KEY (ah, item_id, t)) WITHOUT ROWID;

-- Deep scans: the cheapest price levels (level 1 = cheapest).
CREATE TABLE IF NOT EXISTS ladder (
    ah TEXT, t INTEGER, item_id INTEGER, level INTEGER, price INTEGER, quantity INTEGER,
    PRIMARY KEY (ah, item_id, t, level)) WITHOUT ROWID;

-- Watch mode: the order book after every poll. book = "price:qty:minutesLeft:seller+seller/...".
-- seconds_since_prev = time covered since the previous poll (0 at the start of a session).
CREATE TABLE IF NOT EXISTS watch_polls (
    ah TEXT, t INTEGER, item_id INTEGER, total INTEGER, cap INTEGER, best INTEGER, depth10 INTEGER,
    levels_known INTEGER, seconds_since_prev INTEGER, book TEXT,
    PRIMARY KEY (ah, item_id, t)) WITHOUT ROWID;

-- Watch mode: what happened between two polls. kind = buy | listed | removed | expired | repost.
CREATE TABLE IF NOT EXISTS watch_events (
    ah TEXT, t INTEGER, item_id INTEGER, kind TEXT, quantity INTEGER, low INTEGER, high INTEGER,
    levels INTEGER, avg_price INTEGER, seconds_since_prev INTEGER,
    PRIMARY KEY (ah, item_id, t, kind)) WITHOUT ROWID;

-- Long-term tendencies: one row per auction house, item and UTC day, made by trim.
CREATE TABLE IF NOT EXISTS daily (
    ah TEXT, day TEXT, item_id INTEGER, scans INTEGER, min_low INTEGER, min_median INTEGER,
    min_high INTEGER, qty_avg REAL, watch_seconds INTEGER, buys INTEGER, bought_units INTEGER,
    listed_units INTEGER, removed_units INTEGER, source TEXT, api_sold_est INTEGER,
    PRIMARY KEY (ah, item_id, day)) WITHOUT ROWID;

-- yield_min/yield_max: items made per craft (from the game once its profession window was opened).
CREATE TABLE IF NOT EXISTS recipes (
    spell_id INTEGER PRIMARY KEY, profession TEXT, category TEXT, name TEXT, item_id INTEGER,
    skill INTEGER, source TEXT, yield_min INTEGER, yield_max INTEGER);
CREATE TABLE IF NOT EXISTS recipe_reagents (
    spell_id INTEGER, item_id INTEGER, count INTEGER, PRIMARY KEY (spell_id, item_id)) WITHOUT ROWID;

-- Vendor buy prices per unit, learned in game from merchant windows.
CREATE TABLE IF NOT EXISTS vendor_prices (item_id INTEGER PRIMARY KEY, buy_price INTEGER);

CREATE TABLE IF NOT EXISTS imports (
    id INTEGER PRIMARY KEY, at INTEGER, source TEXT, scans INTEGER, polls INTEGER, events INTEGER,
    daily INTEGER, skipped_old INTEGER);

-- Blizzard API: which of your auction houses each API house is. last_modified = newest snapshot stored.
CREATE TABLE IF NOT EXISTS api_houses (
    region TEXT, house_id INTEGER, name TEXT, ah TEXT, last_modified INTEGER,
    PRIMARY KEY (region, house_id)) WITHOUT ROWID;

-- Blizzard API: per item, how listings changed since the previous snapshot (quantities).
-- bought_partial: listings that shrank (certainly bought). gone_cheap: vanished early, priced at or
-- below the cheapest listing that stayed (probably bought). gone_dear: vanished early above it
-- (cancelled: a buyer would have taken the cheaper one). gone_expiring: had under 30 minutes left.
CREATE TABLE IF NOT EXISTS api_activity (
    ah TEXT, t INTEGER, item_id INTEGER, seconds_since_prev INTEGER, listings INTEGER,
    bought_partial INTEGER, gone_cheap INTEGER, gone_dear INTEGER, gone_expiring INTEGER, new_listed INTEGER,
    PRIMARY KEY (ah, item_id, t)) WITHOUT ROWID;

-- Blizzard API: the listings of each house's latest snapshot, kept only to compare with the next one.
CREATE TABLE IF NOT EXISTS api_listings (
    region TEXT, house_id INTEGER, auction_id INTEGER, item_id INTEGER, quantity INTEGER,
    unit_price INTEGER, time_left TEXT, PRIMARY KEY (region, house_id, auction_id)) WITHOUT ROWID;
"""
RAW_TABLES = ("scans", "ladder", "watch_polls", "watch_events", "api_activity")
SCAN_COLUMNS = "ah, t, item_id, min_price, quantity, deep, source"
DAILY_COLUMNS = ("ah, day, item_id, scans, min_low, min_median, min_high, qty_avg, watch_seconds, buys, "
                 "bought_units, listed_units, removed_units, source, api_sold_est")


def default_db():
    if os.environ.get("PROFSCAN_DB"):
        return Path(os.environ["PROFSCAN_DB"])
    return Path.home() / "Documents" / "ProfScan" / "profscan.db"


def connect(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path)
    con.executescript(SCHEMA)
    # upgrade databases made by older versions of this script
    if "yield_min" not in columns(con, "main", "recipes"):
        con.execute("ALTER TABLE recipes ADD COLUMN yield_min INTEGER")
        con.execute("ALTER TABLE recipes ADD COLUMN yield_max INTEGER")
    if "source" not in columns(con, "main", "scans"):
        con.execute("ALTER TABLE scans ADD COLUMN source TEXT")
    if "api_sold_est" not in columns(con, "main", "daily"):
        con.execute("ALTER TABLE daily ADD COLUMN api_sold_est INTEGER")
    set_meta(con, "schema_version", SCHEMA_VERSION)
    con.commit()
    return con


def columns(con, schema, table):
    return [r[1] for r in con.execute(f"PRAGMA {schema}.table_info({table})")]


def meta(con, key, default=None):
    row = con.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
    return row[0] if row else default


def set_meta(con, key, value):
    con.execute("INSERT OR REPLACE INTO meta VALUES (?, ?)", (key, str(value)))


def trimmed_before(con):
    return int(meta(con, "trimmed_before", 0))


def day_text(day_number):
    return (datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(days=day_number)).strftime("%Y-%m-%d")


def day_number(text):
    return (datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=timezone.utc)
            - datetime(1970, 1, 1, tzinfo=timezone.utc)).days


def iso(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def gold(copper):
    return round((copper or 0) / 10000, 4)


# Watch-mode replay (same rules as Watch.lua) ------------------------------------------------

@dataclass
class Level:
    qty: int
    tl: int | None  # seconds left when last seen
    tl_at: int      # when that was
    owners: tuple

    def time_left(self, t):
        return None if self.tl is None else self.tl - (t - self.tl_at)


@dataclass
class Book:
    t: int
    cap: int
    total: int
    levels: dict  # price -> Level

    def prices(self):
        return sorted(self.levels)

    def best(self):
        return min(self.levels) if self.levels else 0

    def depth(self, within=0.10):
        best = self.best()
        return sum(l.qty for p, l in self.levels.items() if p <= best * (1 + within))

    def text(self):
        return "/".join(f"{p}:{l.qty}:{'' if l.tl is None else max(0, l.time_left(self.t)) // 60}:{'+'.join(l.owners)}"
                        for p, l in sorted(self.levels.items()))


def parse_levels(text, t):
    out = {}
    for token in filter(None, text.split("/")):
        parts = token.split(":")
        price, qty = int(parts[0]), int(parts[1])
        if len(parts) == 2:
            out[price] = None  # level gone (D lines only)
        else:
            tl = int(parts[2]) * 60 if parts[2] else None
            owners = tuple(o for o in parts[3].split("+") if o) if len(parts) > 3 else ()
            out[price] = Level(qty, tl, t, owners)
    return out


def classify(prev, cur):
    """Same rules as ns.Classify in Watch.lua."""
    elapsed = cur.t - prev.t
    caps = [c for c in (prev.cap, cur.cap) if c]
    cap = min(caps) if caps else 0

    def known(price):
        return cap == 0 or price < cap

    added_by, listed, listed_low = set(), 0, None
    for price in cur.prices():
        if not known(price):
            break
        old = prev.levels.get(price)
        added = cur.levels[price].qty - (old.qty if old else 0)
        if added > 0:
            listed += added
            listed_low = listed_low or price
            added_by.update(cur.levels[price].owners)

    buy = {"kind": "buy", "qty": 0, "cost": 0, "levels": 0, "low": None, "high": None}
    expired = reposted = removed = 0
    bottom = True
    for price in prev.prices():
        if not known(price):
            break
        level = prev.levels[price]
        now = cur.levels.get(price)
        left = now.qty if now else 0
        gone = level.qty - left
        time_left = level.time_left(prev.t)
        if gone <= 0:
            bottom = False
        elif left == 0 and time_left is not None and time_left - elapsed <= EXPIRY_MARGIN:
            expired += gone
        elif left == 0 and level.owners and set(level.owners) <= added_by:
            reposted += gone
        elif bottom:
            buy["qty"] += gone
            buy["cost"] += gone * price
            buy["levels"] += 1
            buy["low"] = buy["low"] or price
            buy["high"] = price
            if left > 0:
                bottom = False
        else:
            removed += gone

    events = []
    if buy["qty"]:
        buy["vwap"] = round(buy["cost"] / buy["qty"])
        events.append(buy)
    for kind, qty in (("expired", expired), ("repost", reposted), ("removed", removed)):
        if qty:
            events.append({"kind": kind, "qty": qty})
    if listed:
        events.append({"kind": "listed", "qty": listed, "low": listed_low})
    return events


def replay_watch_log(lines):
    """Yields (poll_row, [event_row, ...]) for each watch-log line, in order."""
    state = {}
    for line in lines:
        parts = line.split(",", 6)
        if len(parts) != 7 or parts[3] not in ("S", "F", "D", "="):
            continue
        ah, t, item, kind, total, cap, levels_text = parts
        t, item, total, cap = int(t), int(item), int(total), int(cap)
        key = (ah, item)
        prev = state.get(key)
        if kind in ("S", "F"):
            levels = {p: l for p, l in parse_levels(levels_text, t).items() if l}
        elif prev is None:
            continue  # a delta whose starting point is not in this file
        elif kind == "D":
            levels = dict(prev.levels)
            for price, level in parse_levels(levels_text, t).items():
                if level is None:
                    levels.pop(price, None)
                else:
                    levels[price] = level
        else:
            levels = prev.levels
        book = Book(t, cap, total, levels)
        compare = kind != "S" and prev is not None and 0 < t - prev.t <= MAX_POLL_GAP
        elapsed = t - prev.t if compare else 0
        events = []
        if compare:
            for e in classify(prev, book):
                events.append((ah, t, item, e["kind"], e["qty"], e.get("low"), e.get("high"),
                               e.get("levels"), e.get("vwap"), elapsed))
        poll = (ah, t, item, total, cap, book.best(), book.depth(), len(book.levels), elapsed, book.text())
        state[key] = book
        yield poll, events


# Import -----------------------------------------------------------------------------------

def find_savedvariables():
    wtf = ADDON_DIR.parents[2] / "WTF" / "Account"  # AddOns/ProfScan -> Interface -> game folder
    return sorted(wtf.glob("*/SavedVariables/ProfScan.lua"))


def load_recipe_data():
    path = ADDON_DIR / "RecipeData.lua"
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8")
    start = text.index("ns.RECIPE_DB =") + len("ns.RECIPE_DB =")
    return luadata.parse_value(text, start)[0]


def import_recipes(con, captured, override=None):
    rows, reagents = {}, {}
    for prof in load_recipe_data():
        for cat in prof["categories"]:
            for r in luadata.as_list(cat.get("recipes")):
                # { spellID, item, skill, { reagent, count, ... }, itemsPerCraft, name }
                spell, item, skill, flat = r[0], r[1], r[2], luadata.as_list(r[3])
                made = r[4] if len(r) > 4 else 1
                rows[spell] = (spell, prof["profession"], cat["name"], r[5] if len(r) > 5 else None, item, skill,
                               "atlasloot", made, made)
                reagents[spell] = list(zip(flat[::2], flat[1::2]))
    for prof, recipes in luadata.as_dict(captured).items():
        for spell, cap in luadata.as_dict(recipes).items():
            flat = luadata.as_list(cap.get("reagents"))
            old = rows.get(spell)
            lo = cap.get("yieldMin") or (old[7] if old else 1)
            hi = cap.get("yieldMax") or (old[8] if old and not cap.get("yieldMin") else lo)
            rows[spell] = (spell, prof, old[2] if old else "Seen in game", cap.get("name") or (old and old[3]),
                           cap.get("item") or (old and old[4]) or 0, old[5] if old else 0, "game", lo, hi)
            if flat:
                reagents[spell] = list(zip(flat[::2], flat[1::2]))
    # same precedence as Recipes.lua: your setting, then game / AtlasLoot
    for spell, o in luadata.as_dict(override).items():
        if spell in rows:
            o = luadata.as_list(o)
            r = list(rows[spell])
            r[6], r[7], r[8] = "set by you", o[0], o[1] if len(o) > 1 else o[0]
            rows[spell] = tuple(r)
    con.executemany("INSERT OR REPLACE INTO recipes VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", rows.values())
    con.execute("DELETE FROM recipe_reagents")
    con.executemany("INSERT OR IGNORE INTO recipe_reagents VALUES (?, ?, ?)",
                    [(s, i, c) for s, pairs in reagents.items() for i, c in pairs])
    return len(rows)


def has_raw_for_day(con, ah, item, day):
    start = day * DAY
    for table in ("scans", "watch_events"):
        if con.execute(f"SELECT 1 FROM {table} WHERE ah = ? AND item_id = ? AND t >= ? AND t < ? LIMIT 1",
                       (ah, item, start, start + DAY)).fetchone():
            return True
    return False


def cmd_import(con, args):
    paths = [Path(p) for p in args.savedvariables] or find_savedvariables()
    if not paths:
        raise SystemExit("No ProfScan.lua found; pass its path (WTF/Account/<account>/SavedVariables/ProfScan.lua).")
    cutoff = trimmed_before(con)
    for path in paths:
        data = luadata.load_assignments(path.read_text(encoding="utf-8", errors="replace")).get("ProfScanDB")
        if not data:
            print(f"{path}: no ProfScanDB in this file, skipped")
            continue
        n = defaultdict(int)

        def changes():
            return con.total_changes

        con.executemany("INSERT OR REPLACE INTO items VALUES (?, ?)",
                        [(int(i), name) for i, name in luadata.as_dict(data.get("names")).items() if name])

        scans, ladders = [], []
        for line in luadata.as_list(data.get("log")):
            parts = line.split(",", 5)
            if len(parts) != 6:
                continue
            ah, t, item, low, qty, ladder = parts[0], int(parts[1]), int(parts[2]), int(parts[3]), int(parts[4]), parts[5]
            if t < cutoff:
                n["skipped_old"] += 1
                continue
            scans.append((ah, t, item, low, qty, 1 if ladder else 0, None))
            for level, token in enumerate(filter(None, ladder.split("/")), 1):
                price, q = token.split(":")
                ladders.append((ah, t, item, level, int(price), int(q)))
        mark = changes()
        con.executemany(f"INSERT OR IGNORE INTO scans ({SCAN_COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?)", scans)
        n["scans"] = changes() - mark
        con.executemany("INSERT OR IGNORE INTO ladder VALUES (?, ?, ?, ?, ?, ?)", ladders)

        polls, events = [], []
        for poll, evs in replay_watch_log(luadata.as_list(data.get("watchLog"))):
            if poll[1] < cutoff:
                n["skipped_old"] += 1
                continue
            polls.append(poll)
            events.extend(evs)
        mark = changes()
        con.executemany("INSERT OR IGNORE INTO watch_polls VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", polls)
        n["polls"] = changes() - mark
        mark = changes()
        con.executemany("INSERT OR IGNORE INTO watch_events VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", events)
        n["events"] = changes() - mark

        for line in luadata.as_list(data.get("daily")):
            f = line.split(",")
            if len(f) != 13:
                continue
            ah, day, item = f[0], int(f[1]), int(f[2])
            nums = [int(x) for x in f[3:]]
            if con.execute("SELECT 1 FROM daily WHERE ah = ? AND item_id = ? AND day = ?",
                           (ah, item, day_text(day))).fetchone() or has_raw_for_day(con, ah, item, day):
                continue
            scans_n, low, med, high, qty, watch_sec, buys, bought, listed, removed = nums
            con.execute(f"INSERT INTO daily ({DAILY_COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'game', 0)",
                        (ah, day_text(day), item, scans_n, low, med, high, qty, watch_sec, buys, bought, listed, removed))
            n["daily"] += 1

        con.executemany("INSERT OR REPLACE INTO vendor_prices VALUES (?, ?)",
                        [(int(i), int(p)) for i, p in luadata.as_dict(data.get("vendor")).items()])
        recipes = import_recipes(con, data.get("captured"), data.get("yieldOverride"))
        con.execute("INSERT INTO imports (at, source, scans, polls, events, daily, skipped_old) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (int(time.time()), str(path), n["scans"], n["polls"], n["events"], n["daily"], n["skipped_old"]))
        con.commit()
        print(f"{path}:\n  new: {n['scans']} scans, {n['polls']} watch polls, {n['events']} watch events, "
              f"{n['daily']} daily summaries; {recipes} recipes known"
              + (f"\n  skipped {n['skipped_old']} raw rows from before the trim cutoff" if n["skipped_old"] else ""))
        if not (n["scans"] or n["polls"] or n["events"] or n["daily"]):
            print("  (nothing new)")


# Trim -------------------------------------------------------------------------------------

def summarize(con, cutoff, schema="main"):
    """Daily summaries of `schema`'s raw rows older than cutoff: {(ah, item, day): dict}."""
    out = defaultdict(lambda: {"scans": 0, "mins": [], "qty": 0, "watch_seconds": 0, "buys": 0,
                               "bought": 0, "listed": 0, "removed": 0, "api_sold": 0})
    for ah, t, item, low, qty in con.execute(
            f"SELECT ah, t, item_id, min_price, quantity FROM {schema}.scans WHERE t < ?", (cutoff,)):
        d = out[(ah, item, t // DAY)]
        d["scans"] += 1
        d["qty"] += qty
        if low > 0:
            d["mins"].append(low)
    for ah, t, item, sec in con.execute(
            f"SELECT ah, t, item_id, seconds_since_prev FROM {schema}.watch_polls WHERE t < ?", (cutoff,)):
        out[(ah, item, t // DAY)]["watch_seconds"] += sec
    for ah, t, item, kind, qty in con.execute(
            f"SELECT ah, t, item_id, kind, quantity FROM {schema}.watch_events WHERE t < ?", (cutoff,)):
        d = out[(ah, item, t // DAY)]
        if kind == "buy":
            d["buys"] += 1
            d["bought"] += qty
        elif kind == "listed":
            d["listed"] += qty
        else:
            d["removed"] += qty
    if "api_activity" in tables_in(con, schema):
        for ah, t, item, partial, cheap in con.execute(
                f"SELECT ah, t, item_id, bought_partial, gone_cheap FROM {schema}.api_activity WHERE t < ?", (cutoff,)):
            out[(ah, item, t // DAY)]["api_sold"] += partial + cheap
    return out


def daily_row(ah, item, day, d, source):
    mins = sorted(d["mins"])
    return (ah, day_text(day), item, d["scans"], mins[0] if mins else 0,
            int(statistics.median(mins)) if mins else 0, mins[-1] if mins else 0,
            round(d["qty"] / d["scans"], 2) if d["scans"] else 0,
            d["watch_seconds"], d["buys"], d["bought"], d["listed"], d["removed"], source, d["api_sold"])


def fold(con, cutoff, schema="main", combine=True):
    """Writes daily rows for raw rows older than cutoff. With combine, a day
    that already has a daily row gets the new counts added to it; without,
    existing daily rows win and the raw rows are only dropped."""
    added = combined = 0
    for (ah, item, day), d in summarize(con, cutoff, schema).items():
        row = daily_row(ah, item, day, d, "db")
        old = con.execute("SELECT scans, min_low, min_median, min_high, qty_avg, watch_seconds, buys, bought_units, "
                          "listed_units, removed_units, COALESCE(api_sold_est, 0) FROM daily "
                          "WHERE ah = ? AND item_id = ? AND day = ?", (ah, item, row[1])).fetchone()
        if old is None:
            con.execute(f"INSERT INTO daily ({DAILY_COLUMNS}) VALUES ({', '.join('?' * 15)})", row)
            added += 1
        elif combine:
            scans = old[0] + row[3]
            low = min(x for x in (old[1], row[4]) if x) if (old[1] or row[4]) else 0
            median = row[5] if row[3] > old[0] else old[2]
            qty = (old[4] * old[0] + row[7] * row[3]) / scans if scans else 0
            con.execute("UPDATE daily SET scans = ?, min_low = ?, min_median = ?, min_high = ?, qty_avg = ?, "
                        "watch_seconds = ?, buys = ?, bought_units = ?, listed_units = ?, removed_units = ?, "
                        "api_sold_est = ? WHERE ah = ? AND item_id = ? AND day = ?",
                        (scans, low, median, max(old[3], row[6]), round(qty, 2), old[5] + row[8], old[6] + row[9],
                         old[7] + row[10], old[8] + row[11], old[9] + row[12], old[10] + row[14], ah, item, row[1]))
            combined += 1
    return added, combined


def raw_counts(con, cutoff, schema="main"):
    present = tables_in(con, schema)
    return {t: con.execute(f"SELECT COUNT(*) FROM {schema}.{t} WHERE t < ?", (cutoff,)).fetchone()[0]
            for t in RAW_TABLES if t in present}


def cmd_trim(con, args):
    if args.before:
        cutoff_day = day_number(args.before)
    else:
        cutoff_day = int(time.time()) // DAY - args.older_than
    cutoff = cutoff_day * DAY
    counts = raw_counts(con, cutoff)
    days = len(summarize(con, cutoff))
    print(f"Raw data before {day_text(cutoff_day)}: " + ", ".join(f"{v} {k}" for k, v in counts.items())
          + f"\nwould become {days} daily rows (auction house x item x day).")
    if not sum(counts.values()):
        return print("Nothing to trim.")
    if args.dry_run:
        return
    if not args.yes and input("Trim now? This deletes those raw rows. [y/N] ").strip().lower() != "y":
        return print("Cancelled.")
    added, combined = fold(con, cutoff, combine=True)
    for table in RAW_TABLES:
        con.execute(f"DELETE FROM {table} WHERE t < ?", (cutoff,))
    set_meta(con, "trimmed_before", max(cutoff, trimmed_before(con)))
    con.commit()
    con.execute("VACUUM")
    print(f"Done: {added} daily rows added, {combined} combined with existing ones. "
          f"Imports now skip raw data from before {day_text(cutoff_day)}.")


# Merge ------------------------------------------------------------------------------------

def cmd_merge(con, args):
    other = Path(args.other)
    if not other.exists():
        raise SystemExit(f"{other} not found")
    con.execute("ATTACH DATABASE ? AS other", (str(other),))
    cutoff = trimmed_before(con)
    counts = {}
    for table in RAW_TABLES:
        if table not in tables_in(con, "other"):
            counts[table] = 0
            continue
        counts[table] = con.execute(
            f"SELECT COUNT(*) FROM other.{table} o WHERE o.t >= ? AND NOT EXISTS "
            f"(SELECT 1 FROM main.{table} m WHERE {' AND '.join(f'm.{c} = o.{c}' for c in key_columns(con, table))})",
            (cutoff,)).fetchone()[0]
    old_raw = raw_counts(con, cutoff, "other") if cutoff else {}
    new_daily = con.execute("SELECT COUNT(*) FROM other.daily o WHERE NOT EXISTS (SELECT 1 FROM main.daily m "
                            "WHERE m.ah = o.ah AND m.item_id = o.item_id AND m.day = o.day)").fetchone()[0]
    print(f"From {other}: " + ", ".join(f"{v} new {k}" for k, v in counts.items()) + f", {new_daily} new daily rows"
          + (f"; {sum(old_raw.values())} raw rows from before this database's cutoff "
             f"({day_text(cutoff // DAY)}) will be folded into daily rows" if old_raw and sum(old_raw.values()) else ""))
    if args.dry_run:
        return
    for table in RAW_TABLES:
        if table in tables_in(con, "other"):
            cols = ", ".join(c for c in columns(con, "main", table) if c in columns(con, "other", table))
            con.execute(f"INSERT OR IGNORE INTO main.{table} ({cols}) SELECT {cols} FROM other.{table} WHERE t >= ?",
                        (cutoff,))
    if cutoff:
        fold(con, cutoff, schema="other", combine=False)
    for table in ("daily", "items", "recipes", "recipe_reagents", "vendor_prices"):
        shared = [c for c in columns(con, "main", table) if c in columns(con, "other", table)]
        cols = ", ".join(shared)
        con.execute(f"INSERT OR IGNORE INTO main.{table} ({cols}) SELECT {cols} FROM other.{table}")
    con.execute("INSERT INTO imports (at, source, scans, polls, events, daily, skipped_old) VALUES (?, ?, ?, ?, ?, ?, 0)",
                (int(time.time()), f"merge {other}", counts["scans"], counts["watch_polls"], counts["watch_events"], new_daily))
    con.commit()
    print("Merged.")


def tables_in(con, schema):
    return {r[0] for r in con.execute(f"SELECT name FROM {schema}.sqlite_master WHERE type = 'table'")}


def key_columns(con, table):
    return [r[1] for r in con.execute(f"PRAGMA main.table_info({table})") if r[5]]


# Export -----------------------------------------------------------------------------------

EXPORTS = {
    "scans": "SELECT s.ah, datetime(s.t, 'unixepoch') AS time_utc, s.t, s.item_id, i.name, s.min_price, "
             "s.quantity, s.deep FROM scans s LEFT JOIN items i USING (item_id) ORDER BY s.ah, s.item_id, s.t",
    "ladder": "SELECT l.ah, datetime(l.t, 'unixepoch') AS time_utc, l.t, l.item_id, i.name, l.level, l.price, "
              "l.quantity FROM ladder l LEFT JOIN items i USING (item_id) ORDER BY l.ah, l.item_id, l.t, l.level",
    "daily": "SELECT d.*, i.name FROM daily d LEFT JOIN items i USING (item_id) ORDER BY d.ah, d.item_id, d.day",
    "watch_events": "SELECT e.ah, datetime(e.t, 'unixepoch') AS time_utc, e.t, e.item_id, i.name, e.kind, "
                    "e.quantity, e.low, e.high, e.levels, e.avg_price, e.seconds_since_prev "
                    "FROM watch_events e LEFT JOIN items i USING (item_id) ORDER BY e.ah, e.item_id, e.t",
    "watch_polls": "SELECT p.ah, datetime(p.t, 'unixepoch') AS time_utc, p.t, p.item_id, i.name, p.best, "
                   "p.depth10, p.total, p.levels_known, p.seconds_since_prev, p.book "
                   "FROM watch_polls p LEFT JOIN items i USING (item_id) ORDER BY p.ah, p.item_id, p.t",
    "items": "SELECT * FROM items ORDER BY item_id",
    "recipes": "SELECT r.*, i.name AS item_name FROM recipes r LEFT JOIN items i USING (item_id) "
               "ORDER BY r.profession, r.category, r.name",
    "recipe_reagents": "SELECT rr.spell_id, r.name AS recipe, rr.item_id, i.name AS reagent, rr.count "
                       "FROM recipe_reagents rr LEFT JOIN recipes r USING (spell_id) "
                       "LEFT JOIN items i ON i.item_id = rr.item_id ORDER BY rr.spell_id",
    "vendor_prices": "SELECT v.*, i.name FROM vendor_prices v LEFT JOIN items i USING (item_id) ORDER BY item_id",
}


def cmd_export(con, args):
    out = Path(args.folder)
    out.mkdir(parents=True, exist_ok=True)
    tables = args.tables.split(",") if args.tables else list(EXPORTS)
    for table in tables:
        if table not in EXPORTS:
            raise SystemExit(f"unknown table {table!r}; choose from {', '.join(EXPORTS)}")
        cur = con.execute(EXPORTS[table])
        with open(out / f"{table}.csv", "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow([c[0] for c in cur.description])
            rows = cur.fetchall()
            w.writerows(rows)
        print(f"{table}.csv: {len(rows)} rows")


# Info and report --------------------------------------------------------------------------

def cmd_info(con, args):
    path = Path(args.db)
    print(f"{path} ({path.stat().st_size / 1e6:.1f} MB), schema version {meta(con, 'schema_version')}")
    cutoff = trimmed_before(con)
    print(f"Trimmed before: {day_text(cutoff // DAY)}" if cutoff else "Never trimmed")
    for table in RAW_TABLES:
        n, lo, hi = con.execute(f"SELECT COUNT(*), MIN(t), MAX(t) FROM {table}").fetchone()
        print(f"  {table:13} {n:9}" + (f"   {iso(lo)[:10]} .. {iso(hi)[:10]}" if n else ""))
    n, lo, hi = con.execute("SELECT COUNT(*), MIN(day), MAX(day) FROM daily").fetchone()
    print(f"  {'daily':13} {n:9}" + (f"   {lo} .. {hi}" if n else ""))
    for table in ("items", "recipes", "vendor_prices"):
        print(f"  {table:13} {con.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0]:9}")
    print("Auction houses:")
    for ah, n in con.execute("SELECT ah, COUNT(*) FROM (SELECT ah FROM scans UNION ALL SELECT ah FROM daily) GROUP BY ah"):
        print(f"  {ah}: {n} scan/daily rows")
    mapped = con.execute("SELECT house_id, ah, last_modified FROM api_houses WHERE ah IS NOT NULL").fetchall()
    if mapped:
        print("Blizzard API houses:")
        for house_id, ah, last in mapped:
            print(f"  house {house_id} = {ah}, latest snapshot {iso(last) if last else 'none yet'}")
    print("Last imports:")
    for at, source, s, p, e, d in con.execute(
            "SELECT at, source, scans, polls, events, daily FROM imports ORDER BY id DESC LIMIT 5"):
        print(f"  {iso(at)}  {s} scans, {p} polls, {e} events, {d} daily  <- {source}")


def name_of(con, item):
    row = con.execute("SELECT name FROM items WHERE item_id = ?", (item,)).fetchone()
    return row[0] if row and row[0] else f"item {item}"


def pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(q * len(values)))]


def cmd_report(con, args):
    since = int(time.time()) - args.days * DAY
    since_day = day_text(since // DAY)
    ahs = [r[0] for r in con.execute("SELECT DISTINCT ah FROM scans UNION SELECT DISTINCT ah FROM watch_polls "
                                     "UNION SELECT DISTINCT ah FROM api_activity")]
    for ah in ahs:
        print(f"\n=== {ah} ===\nCheapest now vs {args.days}-day median of the lowest price:")
        rows = []
        for (item,) in con.execute("SELECT DISTINCT item_id FROM scans WHERE ah = ?", (ah,)):
            latest = con.execute("SELECT min_price, quantity, t FROM scans WHERE ah = ? AND item_id = ? AND min_price > 0 "
                                 "ORDER BY t DESC LIMIT 1", (ah, item)).fetchone()
            mins = [r[0] for r in con.execute("SELECT min_price FROM scans WHERE ah = ? AND item_id = ? AND t >= ? "
                                              "AND min_price > 0", (ah, item, since))]
            mins += [r[0] for r in con.execute("SELECT min_median FROM daily WHERE ah = ? AND item_id = ? AND day >= ? "
                                               "AND min_median > 0", (ah, item, since_day))]
            if latest and len(mins) >= 3:
                rows.append((latest[0] / statistics.median(mins), item, latest, statistics.median(mins)))
        for ratio, item, latest, median in sorted(rows)[:10]:
            print(f"  {name_of(con, item):<28} {gold(latest[0]):>10.4f}g  median {gold(median):>10.4f}g  {ratio:5.0%}"
                  f"  ({latest[1]} listed)")
        if not rows:
            print("  not enough data (items need 3+ scans with listings)")

        sold = api_sold_per_day(con, ah, since)
        if sold:
            print(f"\nBlizzard API, estimated units bought per day (last {args.days} days, from hourly snapshots):")
            for item, per_day in sorted(sold.items(), key=lambda kv: -kv[1])[:15]:
                print(f"  {name_of(con, item):<28} {per_day:>10.0f}")

        watched = list(con.execute("SELECT item_id, SUM(seconds_since_prev) FROM watch_polls WHERE ah = ? AND t >= ? "
                                   "GROUP BY item_id", (ah, since)))
        daily_watch = {i: s for i, s in con.execute("SELECT item_id, SUM(watch_seconds) FROM daily WHERE ah = ? "
                                                     "AND day >= ? GROUP BY item_id", (ah, since_day))}
        if not watched and not any(daily_watch.values()):
            continue
        print(f"\nWatch mode, last {args.days} days:")
        for item, seconds in sorted(watched, key=lambda r: name_of(con, r[0])):
            seconds = (seconds or 0) + (daily_watch.get(item) or 0)
            hours = seconds / 3600
            if hours < 0.05:
                continue
            buys = list(con.execute("SELECT quantity, levels, low, avg_price FROM watch_events WHERE ah = ? AND item_id = ? "
                                    "AND t >= ? AND kind = 'buy'", (ah, item, since)))
            d_buys, d_units = con.execute("SELECT COALESCE(SUM(buys), 0), COALESCE(SUM(bought_units), 0) FROM daily "
                                          "WHERE ah = ? AND item_id = ? AND day >= ?", (ah, item, since_day)).fetchone()
            sizes = [b[0] for b in buys]
            units = sum(sizes) + d_units
            print(f"  {name_of(con, item)}: {hours:.1f}h watched, {len(sizes) + d_buys} purchases, "
                  f"{units} units ({units / hours:.0f}/hour)")
            if sizes:
                walked = [b[1] for b in buys]
                slip = [b[3] / b[2] - 1 for b in buys if b[2]]
                print(f"    purchase size median {statistics.median(sizes):.0f}, 90th pct {pct(sizes, 0.9)}, "
                      f"largest {max(sizes)}; levels walked median {statistics.median(walked):.0f}, max {max(walked)}; "
                      f"slippage mean {statistics.mean(slip):.1%}")
            book = con.execute("SELECT book, total FROM watch_polls WHERE ah = ? AND item_id = ? ORDER BY t DESC LIMIT 1",
                               (ah, item)).fetchone()
            if book and book[0]:
                levels = [tuple(map(int, tok.split(":")[:2])) for tok in book[0].split("/") if tok]
                curve, got, cost = [], 0, 0
                targets = [n for n in (10, 50, 100, 250, 500, 1000)]
                for price, qty in levels:
                    while targets and got + qty >= targets[0]:
                        n = targets.pop(0)
                        curve.append(f"{n}: avg {gold((cost + (n - got) * price) / n):.4f}g")
                    got, cost = got + qty, cost + qty * price
                print(f"    buying now ({book[1]} listed): " + ("; ".join(curve) or "book too thin"))


# Blizzard API -----------------------------------------------------------------------------

LADDER_LEVELS = 15
MAX_SNAPSHOT_GAP = 3 * 3600  # snapshots further apart are not compared
MIN_API_SECONDS = 3 * 3600   # sold-per-day estimates need at least this much compared time


def api_config_path(args):
    return Path(args.db).parent / "blizzard_api.json"


def api_client(args):
    import blizzard
    try:
        return blizzard.Client.from_config(api_config_path(args))
    except blizzard.ApiError as e:
        raise SystemExit(str(e))


def cmd_api_setup(con, args):
    import getpass
    import json
    import blizzard
    path = api_config_path(args)
    print("Create an API client at https://develop.battle.net/access/clients (any name, any redirect URL),\n"
          f"then enter its Client ID and Client Secret. They are saved in plain text to {path}")
    client_id = input("Client ID: ").strip()
    secret = getpass.getpass("Client Secret (not shown while typing): ").strip()
    region = (input("Region eu/us/kr/tw [eu]: ").strip() or "eu").lower()
    client = blizzard.Client(client_id, secret, region)
    try:
        houses = client.houses()
    except blizzard.ApiError as e:
        raise SystemExit(f"Not saved: {e}")
    path.write_text(json.dumps({"client_id": client_id, "client_secret": secret, "region": region}, indent=2),
                    encoding="utf-8")
    store_houses(con, region, houses)
    print(f"Saved. The API lists {len(houses)} auction houses. Next: python profscan_db.py api-houses --match")


def store_houses(con, region, houses):
    for h in houses:
        con.execute("INSERT INTO api_houses (region, house_id, name) VALUES (?, ?, ?) "
                    "ON CONFLICT (region, house_id) DO UPDATE SET name = excluded.name", (region, h["id"], h["name"]))
    con.commit()


def profession_items(con):
    """Items worth keeping from a snapshot: every reagent and product of a known recipe, plus scanned items."""
    ids = {r[0] for r in con.execute("SELECT item_id FROM recipe_reagents")}
    ids |= {r[0] for r in con.execute("SELECT item_id FROM recipes WHERE item_id > 0")}
    ids |= {r[0] for r in con.execute("SELECT item_id FROM items")}
    return ids


def faction_fits(house_name, ah):
    for word in ("Alliance", "Horde"):
        if word in house_name:
            return ah.endswith("-" + word)
    # Blackwater (neutral) houses: ProfScan stores goblin auction house scans as "Realm-Neutral"
    # (older ones are under the scanning character's faction), so any key may fit
    return True


def cmd_api_houses(con, args):
    import math
    client = api_client(args)
    store_houses(con, client.region, client.houses())
    rows = con.execute("SELECT house_id, name, ah, last_modified FROM api_houses WHERE region = ? ORDER BY house_id",
                       (client.region,)).fetchall()
    if not args.match:
        print(f"{'house':>6}  {'name':28} {'your auction house':40} last snapshot")
        for house_id, name, ah, last in rows:
            print(f"{house_id:>6}  {name:28} {ah or '-':40} {iso(last) if last else '-'}")
        if not any(r[2] for r in rows):
            print("\nNone mapped yet: api-houses --match --apply, or api-map HOUSE_ID \"Realm-Faction\".")
        return

    game = defaultdict(dict)  # your latest in-game price per auction house and item
    for ah, item, price in con.execute(
            "SELECT ah, item_id, min_price FROM scans s WHERE source IS NULL AND min_price > 0 AND t = "
            "(SELECT MAX(t) FROM scans s2 WHERE s2.ah = s.ah AND s2.item_id = s.item_id "
            " AND s2.source IS NULL AND s2.min_price > 0)"):
        game[ah][item] = price
    if not game:
        raise SystemExit("Matching needs in-game scans in the database: scan in game, /reload, then run import.")
    print(f"Downloading all {len(rows)} houses once to compare their prices with your scans of "
          f"{', '.join(game)}...\n")
    best_for = {}
    for house_id, name, ah, _ in rows:
        listings, _ = client.listings(house_id)
        mins = {}
        for a in listings or []:
            if a["item"] not in mins or a["unit_price"] < mins[a["item"]]:
                mins[a["item"]] = a["unit_price"]
        scores = []
        for gah, prices in game.items():
            if faction_fits(name, gah):
                diffs = [abs(math.log(mins[i] / p)) for i, p in prices.items() if i in mins and mins[i] > 0]
                if len(diffs) >= 5:
                    scores.append((statistics.median(diffs), len(diffs), gah))
        scores.sort()
        verdict = "no comparable items"
        if scores:
            score, shared, gah = scores[0]
            clear = score < 0.10 and (len(scores) == 1 or scores[1][0] >= 1.5 * score)
            verdict = (f"{'matches' if clear else 'closest to'} {gah}: typical price difference "
                       f"{math.exp(score) - 1:.1%} over {shared} items")
            if clear and (gah not in best_for or score < best_for[gah][0]):
                best_for[gah] = (score, house_id)
        print(f"  house {house_id:>4} {name:28} {len(listings or []):>6} listings  {verdict}")
    if args.apply:
        for gah, (score, house_id) in best_for.items():
            con.execute("UPDATE api_houses SET ah = ? WHERE region = ? AND house_id = ?", (gah, client.region, house_id))
            print(f"Mapped house {house_id} -> {gah}")
        con.commit()
        if not best_for:
            print("No clear match to apply; use api-map HOUSE_ID \"Realm-Faction\" to set it by hand.")
    elif best_for:
        print("\nRun again with --apply to save the clear matches.")


def cmd_api_map(con, args):
    import blizzard
    region = blizzard.Client.from_config(api_config_path(args)).region if api_config_path(args).exists() else "eu"
    ah = None if args.ah in ("-", "none", "") else args.ah
    cur = con.execute("UPDATE api_houses SET ah = ? WHERE region = ? AND house_id = ?", (ah, region, args.house))
    if not cur.rowcount:
        raise SystemExit(f"House {args.house} is not known; run api-houses first.")
    con.commit()
    print(f"House {args.house} -> {ah or '(not mapped)'}")


def store_snapshot(con, region, house_id, ah, t, prev_t, listings, wanted):
    books = defaultdict(list)
    for a in listings:
        if wanted is None or a["item"] in wanted:
            books[a["item"]].append(a)
    scans, ladders = [], []
    for item, rows in books.items():
        rows.sort(key=lambda a: a["unit_price"])
        levels = []
        for a in rows:
            if levels and levels[-1][0] == a["unit_price"]:
                levels[-1][1] += a["quantity"]
            elif len(levels) < LADDER_LEVELS:
                levels.append([a["unit_price"], a["quantity"]])
        scans.append((ah, t, item, rows[0]["unit_price"], sum(a["quantity"] for a in rows), 1, "api"))
        ladders += [(ah, t, item, i, p, q) for i, (p, q) in enumerate(levels, 1)]
    con.executemany(f"INSERT OR IGNORE INTO scans ({SCAN_COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?)", scans)
    con.executemany("INSERT OR IGNORE INTO ladder VALUES (?, ?, ?, ?, ?, ?)", ladders)

    # compare with the previous snapshot's listings
    prev = defaultdict(list)
    for aid, item, qty, price, tl in con.execute(
            "SELECT auction_id, item_id, quantity, unit_price, time_left FROM api_listings "
            "WHERE region = ? AND house_id = ?", (region, house_id)):
        prev[item].append((aid, qty, price, tl))
    cur = {a["id"]: a for rows in books.values() for a in rows}
    prev_ids = {aid for rows in prev.values() for aid, *_ in rows}
    sold = 0
    if prev and prev_t and 0 < t - prev_t <= MAX_SNAPSHOT_GAP:
        activity = []
        for item in set(prev) | set(books):
            plist = prev.get(item, [])
            stayed = [price for aid, qty, price, tl in plist if aid in cur]
            cheapest_stayed = min(stayed) if stayed else None
            partial = cheap = dear = expiring = 0
            for aid, qty, price, tl in plist:
                now = cur.get(aid)
                if now:
                    partial += max(0, qty - now["quantity"])  # sellers can't shrink a listing: bought
                elif tl == "SHORT":
                    expiring += qty
                elif cheapest_stayed is None or price <= cheapest_stayed:
                    cheap += qty
                else:
                    dear += qty
            new = sum(a["quantity"] for a in books.get(item, []) if a["id"] not in prev_ids)
            activity.append((ah, t, item, t - prev_t, len(books.get(item, [])), partial, cheap, dear, expiring, new))
            sold += partial + cheap
        con.executemany("INSERT OR IGNORE INTO api_activity VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", activity)
    con.execute("DELETE FROM api_listings WHERE region = ? AND house_id = ?", (region, house_id))
    con.executemany("INSERT INTO api_listings VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [(region, house_id, a["id"], a["item"], a["quantity"], a["unit_price"], a.get("time_left"))
                     for a in cur.values()])
    con.execute("UPDATE api_houses SET last_modified = ? WHERE region = ? AND house_id = ?", (t, region, house_id))
    con.commit()
    return {"items": len(books), "listings": len(cur), "sold": sold, "compared": bool(prev) and prev_t is not None}


def cmd_api_fetch(con, args):
    client = api_client(args)
    wanted = None
    if not args.all_items:
        wanted = profession_items(con)
        if not wanted:
            print("No recipes or items in the database yet (run import first); keeping every item this time.")
            wanted = None
    try:
        while True:
            houses = con.execute("SELECT house_id, ah, last_modified FROM api_houses WHERE region = ? AND ah IS NOT NULL",
                                 (client.region,)).fetchall()
            if not houses:
                raise SystemExit("No API house is mapped yet: run api-houses --match --apply (or api-map).")
            for house_id, ah, last in houses:
                listings, modified = client.listings(house_id, if_modified_since=last)
                t = modified or int(time.time())
                if listings is None or (last and t <= last):
                    print(f"{iso(int(time.time()))}  {ah}: no new snapshot (latest {iso(last)})")
                    continue
                n = store_snapshot(con, client.region, house_id, ah, t, last, listings, wanted)
                print(f"{iso(int(time.time()))}  {ah}: snapshot of {iso(t)}, {n['items']} items, {n['listings']} listings"
                      + (f", about {n['sold']} units bought since the previous one" if n["compared"] else
                         " (first snapshot: purchases are counted from the next one)"))
            if not args.loop:
                break
            time.sleep(args.loop * 60)
    except KeyboardInterrupt:
        print("Stopped.")


def api_sold_per_day(con, ah, since):
    """{item: estimated units bought per day} from api_activity since `since`."""
    out = {}
    for item, sold, seconds in con.execute(
            "SELECT item_id, SUM(bought_partial + gone_cheap), SUM(seconds_since_prev) FROM api_activity "
            "WHERE ah = ? AND t >= ? GROUP BY item_id", (ah, since)):
        if seconds and seconds >= MIN_API_SECONDS:
            out[item] = sold / seconds * DAY
    return out


def cmd_addon_export(con, args):
    ah = args.ah
    if not ah:
        mapped = [r[0] for r in con.execute("SELECT DISTINCT ah FROM api_houses WHERE ah IS NOT NULL")]
        if len(mapped) != 1:
            raise SystemExit(f"Say which auction house with --ah (mapped: {', '.join(mapped) or 'none'}).")
        ah = mapped[0]
    now = int(time.time())
    hourly_from = (now - args.hours * 3600) // DAY * DAY  # from the start of that day
    daily_from_day = now // DAY - args.days

    hourly = defaultdict(list)
    for t, item, price, qty in con.execute(
            "SELECT t, item_id, min_price, quantity FROM scans WHERE ah = ? AND source = 'api' AND t >= ? "
            "ORDER BY item_id, t", (ah, hourly_from)):
        hourly[item].append(f"{t},{price},{qty}")

    daily = defaultdict(dict)  # item -> day -> line
    for day, item, scans, low, med, high, qty in con.execute(
            "SELECT day, item_id, scans, min_low, min_median, min_high, qty_avg FROM daily "
            "WHERE ah = ? AND day >= ?", (ah, day_text(daily_from_day))):
        daily[item][day_number(day)] = f"{day_number(day)},{scans},{low},{med},{high},{int(qty)}"
    raw = defaultdict(lambda: {"scans": 0, "mins": [], "qty": 0})
    for t, item, price, qty in con.execute(
            "SELECT t, item_id, min_price, quantity FROM scans WHERE ah = ? AND t >= ? AND t < ?",
            (ah, daily_from_day * DAY, hourly_from)):
        d = raw[(item, t // DAY)]
        d["scans"] += 1
        d["qty"] += qty
        if price > 0:
            d["mins"].append(price)
    for (item, day), d in raw.items():
        if day not in daily[item] and d["mins"]:
            m = sorted(d["mins"])
            daily[item][day] = f"{day},{d['scans']},{m[0]},{int(statistics.median(m))},{m[-1]},{d['qty'] // d['scans']}"
    sold = api_sold_per_day(con, ah, now - 7 * DAY)
    # newest price levels per item (deep scans, watch polls, API), so the addon can price buying in bulk
    ladders = {}
    for item, t in con.execute("SELECT item_id, MAX(t) FROM ladder WHERE ah = ? AND t >= ? GROUP BY item_id",
                               (ah, hourly_from)):
        levels = con.execute("SELECT price, quantity FROM ladder WHERE ah = ? AND item_id = ? AND t = ? ORDER BY level",
                             (ah, item, t)).fetchall()
        ladders[item] = f"{t};" + "/".join(f"{p}:{q}" for p, q in levels)

    def lua_str(v):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'

    out = [f"-- Generated by tools/profscan_db.py addon-export at {iso(now)} UTC; replaced on every export.",
           "-- Blizzard API prices for one auction house, shown by ProfScan next to its own scans.",
           "local _, ns = ...", "ns.IMPORTED = {", f"  generated = {now},", f"  ah = {lua_str(ah)},",
           "  -- [itemID] = \"time,lowestPrice,quantity;...\" (hourly snapshots)", "  scans = {"]
    out += [f"    [{item}] = \"{';'.join(lines)}\"," for item, lines in sorted(hourly.items())]
    out += ["  },", "  -- [itemID] = \"day,scans,low,median,high,avgQuantity;...\" (day = UTC days since 1970)", "  daily = {"]
    out += [f"    [{item}] = \"{';'.join(days[d] for d in sorted(days))}\"," for item, days in sorted(daily.items()) if days]
    out += ["  },", "  -- [itemID] = \"time;price:qty/price:qty/...\" newest cheapest price levels", "  ladders = {"]
    out += [f"    [{item}] = \"{text}\"," for item, text in sorted(ladders.items())]
    out += ["  },", "  -- [itemID] = estimated units bought per day over the last 7 days", "  sold = {"]
    out += [f"    [{item}] = {v:.1f}," for item, v in sorted(sold.items())]
    out += ["  },", "}", ""]
    path = Path(args.out) if args.out else ADDON_DIR / "ImportedPrices.lua"
    path.write_text("\n".join(out), encoding="utf-8")
    print(f"{path}: {ah}, {len(hourly)} items with hourly prices since {iso(hourly_from)[:10]}, "
          f"{sum(len(d) for d in daily.values())} daily summaries, {len(ladders)} price ladders, {len(sold)} sold estimates "
          f"({path.stat().st_size / 1e6:.1f} MB). /reload in game to load it.")


# CLI --------------------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--db", default=str(default_db()), help="database file (default: %(default)s)")
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("import", help="add new data from ProfScan.lua")
    s.add_argument("savedvariables", nargs="*", help="ProfScan.lua files (default: every account's in this game)")
    sub.add_parser("info", help="what the database holds")
    s = sub.add_parser("report", help="deals and watch-mode results")
    s.add_argument("--days", type=int, default=7)
    s = sub.add_parser("trim", help="fold old raw data into daily summaries")
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--older-than", type=int, metavar="DAYS")
    g.add_argument("--before", metavar="YYYY-MM-DD")
    s.add_argument("--dry-run", action="store_true", help="only show what would happen")
    s.add_argument("--yes", action="store_true", help="don't ask for confirmation")
    s = sub.add_parser("merge", help="add another ProfScan database")
    s.add_argument("other")
    s.add_argument("--dry-run", action="store_true")
    s = sub.add_parser("export", help="write CSV files")
    s.add_argument("folder")
    s.add_argument("--tables", help="comma-separated, default all: " + ",".join(EXPORTS))
    sub.add_parser("api-setup", help="save Blizzard API credentials")
    s = sub.add_parser("api-houses", help="list the API's auction houses and their mapping")
    s.add_argument("--match", action="store_true", help="compare every house's prices with your in-game scans")
    s.add_argument("--apply", action="store_true", help="with --match: save clear matches")
    s = sub.add_parser("api-map", help="say which of your auction houses an API house is")
    s.add_argument("house", type=int)
    s.add_argument("ah", help='ProfScan\'s name for it, e.g. "MyRealm-Horde"; "-" to clear')
    s = sub.add_parser("api-fetch", help="download the mapped houses' latest snapshots")
    s.add_argument("--loop", type=float, metavar="MINUTES", help="keep fetching every N minutes (Ctrl+C stops)")
    s.add_argument("--all-items", action="store_true", help="keep every item, not only profession-related ones")
    s = sub.add_parser("addon-export", help="write API prices into the addon (ImportedPrices.lua)")
    s.add_argument("--ah", help="which auction house (default: the one mapped house)")
    s.add_argument("--hours", type=int, default=24, help="hourly detail for this many hours (default 24)")
    s.add_argument("--days", type=int, default=30, help="daily summaries for this many days (default 30)")
    s.add_argument("--out", help="output file (default: ImportedPrices.lua in the addon folder)")
    args = p.parse_args()

    con = connect(args.db)
    try:
        {"import": cmd_import, "info": cmd_info, "report": cmd_report, "trim": cmd_trim,
         "merge": cmd_merge, "export": cmd_export, "api-setup": cmd_api_setup, "api-houses": cmd_api_houses,
         "api-map": cmd_api_map, "api-fetch": cmd_api_fetch, "addon-export": cmd_addon_export,
         }[args.command](con, args)
    finally:
        con.close()


if __name__ == "__main__":
    sys.exit(main())

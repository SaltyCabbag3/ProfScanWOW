local _, ns = ...

--[[
  Disenchanting as "recipes": one per band of the game's disenchant table
  (quality x armor/weapon x item level range, ns.DE_BANDS in DisenchantData.lua).

  What a band gives (DE_YIELDS below) is decided by the server, so it isn't in
  the game files. The numbers are Classic's published tables
  (warcraft.wiki.gg "Disenchanting tables", by item level), which Forever
  appears to keep. The 61-99 band is Classic's 61-65 row; Forever's gear above
  item level 65 is assumed to give the same (marked "~").

  Inputs come from the Disenchant scan (Scanner.lua): it browses the auction
  house for uncommon, rare and epic weapons and armor and keeps, per item, the
  lowest price, quantity and item level in ns.db.deScan[auction house]
  (replaced by each scan). Gear the game flags as impossible to disenchant
  (ns.DE_BLOCKED) is left out.

  Value of a disenchant = sum over the materials of chance x average count x
  what one sells for (AH price after the cut, or a vendor, whichever pays more).
]]

local M = { -- materials
  strange = 10940, soul = 11083, vision = 11137, dream = 11176, illusion = 16204,
  lme = 10938, gme = 10939, lae = 10998, gae = 11082, lmye = 11134, gmye = 11135,
  lne = 11174, gne = 11175, lee = 16202, gee = 16203,
  sgs = 10978, lgs = 11084, sglow = 11138, lglow = 11139, srs = 11177, lrs = 11178,
  sbs = 14343, lbs = 14344, nexus = 20725,
}
ns.DE_MATERIALS = {}
for _, id in pairs(M) do ns.DE_MATERIALS[#ns.DE_MATERIALS + 1] = id end
table.sort(ns.DE_MATERIALS)

-- Uncommon: per band start, dust (id, min, max), essence, shard (or nil).
local GREEN = {
  [5] = { { M.strange, 1, 2 }, { M.lme, 1, 2 } },
  [16] = { { M.strange, 2, 3 }, { M.gme, 1, 2 }, M.sgs },
  [21] = { { M.strange, 4, 6 }, { M.lae, 1, 2 }, M.sgs },
  [26] = { { M.soul, 1, 2 }, { M.gae, 1, 2 }, M.lgs },
  [31] = { { M.soul, 2, 5 }, { M.lmye, 1, 2 }, M.sglow },
  [36] = { { M.vision, 1, 2 }, { M.gmye, 1, 2 }, M.lglow },
  [41] = { { M.vision, 2, 5 }, { M.lne, 1, 2 }, M.srs },
  [46] = { { M.dream, 1, 2 }, { M.gne, 1, 2 }, M.lrs },
  [51] = { { M.dream, 2, 5 }, { M.lee, 1, 2 }, M.sbs },
  [56] = { { M.illusion, 1, 2 }, { M.gee, 1, 2 }, M.lbs },
  [61] = { { M.illusion, 2, 5 }, { M.gee, 2, 3 }, M.lbs },
}
-- chances in % for dust / essence / shard
local function GreenChances(kind, min)
  if kind == "a" then
    if min == 5 then return 80, 20, 0 end
    if min == 21 then return 75, 15, 10 end
    return 75, 20, 5
  end
  if min == 5 then return 20, 80, 0 end
  if min == 21 then return 15, 75, 10 end
  if min >= 51 then return 22, 75, 3 end
  return 20, 75, 5
end
local RARE = { [5] = M.sgs, [16] = M.sgs, [21] = M.sgs, [26] = M.lgs, [31] = M.sglow, [36] = M.lglow,
               [41] = M.srs, [46] = M.lrs, [51] = M.sbs, [56] = M.lbs, [61] = M.lbs }
local EPIC = { [40] = { M.srs, 2, 4 }, [46] = { M.lrs, 2, 4 }, [51] = { M.sbs, 2, 4 },
               [56] = { M.nexus, 1, 1 }, [61] = { M.nexus, 1, 2 } }

-- { { item, chance (0..1), min, max }, ... } for a band.
local function Yields(band)
  local q, min = band.quality, band.min
  if q == 2 then
    local g = GREEN[min]
    if not g then return {} end
    local d, e, s = GreenChances(band.kind, min)
    local out = { { g[1][1], d / 100, g[1][2], g[1][3] }, { g[2][1], e / 100, g[2][2], g[2][3] } }
    if g[3] and s > 0 then out[3] = { g[3], s / 100, 1, 1 } end
    return out
  elseif q == 3 then
    local shard = RARE[min]
    if not shard then return {} end
    if min >= 56 then return { { shard, 0.995, 1, 1 }, { M.nexus, 0.005, 1, 1 } } end
    return { { shard, 1, 1, 1 } }
  elseif q == 4 then
    local e = EPIC[min]
    return e and { { e[1], 1, e[2], e[3] } } or {}
  end
  return {}
end

local QUALITY_NAMES = { [2] = "Uncommon", [3] = "Rare", [4] = "Epic" }
local QUALITY_COLORS = { [2] = "|cff1eff00", [3] = "|cff0070dd", [4] = "|cffa335ee" }

for _, band in ipairs(ns.DE_BANDS or {}) do
  band.yields = Yields(band)
  band.assumed = band.min >= 61 -- Classic's 61-65 row stretched to 99
  band.label = ("%s%s %s|r  %d-%d"):format(QUALITY_COLORS[band.quality], QUALITY_NAMES[band.quality],
    band.kind == "a" and "armor" or "weapons", band.min, band.max)
end

-- Which band an item disenchants by (nil when it can't be disenchanted).
local GetItemInfoInstant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
local NOT_GEAR = { [""] = true, INVTYPE_SHIRT = true, INVTYPE_TABARD = true, INVTYPE_BAG = true,
                   INVTYPE_AMMO = true, INVTYPE_QUIVER = true, INVTYPE_NON_EQUIP_IGNORE = true }
function ns:DisenchantBand(id, quality, ilvl)
  if ns.DE_BLOCKED and ns.DE_BLOCKED[id] then return nil end
  local _, _, _, equipLoc, _, classID = GetItemInfoInstant(id)
  local kind = classID == 2 and "w" or classID == 4 and "a" or nil
  if not kind or NOT_GEAR[equipLoc or ""] then return nil end
  if not ilvl or ilvl <= 0 then ilvl = select(4, ns.GetItemInfo(id)) end
  if not ilvl then return nil end
  for _, band in ipairs(ns.DE_BANDS) do
    if band.quality == quality and band.kind == kind and ilvl >= band.min and ilvl <= band.max then return band end
  end
end

-- Average value of one disenchant in a band: value, complete (every material priced),
-- lines describing each material (for tooltips).
function ns:DisenchantValue(band)
  local value, complete, lines = 0, #band.yields > 0, {}
  for _, y in ipairs(band.yields) do
    local item, chance, lo, hi = y[1], y[2], y[3], y[4]
    local avg = (lo + hi) / 2
    local unit = self:SellPrice(item)
    local name = select(2, ns.UI.ItemName(item))
    local count = lo == hi and tostring(lo) or (lo .. "-" .. hi)
    if unit then
      value = value + chance * avg * unit
      lines[#lines + 1] = ("%g%%  %s x %s  at %s = %s"):format(chance * 100, count, name, ns.Money(unit),
        ns.Money(math.floor(chance * avg * unit + 0.5)))
    else
      complete = false
      lines[#lines + 1] = ("%g%%  %s x %s  |cffff8080no price yet|r"):format(chance * 100, count, name)
    end
  end
  return math.floor(value + 0.5), complete, lines
end

-- DisenchantValue, cached until something changes (tooltips ask often).
local valueCache = { gen = -1 }
function ns:DisenchantBandValue(band)
  if valueCache.gen ~= self.changeGen or valueCache.ah ~= self.ahKey then
    wipe(valueCache)
    valueCache.gen, valueCache.ah = self.changeGen, self.ahKey
  end
  local v = valueCache[band]
  if not v then
    local value, complete = self:DisenchantValue(band)
    v = { value, complete }
    valueCache[band] = v
  end
  return v[1], v[2]
end

-- Tooltip line for an item: left text, right text (nil when the item isn't gear that disenchants).
local GetDetailedItemLevelInfo = C_Item and C_Item.GetDetailedItemLevelInfo or GetDetailedItemLevelInfo
function ns:DisenchantTooltip(id, link)
  if not (id and self.DE_BANDS) then return nil end
  local _, _, quality, ilvl = ns.GetItemInfo(link or id)
  if not quality or quality < 2 or quality > 4 then return nil end
  if link and GetDetailedItemLevelInfo then ilvl = GetDetailedItemLevelInfo(link) or ilvl end
  local _, _, _, _, _, classID = GetItemInfoInstant(id)
  if classID ~= 2 and classID ~= 4 then return nil end
  if self.DE_BLOCKED and self.DE_BLOCKED[id] then return "Disenchant", "|cffaaaaaacan't be disenchanted|r" end
  local band = self:DisenchantBand(id, quality, ilvl)
  if not band then return nil end
  local value, complete = self:DisenchantBandValue(band)
  if value <= 0 then return "Disenchant (avg)", "|cffaaaaaamaterials not priced yet|r" end
  return "Disenchant (avg)", (band.assumed and "~" or "") .. ns.Money(value) .. (complete and "" or " |cffff8080*|r")
end

-- The newest Disenchant scan on this auction house: { t =, items = { [id] = { m =, n =, l =, q = } } } or nil.
function ns:DisenchantSnapshot()
  return self.db.deScan[self.ahKey]
end

-- Per band: { band, value, complete, valueLines, items = { { id, price, qty, ilvl }, ... cheapest first } }.
-- Cached until something changes.
local cache = { gen = -1 }
function ns:DisenchantRows()
  if cache.gen == self.changeGen and cache.ah == self.ahKey then return cache.rows end
  local rows, byBand = {}, {}
  for _, band in ipairs(self.DE_BANDS or {}) do
    local value, complete, lines = self:DisenchantValue(band)
    local row = { band = band, value = value, complete = complete, valueLines = lines, items = {} }
    rows[#rows + 1], byBand[band] = row, row
  end
  local snap = self:DisenchantSnapshot()
  for id, it in pairs(snap and snap.items or {}) do
    local band = it.m and it.m > 0 and self:DisenchantBand(id, it.q, it.l)
    if band then
      local list = byBand[band].items
      list[#list + 1] = { id = id, price = it.m, qty = it.n or 1, ilvl = it.l }
    end
  end
  for _, row in ipairs(rows) do
    table.sort(row.items, function(a, b) return a.price < b.price end)
  end
  cache.gen, cache.ah, cache.rows = self.changeGen, self.ahKey, rows
  return rows
end

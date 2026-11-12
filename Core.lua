local ADDON, ns = ...

ns.items = {}     -- the scan list: flat, sorted, de-duplicated item IDs (see RebuildItems)
ns.watched = {}   -- [itemID] = true for items on the scan list

local GetItemInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
ns.GetItemInfo = GetItemInfo

function ns.Print(...)
  print("|cff33ff99ProfScan|r:", ...)
end

-- One event frame for the whole addon. Any file can handle an event by
-- defining ns:EVENT_NAME(...) and calling ns:RegisterEvent("EVENT_NAME").
local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...)
  ns[event](ns, ...)
end)

function ns:RegisterEvent(event)
  events:RegisterEvent(event)
end

local DEFAULTS = {
  trimDays = 30,    -- suggested age for the manual trim (Data tab); nothing is trimmed automatically
  ladderDepth = 15, -- cheapest price levels kept per item in a deep scan
  batchSize = 50,   -- item keys per batch search
  autoScan = false, -- run a quick scan every time the auction house opens
  focus = {},       -- item IDs followed by watch mode
  scanAdd = {},     -- [itemID] = true: added to the scan list in game
  scanRemove = {},  -- [itemID] = true: Items.lua entries removed in game
  watchInterval = 60,   -- seconds between polls of the same item
  watchLevels = 40,     -- cheapest price levels recorded per poll
  watchMaxMinutes = 60, -- a watch session stops by itself after this long
  crateMoneyPerFavor = 50, -- copper a crate turn-in pays per Merchant's Favor (beta reports: ~2.5s per 5 Favor)
  batchCrafts = "stack",   -- crafts priced at once: a number, or "stack" (one stack of the product)
  countTradeItems = true,  -- add the AH price of empty crates and sealed writs to trade company costs
  favorGoal = 1000,        -- Merchant's Favor you aim for: crates are priced for the crates it takes (0 = off)
  repGoal = 0,             -- reputation you aim for with writs: envelopes are priced for it (0 = off)
  -- what the scan list is built from (see RebuildItems)
  scanReagents = true,     -- every reagent of every recipe, plus gathered herbs and fish
  scanTrade = true,        -- trade company items: empty crates, sealed writs, crate fills, writ items
  scanProducts = false,    -- every crafted product (about 1,200 more items, mostly gear)
  -- which crafts ProfScan may suggest in crafting trees, routes and cheapest ways
  craftUse = {},           -- [profession] = false: never suggest crafting with it
  craftKnownOnly = false,  -- only suggest recipes one of your characters has learned
  -- locked recipes (RecipeLocks.lua): [key] = true leaves them out of lists and crafting trees;
  -- keys "cd", "station:<name>", "spec:<name>", "rep"
  lockOff = {},
  lockRepMine = false,     -- reputation recipes only where this character has the standing
  profitGoal = {},         -- [profession] = copper to earn: recipes are priced for the crafts it takes
}

-- Marks the window as needing a redraw (UI.lua checks this flag).
-- changeGen counts changes, so views can cache work until the data changes.
ns.changeGen = 0
function ns:NotifyChanged()
  self.dirty = true
  self.changeGen = self.changeGen + 1
end

function ns:ADDON_LOADED(name)
  if name ~= ADDON then return end
  ProfScanDB = ProfScanDB or {}
  local db = ProfScanDB
  -- see Stats.lua for the storage format
  db.log = db.log or {}
  db.watchLog = db.watchLog or {}
  db.watchEvents = db.watchEvents or {}
  db.coverage = db.coverage or {}
  db.daily = db.daily or {}
  db.vendor = db.vendor or {}     -- [itemID] = vendor buy price per unit, learned from merchant windows
  db.names = db.names or {}
  db.captured = db.captured or {} -- [profession] = { [recipeID] = recipe }, see Recipes.lua
  db.known = db.known or {}       -- [character] = { [recipeID] = true }
  db.skills = db.skills or {}     -- [character] = { [profession] = skill level }
  db.yieldSeen = nil -- yields learned from crafting (removed feature; its readings were unreliable)
  db.yieldOverride = db.yieldOverride or {} -- [recipeID] = { min, max } set by you
  db.batchOverride = db.batchOverride or {} -- [recipeID] = crafts per batch set by you
  db.crateBatch = db.crateBatch or {}       -- [crate name] = crates filled at once (default 1)
  db.settings = db.settings or {}
  for k, v in pairs(DEFAULTS) do
    if db.settings[k] == nil then db.settings[k] = v end
  end
  db.settings.keepDays = nil -- old automatic pruning setting, no longer used
  db.settings.craftOverhead = nil -- old time added between crafts, removed
  self.db = db
end

function ns:PLAYER_LOGIN()
  self:BuildRecipes() -- also builds the scan list, which comes from the recipes
  -- Ask the server for item names now so they are cached before the first scan.
  for _, id in ipairs(self.items) do GetItemInfo(id) end
  for _, id in ipairs(self.db.settings.focus) do GetItemInfo(id) end
  self.ahKey = self:CurrentAHKey()
  self:LoadData()
end

-- Asks for confirmation, then trims (see ns:Trim in Stats.lua).
StaticPopupDialogs["PROFSCAN_TRIM"] = {
  text = "ProfScan: fold all data older than %d days into daily summaries?\n\n"
    .. "The raw scans, watch polls and events of those days are removed. "
    .. "Import into the external database first if you want to keep them there.",
  button1 = YES,
  button2 = NO,
  OnAccept = function(_, days)
    local r = ns:Trim(days)
    ns.Print(("Trimmed: %d scan records, %d watch events, %d watch polls folded into %d daily summaries."):format(
      r.scans, r.events, r.polls, r.days))
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

function ns:ConfirmTrim(days)
  local r = self:Trim(days, true)
  if r.scans + r.events + r.polls + r.coverage == 0 then
    return self.Print(("Nothing older than %d days to trim."):format(days))
  end
  StaticPopup_Show("PROFSCAN_TRIM", days, nil, days)
end

-- Scan list --------------------------------------------------------------------------
-- Built from the data, so nothing a profession uses is missed, and it grows
-- when ProfScan reads new recipes from your profession windows:
--   settings.scanReagents  every reagent of every recipe, plus gathered herbs and fish
--   settings.scanTrade     trade company items (empty crates, sealed writs, crate fills, writ items)
--   settings.scanProducts  every crafted product (off by default: mostly gear)
-- plus Items.lua and what you added in game, minus what you removed.

function ns:RebuildItems()
  local s = self.db.settings
  wipe(self.items)
  wipe(self.watched)
  local function Add(id)
    if id and id > 0 and not self.watched[id] and not s.scanRemove[id] then
      self.watched[id] = true
      self.items[#self.items + 1] = id
    end
  end
  for _, ids in pairs(self.WATCH) do
    for _, id in ipairs(ids) do Add(id) end
  end
  for _, p in ipairs(self.professions or {}) do
    for _, c in ipairs(p.categories) do
      for _, r in ipairs(c.recipes) do
        if s.scanReagents ~= false then
          for _, reagent in ipairs(r.reagents) do Add(reagent[1]) end
          if r.gathered then Add(r.item) end
        end
        if s.scanProducts and not r.gathered then Add(r.item) end
      end
    end
  end
  local trade = self.TRADE
  if trade and s.scanTrade ~= false then
    for _, c in ipairs(trade.crates) do
      Add(c[1])
      for _, fill in ipairs(c[5]) do Add(fill[1]) end
    end
    for _, w in ipairs(trade.writs) do Add(w[3]) end
    for _, id in pairs(trade.sealedWrits) do Add(id) end
  end
  for id in pairs(s.scanAdd) do Add(id) end
  table.sort(self.items)
  self:NotifyChanged()
end

-- Turns one part of the scan list on or off ("reagents" | "trade" | "products").
local SCAN_PARTS = { reagents = "scanReagents", trade = "scanTrade", products = "scanProducts" }
function ns:SetScanPart(part, on)
  local key = SCAN_PARTS[part]
  if not key then return end
  self.db.settings[key] = on and true or false
  self:RebuildItems()
  self.Print(("Scan list: %s %s; %d items now."):format(part, on and "on" or "off", #self.items))
end

-- Adds item IDs to the scan list; returns how many were new.
function ns:AddToScanList(ids)
  local s, added = self.db.settings, 0
  for _, id in ipairs(ids) do
    if id and id > 0 and not self.watched[id] then
      s.scanRemove[id] = nil
      s.scanAdd[id] = true
      self.watched[id] = true -- so duplicates in `ids` count once
      GetItemInfo(id)
      added = added + 1
    end
  end
  if added > 0 then self:RebuildItems() end
  return added
end

function ns:RemoveFromScanList(id)
  local s = self.db.settings
  s.scanAdd[id] = nil
  s.scanRemove[id] = true
  self:RebuildItems()
  self.Print((self:ItemName(id) or id) .. " removed from the scan list.")
end

-- Which auction house the data belongs to. History is kept per key, so
-- prices from different realms or factions never mix.
function ns:CurrentAHKey()
  return GetRealmName() .. "-" .. (UnitFactionGroup("player") or "Neutral")
end

function ns:ItemName(id)
  local name = GetItemInfo(id)
  if name then self.db.names[id] = name end
  return name or self.db.names[id]
end

function ns:PrintWatchList(all)
  local missing = {}
  for _, id in ipairs(self.items) do
    local name = self:ItemName(id)
    if not name then missing[#missing + 1] = id end
    if all then print(("  %d  %s"):format(id, name or "|cffff5555(not loaded / unknown ID)|r")) end
  end
  self.Print(("%d items on the scan list."):format(#self.items))
  if #missing > 0 then
    self.Print("Not resolved yet (run again in a few seconds; still missing = wrong ID): " .. table.concat(missing, ", "))
  end
end

local HELP = {
  "/pscan - open or close the ProfScan window",
  "/pscan scan - quick scan: lowest price and quantity for every watched item",
  "/pscan deep - quick scan plus the cheapest price levels of each item (slower)",
  "/pscan stop - stop the running scan (what was scanned so far is kept)",
  "/pscan watch - start or stop watch mode (order book polling of the focus list)",
  "/pscan focus <item link or ID> - add an item to / remove it from the focus list",
  "/pscan focus clear - empty the focus (watch) list (asks first)",
  "/pscan yield <spell ID> <min> [max] - set how many items a recipe makes (no numbers: undo)",
  "/pscan recipeinfo <spell ID> - what the profession API reports for a recipe",
  "/pscan cratemoney <copper> - money a crate turn-in pays per Merchant's Favor (default 50)",
  "/pscan favorgoal <favor> - Merchant's Favor you aim for; crates are priced for it (0 = off, default 1000)",
  "/pscan repgoal <reputation> - reputation you aim for with writs; envelopes are priced for it (0 = off)",
  "/pscan batch stack|<crafts> - how many crafts recipes are priced for at once (default: one stack)",
  "/pscan scanlist reagents|trade|products on|off - what the scan list includes (default: reagents and trade on)",
  "/pscan interval <seconds> - how often watch mode polls each item",
  "/pscan auto - toggle a quick scan whenever you open the auction house",
  "/pscan deals [days] - items cheapest right now compared with their median",
  "/pscan stats <item link or ID> - price history of one item",
  "/pscan list [all] - check the scan list resolves to real items",
  "/pscan trim <days> - fold data older than <days> into daily summaries (asks first)",
}

SLASH_PROFSCAN1 = "/pscan"
SlashCmdList.PROFSCAN = function(msg)
  local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  local itemArg = tonumber(rest) or tonumber(rest:match("item:(%d+)"))
  if cmd == "" then
    ns:ToggleWindow()
  elseif cmd == "watch" then
    ns:ToggleWatch()
  elseif cmd == "scanlist" and rest:match("^(%a+) (o[nf]f?)$") then
    local part, onoff = rest:match("^(%a+) (o[nf]f?)$")
    ns:SetScanPart(part, onoff == "on")
  elseif cmd == "batch" and (rest == "stack" or tonumber(rest)) then
    ns.db.settings.batchCrafts = tonumber(rest) and math.max(1, math.floor(tonumber(rest))) or "stack"
    ns.Print("Recipes are now priced for " .. (rest == "stack" and "one stack of the product per batch"
      or (ns.db.settings.batchCrafts .. " crafts per batch")) .. " (unless set per recipe).")
    ns:NotifyChanged()
  elseif cmd == "repgoal" and tonumber(rest) then
    ns.db.settings.repGoal = math.max(0, math.floor(tonumber(rest)))
    ns.Print(ns.db.settings.repGoal > 0 and ("Reputation goal: %d. Sealed writs are priced for the envelopes it takes."):format(
      ns.db.settings.repGoal) or "Reputation goal off.")
    ns:NotifyChanged()
  elseif cmd == "favorgoal" and tonumber(rest) then
    ns.db.settings.favorGoal = math.max(0, math.floor(tonumber(rest)))
    ns.Print(ns.db.settings.favorGoal > 0 and ("Favor goal: %d. Crates are priced for the crates it takes."):format(
      ns.db.settings.favorGoal) or "Favor goal off: crates are priced one at a time.")
    ns:NotifyChanged()
  elseif cmd == "cratemoney" and tonumber(rest) then
    ns.db.settings.crateMoneyPerFavor = math.max(0, tonumber(rest))
    ns.Print(("Crate turn-ins now count as paying %dc per Merchant's Favor."):format(ns.db.settings.crateMoneyPerFavor))
    ns:NotifyChanged()
  elseif cmd == "recipeinfo" then
    ns:PrintRecipeInfo(tonumber(rest) or tonumber(rest:match("enchant:(%d+)")) or tonumber(rest:match("spell:(%d+)")))
  elseif cmd == "yield" then
    local spell, lo, hi = rest:match("^(%d+)%s*(%d*)%s*(%d*)$")
    spell, lo, hi = tonumber(spell), tonumber(lo), tonumber(hi)
    if not spell then
      ns.Print("Usage: /pscan yield <spell ID> <min> [max]   (no numbers: remove your setting)")
    else
      ns:SetYieldOverride(spell, lo, hi)
      ns.Print(lo and ("Recipe %d makes %d-%d per craft."):format(spell, lo, math.max(lo, hi or lo))
        or ("Recipe %d: your items-per-craft setting removed."):format(spell))
    end
  elseif cmd == "focus" and rest:lower() == "clear" then
    ns:ConfirmClearFocus()
  elseif cmd == "focus" and itemArg then
    ns:ToggleFocus(itemArg)
  elseif cmd == "interval" and tonumber(rest) then
    ns.db.settings.watchInterval = math.max(15, tonumber(rest))
    ns.Print(("Watch mode polls each item every %ds."):format(ns.db.settings.watchInterval))
  elseif cmd == "scan" then
    ns:StartScan(false)
  elseif cmd == "deep" then
    ns:StartScan(true)
  elseif cmd == "stop" then
    ns:StopScan("stopped")
  elseif cmd == "auto" then
    ns.db.settings.autoScan = not ns.db.settings.autoScan
    ns.Print("Auto scan " .. (ns.db.settings.autoScan and "on" or "off") .. ".")
  elseif cmd == "deals" then
    ns:PrintDeals(tonumber(rest) or 7)
  elseif cmd == "stats" then
    ns:PrintItemStats(itemArg)
  elseif cmd == "list" then
    ns:PrintWatchList(rest == "all")
  elseif cmd == "trim" and tonumber(rest) then
    ns:ConfirmTrim(math.max(1, math.floor(tonumber(rest))))
  else
    for _, line in ipairs(HELP) do print(line) end
  end
end

ns:RegisterEvent("ADDON_LOADED")
ns:RegisterEvent("PLAYER_LOGIN")

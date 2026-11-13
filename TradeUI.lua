local _, ns = ...

--[[
  Trade company pane (the "Trade company" entry on the Professions tab)

  WoW Forever's trade companies (TradeData.lua): Azeroth Commerce Authority
  for the Alliance, Durotar Supply and Logistics for the Horde.
    Crates  Waylaid Crates, filled with one of several bundles of goods and
            handed in for Merchant's Favor plus a little money. One row per way
            to fill a crate: what it costs (each item bought or crafted,
            whichever is cheaper), what the turn-in pays, and the net cost per
            Merchant's Favor; the cheapest way for each crate is green.
            The money is an estimate: settings.crateMoneyPerFavor copper per
            Favor (beta reports: about 2.5s for 5 Favor, 5s for 10 Favor;
            /pscan cratemoney to change it).
    Writs   Craftsman's Writs: daily crafting orders that give reputation.
            Cost of the requested item(s), cost per 100 reputation, and
            whether this character knows a recipe for it. The tooltip says
            where to deliver it, when known.
  Empty crates and sealed writs are items too, tradeable and sold on the
  auction house, so their price is part of the cost (the "Include crate/writ
  prices" box turns that off, e.g. if you loot your own). A sealed writ holds
  a random writ of its tier, so below the writs the expected cost of one
  envelope is worked out: its price plus the average cost of the items that
  tier's writs ask for.
  Favor goal (settings.favorGoal, default 1000): each crate is priced as if
  the whole goal were reached with it (1000 Favor / 20 per crate = 50 crates,
  so 50x the fill and 50 empty crates, walking up the price levels). Below the
  list, the cheapest plan mixes crate kinds: it adds one crate at a time,
  always the one whose next crate is cheapest per Favor at that point (price
  levels already used up count, crafting is used where cheaper, turn-in money
  is subtracted). Crafted fills are costed at today's crafting price, without
  the depth of their own reagents.
  Reputation goal (settings.repGoal, off by default): sealed writs are priced
  for the envelopes the goal takes (9000 reputation / 200 per Artisan writ =
  45 envelopes, walking up the price levels), and a cheapest plan mixes tiers:
  one envelope at a time, always the tier whose next envelope is cheapest per
  reputation (envelope at that depth + the tier's average item cost, since the
  writ inside is random).
  Worth (both lists): what an empty crate or a sealed writ is worth buying against
  the cheapest other crate / writ tier, green above its AH price (a good buy), red
  below it (overpriced); see ns:CrateValues and ns:WritValues.
  Click: crates open the crate view (every fill, its crafting tree and costs),
  writs the recipe view. Right-click: add the item to the scan list.
  Shift-click: link it.
]]

local ROWS = 15
local WRIT_ROWS = 14

-- Envelopes of a tier it takes to reach the reputation goal (nil when the goal is off).
function ns:EnvelopesForGoal(rep)
  local goal = self.db.settings.repGoal or 0
  if goal > 0 and rep then return math.max(1, math.ceil(goal / rep)) end
end
local PLAN_REFRESH = 10 -- seconds: the plan is recomputed at most this often (unless the goal changes)

-- Crates it takes to reach the Favor goal with crates worth `favor` each (nil when the goal is off).
function ns:CratesForGoal(favor)
  local goal = self.db.settings.favorGoal or 0
  if goal > 0 and favor then return math.max(1, math.ceil(goal / favor)) end
end
local TIER_NAMES = { J = "Journeyman", E = "Expert", A = "Artisan" }

-- AH price of an empty crate or a sealed writ, as counted in costs: price, state
-- ("ah" | "unknown" = not scanned yet, counted as 0 | "off" = setting turned off).
function ns:TradeItemPrice(id, qty)
  if not self.db.settings.countTradeItems then return 0, "off" end
  local price = id and id > 0 and self:BuyPrice(id, qty or 1)
  if price then return price, "ah" end
  return 0, "unknown"
end

-- What an empty crate or a sealed writ is worth buying, against the cheapest *other*
-- way to the same Merchant's Favor or reputation, for one at today's prices:
--   crate  cheapest other crate's net cost per Favor x this crate's Favor
--          - its cheapest fill + its turn-in money
--   writ   cheapest other tier's cost per reputation x this tier's reputation
--          - the average cost of the items this tier's writs ask for
-- Worth more than the AH price: a better deal than the other crates/tiers by the
-- difference; less: overpriced (better sold, if you have one). Only alternatives whose
-- own crate/envelope price is scanned count. Cached until the data changes.
local valueCache = {}

-- Cheapest of several values, skipping one index.
local function BestOther(list, skip)
  local best
  for i, v in pairs(list) do
    if i ~= skip and v and (not best or v.per < best.per) then best = v end
  end
  return best
end

-- [crate index] = { worth =, price =, fill =, pays =, other = { per =, name = } }
function ns:CrateValues()
  local key = self.changeGen .. ":" .. self.ahKey .. ":" .. self:BonusValue("performance")
  if valueCache.crates and valueCache.cratesKey == key then return valueCache.crates end
  local moneyPerFavor = self.db.settings.crateMoneyPerFavor or 0
  local info, out = {}, {}
  for i, c in ipairs(self.TRADE.crates) do
    if c[4] then
      local fill
      for _, f in ipairs(c[5]) do
        local unit = self:BestItemCost(f[1], f[2])
        if unit and (not fill or unit * f[2] < fill) then fill = unit * f[2] end
      end
      local price = c[1] > 0 and self:BuyPrice(c[1], 1) or nil
      local avg, pays = self:ExpectedFavor(c[4]), c[4] * moneyPerFavor
      info[i] = { fill = fill, price = price, avg = avg, pays = pays, name = c[2],
                  per = fill and price and (fill + price - pays) / avg }
    end
  end
  local priced = {}
  for i, v in pairs(info) do if v.per then priced[i] = v end end
  for i, v in pairs(info) do
    local other = BestOther(priced, i)
    if other and v.fill then
      out[i] = { worth = other.per * v.avg - v.fill + v.pays, price = v.price, fill = v.fill, pays = v.pays,
                 other = other }
    end
  end
  valueCache.crates, valueCache.cratesKey = out, key
  return out
end

-- [tier] = { worth =, price =, avgItem =, rep =, other = { per =, tier = } }
function ns:WritValues()
  local key = self.changeGen .. ":" .. self.ahKey
  if valueCache.writs and valueCache.writsKey == key then return valueCache.writs end
  local data, info, out = self.TRADE, {}, {}
  for _, tier in ipairs({ "J", "E", "A" }) do
    local total, priced = 0, 0
    for _, w in ipairs(data.writs) do
      if w[2] == tier then
        local unit = self:BestItemCost(w[3], w[5])
        if unit then total, priced = total + unit * w[5], priced + 1 end
      end
    end
    local rep, price = data.writRep[tier], self:BuyPrice(data.sealedWrits[tier], 1)
    local avgItem = priced > 0 and total / priced or nil
    info[tier] = { tier = tier, rep = rep, price = price, avgItem = avgItem,
                   per = avgItem and price and (price + avgItem) / rep }
  end
  local priced = {}
  for t, v in pairs(info) do if v.per then priced[t] = v end end
  for t, v in pairs(info) do
    local other = BestOther(priced, t)
    if other and v.avgItem then
      out[t] = { worth = other.per * v.rep - v.avgItem, price = v.price, avgItem = v.avgItem, rep = v.rep,
                 other = other }
    end
  end
  valueCache.writs, valueCache.writsKey = out, key
  return out
end

-- Cell: the worth, green when above the AH price (a good buy), red below it.
local function WorthCell(v)
  if not v then return "|cffaaaaaa?|r" end
  local text = v.worth > 0 and ns.Money(v.worth):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") or "0"
  if not v.price then return text end
  return (v.worth >= v.price and "|cff40ff40" or "|cffff6060") .. text .. "|r"
end

-- Tooltip line for a worth estimate.
local function WorthLine(v, what, otherText)
  if not v then return ("Worth: not known yet (scan this %s and the alternatives)"):format(what) end
  local verdict = not v.price and "its AH price isn't scanned yet"
    or v.worth >= v.price and ("|cff40ff40a good buy|r at %s: %s cheaper than the alternatives"):format(
      ns.Money(v.price), ns.Money(v.worth - v.price))
    or ("|cffff6060overpriced|r at %s by %s (sell yours rather than use it)"):format(ns.Money(v.price),
      ns.Money(v.price - v.worth))
  return ("Worth about %s against %s: %s"):format(v.worth > 0 and ns.Money(v.worth) or "nothing", otherText, verdict)
end
ns.UI.WorthCell, ns.UI.WorthLine = WorthCell, WorthLine

-- Where a buy price came from, for the "Via" column.
local function Via(node)
  if not node or not node.best then return "|cffff8080no price|r" end
  if node.best == "craft" then return "|cff40ff40craft|r" end
  return node.buyVia == "vendor" and "vendor" or "AH"
end

local function KnowsRecipeFor(item)
  for _, r in ipairs(ns.recipesByItem[item] or {}) do
    if ns:IsKnown(r.spell) then return true end
  end
  return false
end

function ns.UI.BuildTradePane(parent)
  local UI = ns.UI
  local data = ns.TRADE
  local state = { mode = "crates", prof = 0, craftableOnly = false,
                  sort = { crates = { "perFavor", false }, writs = { "per100", false } } }
  local shownItems = {}

  local frame = CreateFrame("Frame", nil, parent)
  frame:SetPoint("TOPLEFT", 134, 0)
  frame:SetPoint("BOTTOMRIGHT")
  frame:Hide()

  local refresh -- defined below
  local include = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  include:SetSize(22, 22)
  include:SetPoint("TOPRIGHT", -150, 3)
  include:SetScript("OnClick", function(self)
    ns.db.settings.countTradeItems = self:GetChecked() and true or false
    refresh()
  end)
  local includeLabel = UI.Text(frame, "GameFontNormalSmall")
  includeLabel:SetPoint("LEFT", include, "RIGHT", 2, 0)
  includeLabel:SetText("Include crate/writ prices")

  local company = UI.Text(frame)
  company:SetPoint("TOPLEFT", 2, -2)
  company:SetPoint("RIGHT", include, "LEFT", -8, 0)
  company:SetWordWrap(false)

  local cratesBtn = UI.Button(frame, "Crates", 80, function() state.mode = "crates"; refresh() end)
  cratesBtn:SetPoint("TOPLEFT", 0, -18)
  local writsBtn = UI.Button(frame, "Writs", 80, function() state.mode = "writs"; refresh() end)
  writsBtn:SetPoint("LEFT", cratesBtn, "RIGHT", 4, 0)

  -- Favor goal (crates mode)
  local goalLabel = UI.Text(frame, "GameFontNormalSmall")
  goalLabel:SetPoint("LEFT", writsBtn, "RIGHT", 14, 0)
  goalLabel:SetText("Favor goal")
  local goalBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  goalBox:SetSize(48, 18)
  goalBox:SetPoint("LEFT", goalLabel, "RIGHT", 8, 0)
  goalBox:SetAutoFocus(false)
  goalBox:SetNumeric(true)
  goalBox:SetMaxLetters(6)
  goalBox:SetScript("OnEscapePressed", goalBox.ClearFocus)
  local goalSet = UI.Button(frame, "Set", 44, function()
    ns.db.settings.favorGoal = tonumber(goalBox:GetText()) or 0
    goalBox:ClearFocus()
    ns:NotifyChanged()
    refresh()
  end)
  goalSet:SetPoint("LEFT", goalBox, "RIGHT", 4, 0)
  goalBox:SetScript("OnEnterPressed", function() goalSet:Click() end)
  goalSet:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Favor goal")
    GameTooltip:AddLine("Crates are priced for the number it takes to reach this much Merchant's Favor, "
      .. "and a cheapest mixed plan is worked out below the list. 0 turns it off.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  goalSet:SetScript("OnLeave", GameTooltip_Hide)
  local goalWidgets = { goalLabel, goalBox, goalSet }

  local professions = { "All professions" }
  local seenProf = {}
  for _, w in ipairs(data.writs) do
    if not seenProf[w[1]] then
      seenProf[w[1]] = true
      professions[#professions + 1] = w[1]
    end
  end
  local profBtn = UI.Button(frame, "All professions", 130, nil)
  profBtn:SetPoint("LEFT", writsBtn, "RIGHT", 12, 0)
  profBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  profBtn:SetScript("OnClick", function(_, button)
    state.prof = (state.prof + (button == "RightButton" and -1 or 1)) % #professions
    refresh()
  end)
  local craftable = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  craftable:SetSize(22, 22)
  craftable:SetPoint("LEFT", profBtn, "RIGHT", 8, 0)
  craftable:SetScript("OnClick", function(self)
    state.craftableOnly = self:GetChecked() and true or false
    refresh()
  end)
  local craftableLabel = UI.Text(frame, "GameFontNormalSmall")
  craftableLabel:SetPoint("LEFT", craftable, "RIGHT", 2, 0)
  craftableLabel:SetText("I can craft")

  local scanBtn = UI.Button(frame, "Scan these items", 120, function()
    ns:ReportScanAdd(shownItems)
  end)
  scanBtn:SetPoint("TOPRIGHT", 0, -18)

  -- Tables -----------------------------------------------------------------------------
  local crates = UI.CreateTable(frame, {
    { title = "Crate", width = 128, key = "name" },
    { title = "Filled with", width = 140, key = "fill" },
    { title = "Favor", width = 38, justify = "RIGHT", key = "favor" },
    { title = "Crate", width = 64, justify = "RIGHT", key = "crate" },
    { title = "Worth", width = 64, justify = "RIGHT", key = "worth" },
    { title = "Fill", width = 76, justify = "RIGHT", key = "cost" },
    { title = "Pays", width = 56, justify = "RIGHT", key = "pays" },
    { title = "Net/Favor", width = 76, justify = "RIGHT", key = "perFavor" },
    { title = "Need", width = 44, justify = "RIGHT", key = "need" },
  }, ROWS)
  -- cheapest mixed plan for the Favor goal
  local planText = UI.Text(frame)
  planText:SetPoint("TOPLEFT", crates, "BOTTOMLEFT", 2, -4)
  planText:SetPoint("RIGHT", frame, "RIGHT")
  planText:SetJustifyV("TOP")
  local writs = UI.CreateTable(frame, {
    { title = "Writ asks for", width = 170, key = "name" },
    { title = "Profession", width = 80, key = "prof" },
    { title = "Tier", width = 62, key = "tier" },
    { title = "Skill", width = 34, justify = "RIGHT", key = "skill" },
    { title = "Rep", width = 34, justify = "RIGHT", key = "rep" },
    { title = "Item", width = 72, justify = "RIGHT", key = "cost" },
    { title = "Envelope", width = 64, justify = "RIGHT", key = "sealed" },
    { title = "Worth", width = 64, justify = "RIGHT", key = "worth" },
    { title = "Per 100 rep", width = 70, justify = "RIGHT", key = "per100" },
    { title = "Craft", width = 36, key = "known" },
  }, WRIT_ROWS)
  -- expected cost of a sealed writ per tier (random writ inside)
  -- reputation goal (writs mode)
  local repLabel = UI.Text(frame, "GameFontNormalSmall")
  repLabel:SetPoint("TOPLEFT", writs, "BOTTOMLEFT", 2, -6)
  repLabel:SetText("Reputation goal")
  local repBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  repBox:SetSize(52, 18)
  repBox:SetPoint("LEFT", repLabel, "RIGHT", 8, 0)
  repBox:SetAutoFocus(false)
  repBox:SetNumeric(true)
  repBox:SetMaxLetters(6)
  repBox:SetScript("OnEscapePressed", repBox.ClearFocus)
  local repSet = UI.Button(frame, "Set", 44, function()
    ns.db.settings.repGoal = tonumber(repBox:GetText()) or 0
    repBox:ClearFocus()
    ns:NotifyChanged()
    refresh()
  end)
  repSet:SetPoint("LEFT", repBox, "RIGHT", 4, 0)
  repBox:SetScript("OnEnterPressed", function() repSet:Click() end)
  local repHint = UI.Text(frame, "GameFontDisableSmall")
  repHint:SetPoint("LEFT", repSet, "RIGHT", 8, 0)
  repHint:SetText("e.g. Neutral to Honored 9000, to Revered 21000, to Exalted 42000; 0 = off")
  local repWidgets = { repLabel, repBox, repSet, repHint }

  local tierSummary = UI.Text(frame)
  tierSummary:SetPoint("TOPLEFT", repLabel, "BOTTOMLEFT", 0, -8)
  tierSummary:SetPoint("RIGHT", frame, "RIGHT")
  tierSummary:SetJustifyV("TOP")
  for mode, list in pairs({ crates = crates, writs = writs }) do
    list:SetPoint("TOPLEFT", 0, -44)
    list.emptyText = "Nothing matches."
    list.onSort = function(key)
      local s = state.sort[mode]
      if s[1] == key then s[2] = not s[2] else s[1], s[2] = key, false end
      refresh()
    end
    list.onClick = function(row, button)
      if button == "RightButton" then
        ns:ReportScanAdd({ row.id })
      elseif IsModifiedClick("CHATLINK") then
        UI.InsertItemLink(row.id)
      elseif mode == "crates" then
        ns:OpenCrate(row.crateIndex)
      elseif mode == "writs" and ns.recipesByItem[row.id] then
        ns:OpenRecipe(ns.recipesByItem[row.id][1])
      else
        ns:OpenItem(row.id)
      end
    end
  end

  -- Rows ---------------------------------------------------------------------------------
  local function CrateRows()
    local rows = {}
    wipe(shownItems)
    local values = ns:CrateValues()
    for crateIndex, c in ipairs(data.crates) do
      local crateID, name, level, favor, fills = c[1], c[2], c[3], c[4], c[5]
      local avgFavor = ns:ExpectedFavor(favor) -- with Performance Bonus (Craft settings)
      local options, bestCost = {}, nil
      local need = ns:CratesForGoal(avgFavor) or 1 -- crates the Favor goal takes with this kind
      for _, fill in ipairs(fills) do
        local item, qty = fill[1], fill[2]
        shownItems[#shownItems + 1] = item
        local unit, _, node = ns:BestItemCost(item, qty * need) -- 50 crates of 40 cloth: priced as buying 2000
        local cost = unit and math.floor(unit * qty + 0.5)
        if cost and (not bestCost or cost < bestCost) then bestCost = cost end
        options[#options + 1] = { item = item, qty = qty, cost = cost, node = node }
      end
      local pays = favor and favor * (ns.db.settings.crateMoneyPerFavor or 0)
      local cratePrice, crateState = ns:TradeItemPrice(crateID, need)
      shownItems[#shownItems + 1] = crateID
      local value = values[crateIndex]
      local worthLine = favor and UI.WorthLine(value, "crate", value and ("the cheapest other crate (%s, %s per Favor)"):format(
        value.other.name, value.other.per > 0 and ns.Money(value.other.per) or "profit"))
      for _, o in ipairs(options) do
        local itemName = select(2, UI.ItemName(o.item))
        local best = o.cost and o.cost == bestCost
        local perFavor = favor and o.cost and (o.cost + cratePrice - pays) / avgFavor
        rows[#rows + 1] = {
          id = o.item,
          crateIndex = crateIndex,
          icon = UI.GetItemIcon(o.item),
          tooltipLines = {
            ("%s crate (level %d)%s"):format(name, level,
              favor and (": " .. favor .. " Merchant's Favor") or ": Favor not known yet (seen in beta only)"),
            favor and avgFavor > favor and ("Performance Bonus: about %.1f Favor per turn-in on average"):format(avgFavor) or nil,
            crateState == "ah" and ("The empty crate costs %s on the auction house"):format(ns.Money(cratePrice))
              or crateState == "unknown" and "The empty crate's price isn't scanned yet (counted as 0)"
              or "Crate price not counted (setting off)",
            pays and ("Turn-in also pays about %s (estimate; /pscan cratemoney to change)"):format(ns.Money(pays)) or nil,
            need > 1 and perFavor and ("Priced for %d crates (the Favor goal): about %s in total"):format(
              need, ns.Money(perFavor * avgFavor * need)) or nil,
            "Cheapest way to get the fill: " .. Via(o.node),
            worthLine,
          },
          sort = {
            name = name, fill = itemName, favor = favor or -1, cost = o.cost or 1e12, pays = pays or -1,
            crate = crateState == "ah" and cratePrice or -1,
            worth = value and value.price and value.worth - value.price or -1e12,
            perFavor = perFavor or 1e12, need = favor and need or -1,
          },
          cells = {
            name,
            (best and "|cff40ff40" or "") .. o.qty .. " " .. itemName .. (best and "|r" or ""),
            favor or "?",
            crateState == "ah" and ns.Money(cratePrice) or crateState == "unknown" and "|cffaaaaaa?|r" or "-",
            favor and UI.WorthCell(value) or "-",
            o.cost and ns.Money(o.cost) or "?",
            pays and ("~" .. ns.Money(pays)) or "?",
            not perFavor and "-" or (perFavor > 0 and ns.Money(perFavor) or "|cff40ff40profit|r")
              .. (crateState == "unknown" and " |cffaaaaaa+?|r" or ""),
            favor and need or "-",
          },
        }
      end
    end
    return rows
  end

  local function WritRows()
    local rows = {}
    wipe(shownItems)
    for _, id in pairs(data.sealedWrits) do shownItems[#shownItems + 1] = id end
    local onlyProf = state.prof > 0 and professions[state.prof + 1]
    local values = ns:WritValues()
    for _, w in ipairs(data.writs) do
      local prof, tier, item, skill, qty, deliver = w[1], w[2], w[3], w[4], w[5], w[6]
      local known = KnowsRecipeFor(item)
      if (not onlyProf or prof == onlyProf) and (not state.craftableOnly or known) then
        shownItems[#shownItems + 1] = item
        local unit, _, node = ns:BestItemCost(item, qty)
        local cost = unit and math.floor(unit * qty + 0.5)
        local rep = data.writRep[tier]
        local sealed, sealedState = ns:TradeItemPrice(data.sealedWrits[tier], ns:EnvelopesForGoal(rep))
        local per100 = cost and (cost + sealed) / rep * 100
        local itemName = select(2, UI.ItemName(item))
        local value = values[tier]
        rows[#rows + 1] = {
          id = item,
          icon = UI.GetItemIcon(item),
          tooltipLines = {
            ("Craftsman's Writ (%s, %d reputation)"):format(TIER_NAMES[tier], rep),
            deliver ~= "" and ("Deliver to: " .. deliver) or "Delivery place not known yet",
            "Cheapest way: " .. Via(node),
            sealedState == "ah" and ("A Sealed %s's Writ costs %s on the auction house (it holds a random %s writ)"):format(
              TIER_NAMES[tier], ns.Money(sealed), TIER_NAMES[tier])
              or sealedState == "unknown" and "Sealed writ price not scanned yet (counted as 0)" or nil,
            ("Sealed %s's Writ: "):format(TIER_NAMES[tier]) .. UI.WorthLine(value, "envelope", value and
              ("the cheapest other tier (%s, %s per 100 rep)"):format(TIER_NAMES[value.other.tier], ns.Money(value.other.per * 100))),
          },
          sort = {
            name = itemName, prof = prof, tier = ({ J = 1, E = 2, A = 3 })[tier], skill = skill, rep = rep,
            cost = cost or 1e12, per100 = per100 or 1e12, known = known and 0 or 1,
            sealed = sealedState == "ah" and sealed or -1,
            worth = value and value.price and value.worth - value.price or -1e12,
          },
          cells = {
            (qty > 1 and (qty .. " x ") or "") .. (UI.ItemName(item)),
            prof, TIER_NAMES[tier], skill, rep,
            cost and ns.Money(cost) or "?",
            sealedState == "ah" and ns.Money(sealed) or sealedState == "unknown" and "|cffaaaaaa?|r" or "-",
            UI.WorthCell(value),
            per100 and (ns.Money(per100) .. (sealedState == "unknown" and " |cffaaaaaa+?|r" or "")) or "-",
            known and "|cff40ff40yes|r" or "|cffaaaaaano|r",
          },
        }
      end
    end
    return rows
  end

  -- Cheapest way to reach the Favor goal, mixing crate kinds: add one crate at
  -- a time, always the one whose next crate is cheapest per Favor right now.
  local planCache = {}
  local function GoalPlan(goal)
    local s = ns.db.settings
    local moneyPerFavor = s.crateMoneyPerFavor or 0
    local countCrates = s.countTradeItems ~= false
    local curves, used, cratesUsed = {}, {}, {}
    local function Curve(id)
      if curves[id] == nil then curves[id] = ns:PriceCurve(id) or false end
      return curves[id] or nil
    end
    local function Marginal(id, have, more)
      local curve = Curve(id)
      if not curve then return nil end
      local before, after = ns.CurveCost(curve, have), ns.CurveCost(curve, have + more)
      return before and after and after - before
    end
    local opts = {}
    for _, c in ipairs(data.crates) do
      if c[4] then -- Favor known
        for _, fill in ipairs(c[5]) do
          local _, _, node = ns:BestItemCost(fill[1], fill[2])
          opts[#opts + 1] = { crate = c, item = fill[1], qty = fill[2], n = 0, crafted = 0,
                              craftUnit = node and node.craft and node.craft.complete and node.craftUnit or nil }
        end
      end
    end
    local favor, total = 0, 0
    for _ = 1, 5000 do
      if favor >= goal then break end
      local best, bestPer, bestBuys
      for _, o in ipairs(opts) do
        local buy = Marginal(o.item, used[o.item] or 0, o.qty)
        local craft = o.craftUnit and o.craftUnit * o.qty
        local fill = (buy and craft) and math.min(buy, craft) or buy or craft
        if fill then
          local crateCost = 0
          if countCrates then crateCost = Marginal(o.crate[1], cratesUsed[o.crate[1]] or 0, 1) or 0 end
          local per = (fill + crateCost - o.crate[4] * moneyPerFavor) / ns:ExpectedFavor(o.crate[4])
          if not bestPer or per < bestPer then best, bestPer, bestBuys = o, per, buy ~= nil and (not craft or buy <= craft) end
        end
      end
      if not best then break end
      best.n = best.n + 1
      if bestBuys then used[best.item] = (used[best.item] or 0) + best.qty else best.crafted = best.crafted + 1 end
      cratesUsed[best.crate[1]] = (cratesUsed[best.crate[1]] or 0) + 1
      local gained = ns:ExpectedFavor(best.crate[4])
      total, favor = total + bestPer * gained, favor + gained
    end
    local parts, crates = {}, 0
    table.sort(opts, function(a, b) return a.n > b.n end)
    for _, o in ipairs(opts) do
      if o.n > 0 then
        crates = crates + o.n
        parts[#parts + 1] = ("%dx %s (%d %s%s)"):format(o.n, o.crate[2], o.qty, select(2, UI.ItemName(o.item)),
          o.crafted > 0 and (", " .. (o.crafted == o.n and "crafted" or (o.crafted .. " crafted"))) or "")
      end
    end
    if favor < goal then
      return ("|cffffd100Plan for %d Favor:|r not enough priced crates; scan the crates and their fills."):format(goal)
    end
    return ("|cffffd100Cheapest plan for %d Favor|r (%d crates, %d Favor): %s\n= %s in total, %s per Favor"
      .. " (after turn-in money%s)"):format(goal, crates, favor, table.concat(parts, ", "),
      total > 0 and ns.Money(total) or ("|cff40ff40profit|r " .. ns.Money(-total)),
      total > 0 and ns.Money(total / favor) or "profit", countCrates and ", incl. empty crates" or "")
  end

  local function PlanText()
    local goal = ns.db.settings.favorGoal or 0
    if goal <= 0 then return "|cffaaaaaaSet a Favor goal to price crates in bulk and get a cheapest plan.|r" end
    local key = goal .. ":" .. ns:BonusValue("performance")
    if planCache.goal ~= key or not planCache.at or GetTime() - planCache.at > PLAN_REFRESH then
      planCache.goal, planCache.at, planCache.text = key, GetTime(), GoalPlan(goal)
    end
    return planCache.text
  end

  -- Expected cost of buying one sealed writ of each tier: envelope + average
  -- cost of the items that tier's writs ask for (all professions; the writ is random).
  local function TierSummary()
    local lines, tiers = {}, {}
    local values = ns:WritValues()
    for _, tier in ipairs({ "J", "E", "A" }) do
      local total, priced, count = 0, 0, 0
      for _, w in ipairs(data.writs) do
        if w[2] == tier then
          count = count + 1
          local unit = ns:BestItemCost(w[3], w[5])
          if unit then
            total, priced = total + unit * w[5], priced + 1
          end
        end
      end
      local rep = data.writRep[tier]
      local sealed, sealedState = ns:TradeItemPrice(data.sealedWrits[tier], ns:EnvelopesForGoal(rep))
      if priced > 0 then
        tiers[#tiers + 1] = { tier = tier, rep = rep, avgItem = total / priced }
        local expected = sealed + total / priced
        lines[#lines + 1] = ("|cffffd100Sealed %s's Writ|r %s + average item %s (%d of %d priced) = %s per writ, %s per 100 rep"):format(
          TIER_NAMES[tier], sealedState == "ah" and ns.Money(sealed) or "|cffaaaaaa?|r", ns.Money(total / priced),
          priced, count, ns.Money(expected), ns.Money(expected / rep * 100))
          .. (values[tier] and ("; worth %s vs the other tiers"):format(UI.WorthCell(values[tier])) or "")
      else
        lines[#lines + 1] = ("|cffffd100Sealed %s's Writ|r: no writ items priced yet (scan them)"):format(TIER_NAMES[tier])
      end
    end

    -- cheapest mix of tiers for the reputation goal
    local goal = ns.db.settings.repGoal or 0
    if goal > 0 and #tiers > 0 then
      local counting = ns.db.settings.countTradeItems ~= false
      for _, t in ipairs(tiers) do
        t.n = 0
        t.curve = counting and ns:PriceCurve(data.sealedWrits[t.tier]) or nil
      end
      local rep, total = 0, 0
      for _ = 1, 5000 do
        if rep >= goal then break end
        local best, bestPer
        for _, t in ipairs(tiers) do
          local envelope = 0
          if t.curve then
            local before, after = ns.CurveCost(t.curve, t.n), ns.CurveCost(t.curve, t.n + 1)
            envelope = before and after and after - before or 0
          end
          local per = (envelope + t.avgItem) / t.rep
          if not bestPer or per < bestPer then best, bestPer = t, per end
        end
        best.n = best.n + 1
        rep, total = rep + best.rep, total + bestPer * best.rep
      end
      local parts = {}
      for _, t in ipairs(tiers) do
        if t.n > 0 then parts[#parts + 1] = ("%dx %s"):format(t.n, TIER_NAMES[t.tier]) end
      end
      lines[#lines + 1] = ("|cffffd100Cheapest plan for %d reputation|r: %s envelopes = %s in total, %s per 100 rep%s"):format(
        goal, table.concat(parts, " + "), ns.Money(total), ns.Money(total / rep * 100),
        counting and "" or " (envelope prices not counted)")
      lines[#lines + 1] = "|cffaaaaaaEach writ can be turned in once a day; writs are random, so expect some days of turn-ins.|r"
    end
    return table.concat(lines, "\n")
  end

  refresh = function()
    include:SetChecked(ns.db.settings.countTradeItems ~= false)
    local faction = UnitFactionGroup("player")
    local c = data.companies[faction]
    company:SetText(c and ("|cffffd100%s|r  -  %s; crates to %s"):format(c.name, c.hub, c.crates)
      or "|cffaaaaaaTrade companies are for Alliance and Horde characters.|r")
    local isCrates = state.mode == "crates"
    crates:SetShown(isCrates)
    planText:SetShown(isCrates)
    for _, w in ipairs(goalWidgets) do w:SetShown(isCrates) end
    if isCrates then
      if not goalBox:HasFocus() then goalBox:SetText(ns.db.settings.favorGoal or 0) end
      planText:SetText(PlanText())
    end
    writs:SetShown(not isCrates)
    tierSummary:SetShown(not isCrates)
    for _, w in ipairs(repWidgets) do w:SetShown(not isCrates) end
    if not isCrates and not repBox:HasFocus() then repBox:SetText(ns.db.settings.repGoal or 0) end
    if not isCrates then tierSummary:SetText(TierSummary()) end
    profBtn:SetShown(not isCrates)
    craftable:SetShown(not isCrates)
    craftableLabel:SetShown(not isCrates)
    if isCrates then cratesBtn:LockHighlight() writsBtn:UnlockHighlight()
    else writsBtn:LockHighlight() cratesBtn:UnlockHighlight() end
    profBtn:SetText(professions[state.prof + 1])

    local list, rows = isCrates and crates or writs, isCrates and CrateRows() or WritRows()
    local s = state.sort[state.mode]
    UI.SortRows(rows, s[1], s[2])
    list:SetData(rows)
  end

  return { frame = frame, refresh = refresh }
end

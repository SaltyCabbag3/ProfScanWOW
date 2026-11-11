local _, ns = ...

--[[
  Professions tab: the recipe browser

  Left: "Trade company" (Forever's crates and writs, TradeUI.lua), then the
  professions (your skill level shows once you have opened that profession's
  window), and buttons that add the items of every recipe currently listed to
  the scan list or to watch mode.
  Right: recipes, filtered by category, name, and optionally to the ones this
  character knows. Per recipe: cost of buying the reagents (per craft), the
  margin per craft when selling on the auction house (price after the 5% cut)
  and when selling to a vendor, each = price x items made ("x2" after the
  name) minus cost, and how sellable the product is: average quantity listed over 7 days
  and units sold per day (watch mode, or "~" = Blizzard API estimate).
  "Max AH/h" and "Max vend/h": the best margin per hour of crafting over every
  route (each reagent bought or crafted), as in the recipe view's routes.
  Click a recipe: recipe view. Right-click: add its items to the scan list.
  Shift-click: link the product.

  Reagents without any price (never scanned, no vendor seen) make the cost a
  minimum, marked "+?", and leave the margin blank.
  Costs are per craft but priced for a batch (default one stack of the
  product; /pscan batch, or per recipe in the recipe view): buying a batch's
  worth takes the cheapest listings first and then pricier ones. A red "*"
  means some reagent ran out of known listings.
]]

local ROWS = 20
local MAX_PROFESSIONS = 12

local function SignedMoney(copper)
  if not copper then return "-" end
  if copper == 0 then return "0" end
  return (copper > 0 and "|cff40ff40+|r" or "|cffff6060-|r") .. ns.Money(math.abs(copper))
end
ns.SignedMoney = SignedMoney

-- "*" in red: some reagent has fewer listings than the batch needs at the known price levels.
local function CostText(recipe, e)
  if #recipe.reagents == 0 then return "-" end
  if e.missing == #recipe.reagents then return "?" end
  return ns.Money(e.cost) .. (e.missing > 0 and " |cffff8080+?|r" or "") .. (e.short and " |cffff6060*|r" or "")
end
ns.CostText = CostText

local function SellText(e)
  if not e.sell then return "-" end
  return ns.Money(e.sell) .. (e.sellVia == "vendor" and " |cffaaaaaav|r" or "")
end
ns.SellText = SellText

local function MarginPct(ratio)
  if not ratio then return "-" end
  local pct = math.floor(ratio * 100 + 0.5)
  return (pct >= 0 and "|cff40ff40" or "|cffff6060") .. pct .. "%|r"
end
ns.MarginPct = MarginPct

-- Margin per hour cell: "cd" for recipes on a cooldown, "?" when the cast time is unknown.
local function PerHourText(e, value)
  if e.timing and e.timing.cooldown then return "|cffaaaaaacd " .. ns.Duration(e.timing.cooldown) .. "|r" end
  if not e.timing then return "|cffaaaaaa?|r" end
  return SignedMoney(value and math.floor(value + 0.5))
end

local function RecipeKey(recipe)
  return recipe.spell > 0 and ("s" .. recipe.spell) or ("i" .. recipe.item)
end

-- Best margin per hour over every crafting route (buy or craft each reagent,
-- the same routes as the recipe view's "Best AH/vendor margin/hour").
-- Returns { ah = route, vendor = route } (route.perHour nil when it doesn't
-- apply), or nil for recipes without a craft of their own. Cached until data
-- or settings change (ns.changeGen), so sorting and filtering stay quick;
-- while a scan keeps changing data, routes are worked out at most every few
-- seconds (with a redraw once they are due).
local ROUTE_REFRESH = 3
local routeCache, routeGen, routeTime, redrawQueued = {}, -1, 0, false
local function BestPerHour(recipe, e)
  if recipe.gathered or recipe.item <= 0 or #recipe.reagents == 0 then return nil end
  if routeGen ~= ns.changeGen then
    local now = GetTime()
    if now - routeTime >= ROUTE_REFRESH then
      wipe(routeCache)
      routeGen, routeTime = ns.changeGen, now
    elseif not redrawQueued then
      redrawQueued = true
      C_Timer.After(ROUTE_REFRESH - (now - routeTime), function()
        redrawQueued = false
        ns.dirty = true
      end)
    end
  end
  local key = RecipeKey(recipe)
  local cached = routeCache[key]
  if cached == nil then
    cached = false
    local ok, routes = pcall(ns.CraftRoutes, ns, recipe, ns:CraftTree(recipe), e)
    if ok and routes then
      cached = {}
      for _, r in ipairs(routes) do
        if r.key == "ahHour" then cached.ah = r elseif r.key == "vendorHour" then cached.vendor = r end
      end
    end
    routeCache[key] = cached
  end
  return cached or nil
end

-- Cell for a best-per-hour route: "cd" for cooldowns, "?" when the cast time is
-- unknown, a grey "~" when some crafted reagent's cast time is unknown.
local function BestHourText(e, route)
  if e.timing and e.timing.cooldown then return "|cffaaaaaacd " .. ns.Duration(e.timing.cooldown) .. "|r" end
  if not e.timing then return "|cffaaaaaa?|r" end
  if not (route and route.perHour) then return "-" end
  return SignedMoney(math.floor(route.perHour + 0.5))
    .. (route.point and route.point.approx and "|cffaaaaaa~|r" or "")
end

local function ReagentIDs(recipes)
  local ids = {}
  for _, recipe in ipairs(recipes) do
    for _, reagent in ipairs(recipe.reagents) do ids[#ids + 1] = reagent[1] end
  end
  return ids
end

local function ProductIDs(recipes)
  local ids = {}
  for _, recipe in ipairs(recipes) do
    if recipe.item > 0 then ids[#ids + 1] = recipe.item end
  end
  return ids
end

-- Reagents and products of the given recipes.
local function RecipeItems(recipes)
  local ids = ReagentIDs(recipes)
  for _, id in ipairs(ProductIDs(recipes)) do ids[#ids + 1] = id end
  return ids
end
ns.RecipeItems = RecipeItems

function ns:ReportScanAdd(ids)
  local added = self:AddToScanList(ids)
  self.Print(("Added %d new items to the scan list (%d were already on it)."):format(added, #ids - added))
end

function ns:ReportWatchAdd(ids)
  local added = self:AddFocus(ids)
  local total = #self.db.settings.focus
  self.Print(("Watching %d more items, %d in total."):format(added, total))
  if total > 20 then
    self.Print(("With %d items each poll round takes a while; consider a longer interval than %ds."):format(
      total, self.db.settings.watchInterval))
  end
end

-- Craft settings panel ----------------------------------------------------------------------

local settingsPanel

local function BuildCraftSettings()
  local UI = ns.UI
  local panel = UI.Panel(nil, ProfScanFrame, 330, 0)
  panel:SetFrameStrata("DIALOG")
  panel:EnableMouse(true)
  panel:Hide()
  local title = UI.Text(panel, "GameFontNormal")
  title:SetPoint("TOPLEFT", 12, -12)
  title:SetText("Craft settings")
  local help = UI.Text(panel)
  help:SetPoint("TOPLEFT", 12, -30)
  help:SetWidth(306)
  help:SetText("Crafting trees, routes and cheapest ways only use these professions; "
    .. "anything else is bought instead.")
  local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  local checks = {}
  local function Refresh()
    local s = ns.db.settings
    for _, c in ipairs(checks) do c:SetChecked(s.craftUse[c.profession] ~= false) end
    panel.knownOnly:SetChecked(s.craftKnownOnly == true)
  end
  local function Changed()
    ns:NotifyChanged()
    Refresh()
  end

  local allBtn = UI.Button(panel, "All", 60, function()
    wipe(ns.db.settings.craftUse)
    Changed()
  end)
  allBtn:SetPoint("TOPLEFT", 12, -60)
  local mineBtn = UI.Button(panel, "My characters' professions", 190, function()
    local mine = ns:MyProfessions()
    for _, p in ipairs(ns.professions) do ns.db.settings.craftUse[p.name] = mine[p.name] and true or false end
    Changed()
  end)
  mineBtn:SetPoint("LEFT", allBtn, "RIGHT", 4, 0)
  mineBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("My characters' professions")
    GameTooltip:AddLine("Professions this character has, plus those of any character whose profession "
      .. "window ProfScan has seen. Log in on an alt and open its profession window to include it.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  mineBtn:SetScript("OnLeave", GameTooltip_Hide)

  for i, p in ipairs(ns.professions) do
    local box = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    box:SetSize(22, 22)
    box:SetPoint("TOPLEFT", 12 + ((i - 1) % 2) * 156, -88 - math.floor((i - 1) / 2) * 22)
    box.profession = p.name
    box:SetScript("OnClick", function(self)
      ns.db.settings.craftUse[self.profession] = self:GetChecked() and true or false
      Changed()
    end)
    local label = UI.Text(panel, "GameFontHighlightSmall")
    label:SetPoint("LEFT", box, "RIGHT", 2, 0)
    label:SetText(p.name)
    checks[#checks + 1] = box
  end
  local rows = math.ceil(#ns.professions / 2)
  local knownOnly = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  knownOnly:SetSize(22, 22)
  knownOnly:SetPoint("TOPLEFT", 12, -96 - rows * 22)
  knownOnly:SetScript("OnClick", function(self)
    ns.db.settings.craftKnownOnly = self:GetChecked() and true or false
    Changed()
  end)
  local knownLabel = UI.Text(panel, "GameFontHighlightSmall")
  knownLabel:SetPoint("LEFT", knownOnly, "RIGHT", 2, 0)
  knownLabel:SetWidth(280)
  knownLabel:SetText("Only recipes one of my characters has learned")
  panel.knownOnly = knownOnly
  panel:SetHeight(96 + rows * 22 + 34)
  panel.Refresh = Refresh
  return panel
end

function ns.UI.ToggleCraftSettings(anchor)
  if not settingsPanel then settingsPanel = BuildCraftSettings() end
  if settingsPanel:IsShown() then return settingsPanel:Hide() end
  settingsPanel:ClearAllPoints()
  settingsPanel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 0)
  settingsPanel.Refresh()
  settingsPanel:Show()
end

function ns.UI.BuildRecipesPage(page)
  local UI = ns.UI
  local state = { profName = nil, cat = 0, knownOnly = false, sortKey = "margin", sortDesc = true, perHour = false }
  local shown = {} -- recipes currently listed, for the bulk buttons

  -- Left column ------------------------------------------------------------------------
  local left = CreateFrame("Frame", nil, page)
  left:SetPoint("TOPLEFT")
  left:SetPoint("BOTTOMLEFT")
  left:SetWidth(126)

  local refresh -- defined below
  local TRADE = "__trade" -- state.profName when the trade company pane is shown
  local tradeButton = UI.Button(left, "|cffffd100Trade company|r", 126, function()
    state.profName = TRADE
    refresh()
  end)
  tradeButton:SetPoint("TOPLEFT", 0, 0)
  local profButtons = {}
  local settingsButton -- placed under the profession list, see below
  for i = 1, MAX_PROFESSIONS do
    local b = UI.Button(left, "", 126, function(self)
      state.profName, state.cat = self.profName, 0
      refresh()
    end)
    b:SetPoint("TOPLEFT", 0, -i * 22)
    b:Hide()
    profButtons[i] = b
  end

  settingsButton = UI.Button(left, "Craft settings...", 126, function(self) UI.ToggleCraftSettings(self) end)
  settingsButton:SetPoint("TOPLEFT", 0, -(MAX_PROFESSIONS + 1) * 22 - 6)
  settingsButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Craft settings")
    GameTooltip:AddLine("Which professions and recipes crafting trees, routes and cheapest ways may use. "
      .. "Left-out crafts are bought instead.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  settingsButton:SetScript("OnLeave", GameTooltip_Hide)

  local bulkLabel = UI.Text(left, "GameFontNormalSmall")
  bulkLabel:SetPoint("BOTTOMLEFT", 2, 76)
  bulkLabel:SetText("All listed recipes:")
  local watchRecipes = UI.Button(left, "Watch recipes", 126, function() ns:ReportWatchAdd(RecipeItems(shown)) end)
  watchRecipes:SetPoint("BOTTOMLEFT", 0, 0)
  local scanProducts = UI.Button(left, "Scan products", 126, function() ns:ReportScanAdd(ProductIDs(shown)) end)
  scanProducts:SetPoint("BOTTOMLEFT", 0, 24)
  local scanReagents = UI.Button(left, "Scan reagents", 126, function() ns:ReportScanAdd(ReagentIDs(shown)) end)
  scanReagents:SetPoint("BOTTOMLEFT", 0, 48)

  -- Right column: controls ---------------------------------------------------------------
  local right = CreateFrame("Frame", nil, page)
  right:SetPoint("TOPLEFT", 134, 0)
  right:SetPoint("BOTTOMRIGHT")
  local trade = UI.BuildTradePane(page) -- crates and writs (TradeUI.lua)

  local catButton = UI.Button(right, "All categories", 190, nil)
  catButton:SetPoint("TOPLEFT", 0, 0)
  catButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  catButton:SetScript("OnClick", function(_, button)
    local prof = state.prof
    if not prof then return end
    local n = #prof.categories + 1
    state.cat = (state.cat + (button == "RightButton" and -1 or 1)) % n
    refresh()
  end)
  catButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Category")
    GameTooltip:AddLine("Left-click: next, right-click: previous", 1, 1, 1)
    GameTooltip:Show()
  end)
  catButton:SetScript("OnLeave", GameTooltip_Hide)

  local filterLabel = UI.Text(right, "GameFontNormalSmall")
  filterLabel:SetPoint("LEFT", catButton, "RIGHT", 10, 0)
  filterLabel:SetText("Filter")
  local filter = CreateFrame("EditBox", nil, right, "InputBoxTemplate")
  filter:SetSize(140, 18)
  filter:SetPoint("LEFT", filterLabel, "RIGHT", 8, 0)
  filter:SetAutoFocus(false)
  filter:SetScript("OnTextChanged", function() refresh() end)
  filter:SetScript("OnEscapePressed", filter.ClearFocus)

  local known = CreateFrame("CheckButton", nil, right, "UICheckButtonTemplate")
  known:SetSize(22, 22)
  known:SetPoint("LEFT", filter, "RIGHT", 10, 0)
  known:SetScript("OnClick", function(self)
    state.knownOnly = self:GetChecked() and true or false
    refresh()
  end)
  known:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Known only")
    GameTooltip:AddLine("Show only recipes this character has learned. ProfScan learns them when you open your profession window.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  known:SetScript("OnLeave", GameTooltip_Hide)
  local knownLabel = UI.Text(right, "GameFontNormalSmall")
  knownLabel:SetPoint("LEFT", known, "RIGHT", 2, 0)
  knownLabel:SetText("Known only")

  -- margins per craft or per hour of crafting
  local perHour = UI.Button(right, "Per craft", 90, function(self)
    state.perHour = not state.perHour
    refresh()
  end)
  perHour:SetPoint("TOPRIGHT", 0, 0)
  perHour:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Margins per craft or per hour")
    GameTooltip:AddLine(("Per hour = margin per craft x crafts per hour, from the recipe's cast time plus %.1fs "
      .. "between crafts (/pscan overhead to change). Recipes with a cooldown show \"cd\"."):format(
      ns.db.settings.craftOverhead or 0.5), 1, 1, 1, true)
    GameTooltip:Show()
  end)
  perHour:SetScript("OnLeave", GameTooltip_Hide)

  -- Right column: recipe list ------------------------------------------------------------
  local list = UI.CreateTable(right, {
    { title = "Recipe", width = 212, key = "name" },
    { title = "Skill", width = 34, justify = "RIGHT", key = "skill" },
    { title = "Reagents", width = 76, justify = "RIGHT", key = "cost" },
    { title = "AH margin", width = 84, justify = "RIGHT", key = "margin" },
    { title = "AH %", width = 44, justify = "RIGHT", key = "pct" },
    { title = "Vendor margin", width = 84, justify = "RIGHT", key = "vmargin" },
    { title = "Listed", width = 44, justify = "RIGHT", key = "listed" },
    { title = "Sold/d", width = 44, justify = "RIGHT", key = "sold" },
    { title = "Max AH/h", width = 74, justify = "RIGHT", key = "maxAH" },
    { title = "Max vend/h", width = 74, justify = "RIGHT", key = "maxVendor" },
  }, ROWS)
  -- column tips for the best-route columns
  for i, tip in pairs({
    [9] = "Best AH margin per hour over every crafting route: each reagent bought or crafted, "
      .. "whichever earns the most per hour of crafting (the recipe view's \"Best AH margin/hour\" route).",
    [10] = "Best vendor margin per hour over every crafting route: each reagent bought or crafted, "
      .. "whichever earns the most per hour of crafting (the recipe view's \"Best vendor margin/hour\" route).",
  }) do
    local header = list.titles[i]:GetParent()
    header:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText(list.titles[i]:GetText())
      GameTooltip:AddLine(tip, 1, 1, 1, true)
      GameTooltip:AddLine("\"cd\" = cooldown recipe, \"?\" = cast time unknown, grey \"~\" = some crafted "
        .. "reagent's cast time unknown. Click to sort.", 0.7, 0.7, 0.7, true)
      GameTooltip:Show()
    end)
    header:SetScript("OnLeave", GameTooltip_Hide)
  end
  list:SetPoint("TOPLEFT", 0, -26)
  list.emptyText = "No recipes match."
  list.onSort = function(key)
    if state.sortKey == key then state.sortDesc = not state.sortDesc else state.sortKey, state.sortDesc = key, key ~= "name" end
    refresh()
  end
  list.onClick = function(row, button)
    if button == "RightButton" then
      ns:ReportScanAdd(RecipeItems({ row.recipe }))
    elseif IsModifiedClick("CHATLINK") and row.recipe.item > 0 then
      UI.InsertItemLink(row.recipe.item)
    else
      ns:OpenRecipe(row.recipe)
    end
  end

  -- Refresh ------------------------------------------------------------------------------
  refresh = function()
    local prof
    for i, button in ipairs(profButtons) do
      local p = ns.professions[i]
      if p then
        local skill = ns:ProfessionSkill(p.name)
        button.profName = p.name
        local label = skill and ("%s (%d)"):format(p.name, skill) or p.name
        -- greyed: craft settings leave this profession out of crafting suggestions
        button:SetText(ns.db.settings.craftUse[p.name] == false and ("|cff808080" .. label .. "|r") or label)
        button:Show()
        if not state.profName then state.profName = p.name end
        if p.name == state.profName then
          prof = p
          button:LockHighlight()
        else
          button:UnlockHighlight()
        end
      else
        button:Hide()
      end
    end
    state.prof = prof
    wipe(shown)
    local showTrade = state.profName == TRADE
    if showTrade then tradeButton:LockHighlight() else tradeButton:UnlockHighlight() end
    right:SetShown(not showTrade)
    trade.frame:SetShown(showTrade)
    if showTrade then return trade.refresh() end
    if not prof then
      list:SetData({})
      return
    end
    if state.cat > #prof.categories then state.cat = 0 end
    catButton:SetText(state.cat == 0 and "All categories" or prof.categories[state.cat].name)

    local text = filter:GetText():lower()
    local rows, seen = {}, {}
    for ci, cat in ipairs(prof.categories) do
      if state.cat == 0 or state.cat == ci then
        for _, recipe in ipairs(cat.recipes) do
          local key = RecipeKey(recipe)
          local name = ns:RecipeName(recipe)
          local isKnown = recipe.spell > 0 and ns:IsKnown(recipe.spell)
          if not seen[key]
              and (text == "" or name:lower():find(text, 1, true))
              and (not state.knownOnly or recipe.gathered or isKnown) then
            seen[key] = true
            shown[#shown + 1] = recipe
            local e = ns:RecipeEconomics(recipe)
            local st = recipe.item > 0 and ns:GetStats(recipe.item, 7)
            local sold, soldVia
            if recipe.item > 0 then sold, soldVia = ns:SoldPerDay(recipe.item) end
            local best = BestPerHour(recipe, e)
            local bestAH = best and best.ah and best.ah.perHour
            local bestVendor = best and best.vendor and best.vendor.perHour
            local icon = recipe.item > 0 and UI.GetItemIcon(recipe.item)
              or (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(recipe.spell))
            rows[#rows + 1] = {
              id = recipe.item > 0 and recipe.item or nil,
              spell = recipe.item == 0 and recipe.spell > 0 and recipe.spell or nil,
              icon = icon,
              recipe = recipe,
              sort = {
                name = name,
                skill = recipe.skill,
                cost = e.complete and e.cost or -1,
                margin = (state.perHour and e.ahPerHour or not state.perHour and e.marginAH) or -1e12,
                pct = e.pctAH or -1e12,
                vmargin = (state.perHour and e.vendorPerHour or not state.perHour and e.marginVendor) or -1e12,
                listed = st and st.avgQty or -1,
                sold = sold or -1,
                maxAH = bestAH or -1e12,
                maxVendor = bestVendor or -1e12,
              },
              cells = {
                (isKnown and "|cff40ff40[K]|r " or "") .. name
                  .. (ns.YieldText(recipe) ~= "" and (" |cffaaaaaa" .. ns.YieldText(recipe) .. "|r") or ""),
                recipe.skill > 0 and recipe.skill or "",
                CostText(recipe, e),
                state.perHour and PerHourText(e, e.ahPerHour) or SignedMoney(e.marginAH),
                MarginPct(e.pctAH),
                state.perHour and PerHourText(e, e.vendorPerHour) or SignedMoney(e.marginVendor),
                st and ("%d"):format(st.avgQty + 0.5) or "-",
                ns.SoldText(sold, soldVia),
                best and BestHourText(e, best.ah) or "-",
                best and BestHourText(e, best.vendor) or "-",
              },
            }
          end
        end
      end
    end
    UI.SortRows(rows, state.sortKey, state.sortDesc)
    perHour:SetText(state.perHour and "Per hour" or "Per craft")
    list.titles[4]:SetText(state.perHour and "AH /hour" or "AH margin")
    list.titles[6]:SetText(state.perHour and "Vendor /hour" or "Vendor margin")
    list:SetData(rows)

    local hasKnown = ns.db.known[UnitName("player") .. "-" .. GetRealmName()] ~= nil
    known:SetEnabled(hasKnown)
    knownLabel:SetText(hasKnown and "Known only" or "|cff808080Known only|r")
  end

  return refresh
end

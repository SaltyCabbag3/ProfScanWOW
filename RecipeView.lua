local _, ns = ...

--[[
  Recipe view

  What the recipe makes, what it costs and what it earns, and its crafting
  tree: every reagent, and for reagents that can be crafted the cheapest
  recipe making them, recursively. Each row shows the price to buy one, the
  cost to craft one (sub-recipe cost / items it makes), which is cheaper, and
  the total for one craft of this recipe. Quantities can be fractional when a
  sub-recipe makes several (3 bars from a 2-bar smelt = 1.5 smelts). Rows
  below a reagent that is cheaper to buy are greyed: they show the option,
  not the plan.
  The summary shows the margin per craft for selling on the auction house
  (after the 5% cut) and to a vendor, each against the cheapest way to craft.
  Batch: how many crafts are priced at once (default one stack of the
  product). Reagents are priced as buying the whole batch's worth, cheapest
  listings first, so thin markets cost more than their lowest price. In the
  tree, "Need", "Time" and "Total" are for the whole batch; a red "*" on a buy
  price means fewer were listed than needed at the known price levels, a grey
  "~" that no price levels were known (deep scan or watch the item).
  Routes (below the tree): the best choice of buying or crafting each reagent
  for four goals: AH margin, vendor margin, AH margin per hour, vendor margin
  per hour. Per-hour routes count the time of every craft they involve (the
  product and each crafted reagent), so they may buy a reagent that is a bit
  cheaper to craft when crafting it takes long. Click a route: the tree shows
  its choices ("Best" column) and the time each crafted step takes.
  Click a row: item view. Right-click a crafted reagent: its recipe view.
  "Items per craft" shows the range used and where it came from; type your
  own numbers and press Set to override it, Reset to go back.
]]

local ROWS = 8
local ROUTE_ROWS = 4
local INDENT = 14

local function Seconds(s)
  if s >= 86400 then return ("%.1fd"):format(s / 86400) end
  if s >= 3600 then return ("%.1fh"):format(s / 3600) end
  if s >= 120 then return ("%.1fm"):format(s / 60) end
  return ("%.1fs"):format(s)
end

local function Qty(n)
  if math.abs(n - math.floor(n + 0.5)) < 0.01 then return ("%d"):format(n + 0.5) end
  return ("%.1f"):format(n)
end

-- Rows for a crafting tree table (shared with the crate view). `crafted` is the
-- set of item nodes the chosen route crafts; everything else is bought, and
-- the rows under a bought reagent are greyed.
local function TreeRows(root, crafted)
  local rows = {}
  local function Walk(node, depth, active)
    local colored, plain = ns.UI.ItemName(node.id)
    local name = active and colored or ("|cff808080" .. plain .. "|r")
    local craft = ""
    if node.craft then
      craft = node.craft.complete and ns.Money(node.craftUnit) or "|cffff8080?|r"
      if node.makers > 1 then craft = craft .. (" |cffaaaaaa(1 of %d)|r"):format(node.makers) end
    end
    -- what the selected route does with this reagent, and how long its crafting takes
    local isCrafted = crafted[node]
    local best = isCrafted and "|cff40ff40craft|r" or node.buy and "buy" or "|cffff8080?|r"
    local time = ""
    if isCrafted then
      local t = ns:CraftTiming(node.craft.recipe)
      local seconds = node.craft.qty * (t and t.seconds or 0)
      time = (t and "" or "~") .. Seconds(seconds)
    end
    local unit = isCrafted and node.craftUnit or node.buy
    -- what buying this much costs, and why the average is what it is
    local lines = {}
    if node.buy and node.buyVia == "ah" then
      local lowest = ns:LatestAHPrice(node.id)
      lines[1] = ("Buying %s: %s each on average (lowest listing %s)"):format(
        Qty(node.qty), ns.Money(node.buy), ns.Money(lowest))
      if node.depth == "short" then
        lines[2] = "|cffff6060Fewer listed than needed at the known price levels; the rest is priced at the highest known level.|r"
      elseif node.depth == "nodepth" then
        lines[2] = "No recent price levels known (deep scan or watch this item); the lowest price is used for all."
      end
    elseif node.buyVia == "vendor" then
      lines[1] = "Bought from a vendor: " .. ns.Money(node.buy) .. " each"
    end
    rows[#rows + 1] = {
      id = node.id,
      icon = ns.UI.GetItemIcon(node.id),
      indent = depth * INDENT,
      node = node,
      tooltipLines = lines,
      cells = {
        name,
        Qty(node.qty),
        node.buy and (ns.Money(node.buy) .. (node.buyVia == "vendor" and " |cffaaaaaav|r" or "")
          .. (node.depth == "short" and " |cffff6060*|r" or node.depth == "nodepth" and " |cffaaaaaa~|r" or ""))
          or "|cffff8080no price|r",
        craft,
        best,
        time,
        unit and ns.Money(unit * node.qty) or "-",
      },
    }
    if node.craft then
      for _, child in ipairs(node.craft.children) do
        Walk(child, depth + 1, active and isCrafted)
      end
    end
  end
  for _, child in ipairs(root.children) do Walk(child, 0, true) end
  return rows
end

ns.UI.CraftTreeRows = TreeRows
ns.UI.Seconds = Seconds
ns.UI.Qty = Qty
ns.UI.TREE_COLUMNS = {
  { title = "Crafting tree", width = 270 },
  { title = "Need", width = 50, justify = "RIGHT" },
  { title = "Buy (avg)", width = 96, justify = "RIGHT" },
  { title = "Craft one", width = 110, justify = "RIGHT" },
  { title = "Route", width = 50, justify = "RIGHT" },
  { title = "Time", width = 60, justify = "RIGHT" },
  { title = "Total", width = 100, justify = "RIGHT" },
}

function ns.UI.BuildRecipeView(frame)
  local UI = ns.UI
  local recipe

  -- Header -------------------------------------------------------------------------------
  local icon = frame:CreateTexture(nil, "ARTWORK")
  icon:SetSize(32, 32)
  icon:SetPoint("TOPLEFT", 0, 0)
  local title = UI.Text(frame, "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -1)
  local sub = UI.Text(frame, "GameFontDisableSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)

  local product = UI.Button(frame, "", 240, function()
    if recipe and recipe.item > 0 then ns:OpenItem(recipe.item) end
  end)
  product:SetPoint("TOPRIGHT", 0, -4)
  local productLabel = UI.Text(frame, "GameFontNormalSmall")
  productLabel:SetPoint("RIGHT", product, "LEFT", -6, 0)
  productLabel:SetText("Makes")

  -- Items per craft ------------------------------------------------------------------------
  local selectedRoute = "ahMargin"
  local refresh -- set below

  local function NumberBox()
    local box = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    box:SetSize(28, 18)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(2)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    return box
  end
  local yieldReset = UI.Button(frame, "Reset", 54, function()
    if recipe then ns:SetYieldOverride(recipe.spell, nil) end
  end)
  yieldReset:SetPoint("TOPRIGHT", 0, -30)
  local yieldSet
  local yieldMax = NumberBox()
  local yieldMin = NumberBox()
  yieldSet = UI.Button(frame, "Set", 44, function()
    local lo, hi = tonumber(yieldMin:GetText()), tonumber(yieldMax:GetText())
    if recipe and lo and lo >= 1 then
      yieldMin:ClearFocus()
      yieldMax:ClearFocus()
      ns:SetYieldOverride(recipe.spell, lo, hi and hi >= lo and hi or lo)
    end
  end)
  yieldSet:SetPoint("RIGHT", yieldReset, "LEFT", -4, 0)
  yieldMax:SetPoint("RIGHT", yieldSet, "LEFT", -8, 0)
  local yieldDash = UI.Text(frame, "GameFontNormalSmall")
  yieldDash:SetPoint("RIGHT", yieldMax, "LEFT", -8, 0)
  yieldDash:SetText("to")
  yieldMin:SetPoint("RIGHT", yieldDash, "LEFT", -8, 0)
  local yieldLabel = UI.Text(frame, "GameFontNormalSmall")
  yieldLabel:SetPoint("RIGHT", yieldMin, "LEFT", -10, 0)
  yieldLabel:SetText("Items per craft")
  local yieldSource = UI.Text(frame, "GameFontDisableSmall", "RIGHT")
  yieldSource:SetPoint("RIGHT", yieldLabel, "LEFT", -8, 0)

  -- what limits this recipe besides skill (RecipeLocks.lua): cooldown, station, tools, learning
  local locks = UI.Text(frame, "GameFontHighlightSmall")
  locks:SetPoint("TOPLEFT", 0, -38)
  locks:SetPoint("RIGHT", yieldSource, "LEFT", -12, 0)
  locks:SetHeight(22)
  locks:SetJustifyV("TOP")
  locks:SetWordWrap(true)
  local yieldWidgets = { yieldReset, yieldSet, yieldMax, yieldMin, yieldDash, yieldLabel, yieldSource }

  -- Summary ------------------------------------------------------------------------------
  -- Batch size ----------------------------------------------------------------------------
  local batchReset = UI.Button(frame, "Reset", 54, function()
    if recipe then ns:SetBatchOverride(recipe.spell, nil) end
  end)
  batchReset:SetPoint("TOPRIGHT", 0, -55)
  local batchBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  batchBox:SetSize(34, 18)
  batchBox:SetAutoFocus(false)
  batchBox:SetNumeric(true)
  batchBox:SetMaxLetters(3)
  batchBox:SetScript("OnEscapePressed", batchBox.ClearFocus)
  local batchSet = UI.Button(frame, "Set", 44, function()
    local n = tonumber(batchBox:GetText())
    if recipe and n and n >= 1 then
      batchBox:ClearFocus()
      ns:SetBatchOverride(recipe.spell, n)
    end
  end)
  batchBox:SetScript("OnEnterPressed", function() batchSet:Click() end)
  batchSet:SetPoint("RIGHT", batchReset, "LEFT", -4, 0)
  local batchUnit = UI.Text(frame, "GameFontNormalSmall")
  batchUnit:SetPoint("RIGHT", batchSet, "LEFT", -6, 0)
  batchUnit:SetText("crafts")
  batchBox:SetPoint("RIGHT", batchUnit, "LEFT", -6, 0)
  local batchLabel = UI.Text(frame, "GameFontNormalSmall")
  batchLabel:SetPoint("RIGHT", batchBox, "LEFT", -10, 0)
  batchLabel:SetText("Batch")
  local batchWhy = UI.Text(frame, "GameFontDisableSmall", "RIGHT")
  batchWhy:SetPoint("RIGHT", batchLabel, "LEFT", -8, 0)

  local summary1 = UI.Text(frame)
  summary1:SetPoint("TOPLEFT", 0, -60)
  summary1:SetPoint("RIGHT", batchWhy, "LEFT", -10, 0)
  summary1:SetWordWrap(false)
  local summary2 = UI.Text(frame)
  summary2:SetPoint("TOPLEFT", summary1, "BOTTOMLEFT", 0, -5)
  summary2:SetPoint("RIGHT", frame, "RIGHT")
  local summary3 = UI.Text(frame)
  summary3:SetPoint("TOPLEFT", summary2, "BOTTOMLEFT", 0, -5)
  summary3:SetPoint("RIGHT", frame, "RIGHT")

  -- Tree ---------------------------------------------------------------------------------
  local tree = UI.CreateTable(frame, UI.TREE_COLUMNS, ROWS)
  tree:SetPoint("TOPLEFT", 0, -110)
  tree.emptyText = "This recipe has no reagents."
  tree.onClick = function(row, button)
    if button == "RightButton" and row.node.craft then
      ns:OpenRecipe(row.node.craft.recipe)
    elseif IsModifiedClick("CHATLINK") then
      UI.InsertItemLink(row.node.id)
    else
      ns:OpenItem(row.node.id)
    end
  end

  -- Routes ---------------------------------------------------------------------------------
  local routes = UI.CreateTable(frame, {
    { title = "Route", width = 170 },
    { title = "Crafts", width = 100 },
    { title = "Cost", width = 90, justify = "RIGHT" },
    { title = "Time/craft", width = 76, justify = "RIGHT" },
    { title = "Margin", width = 96, justify = "RIGHT" },
    { title = "Margin/hour", width = 110, justify = "RIGHT" },
    { title = "Sell to", width = 60 },
  }, ROUTE_ROWS)
  routes:SetPoint("TOPLEFT", tree, "BOTTOMLEFT", 0, 2)
  routes.emptyText = "No route can be priced yet (scan the reagents)."
  routes.onClick = function(row)
    selectedRoute = row.key
    refresh()
  end

  -- Buttons ------------------------------------------------------------------------------
  local function TreePreview(self)
    if not recipe then return end
    local ids = ns:RecipeTreeItems(recipe)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(("Full tree: %d items"):format(#ids))
    GameTooltip:AddLine("The product, its reagents, and the reagents of anything among them that is crafted, down to raw materials.", 1, 1, 1, true)
    for j, id in ipairs(ids) do
      if j > 20 then
        GameTooltip:AddLine(("... and %d more"):format(#ids - 20), 0.7, 0.7, 0.7)
        break
      end
      GameTooltip:AddLine((UI.ItemName(id)))
    end
    GameTooltip:Show()
  end
  local actions = {
    { "Scan recipe", function() ns:ReportScanAdd(ns.RecipeItems({ recipe })) end },
    { "Scan full tree", function() ns:ReportScanAdd(ns:RecipeTreeItems(recipe)) end, true },
    { "Watch recipe", function() ns:ReportWatchAdd(ns.RecipeItems({ recipe })) end },
    { "Watch full tree", function() ns:ReportWatchAdd(ns:RecipeTreeItems(recipe)) end, true },
  }
  for i, action in ipairs(actions) do
    local b = UI.Button(frame, action[1], 120, function() if recipe then action[2]() end end)
    b:SetPoint("BOTTOMLEFT", (i - 1) * 124, 0)
    if action[3] then
      b:SetScript("OnEnter", TreePreview)
      b:SetScript("OnLeave", GameTooltip_Hide)
    end
  end
  local openInGame = UI.Button(frame, "Open in profession", 140, function()
    if recipe then ns:OpenRecipeInGame(recipe) end
  end)
  openInGame:SetPoint("BOTTOMRIGHT", 0, 0)
  openInGame:SetMotionScriptsWhileDisabled(true)
  openInGame:SetScript("OnEnter", function(self)
    if not recipe then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Open in the profession window")
    if not ns:HasProfession(recipe.profession) then
      GameTooltip:AddLine(("This character doesn't have %s."):format(recipe.profession or "this profession"), 1, 0.4, 0.4, true)
    elseif recipe.spell > 0 and not ns:IsKnown(recipe.spell) then
      GameTooltip:AddLine("This character hasn't learned this recipe yet (as far as ProfScan saw).", 1, 0.8, 0.3, true)
    else
      GameTooltip:AddLine("Shows this recipe in your " .. recipe.profession .. " window, ready to craft.", 1, 1, 1, true)
    end
    GameTooltip:Show()
  end)
  openInGame:SetScript("OnLeave", GameTooltip_Hide)
  local hint = UI.Text(frame, "GameFontDisableSmall", "RIGHT")
  hint:SetPoint("BOTTOMRIGHT", 0, 26)
  hint:SetText("Click: item details   Right-click a crafted reagent: its recipe")

  -- Refresh ------------------------------------------------------------------------------

  local function RouteRows(list, root)
    local rows = {}
    local rootTiming = ns:CraftTiming(recipe)
    for _, r in ipairs(list) do
      local p = r.point
      local crafted, names = p and ns.RouteCrafted(p) or {}, {}
      for node in pairs(crafted) do names[#names + 1] = (select(2, UI.ItemName(node.id))) end
      table.sort(names)
      local lines = {}
      if p then
        lines[#lines + 1] = #names > 0 and ("Crafts: " .. table.concat(names, ", ")) or "Buys every reagent"
        local own = rootTiming and rootTiming.seconds
        if own then
          lines[#lines + 1] = ("Time per craft: %s for the product + %s for crafted reagents"):format(
            Seconds(own), Seconds(math.max(0, p.time - own)))
        end
        if p.approx then lines[#lines + 1] = "Some cast times are unknown; those crafts count as instant." end
        if p.cooldown then lines[#lines + 1] = "Involves a recipe with a cooldown, so per hour doesn't apply." end
      end
      local perHour
      if r.perHour then
        perHour = ns.SignedMoney(math.floor(r.perHour + 0.5))
      elseif p and p.cooldown then
        perHour = "|cffaaaaaacooldown|r"
      else
        perHour = "-"
      end
      rows[#rows + 1] = {
        key = r.key,
        selected = r.key == selectedRoute,
        tooltipTitle = r.label,
        tooltipLines = lines,
        cells = {
          r.label,
          p and (#names == 0 and "nothing" or (#names .. " reagent" .. (#names > 1 and "s" or ""))) or "-",
          p and ns.Money(p.cost) or "?",
          p and ((p.approx and "~" or "") .. Seconds(p.time)) or "-",
          ns.SignedMoney(r.margin and math.floor(r.margin + 0.5)),
          perHour,
          r.sell == "ah" and "AH" or "vendor",
        },
      }
    end
    return rows
  end

  local function Refresh()
    if not recipe then return end
    local name = ns:RecipeName(recipe)
    icon:SetTexture(recipe.item > 0 and UI.GetItemIcon(recipe.item)
      or (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(recipe.spell)))
    title:SetText(name)
    local parts = { recipe.profession or "?", recipe.category }
    if recipe.skill > 0 then parts[#parts + 1] = "skill " .. recipe.skill end
    if recipe.spell > 0 and ns:IsKnown(recipe.spell) then parts[#parts + 1] = "|cff40ff40known|r" end
    sub:SetText(table.concat(parts, "  -  "))
    locks:SetText(table.concat(ns:LockLines(recipe, true), "     "))
    product:SetShown(recipe.item > 0)
    for _, w in ipairs(yieldWidgets) do w:SetShown(recipe.item > 0 and recipe.spell > 0) end
    if not yieldMin:HasFocus() then yieldMin:SetText(recipe.yieldMin or 1) end
    if not yieldMax:HasFocus() then yieldMax:SetText(recipe.yieldMax or recipe.yieldMin or 1) end
    yieldSource:SetText(("(%s, average %s)"):format(recipe.yieldSource or "?", Qty(ns.Yield(recipe))))
    yieldReset:SetEnabled(ns.db.yieldOverride[recipe.spell] ~= nil)
    local batch, why = ns:BatchCrafts(recipe)
    if not batchBox:HasFocus() then batchBox:SetText(batch) end
    batchWhy:SetText("(" .. why .. ")")
    batchReset:SetEnabled(ns.db.batchOverride[recipe.spell] ~= nil)
    openInGame:SetEnabled(recipe.spell > 0 and ns:HasProfession(recipe.profession)
      and C_TradeSkillUI ~= nil and C_TradeSkillUI.OpenRecipe ~= nil)
    productLabel:SetShown(recipe.item > 0)
    if recipe.item > 0 then
      local yield = ns.YieldText(recipe)
      product:SetText((UI.ItemName(recipe.item)) .. (yield ~= "" and ("  " .. yield) or ""))
    end

    local e = ns:RecipeEconomics(recipe)
    local root = ns:CraftTree(recipe)
    local cheapest = root.complete and root.unit or nil
    local crafted = 0
    for _, child in ipairs(root.children) do
      if child.best == "craft" then crafted = crafted + 1 end
    end
    summary1:SetText(("Per craft:  buy all %s     cheapest %s%s"):format(
      ns.CostText(recipe, e),
      cheapest and ns.Money(cheapest) or "|cffff8080incomplete|r",
      crafted > 0 and (" |cffaaaaaa(crafting %d reagent%s)|r"):format(crafted, crafted > 1 and "s" or "") or ""))

    if recipe.item > 0 then
      -- margins against the cheapest way to make it (or buying all reagents if that's incomplete)
      local basis = cheapest or (e.complete and e.cost) or nil
      local function Side(label, perItem)
        if not perItem then return label .. " |cffaaaaaano price|r" end
        local revenue = math.floor(perItem * e.yield)
        local margin = basis and revenue - basis
        return ("%s %s%s  margin %s%s"):format(label, ns.Money(perItem),
          e.yield ~= 1 and (" x %s = %s"):format(Qty(e.yield), ns.Money(revenue)) or "",
          ns.SignedMoney(margin), margin and basis > 0 and (" (%s)"):format(ns.MarginPct(margin / basis)) or "")
      end
      summary2:SetText(Side("|cffffd100Sell on AH|r (after cut)", e.ahNet) .. "        "
        .. Side("|cffffd100Sell to vendor|r", e.vendorSell))

      -- per hour of crafting, and how much the market actually takes
      local t = e.timing
      local sold, soldVia = ns:SoldPerDay(recipe.item)
      local units = math.floor(e.batch * e.yield + 0.5)
      local market = sold and ("     market buys %s/day: a batch (%d) sells in ~%s"):format(
        ns.SoldText(sold, soldVia), units, sold > 0 and Seconds(units / sold * 86400) or "never") or ""
      if not t then
        summary3:SetText("|cffaaaaaaCraft time unknown (the game gave no cast time for this recipe).|r" .. market)
      elseif t.cooldown then
        summary3:SetText(("Craft time %.1fs, cooldown %s: per-hour margins don't apply.%s"):format(
          t.cast, ns.Duration(t.cooldown), market))
      else
        summary3:SetText(("This recipe: %.1fs cast + %.1fs between crafts (%d/hour if every reagent is bought). "
          .. "Routes below add crafted reagents' time.%s"):format(t.cast, t.seconds - t.cast, t.perHour, market))
      end
    else
      summary2:SetText("|cffaaaaaaThis recipe makes no item (an enchant or similar), so there is no sale price.|r")
      summary3:SetText("")
    end
    local list = recipe.item > 0 and ns:CraftRoutes(recipe, root, e) or {}
    local crafted = {}
    for _, r in ipairs(list) do
      if r.key == selectedRoute and r.point then crafted = ns.RouteCrafted(r.point) end
    end
    if #list == 0 then -- no product to sell (enchants): show the cheapest choices
      for _, child in ipairs(root.children) do
        local function Mark(node)
          if node.best == "craft" then
            crafted[node] = true
            for _, c in ipairs(node.craft.children) do Mark(c) end
          end
        end
        Mark(child)
      end
    end
    routes:SetData(RouteRows(list, root))
    tree:SetData(TreeRows(root, crafted))
  end
  refresh = Refresh

  return {
    show = function(r)
      recipe = r
      tree.offset = 0
    end,
    refresh = Refresh,
  }
end

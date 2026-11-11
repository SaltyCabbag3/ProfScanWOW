local _, ns = ...

--[[
  Crate view (from the Trade company tab: click a crate)

  A Waylaid Crate is "made" from one of several bundles of goods. For each
  way to fill it: the cost of buying the whole bundle, the cheapest cost
  (crafting parts of it where that is cheaper, e.g. smelting the bars
  yourself) with the crafting time that takes, and the net cost per
  Merchant's Favor for both: (empty crate's AH price + fill - the money the
  turn-in pays, an estimate: /pscan cratemoney) / Favor. Below, the crafting tree of the selected fill shows what
  the cheapest way buys and what it crafts.
  "Crates" is how many you plan to fill at once (default: what the Favor goal
  takes, /pscan favorgoal): the goods are priced as buying that much,
  cheapest listings first.
  Click a fill: show its tree. Right-click: add its item to the scan list.
  In the tree: click for the item view, right-click a crafted reagent for its recipe.
]]

local OPTION_ROWS = 5
local TREE_ROWS = 9
local CRATE_ICON = "Interface\\Icons\\INV_Crate_02"

function ns.UI.BuildCrateView(frame)
  local UI = ns.UI
  local index, selected
  local refresh -- defined below

  -- Header -------------------------------------------------------------------------------
  local icon = frame:CreateTexture(nil, "ARTWORK")
  icon:SetSize(32, 32)
  icon:SetPoint("TOPLEFT", 0, 0)
  local title = UI.Text(frame, "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -1)
  local sub = UI.Text(frame, "GameFontDisableSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
  local handIn = UI.Text(frame, "GameFontNormalSmall", "RIGHT")
  handIn:SetPoint("TOPRIGHT", 0, -4)

  -- How many crates ------------------------------------------------------------------------
  local countReset = UI.Button(frame, "Reset", 54, function()
    local c = index and ns.TRADE.crates[index]
    if c then
      ns.db.crateBatch[c[2]] = nil
      ns:NotifyChanged()
    end
  end)
  countReset:SetPoint("TOPRIGHT", 0, -24)
  local countBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  countBox:SetSize(34, 18)
  countBox:SetAutoFocus(false)
  countBox:SetNumeric(true)
  countBox:SetMaxLetters(3)
  countBox:SetScript("OnEscapePressed", countBox.ClearFocus)
  local countSet = UI.Button(frame, "Set", 44, function()
    local c, n = index and ns.TRADE.crates[index], tonumber(countBox:GetText())
    if c and n and n >= 1 then
      countBox:ClearFocus()
      ns.db.crateBatch[c[2]] = math.floor(n)
      ns:NotifyChanged()
    end
  end)
  countBox:SetScript("OnEnterPressed", function() countSet:Click() end)
  countSet:SetPoint("RIGHT", countReset, "LEFT", -4, 0)
  countBox:SetPoint("RIGHT", countSet, "LEFT", -8, 0)
  local countLabel = UI.Text(frame, "GameFontNormalSmall")
  countLabel:SetPoint("RIGHT", countBox, "LEFT", -10, 0)
  countLabel:SetText("Crates at once")

  -- Fill options ---------------------------------------------------------------------------
  local options = UI.CreateTable(frame, {
    { title = "Fill with", width = 210 },
    { title = "Buy all", width = 86, justify = "RIGHT" },
    { title = "Cheapest", width = 86, justify = "RIGHT" },
    { title = "Crafting", width = 86, justify = "RIGHT" },
    { title = "Net/Favor (cheapest)", width = 130, justify = "RIGHT" },
    { title = "Net/Favor (buy all)", width = 130, justify = "RIGHT" },
  }, OPTION_ROWS)
  options:SetPoint("TOPLEFT", 0, -50)
  options.onClick = function(row, button)
    if button == "RightButton" then
      ns:ReportScanAdd({ row.id })
    elseif IsModifiedClick("CHATLINK") then
      UI.InsertItemLink(row.id)
    else
      selected = row.option
      refresh()
    end
  end

  local treeTitle = UI.Text(frame, "GameFontNormal")
  treeTitle:SetPoint("TOPLEFT", options, "BOTTOMLEFT", 2, -2)
  local tree = UI.CreateTable(frame, UI.TREE_COLUMNS, TREE_ROWS)
  tree:SetPoint("TOPLEFT", options, "BOTTOMLEFT", 0, -18)
  tree.onClick = function(row, button)
    if button == "RightButton" and row.node.craft then
      ns:OpenRecipe(row.node.craft.recipe)
    elseif IsModifiedClick("CHATLINK") then
      UI.InsertItemLink(row.node.id)
    else
      ns:OpenItem(row.node.id)
    end
  end

  -- Buttons ------------------------------------------------------------------------------
  local scanAll = UI.Button(frame, "Scan crate + fills", 120, function()
    local c = index and ns.TRADE.crates[index]
    if not c then return end
    local ids = {}
    for _, fill in ipairs(c[5]) do ids[#ids + 1] = fill[1] end
    if c[1] > 0 then ids[#ids + 1] = c[1] end -- the empty crate itself
    ns:ReportScanAdd(ids)
  end)
  scanAll:SetPoint("BOTTOMLEFT", 0, 0)
  local scanTree = UI.Button(frame, "Scan fill tree", 120, function()
    local c = index and ns.TRADE.crates[index]
    local fill = c and c[5][selected or 1]
    if fill then ns:ReportScanAdd(ns:RecipeTreeItems(ns.BundleRecipe(fill[1], fill[2]))) end
  end)
  scanTree:SetPoint("LEFT", scanAll, "RIGHT", 4, 0)
  local watchFill = UI.Button(frame, "Watch this fill", 120, function()
    local c = index and ns.TRADE.crates[index]
    local fill = c and c[5][selected or 1]
    if fill then ns:ReportWatchAdd({ fill[1] }) end
  end)
  watchFill:SetPoint("LEFT", scanTree, "RIGHT", 4, 0)
  local hint = UI.Text(frame, "GameFontDisableSmall", "RIGHT")
  hint:SetPoint("BOTTOMRIGHT", 0, 6)
  hint:SetText("Click a fill: its tree   Right-click: scan it")

  -- Refresh ------------------------------------------------------------------------------
  refresh = function()
    local c = index and ns.TRADE.crates[index]
    if not c then return end
    local crateID, name, level, favor, fills = c[1], c[2], c[3], c[4], c[5]
    local ownCount = ns.db.crateBatch[name]
    local count = ownCount or ns:CratesForGoal(favor) or 1 -- default: what the Favor goal takes
    local pays = favor and favor * (ns.db.settings.crateMoneyPerFavor or 0)
    local cratePrice, crateState = ns:TradeItemPrice(crateID, count)

    icon:SetTexture(crateID > 0 and UI.GetItemIcon(crateID) or CRATE_ICON)
    title:SetText(name .. " crate")
    sub:SetText(("Level %d  -  %s  -  empty crate %s  -  turn-in pays about %s (estimate)"):format(level,
      favor and (favor .. " Merchant's Favor") or "|cffffaa00Favor not known yet (seen in beta only)|r",
      crateState == "ah" and ns.Money(cratePrice) or crateState == "unknown" and "not scanned (counted as 0)"
        or "not counted", pays and ns.Money(pays) or "?"))
    local company = ns.TRADE.companies[UnitFactionGroup("player")]
    handIn:SetText(company and ("Hand in: " .. company.crates) or "")
    if not countBox:HasFocus() then countBox:SetText(count) end
    countLabel:SetText(not ownCount and ns:CratesForGoal(favor)
      and ("Crates (for %d Favor)"):format(ns.db.settings.favorGoal) or "Crates at once")
    countReset:SetEnabled(ns.db.crateBatch[name] ~= nil)

    -- every way to fill it, per crate, priced for `count` crates
    local rows, bestCost, bestIndex, roots = {}, nil, nil, {}
    for i, fill in ipairs(fills) do
      local item, qty = fill[1], fill[2]
      local root = ns:CraftTree(ns.BundleRecipe(item, qty), count)
      local points = ns:RoutePoints(root)
      local cheapest = points[1]
      local node = root.children[1]
      local buyAll = node.buy and node.buy * qty
      local cost = cheapest and cheapest.cost / count
      local time = cheapest and cheapest.time / count
      roots[i] = { root = root, point = cheapest }
      if cost and (not bestCost or cost < bestCost) then bestCost, bestIndex = cost, i end
      local crafted = cheapest and ns.RouteCrafted(cheapest) or {}
      local nCrafted = 0
      for _ in pairs(crafted) do nCrafted = nCrafted + 1 end
      local function PerFavor(total)
        if not (total and favor) then return "-" end
        local v = (total + cratePrice - pays) / favor
        return v > 0 and ns.Money(v) or "|cff40ff40profit|r"
      end
      rows[i] = {
        id = item,
        icon = UI.GetItemIcon(item),
        option = i,
        tooltipLines = {
          ("Priced for %d crate%s: buying %d in total"):format(count, count > 1 and "s" or "", qty * count),
          nCrafted > 0 and ("Cheapest way crafts %d step%s, %s per crate"):format(nCrafted, nCrafted > 1 and "s" or "",
            UI.Seconds(time)) or "Cheapest way: buy it all",
        },
        cells = {
          ("%d %s"):format(qty, (UI.ItemName(item))) .. (node.depth == "short" and " |cffff6060*|r" or ""),
          buyAll and ns.Money(buyAll) or "|cffff8080no price|r",
          cost and ns.Money(cost) or "?",
          nCrafted > 0 and ((cheapest.approx and "~" or "") .. UI.Seconds(time)) or "-",
          PerFavor(cost),
          PerFavor(buyAll),
        },
      }
    end
    if not selected or not fills[selected] then selected = bestIndex or 1 end
    for i, row in ipairs(rows) do
      row.selected = i == selected
      if i == bestIndex then row.cells[3] = "|cff40ff40" .. row.cells[3] .. "|r" end
    end
    options:SetData(rows)

    local fill, chosen = fills[selected], roots[selected]
    treeTitle:SetText(("Crafting tree: %d %s for %d crate%s (cheapest way)"):format(
      fill[2], select(2, UI.ItemName(fill[1])), count, count > 1 and "s" or ""))
    local crafted = chosen.point and ns.RouteCrafted(chosen.point) or {}
    -- the bundle itself is the root; show its one item and what crafting it involves
    tree:SetData(UI.CraftTreeRows(chosen.root, crafted))
  end

  return {
    show = function(i)
      if i ~= index then selected = nil end
      index = i
      options.offset, tree.offset = 0, 0
    end,
    refresh = refresh,
  }
end

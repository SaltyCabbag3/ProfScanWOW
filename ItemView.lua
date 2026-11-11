local _, ns = ...

--[[
  Item view

  Left: auction house statistics for 1 / 7 / 30 days and all history (median,
  low and high of the lowest price, average quantity listed, number of scans),
  vendor prices, and what watch mode measured (sold per day, purchase sizes,
  how deep purchases go). Right: price chart with a range selector, and the
  recipes that make or use this item (click one to open it).
  Older history comes from daily summaries once data has been trimmed.
]]

local RANGES = { { "1 day", 1 }, { "7 days", 7 }, { "30 days", 30 }, { "All", nil } }
local RECIPE_ROWS = 7

function ns.UI.BuildItemView(frame)
  local UI = ns.UI
  local itemID
  local range = 2 -- index into RANGES

  -- Header -------------------------------------------------------------------------------
  local icon = frame:CreateTexture(nil, "ARTWORK")
  icon:SetSize(32, 32)
  icon:SetPoint("TOPLEFT", 0, 0)
  local title = UI.Text(frame, "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -1)
  local sub = UI.Text(frame, "GameFontDisableSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)

  local watchBtn = UI.Button(frame, "Watch", 90, function() if itemID then ns:ToggleFocus(itemID) end end)
  watchBtn:SetPoint("TOPRIGHT", 0, -4)
  local scanBtn = UI.Button(frame, "Add to scan list", 120, function()
    if not itemID then return end
    if ns.watched[itemID] then ns:RemoveFromScanList(itemID) else ns:ReportScanAdd({ itemID }) end
  end)
  scanBtn:SetPoint("RIGHT", watchBtn, "LEFT", -4, 0)
  local linkBtn = UI.Button(frame, "Link", 60, function() if itemID then UI.InsertItemLink(itemID) end end)
  linkBtn:SetPoint("RIGHT", scanBtn, "LEFT", -4, 0)

  -- Left: statistics ----------------------------------------------------------------------
  local now = UI.Text(frame)
  now:SetPoint("TOPLEFT", 0, -46)
  now:SetWidth(280)

  local GRID_X = { 0, 76, 128, 180, 232 }
  local GRID_W = { 74, 50, 50, 50, 50 }
  local function Column(y, x, width, justify)
    local fs = UI.Text(frame, nil, justify)
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetWidth(width)
    fs:SetJustifyV("TOP")
    return fs
  end
  local ahCols, watchCols = {}, {}
  for i = 1, 5 do ahCols[i] = Column(-68, GRID_X[i], GRID_W[i], i == 1 and "LEFT" or "RIGHT") end
  local vendorText = UI.Text(frame)
  vendorText:SetPoint("TOPLEFT", 0, -160)
  vendorText:SetWidth(280)
  vendorText:SetJustifyV("TOP")
  for i = 1, 3 do watchCols[i] = Column(-200, ({ 0, 160, 220 })[i], ({ 156, 56, 60 })[i], i == 1 and "LEFT" or "RIGHT") end
  local lastBuy = UI.Text(frame)
  lastBuy:SetPoint("TOPLEFT", 0, -310)
  lastBuy:SetWidth(280)
  lastBuy:SetJustifyV("TOP")

  -- Right: chart and recipes --------------------------------------------------------------
  local rangeButtons = {}
  local refresh -- defined below
  for i, r in ipairs(RANGES) do
    local b = UI.Button(frame, r[1], 70, function()
      range = i
      refresh()
    end)
    b:SetPoint("TOPLEFT", 290 + (i - 1) * 74, -44)
    rangeButtons[i] = b
  end
  local chart = UI.CreateChart(frame, 466, 200)
  chart:SetPoint("TOPLEFT", 290, -70)

  local recipes = UI.CreateTable(frame, {
    { title = "Recipes with this item", width = 220 },
    { title = "Role", width = 70 },
    { title = "Profession", width = 90 },
    { title = "Margin", width = 86, justify = "RIGHT" },
  }, RECIPE_ROWS)
  recipes:SetPoint("TOPLEFT", 290, -278)
  recipes.emptyText = "No recipe makes or uses this item."
  recipes.onClick = function(row) ns:OpenRecipe(row.recipe) end

  -- Refresh ------------------------------------------------------------------------------
  local function F(v) return v and ns.ShortMoney(v) or "-" end

  refresh = function()
    if not itemID then return end
    local colored = UI.ItemName(itemID)
    icon:SetTexture(UI.GetItemIcon(itemID))
    title:SetText(colored)
    local flags = { "item " .. itemID }
    if ns.watched[itemID] then flags[#flags + 1] = "on the scan list" end
    if ns:IsFocus(itemID) then flags[#flags + 1] = "watched" end
    sub:SetText(table.concat(flags, "  -  "))
    watchBtn:SetText(ns:IsFocus(itemID) and "Unwatch" or "Watch")
    scanBtn:SetText(ns.watched[itemID] and "Remove from scan" or "Add to scan list")

    -- auction house
    local all = ns:GetStats(itemID, nil)
    if all then
      now:SetText(("Lowest now: %s  |cffaaaaaa(%s ago)|r   Listed: %d"):format(
        ns.Money(all.latest.min), ns.Age(all.latest.t), all.latest.qty))
    else
      now:SetText("|cffaaaaaaNot scanned yet on " .. ns.ahKey .. ".|r")
    end
    local cols = { { "|cffffd100Auction house|r" }, { "1d" }, { "7d" }, { "30d" }, { "All" } }
    for _, label in ipairs({ "Median", "Low", "High", "Avg listed", "Scans" }) do cols[1][#cols[1] + 1] = label end
    for i, days in ipairs({ 1, 7, 30, false }) do
      local st = ns:GetStats(itemID, days or nil)
      local c = cols[i + 1]
      c[#c + 1] = F(st and st.median)
      c[#c + 1] = F(st and st.low)
      c[#c + 1] = F(st and st.high)
      c[#c + 1] = st and ("%d"):format(st.avgQty + 0.5) or "-"
      c[#c + 1] = st and st.scans or 0
    end
    for i, fs in ipairs(ahCols) do fs:SetText(table.concat(cols[i], "\n")) end

    -- vendor
    local sell, buy = ns:VendorSellPrice(itemID), ns.db.vendor[itemID]
    local imp = ns.IMPORTED
    local est = imp and imp.ah == ns.ahKey and imp.sold and imp.sold[itemID]
    vendorText:SetText(("|cffffd100Vendor|r\nPays %s   Sells for %s%s"):format(
      sell and ns.Money(sell) or "-", buy and ns.Money(buy) or "|cffaaaaaanot seen|r",
      est and ("\n|cffffd100Blizzard API|r  about %d sold per day (7 days)"):format(est + 0.5) or ""))

    -- watch mode
    local w7, wall = ns:GetWatchStats(itemID, 7), ns:GetWatchStats(itemID, nil)
    local wc = { { "|cffffd100Watch mode|r", "Hours watched", "Sold per day", "Purchases per day",
                   "Typical purchase", "Largest purchase", "Most price levels" }, { "7d" }, { "All" } }
    for i, w in ipairs({ w7, wall }) do
      local c = wc[i + 1]
      c[#c + 1] = w and ("%.1f"):format(w.hours) or "-"
      c[#c + 1] = w and ("%d"):format(w.soldPerDay + 0.5) or "-"
      c[#c + 1] = w and ("%.1f"):format(w.buysPerDay) or "-"
      c[#c + 1] = w and w.medianSize or "-"
      c[#c + 1] = w and w.maxSize or "-"
      c[#c + 1] = w and w.maxLevels > 0 and w.maxLevels or "-"
    end
    for i, fs in ipairs(watchCols) do fs:SetText(table.concat(wc[i], "\n")) end
    local last = wall and wall.lastBuy
    if last then
      lastBuy:SetText(("Last purchase seen %s ago: %d at %s%s"):format(ns.Age(last.t), last.qty, ns.Money(last.low),
        last.levels > 1 and (" up to %s"):format(ns.Money(last.high)) or ""))
    elseif not wall then
      lastBuy:SetText("|cffaaaaaaNot watched yet. Watch it to measure how much actually sells.|r")
    else
      lastBuy:SetText("")
    end

    -- chart
    for i, b in ipairs(rangeButtons) do
      if i == range then b:LockHighlight() else b:UnlockHighlight() end
    end
    local days = RANGES[range][2]
    chart:SetData(ns:GetSeries(itemID, days and (time() - days * ns.DAY) or nil))

    -- recipes
    local rows = {}
    local function Add(list, role)
      for _, r in ipairs(list or {}) do
        local e = ns:RecipeEconomics(r)
        rows[#rows + 1] = {
          id = r.item > 0 and r.item or nil,
          spell = r.item == 0 and r.spell or nil,
          icon = r.item > 0 and UI.GetItemIcon(r.item) or nil,
          recipe = r,
          sort = { name = ns:RecipeName(r), margin = e.margin or -1e12, role = role },
          cells = { ns:RecipeName(r), role, r.profession or "", ns.SignedMoney(e.margin) },
        }
      end
    end
    Add(ns.recipesByItem[itemID], "|cff40ff40makes it|r")
    Add(ns.recipesUsing[itemID], "uses it")
    UI.SortRows(rows, "margin", true)
    recipes:SetData(rows)
  end

  return {
    show = function(id)
      itemID = id
      ns.GetItemInfo(id) -- make sure item info (name, vendor price) gets loaded
      recipes.offset = 0
    end,
    refresh = refresh,
  }
end

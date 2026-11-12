local _, ns = ...

--[[
  Interface

  Main window (/pscan, or the addon compartment button). Tabs:
    Prices       every item on the scan list: lowest price, 7-day median, how
                 far the price is from it, quantity listed, sold per day
                 (measured by watch mode, or "~" = Blizzard API estimate), scan age. Click: item view. Right-click: watch or
                 unwatch. Ctrl-right-click: remove. Shift-click: link.
    Professions  recipe browser (RecipesUI.lua). Click a recipe: recipe view.
    Watch        watch mode: best price, depth, purchases; click a row for its
                 order book and recent activity.
    Data         what is stored, manual trim, external database (DataUI.lua).
  Views on top of the tabs, reached by clicking and left with Back:
    Recipe view (RecipeView.lua), Item view (ItemView.lua) and Crate view
    (CrateView.lua). They link to each other, so you can go browser -> recipe
    -> reagent -> another recipe, or trade company -> crate -> bar -> smelting.
  AH panel       docked to the right of the auction house window.

  Other files call ns:NotifyChanged() when data changes; the window redraws
  at most twice a second while it is open.
]]

local WIDTH, HEIGHT = 980, 580
local ROW_H = 18
local PRICE_ROWS = 19
local WATCH_ROWS = 8
local BOOK_LINES = 10
local MAX_STACK = 20

local GetItemIcon = C_Item and C_Item.GetItemIconByID or GetItemIcon
local InsertLink = ChatEdit_InsertLink or (ChatFrameUtil and ChatFrameUtil.InsertLink)

local BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8X8", -- plain texture, tinted solid below
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 8, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

-- Small widget helpers ---------------------------------------------------------------

local function Panel(name, parent, width, height)
  local f = CreateFrame("Frame", name, parent, "BackdropTemplate")
  f:SetSize(width, height)
  f:SetBackdrop(BACKDROP)
  f:SetBackdropColor(0.07, 0.07, 0.08, 1)
  f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
  return f
end

local function Button(parent, text, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

local function Text(parent, font, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  fs:SetJustifyH(justify or "LEFT")
  return fs
end

-- Quality-coloured name, and the plain name.
local function ItemName(id)
  local name, _, quality = ns.GetItemInfo(id)
  name = name or ns.db.names[id] or ("item:" .. id)
  local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
  return color and color.hex and (color.hex .. name .. "|r") or name, name
end

local function Percent(ratio)
  if not ratio then return "-" end
  local pct = math.floor(ratio * 100 + 0.5)
  if ratio < 0.85 then return "|cff40ff40" .. pct .. "%|r" end
  if ratio > 1.15 then return "|cffff6060" .. pct .. "%|r" end
  return pct .. "%"
end

local function InsertItemLink(id)
  local _, link = ns.GetItemInfo(id)
  if link and InsertLink then InsertLink(link) end
end

-- A list with clickable column titles, mouse-wheel scrolling and tooltips.
-- columns = { { title =, width =, justify =, key = sort key or nil }, ... }
-- SetData(rows): rows = { { id = item, spell = (tooltip instead of item), icon =,
--                           cells = { text, ... }, selected = bool, indent = px }, ... }
local function CreateTable(parent, columns, numRows)
  local t = CreateFrame("Frame", nil, parent)
  t.rows, t.data, t.offset = {}, {}, 0

  local x = 0
  for _, col in ipairs(columns) do
    local h = CreateFrame("Button", nil, t)
    h:SetSize(col.width, ROW_H)
    h:SetPoint("TOPLEFT", x, 0)
    local fs = Text(h, "GameFontNormalSmall", col.justify)
    fs:SetPoint("LEFT", 4, 0)
    fs:SetPoint("RIGHT", -4, 0)
    fs:SetText(col.title)
    t.titles = t.titles or {}
    t.titles[#t.titles + 1] = fs
    if col.key then
      h:SetScript("OnClick", function() if t.onSort then t.onSort(col.key) end end)
      h:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    end
    x = x + col.width
  end
  t:SetSize(x, (numRows + 1) * ROW_H + 16)
  local firstWidth = columns[1].width

  for r = 1, numRows do
    local row = CreateFrame("Button", nil, t)
    row:SetSize(x, ROW_H)
    row:SetPoint("TOPLEFT", 0, -r * ROW_H)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(0.2, 0.6, 1, 0.18)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 2, 0)
    row.cells = {}
    local cx = 0
    for i, col in ipairs(columns) do
      local fs = Text(row, nil, col.justify)
      local pad = i == 1 and 22 or 4
      fs:SetPoint("LEFT", cx + pad, 0)
      fs:SetWidth(col.width - pad - 4)
      fs:SetWordWrap(false)
      row.cells[i] = fs
      cx = cx + col.width
    end
    row:SetScript("OnClick", function(self, button)
      if self.item and t.onClick then t.onClick(self.item, button) end
    end)
    row:SetScript("OnEnter", function(self)
      local item = self.item
      if not item or not (item.spell or item.id or item.tooltipTitle) then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if item.spell then
        GameTooltip:SetSpellByID(item.spell)
      elseif item.id then
        GameTooltip:SetItemByID(item.id)
      else
        GameTooltip:SetText(item.tooltipTitle) -- rows that aren't an item, e.g. crafting routes
      end
      for _, line in ipairs(item.tooltipLines or {}) do
        GameTooltip:AddLine(line, 0.2, 1, 0.6, true)
      end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    t.rows[r] = row
  end

  t.info = Text(t, "GameFontDisableSmall")
  t.info:SetPoint("BOTTOMLEFT", 4, 0)

  t:EnableMouseWheel(true)
  t:SetScript("OnMouseWheel", function(self, delta)
    self.offset = math.max(0, math.min(self.offset - delta * 3, #self.data - numRows))
    self:Refresh()
  end)

  function t:SetData(data)
    self.data = data
    self.offset = math.max(0, math.min(self.offset, #data - numRows))
    self:Refresh()
  end

  function t:Refresh()
    for r, row in ipairs(self.rows) do
      local item = self.data[r + self.offset]
      row.item = item
      if item then
        local indent = item.indent or 0
        row.icon:SetPoint("LEFT", 2 + indent, 0)
        row.cells[1]:SetPoint("LEFT", 22 + indent, 0)
        row.cells[1]:SetWidth(math.max(20, firstWidth - 26 - indent))
        row.icon:SetTexture(item.icon)
        for i, fs in ipairs(row.cells) do fs:SetText(item.cells[i] or "") end
        row.sel:SetShown(item.selected == true)
        row:Show()
      else
        row:Hide()
      end
    end
    if #self.data > numRows then
      self.info:SetText(("%d-%d of %d (scroll for more)"):format(
        self.offset + 1, math.min(self.offset + numRows, #self.data), #self.data))
    else
      self.info:SetText(#self.data == 0 and (self.emptyText or "") or "")
    end
  end

  return t
end

local function SortRows(rows, key, desc)
  table.sort(rows, function(a, b)
    local x, y = a.sort[key], b.sort[key]
    if x == y then return a.sort.name < b.sort.name end
    if desc then return x > y end
    return x < y
  end)
end

-- Shared with the other UI files.
ns.UI = {
  Panel = Panel, Button = Button, Text = Text, CreateTable = CreateTable,
  ItemName = ItemName, SortRows = SortRows, GetItemIcon = GetItemIcon,
  Percent = Percent, InsertItemLink = InsertItemLink,
}

-- Main window ----------------------------------------------------------------------------

local main
local stack = {} -- open views on top of the current tab: { kind =, arg =, title = }

local TABS = { "prices", "recipes", "watch", "data" }
local TAB_TITLES = { prices = "Prices", recipes = "Professions", watch = "Watch", data = "Data" }

local function PriceRows()
  local rows, filter = {}, main.filter:GetText():lower()
  for _, id in ipairs(main.focusedList and ns.focusItems or ns.items) do
    local colored, name = ItemName(id)
    if filter == "" or name:lower():find(filter, 1, true) then
      local st = ns:GetStats(id, 7)
      local r = st and st.latest
      local ratio = st and st.median and r.min > 0 and r.min / st.median or nil
      local sold, soldVia = ns:SoldPerDay(id)
      rows[#rows + 1] = {
        id = id,
        icon = GetItemIcon(id),
        sort = {
          name = name,
          min = r and r.min or 0,
          median = st and st.median or 0,
          ratio = ratio or 99,
          qty = r and r.qty or -1,
          sold = sold or -1,
          age = r and -r.t or 0,
        },
        cells = {
          (ns:IsFocus(id) and "|cff33ccff[W]|r " or "")
            .. (not main.focusedList and ns:IsFocusScan(id) and "|cffffaa33[F]|r " or "") .. colored,
          r and ns.Money(r.min) or "-",
          st and ns.Money(st.median) or "-",
          Percent(ratio),
          r and r.qty or "-",
          ns.SoldText(sold, soldVia),
          r and ns.Age(r.t) or "never",
        },
      }
    end
  end
  SortRows(rows, main.sortKey, main.sortDesc)
  return rows
end

local EVENT_TEXT = {
  buy = function(e)
    local walk = e.levels > 1 and (" up to %s, %d levels"):format(ns.Money(e.high), e.levels) or ""
    return ("|cff40ff40bought %d|r at %s%s, avg %s"):format(e.qty, ns.Money(e.low), walk, ns.Money(e.vwap))
  end,
  listed = function(e) return ("|cff80c0fflisted %d|r from %s"):format(e.qty, ns.Money(e.low)) end,
  removed = function(e) return ("|cffaaaaaacancelled/expired %d|r (not from the bottom)"):format(e.qty) end,
  expired = function(e) return ("|cffaaaaaaexpired %d|r"):format(e.qty) end,
  repost = function(e) return ("|cffffcc66reposted %d|r (seller undercut)"):format(e.qty) end,
}
ns.UI.EVENT_TEXT = EVENT_TEXT

local function WatchRows()
  local rows = {}
  for _, id in ipairs(ns.db.settings.focus) do
    local colored = ItemName(id)
    local s = ns:WatchSummary(id)
    local last = s.lastBuy
    rows[#rows + 1] = {
      id = id,
      icon = GetItemIcon(id),
      selected = id == main.selected,
      cells = {
        colored,
        s.best and ns.Money(s.best) or "-",
        s.depth or "-",
        s.buysPerHour and ("%.1f"):format(s.buysPerHour) or "-",
        s.unitsPerHour and ("%d"):format(s.unitsPerHour + 0.5) or "-",
        last and ("%d, %d lvl%s, %s ago"):format(last.qty, last.levels, last.levels > 1 and "s" or "", ns.Age(last.t)) or "-",
        s.polled and ns.Age(s.polled) or "-",
      },
    }
  end
  return rows
end

local function RefreshWatchDetail()
  local d = main.detail
  local id = main.selected
  local shown = id and ns:IsFocus(id)
  d.open:SetShown(shown)
  if not shown then
    d.title:SetText("Click an item above to see its order book and activity.")
    for _, col in ipairs(d.book) do col:SetText("") end
    d.activity:SetText("")
    return
  end
  local book = ns.books[id]
  d.title:SetText((ItemName(id)))
  local cols = { { "Price" }, { "Qty" }, { "Cum. qty" }, { "Avg if you buy all" } }
  if book then
    local cumQty, cumCost = 0, 0
    for i = 1, math.min(BOOK_LINES, #book.levels) do
      local level = book.levels[i]
      cumQty = cumQty + level.qty
      cumCost = cumCost + level.qty * level.price
      cols[1][#cols[1] + 1] = ns.Money(level.price)
      cols[2][#cols[2] + 1] = level.qty
      cols[3][#cols[3] + 1] = cumQty
      cols[4][#cols[4] + 1] = ns.Money(math.floor(cumCost / cumQty + 0.5))
    end
    if #book.levels == 0 then cols[1][2] = "nothing listed" end
  else
    cols[1][2] = "not polled yet"
  end
  for i, col in ipairs(d.book) do col:SetText(table.concat(cols[i], "\n")) end

  local lines, events = {}, ns.activity[id] or {}
  for i = #events, math.max(1, #events - BOOK_LINES + 1), -1 do
    local e = events[i]
    lines[#lines + 1] = date("%H:%M", e.t) .. "  " .. EVENT_TEXT[e.kind](e)
  end
  d.activity:SetText(#lines > 0 and table.concat(lines, "\n") or "|cffaaaaaaNo changes seen yet.|r")
end

local function Refresh()
  if not (main and main:IsShown()) then return end
  ns.dirty = false
  local top = stack[#stack]
  if top then
    main.views[top.kind].refresh()
  elseif main.tab == "prices" then
    main.listSwitch:SetText(main.focusedList and ("Focused list (%d)"):format(#ns.focusItems)
      or ("Full scan list (%d)"):format(#ns.items))
    main.clearFocused:SetShown(main.focusedList == true)
    main.prices.emptyText = main.focusedList and "The focused scan list is empty, or no items match." or "No items match."
    main.prices:SetData(PriceRows())
  elseif main.tab == "recipes" then
    main.refreshRecipes()
  elseif main.tab == "data" then
    main.refreshData()
  else
    main.watch:SetData(WatchRows())
    main.interval:SetText(("Poll every %ds"):format(ns.db.settings.watchInterval))
    RefreshWatchDetail()
  end
end

-- Shows the current tab, or the view on top of the stack, and the breadcrumb.
local function ShowContent()
  local top = stack[#stack]
  for _, tab in ipairs(TABS) do
    main.pages[tab]:SetShown(not top and tab == main.tab)
    if tab == main.tab then main.tabs[tab]:LockHighlight() else main.tabs[tab]:UnlockHighlight() end
  end
  for kind, view in pairs(main.views) do
    view.frame:SetShown(top ~= nil and top.kind == kind)
  end
  main.back:SetShown(top ~= nil)
  local parts = { TAB_TITLES[main.tab] }
  for _, entry in ipairs(stack) do parts[#parts + 1] = entry.title end
  main.crumb:SetText(top and table.concat(parts, "  >  ") or "")
  if top then main.views[top.kind].show(top.arg) end
  Refresh()
end

local function SelectTab(name)
  main.tab = name
  wipe(stack)
  ShowContent()
end

local function OpenView(kind, arg, title)
  if not main then ns:ToggleWindow() end
  main:Show()
  local top = stack[#stack]
  if not (top and top.kind == kind and top.arg == arg) then
    if #stack >= MAX_STACK then table.remove(stack, 1) end
    stack[#stack + 1] = { kind = kind, arg = arg, title = title }
  end
  ShowContent()
end

function ns:OpenItem(id)
  local _, name = ItemName(id)
  OpenView("item", id, name)
end

-- A Waylaid Crate from TradeData.lua, by its index in ns.TRADE.crates.
function ns:OpenCrate(index)
  local crate = self.TRADE.crates[index]
  if crate then OpenView("crate", index, crate[2] .. " crate") end
end

function ns:OpenRecipe(recipe)
  if recipe.gathered then return self:OpenItem(recipe.item) end
  OpenView("recipe", recipe, self:RecipeName(recipe))
end

local function Back()
  table.remove(stack)
  ShowContent()
end

local function StatusText()
  local s = ns:ScanStatus() or ns:WatchStatus()
  if s then return s end
  if not ns.ahOpen then return "|cffaaaaaaOpen the auction house to scan or watch.|r" end
  local last = ns.lastScan[ns.ahKey]
  return last and ("Last scan " .. ns.Age(last) .. " ago") or "No scans yet on " .. ns.ahKey
end

-- Enables/disables scan and watch buttons and keeps their labels current.
local function UpdateControls(scanButtons, watchBtn)
  local busy = ns:IsScanning()
  for _, b in ipairs(scanButtons) do b:SetEnabled(ns.ahOpen and not busy) end
  watchBtn:SetEnabled(ns.ahOpen or ns:IsWatching()) -- a paused watch can be stopped with the AH closed
  watchBtn:SetText(ns:IsWatching() and "Stop watch" or "Start watch")
end

local SCAN_TIPS = {
  full = "Every item on the scan list (reagents, trade company items, and what you added; see the Data tab).",
  focused = "Only the items on the focused scan list, which you fill yourself: \"Focus recipes\" on the "
    .. "Professions tab, \"Focused scan\" on an item or recipe, or /pscan fadd. The Prices tab can show it.",
  quick = "Quick: lowest price and quantity listed, about 50 items per request.",
  deep = "Deep: a quick scan, then each commodity's cheapest price levels (one request per item, slower). "
    .. "Crafting costs for more than a few crafts need these.",
}
function ns.UI.ScanButtonTooltip(btn, deep, focused)
  btn:SetMotionScriptsWhileDisabled(true)
  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(ns:ScanName(deep, focused))
    local n = focused and #ns.focusItems or #ns.items
    GameTooltip:AddLine(("%d items. %s"):format(n, focused and SCAN_TIPS.focused or SCAN_TIPS.full), 1, 1, 1, true)
    GameTooltip:AddLine(deep and SCAN_TIPS.deep or SCAN_TIPS.quick, 0.8, 0.8, 0.8, true)
    if not ns.ahOpen then GameTooltip:AddLine("Open the auction house first.", 1, 0.4, 0.4) end
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", GameTooltip_Hide)
end

local function CreatePricesPage(page)
  local hint = Text(page, "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", 4, -4)
  hint:SetText("Click: details   Right-click: watch/unwatch   Ctrl-right-click: remove from this list   Shift-click: link")
  main.filter = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
  main.filter:SetSize(140, 18)
  main.filter:SetPoint("TOPRIGHT", -4, 0)
  main.filter:SetAutoFocus(false)
  main.filter:SetScript("OnTextChanged", Refresh)
  main.filter:SetScript("OnEscapePressed", main.filter.ClearFocus)
  local filterLabel = Text(page, "GameFontNormalSmall")
  filterLabel:SetPoint("RIGHT", main.filter, "LEFT", -8, 0)
  filterLabel:SetText("Filter")
  local clearFocused = Button(page, "Clear...", 64, function() ns:ConfirmClearFocusScan() end)
  clearFocused:SetPoint("RIGHT", filterLabel, "LEFT", -12, 0)
  main.listSwitch = Button(page, "", 150, function()
    main.focusedList = not main.focusedList
    Refresh()
  end)
  main.listSwitch:SetPoint("RIGHT", clearFocused, "LEFT", -4, 0)
  main.listSwitch:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Which list to show")
    GameTooltip:AddLine("Full scan list: everything Full scan covers. Focused list: the items you picked for "
      .. "Focused scan (\"Focus recipes\" on the Professions tab, \"Focused scan\" on an item or recipe, "
      .. "/pscan fadd). Items on the focused list show [F] on the full list.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  main.listSwitch:SetScript("OnLeave", GameTooltip_Hide)
  main.clearFocused = clearFocused

  main.sortKey, main.sortDesc = "name", false
  main.prices = CreateTable(page, {
    { title = "Item", width = 270, key = "name" },
    { title = "Lowest", width = 95, justify = "RIGHT", key = "min" },
    { title = "7-day median", width = 95, justify = "RIGHT", key = "median" },
    { title = "vs median", width = 75, justify = "RIGHT", key = "ratio" },
    { title = "Listed", width = 65, justify = "RIGHT", key = "qty" },
    { title = "Sold/day", width = 65, justify = "RIGHT", key = "sold" },
    { title = "Scanned", width = 70, justify = "RIGHT", key = "age" },
  }, PRICE_ROWS)
  main.prices:SetPoint("TOPLEFT", 0, -24)
  main.prices.emptyText = "No items match."
  main.prices.onSort = function(key)
    if main.sortKey == key then main.sortDesc = not main.sortDesc else main.sortKey, main.sortDesc = key, false end
    Refresh()
  end
  main.prices.onClick = function(item, button)
    if button == "RightButton" and IsControlKeyDown() then
      if main.focusedList then ns:RemoveFromFocusScan(item.id) else ns:RemoveFromScanList(item.id) end
    elseif button == "RightButton" then
      ns:ToggleFocus(item.id)
    elseif IsModifiedClick("CHATLINK") then
      InsertItemLink(item.id)
    else
      ns:OpenItem(item.id)
    end
  end
end

local function CreateWatchPage(page)
  local hint = Text(page, "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", 4, -4)
  hint:SetText("Add: right-click on Prices, or from a recipe. Right-click here: remove.")
  local faster = Button(page, "-", 24, function()
    ns.db.settings.watchInterval = math.max(15, ns.db.settings.watchInterval - 15)
    Refresh()
  end)
  local slower = Button(page, "+", 24, function()
    ns.db.settings.watchInterval = math.min(600, ns.db.settings.watchInterval + 15)
    Refresh()
  end)
  slower:SetPoint("TOPRIGHT", -4, 0)
  faster:SetPoint("RIGHT", slower, "LEFT", -2, 0)
  main.interval = Text(page, "GameFontNormalSmall", "RIGHT")
  main.interval:SetPoint("RIGHT", faster, "LEFT", -6, 0)
  local clear = Button(page, "Clear list", 80, function() ns:ConfirmClearFocus() end)
  clear:SetPoint("RIGHT", main.interval, "LEFT", -12, 0)

  main.watch = CreateTable(page, {
    { title = "Item", width = 210 },
    { title = "Best price", width = 95, justify = "RIGHT" },
    { title = "Depth 10%", width = 75, justify = "RIGHT" },
    { title = "Buys/h", width = 60, justify = "RIGHT" },
    { title = "Units/h", width = 65, justify = "RIGHT" },
    { title = "Last purchase", width = 185 },
    { title = "Polled", width = 60, justify = "RIGHT" },
  }, WATCH_ROWS)
  main.watch:SetPoint("TOPLEFT", 0, -24)
  main.watch.emptyText = "The watch list is empty."
  main.watch.onClick = function(item, button)
    if button == "RightButton" then
      ns:ToggleFocus(item.id)
    else
      main.selected = item.id
      Refresh()
    end
  end

  local d = CreateFrame("Frame", nil, page)
  d:SetPoint("TOPLEFT", main.watch, "BOTTOMLEFT", 0, -6)
  d:SetPoint("BOTTOMRIGHT")
  main.detail = d
  d.title = Text(d, "GameFontNormal")
  d.title:SetPoint("TOPLEFT", 4, 0)
  d.open = Button(d, "Item details", 110, function() if main.selected then ns:OpenItem(main.selected) end end)
  d.open:SetPoint("TOPRIGHT", -4, 4)
  d.book = {}
  local widths = { 80, 50, 65, 110 }
  local x = 4
  for i, width in ipairs(widths) do
    local col = Text(d, nil, i == 1 and "LEFT" or "RIGHT")
    col:SetPoint("TOPLEFT", x, -22)
    col:SetWidth(width)
    col:SetJustifyV("TOP")
    d.book[i] = col
    x = x + width + 6
  end
  d.activity = Text(d)
  d.activity:SetPoint("TOPLEFT", x + 14, -22)
  d.activity:SetPoint("RIGHT", -4, 0)
  d.activity:SetJustifyV("TOP")
  d.activity:SetWordWrap(false)
end

local function CreateMain()
  main = Panel("ProfScanFrame", UIParent, WIDTH, HEIGHT)
  main:SetPoint("CENTER")
  main:SetFrameStrata("HIGH")
  main:SetClampedToScreen(true)
  main:SetMovable(true)
  main:EnableMouse(true)
  main:RegisterForDrag("LeftButton")
  main:SetScript("OnDragStart", main.StartMoving)
  main:SetScript("OnDragStop", main.StopMovingOrSizing)
  main:Hide()
  tinsert(UISpecialFrames, "ProfScanFrame") -- Escape closes it

  local title = Text(main, "GameFontNormal")
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText("ProfScan")
  local close = CreateFrame("Button", nil, main, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  main.tabs = {}
  local prev
  for _, name in ipairs(TABS) do
    local b = Button(main, TAB_TITLES[name], 92, function() SelectTab(name) end)
    if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 12, -30) end
    main.tabs[name], prev = b, b
  end
  main.back = Button(main, "< Back", 70, Back)
  main.back:SetPoint("LEFT", prev, "RIGHT", 16, 0)
  main.crumb = Text(main, "GameFontNormalSmall")
  main.crumb:SetPoint("LEFT", main.back, "RIGHT", 8, 0)
  main.crumb:SetPoint("RIGHT", main, "RIGHT", -14, 0)
  main.crumb:SetWordWrap(false)

  local function Content()
    local f = CreateFrame("Frame", nil, main)
    f:SetPoint("TOPLEFT", 12, -58)
    f:SetPoint("BOTTOMRIGHT", -12, 40)
    f:Hide()
    return f
  end
  main.pages = {}
  for _, name in ipairs(TABS) do main.pages[name] = Content() end

  CreatePricesPage(main.pages.prices)
  main.refreshRecipes = ns.UI.BuildRecipesPage(main.pages.recipes)
  CreateWatchPage(main.pages.watch)
  main.refreshData = ns.UI.BuildDataPage(main.pages.data)

  main.views = {}
  for kind, build in pairs({ recipe = ns.UI.BuildRecipeView, item = ns.UI.BuildItemView,
                             crate = ns.UI.BuildCrateView }) do
    local frame = Content()
    local view = build(frame)
    view.frame = frame
    main.views[kind] = view
  end

  -- Bottom bar
  main.status = Text(main)
  main.status:SetPoint("BOTTOMLEFT", 16, 16)
  local watchBtn = Button(main, "Start watch", 100, function() ns:ToggleWatch() end)
  watchBtn:SetPoint("BOTTOMRIGHT", -12, 10)
  local scanButtons = {}
  local anchor = watchBtn
  for _, b in ipairs({ -- right to left
    { "Focused deep", true, true }, { "Focused quick", false, true },
    { "Full deep", true, false }, { "Full quick", false, false },
  }) do
    local btn = Button(main, b[1], 104, function() ns:StartScan(b[2], b[3]) end)
    btn:SetPoint("RIGHT", anchor, "LEFT", anchor == watchBtn and -12 or -4, 0)
    ns.UI.ScanButtonTooltip(btn, b[2], b[3])
    scanButtons[#scanButtons + 1], anchor = btn, btn
  end

  local elapsed = 0
  main:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 0.5 then return end
    elapsed = 0
    main.status:SetText(StatusText())
    UpdateControls(scanButtons, watchBtn)
    -- the watch tab shows ages and live activity, so keep it ticking
    if ns.dirty or (#stack == 0 and main.tab == "watch") then Refresh() end
  end)
  main:SetScript("OnShow", Refresh)

  main.tab = "prices"
  ShowContent()
end

function ns:ToggleWindow()
  if not main then CreateMain() end
  main:SetShown(not main:IsShown())
end

-- Global entry point for the addon compartment button (see ProfScan.toc).
function ProfScan_OnCompartmentClick()
  ns:ToggleWindow()
end

-- Auction house panel ---------------------------------------------------------------------

local ahPanel

local function CreateAHPanel()
  local host = AuctionHouseFrame or AuctionFrame
  if not host then return end
  ahPanel = Panel(nil, host, 186, 284)
  ahPanel:SetPoint("TOPLEFT", host, "TOPRIGHT", 2, 0)
  ahPanel:SetClampedToScreen(true)

  local title = Text(ahPanel, "GameFontNormal")
  title:SetPoint("TOP", 0, -10)
  title:SetText("ProfScan")

  local scanButtons, prev = {}, nil
  for _, b in ipairs({
    { "Full scan (quick)", false, false }, { "Full scan (deep)", true, false },
    { "Focused scan (quick)", false, true }, { "Focused scan (deep)", true, true },
  }) do
    local btn = Button(ahPanel, b[1], 162, function() ns:StartScan(b[2], b[3]) end)
    if prev then btn:SetPoint("TOP", prev, "BOTTOM", 0, b[3] and not scanButtons[3] and -10 or -4)
    else btn:SetPoint("TOP", 0, -30) end
    ns.UI.ScanButtonTooltip(btn, b[2], b[3])
    scanButtons[#scanButtons + 1], prev = btn, btn
  end
  local deBtn = Button(ahPanel, "Disenchant scan", 162, function() ns:StartScan(true, "disenchant") end)
  deBtn:SetPoint("TOP", prev, "BOTTOM", 0, -10)
  deBtn:SetMotionScriptsWhileDisabled(true)
  deBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Disenchant scan")
    GameTooltip:AddLine("Every listed uncommon, rare and epic weapon and armor piece, plus the enchanting "
      .. "materials. Results: Professions tab, Disenchanting.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  deBtn:SetScript("OnLeave", GameTooltip_Hide)
  scanButtons[#scanButtons + 1] = deBtn
  local watchBtn = Button(ahPanel, "Start watch", 162, function() ns:ToggleWatch() end)
  watchBtn:SetPoint("TOP", deBtn, "BOTTOM", 0, -10)
  local openBtn = Button(ahPanel, "Open window", 162, function() ns:ToggleWindow() end)
  openBtn:SetPoint("TOP", watchBtn, "BOTTOM", 0, -4)

  local status = Text(ahPanel)
  status:SetPoint("TOPLEFT", openBtn, "BOTTOMLEFT", 0, -8)
  status:SetWidth(162)
  status:SetJustifyV("TOP")

  local elapsed = 0
  ahPanel:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 0.25 then return end
    elapsed = 0
    status:SetText(StatusText())
    UpdateControls(scanButtons, watchBtn)
  end)
end

-- Called from Scanner.lua when the auction house opens.
function ns:OnAuctionHouseShow()
  if not ahPanel then CreateAHPanel() end
end

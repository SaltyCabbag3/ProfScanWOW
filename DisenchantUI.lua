local _, ns = ...

--[[
  Disenchanting pane (Professions tab, "Disenchanting" button): one row per
  disenchant band, the "recipes" of disenchanting (see Disenchant.lua).

    Listed      pieces of gear in the band on the auction house (newest Disenchant scan)
    Cheapest    the lowest price among them
    DE value    average worth of one disenchant (materials at their sell price)
    Margin      DE value - cheapest
    Deals       listed items priced below the DE value, and what buying one of
                each and disenchanting it would make in total

  Hover a row for what the band disenchants into and its cheapest listings.
  Click: the cheapest item. Shift-click: link it.
]]

local ROWS = 21

function ns.UI.BuildDisenchantPane(parent)
  local UI = ns.UI
  local state = { listedOnly = false, sortKey = "band", sortDesc = false }

  local frame = CreateFrame("Frame", nil, parent)
  frame:SetPoint("TOPLEFT", 134, 0)
  frame:SetPoint("BOTTOMRIGHT")
  frame:Hide()

  local refresh -- defined below
  local scanBtn = UI.Button(frame, "Disenchant scan", 130, function() ns:StartScan(true, "disenchant") end)
  scanBtn:SetPoint("TOPRIGHT", 0, 0)
  scanBtn:SetMotionScriptsWhileDisabled(true)
  scanBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Disenchant scan")
    GameTooltip:AddLine("Browses the auction house for every uncommon, rare and epic weapon and armor piece "
      .. "(lowest price and item level of each), then deep-scans the enchanting materials. Separate from the "
      .. "full and focused scans; each run replaces the previous one.", 1, 1, 1, true)
    if not ns.ahOpen then GameTooltip:AddLine("Open the auction house first.", 1, 0.4, 0.4) end
    GameTooltip:Show()
  end)
  scanBtn:SetScript("OnLeave", GameTooltip_Hide)

  local listed = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  listed:SetSize(22, 22)
  listed:SetPoint("RIGHT", scanBtn, "LEFT", -110, 0)
  listed:SetScript("OnClick", function(self)
    state.listedOnly = self:GetChecked() and true or false
    refresh()
  end)
  local listedLabel = UI.Text(frame, "GameFontNormalSmall")
  listedLabel:SetPoint("LEFT", listed, "RIGHT", 2, 0)
  listedLabel:SetText("Listed only")

  local status = UI.Text(frame)
  status:SetPoint("TOPLEFT", 2, -4)
  status:SetPoint("RIGHT", listed, "LEFT", -8, 0)
  status:SetWordWrap(false)

  local list = UI.CreateTable(frame, {
    { title = "Disenchant band (item level)", width = 230, key = "band" },
    { title = "Listed", width = 54, justify = "RIGHT", key = "listed" },
    { title = "Cheapest", width = 92, justify = "RIGHT", key = "cheapest" },
    { title = "DE value", width = 92, justify = "RIGHT", key = "value" },
    { title = "Margin", width = 92, justify = "RIGHT", key = "margin" },
    { title = "Deals", width = 50, justify = "RIGHT", key = "deals" },
    { title = "Deal profit", width = 92, justify = "RIGHT", key = "profit" },
    { title = "Mostly gives", width = 110, key = "gives" },
  }, ROWS)
  list:SetPoint("TOPLEFT", 0, -26)
  list.onSort = function(key)
    if state.sortKey == key then state.sortDesc = not state.sortDesc
    else state.sortKey, state.sortDesc = key, key ~= "band" end
    refresh()
  end
  list.onClick = function(row, button)
    local cheapest = row.de.items[1]
    if not cheapest then return end
    if IsModifiedClick("CHATLINK") then UI.InsertItemLink(cheapest.id) else ns:OpenItem(cheapest.id) end
  end

  local help = UI.Text(frame, "GameFontDisableSmall")
  help:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 2, -2)
  help:SetPoint("RIGHT", frame, "RIGHT")
  help:SetJustifyV("TOP")
  help:SetText("Yields are Classic's tables by item level (Forever keeps the same bands); "
    .. "~ = level 61+ gear, assumed to give what 61-65 gives. Materials are valued at what they sell for "
    .. "(AH after the 5% cut). Hover a band for details; click it to open its cheapest item.")

  local function MainMaterial(band)
    local best
    for _, y in ipairs(band.yields) do
      if not best or y[2] > best[2] then best = y end
    end
    return best and select(2, UI.ItemName(best[1])) or "-"
  end

  local function Tooltip(de, value, deals, profit)
    local band = de.band
    local lines = { "|cffffd100Disenchants into (average per item):|r" }
    for _, l in ipairs(de.valueLines) do lines[#lines + 1] = "  " .. l end
    lines[#lines + 1] = ("Average value: %s%s"):format(ns.Money(value),
      de.complete and "" or "  |cffff8080(some materials not priced: run the Disenchant scan)|r")
    if band.assumed then
      lines[#lines + 1] = "|cffaaaaaaLevel 61+ gear: Classic only lists 61-65; higher items are assumed to give the same.|r"
    end
    if #de.items > 0 then
      lines[#lines + 1] = ("|cffffd100Cheapest listed (%d items, %d below value, %s to make buying one of each):|r"):format(
        #de.items, deals, ns.Money(profit))
      for i = 1, math.min(10, #de.items) do
        local it = de.items[i]
        local m = value - it.price
        lines[#lines + 1] = ("  %s  (ilvl %s)  %s  %s"):format(UI.ItemName(it.id), it.ilvl or "?", ns.Money(it.price),
          m > 0 and ("|cff40ff40+" .. ns.Money(m) .. "|r") or ("|cffff8080-" .. ns.Money(-m) .. "|r"))
      end
      if #de.items > 10 then lines[#lines + 1] = ("  ... and %d more"):format(#de.items - 10) end
    else
      lines[#lines + 1] = "|cffaaaaaaNothing listed in this band (as of the last Disenchant scan).|r"
    end
    return lines
  end

  refresh = function()
    scanBtn:SetEnabled(ns.ahOpen and not ns:IsScanning())
    listed:SetChecked(state.listedOnly)
    local snap = ns:DisenchantSnapshot()
    if snap then
      local n = 0
      for _ in pairs(snap.items) do n = n + 1 end
      status:SetText(("Last Disenchant scan %s ago: %d pieces of gear listed%s"):format(ns.Age(snap.t), n,
        snap.partial and "  |cffff8080(stopped early, incomplete)|r" or ""))
    else
      status:SetText("|cffaaaaaaNo Disenchant scan on this auction house yet: open it and press Disenchant scan.|r")
    end

    local rows = {}
    for i, de in ipairs(ns:DisenchantRows()) do
      if not state.listedOnly or #de.items > 0 then
        local value = de.value
        local cheapest = de.items[1]
        local margin = cheapest and value > 0 and value - cheapest.price
        local deals, profit = 0, 0
        for _, it in ipairs(de.items) do
          if it.price < value then deals, profit = deals + 1, profit + value - it.price end
        end
        local tilde = de.band.assumed and "~" or ""
        rows[#rows + 1] = {
          de = de,
          icon = cheapest and UI.GetItemIcon(cheapest.id) or nil,
          tooltipTitle = de.band.label,
          tooltipLines = Tooltip(de, value, deals, profit),
          sort = {
            name = i, band = i, listed = #de.items, -- name: SortRows' tie-breaker cheapest = cheapest and cheapest.price or 1e12,
            value = value, margin = margin or -1e12, deals = deals, profit = profit, gives = MainMaterial(de.band),
          },
          cells = {
            de.band.label,
            #de.items > 0 and #de.items or "-",
            cheapest and ns.Money(cheapest.price) or "-",
            value > 0 and (tilde .. ns.Money(value) .. (de.complete and "" or "|cffff8080*|r")) or "?",
            margin and ns.SignedMoney(margin) or "-",
            deals > 0 and ("|cff40ff40%d|r"):format(deals) or "-",
            profit > 0 and ("|cff40ff40" .. ns.Money(profit) .. "|r") or "-",
            MainMaterial(de.band),
          },
        }
      end
    end
    list.emptyText = state.listedOnly and "Nothing listed yet: run the Disenchant scan." or "No disenchant bands."
    UI.SortRows(rows, state.sortKey, state.sortDesc)
    list:SetData(rows)
  end

  return { frame = frame, refresh = refresh }
end

-- A small "what does this disenchant into" table for the item and recipe views:
-- header (average value), the band, then one row per material (chance, count, value).
-- box:SetItem(id, perCraft) fills it and shows it; returns false (and hides) when the
-- item doesn't disenchant. perCraft = items one craft makes (recipe view).
function ns.UI.CreateDisenchantBox(parent, width)
  local UI = ns.UI
  local box = CreateFrame("Frame", nil, parent)
  box:SetSize(width, 150)
  local header = UI.Text(box, "GameFontNormal")
  header:SetPoint("TOPLEFT", 0, 0)
  header:SetWidth(width)
  local sub = UI.Text(box, "GameFontDisableSmall")
  sub:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
  sub:SetWidth(width)
  local list = UI.CreateTable(box, {
    { title = "Disenchants into", width = width - 158 },
    { title = "Chance", width = 46, justify = "RIGHT" },
    { title = "Count", width = 40, justify = "RIGHT" },
    { title = "Value", width = 72, justify = "RIGHT" },
  }, 3)
  list:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -4)
  list.onClick = function(row)
    if IsModifiedClick("CHATLINK") then UI.InsertItemLink(row.id) else ns:OpenItem(row.id) end
  end

  function box:SetItem(id, perCraft)
    local value, complete, band = ns:DisenchantItemValue(id)
    if not band then
      self:Hide()
      return false
    end
    header:SetText(("Disenchant: %s%s average per item%s"):format(band.assumed and "~" or "", ns.Money(value),
      complete and "" or " |cffff8080*|r"))
    local extra = perCraft and perCraft ~= 1
      and ("   x %g per craft = %s"):format(perCraft, ns.Money(math.floor(value * perCraft + 0.5))) or ""
    sub:SetText(band.label .. extra .. (band.assumed and "   |cffaaaaaa(61-65 yields assumed)|r" or ""))
    local rows = {}
    for _, y in ipairs(band.yields) do
      local item, chance, lo, hi = y[1], y[2], y[3], y[4]
      local unit = ns:SellPrice(item)
      local name = UI.ItemName(item)
      rows[#rows + 1] = {
        id = item,
        icon = UI.GetItemIcon(item),
        tooltipLines = { unit and ("Sells for %s each (AH after the cut, or a vendor)"):format(ns.Money(unit))
          or "No price yet: run the Disenchant scan" },
        cells = {
          name,
          ("%g%%"):format(chance * 100),
          lo == hi and tostring(lo) or (lo .. "-" .. hi),
          unit and ns.Money(math.floor(chance * (lo + hi) / 2 * unit + 0.5)) or "|cffff8080?|r",
        },
      }
    end
    list:SetData(rows)
    self:Show()
    return true
  end

  return box
end

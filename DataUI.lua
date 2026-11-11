local _, ns = ...

--[[
  Data tab: what ProfScan has stored in game, the manual trim, and how to get
  the data into the external database (tools/profscan_db.py).
]]

local function Oldest(lines)
  local oldest
  for _, line in ipairs(lines) do
    local t = tonumber(line:match("^[^,]*,(%d+),"))
    if t and (not oldest or t < oldest) then oldest = t end
  end
  return oldest
end

local function OldestDay(lines)
  local oldest
  for _, line in ipairs(lines) do
    local day = tonumber(line:match("^[^,]*,(%d+),"))
    if day and (not oldest or day < oldest) then oldest = day end
  end
  return oldest and oldest * ns.DAY
end

local function ImportedLine()
  local imp = ns.IMPORTED
  if not (imp and imp.ah) then return "Blizzard API prices: none imported (see right)" end
  local n = 0
  for _ in pairs(imp.scans or {}) do n = n + 1 end
  return ("Blizzard API prices: %d items for %s, exported %s ago"):format(n, imp.ah, ns.Age(imp.generated))
end

local function Since(t)
  return t and ("  |cffaaaaaa(since %s)|r"):format(date("%d %b %Y", t)) or ""
end

function ns.UI.BuildDataPage(page)
  local UI = ns.UI

  local stored = UI.Text(page)
  stored:SetPoint("TOPLEFT", 4, -4)
  stored:SetWidth(360)
  stored:SetJustifyV("TOP")

  -- Scan list contents --------------------------------------------------------------------
  local listTitle = UI.Text(page, "GameFontNormal")
  listTitle:SetPoint("TOPLEFT", 4, -130)
  listTitle:SetText("Scan list includes")
  local parts = {
    { "reagents", "scanReagents", "Every reagent of every recipe, plus herbs and fish" },
    { "trade", "scanTrade", "Trade company: crates, sealed writs, crate fills, writ items" },
    { "products", "scanProducts", "Every crafted product (~1,200 more items, mostly gear)" },
  }
  local checks = {}
  for i, part in ipairs(parts) do
    local box = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
    box:SetSize(22, 22)
    box:SetPoint("TOPLEFT", 0, -144 - (i - 1) * 20)
    box:SetScript("OnClick", function(self) ns:SetScanPart(part[1], self:GetChecked()) end)
    local label = UI.Text(page, "GameFontHighlightSmall")
    label:SetPoint("LEFT", box, "RIGHT", 2, 0)
    label:SetText(part[3])
    checks[i] = { box = box, key = part[2] }
  end

  -- Trim ---------------------------------------------------------------------------------
  local trimTitle = UI.Text(page, "GameFontNormal")
  trimTitle:SetPoint("TOPLEFT", 4, -214)
  trimTitle:SetText("Trim old data")
  local trimHelp = UI.Text(page)
  trimHelp:SetPoint("TOPLEFT", trimTitle, "BOTTOMLEFT", 0, -6)
  trimHelp:SetWidth(360)
  trimHelp:SetJustifyV("TOP")
  trimHelp:SetText("Folds everything older than the given age into one summary per item and day "
    .. "(lowest price range, average quantity, purchases seen) and removes the raw records. "
    .. "Charts and statistics keep working from the summaries. Nothing is ever trimmed automatically.")

  local daysLabel = UI.Text(page, "GameFontNormalSmall")
  daysLabel:SetPoint("TOPLEFT", trimHelp, "BOTTOMLEFT", 0, -14)
  daysLabel:SetText("Older than")
  local days = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
  days:SetSize(40, 18)
  days:SetPoint("LEFT", daysLabel, "RIGHT", 10, 0)
  days:SetAutoFocus(false)
  days:SetNumeric(true)
  days:SetScript("OnEscapePressed", days.ClearFocus)
  local daysUnit = UI.Text(page, "GameFontNormalSmall")
  daysUnit:SetPoint("LEFT", days, "RIGHT", 6, 0)
  daysUnit:SetText("days")

  local preview = UI.Text(page)
  preview:SetPoint("TOPLEFT", daysLabel, "BOTTOMLEFT", 0, -36)
  preview:SetWidth(360)
  preview:SetJustifyV("TOP")

  local function Days()
    local n = tonumber(days:GetText())
    if n and n >= 1 then
      ns.db.settings.trimDays = n
      return n
    end
  end
  local previewBtn = UI.Button(page, "Preview", 80, function()
    local n = Days()
    if not n then return end
    local r = ns:Trim(n, true)
    preview:SetText(("Older than %d days: %d scan records, %d watch events, %d watch polls -> %d daily summaries."):format(
      n, r.scans, r.events, r.polls, r.days))
  end)
  previewBtn:SetPoint("TOPLEFT", daysLabel, "BOTTOMLEFT", 0, -8)
  local trimBtn = UI.Button(page, "Trim...", 80, function()
    local n = Days()
    if n then ns:ConfirmTrim(n) end
  end)
  trimBtn:SetPoint("LEFT", previewBtn, "RIGHT", 4, 0)

  -- External database --------------------------------------------------------------------
  local dbTitle = UI.Text(page, "GameFontNormal")
  dbTitle:SetPoint("TOPLEFT", 390, -4)
  dbTitle:SetText("External database")
  local dbHelp = UI.Text(page)
  dbHelp:SetPoint("TOPLEFT", dbTitle, "BOTTOMLEFT", 0, -6)
  dbHelp:SetWidth(360)
  dbHelp:SetJustifyV("TOP")
  dbHelp:SetText(table.concat({
    "The game writes ProfScan's data to disk only on /reload, logout or exit:",
    "WTF\\Account\\<account>\\SavedVariables\\ProfScan.lua",
    "",
    "tools\\profscan_db.py (in the ProfScan addon folder) keeps a permanent SQLite",
    "database built from it. From that folder:",
    "",
    "|cffffffffpython profscan_db.py import <ProfScan.lua>|r",
    "     add new data (safe to repeat; nothing is duplicated)",
    "|cffffffffpython profscan_db.py info|r      what the database holds",
    "|cffffffffpython profscan_db.py report|r    deals and watch-mode results",
    "|cffffffffpython profscan_db.py trim --older-than 90|r",
    "     fold old raw data into daily summaries (asks first)",
    "|cffffffffpython profscan_db.py merge <other.db>|r   combine databases",
    "|cffffffffpython profscan_db.py export <folder>|r    CSV files",
    "",
    "Blizzard API (hourly prices of the whole auction house):",
    "|cffffffffapi-setup|r, then |cffffffffapi-houses --match --apply|r once,",
    "then |cffffffffapi-fetch --loop 20|r and |cffffffffaddon-export|r + /reload.",
    "",
    "Import before trimming in game if you want the raw detail kept there.",
  }, "\n"))
  local reload = UI.Button(page, "Save to disk now (/reload)", 200, ReloadUI)
  reload:SetPoint("TOPLEFT", dbHelp, "BOTTOMLEFT", 0, -10)

  return function()
    local db = ns.db
    for _, c in ipairs(checks) do c.box:SetChecked(db.settings[c.key] == true) end
    if days:GetText() == "" then days:SetText(db.settings.trimDays) end
    local captured, vendor = 0, 0
    for _, recipes in pairs(db.captured) do
      for _ in pairs(recipes) do captured = captured + 1 end
    end
    for _ in pairs(db.vendor) do vendor = vendor + 1 end
    stored:SetText(table.concat({
      "|cffffd100Stored in game|r",
      ("Scan records: %d%s"):format(#db.log, Since(Oldest(db.log))),
      ("Daily summaries: %d%s"):format(#db.daily, Since(OldestDay(db.daily))),
      ("Watch polls: %d%s"):format(#db.watchLog, Since(Oldest(db.watchLog))),
      ("Watch events: %d%s"):format(#db.watchEvents, Since(Oldest(db.watchEvents))),
      ("Scan list: %d items    Watch list: %d items"):format(#ns.items, #db.settings.focus),
      ("Recipes read from profession windows: %d"):format(captured),
      ("Vendor prices learned: %d"):format(vendor),
      ImportedLine(),
    }, "\n"))
  end
end

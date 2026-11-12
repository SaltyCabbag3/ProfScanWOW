local _, ns = ...

--[[
  Storage (ProfScanDB). Lines are comma-separated strings; prices in copper.

    log          scan records    "ah,t,itemID,minPrice,qty,ladder"
                 (ladder = "price:qty/..." cheapest first, deep scans and watch polls;
                 watch mode writes its polls here too, see Watch.lua)
    watchLog     watch polls     see Watch.lua
    watchEvents  inferred events "ah,t,itemID,kind,qty,low,high,levels,avgPrice"
                 (kind = buy | listed | removed | expired | repost)
    coverage     [ah][itemID][day] = seconds that item was watched that day;
                 rates ("sold per day") divide by time watched, not by time
    daily        summaries       "ah,day,itemID,scans,minLow,minMedian,minHigh,qtyAvg,
                                  watchSeconds,buys,boughtUnits,listedUnits,removedUnits"
    day = whole UTC days since 1970, floor(t / 86400).

  Nothing is deleted automatically. ns:Trim(days) (the Data tab, or
  /pscan trim <days>) folds everything older than <days> into one daily line
  per item and day and removes the raw records, so long-term tendencies stay
  and the file stays small. Import into the external database
  (tools/profscan_db.py) before trimming if you want the raw detail there.
]]

ns.index = {}      -- [ah][itemID] = { { t, min, qty }, ... } scan records, oldest first
ns.dailyIndex = {} -- [ah][itemID] = { daily, ... } oldest first
ns.eventIndex = {} -- [ah][itemID] = { event, ... } oldest first
ns.lastScan = {}   -- [ah] = time of the newest scan record
ns.ladders = {}    -- [ah][itemID] = { t =, text = "price:qty/..." } newest price levels known

local DAY = 86400
ns.DAY = DAY

function ns.DayOf(t)
  return math.floor(t / DAY)
end

local function List(index, ah, id)
  local byItem = index[ah]
  if not byItem then
    byItem = {}
    index[ah] = byItem
  end
  local list = byItem[id]
  if not list then
    list = {}
    byItem[id] = list
  end
  return list
end

-- Parsing ------------------------------------------------------------------------------

local function ParseScan(line)
  local ah, t, id, min, qty, ladder = strsplit(",", line)
  return ah, { t = tonumber(t), id = tonumber(id), min = tonumber(min), qty = tonumber(qty) }, ladder
end

-- Remembers price levels (deep scans, watch polls, API) if they are the newest for the item.
function ns.SetLadder(ah, id, t, text)
  if not text or text == "" then return end
  local byItem = ns.ladders[ah]
  if not byItem then
    byItem = {}
    ns.ladders[ah] = byItem
  end
  local cur = byItem[id]
  if not cur or t >= cur.t then byItem[id] = { t = t, text = text } end
end

local function ParseEvent(line)
  local ah, t, id, kind, qty, low, high, levels, vwap = strsplit(",", line)
  return ah, {
    t = tonumber(t), id = tonumber(id), kind = kind, qty = tonumber(qty),
    low = tonumber(low), high = tonumber(high), levels = tonumber(levels), vwap = tonumber(vwap),
  }
end

local DAILY_FIELDS = { "scans", "low", "median", "high", "qty", "watchSec", "buys", "bought", "listed", "removed" }

local function ParseDaily(line)
  local fields = { strsplit(",", line) }
  local d = { day = tonumber(fields[2]), id = tonumber(fields[3]) }
  for i, name in ipairs(DAILY_FIELDS) do d[name] = tonumber(fields[i + 3]) or 0 end
  d.t = d.day * DAY + DAY / 2
  return fields[1], d
end

local function DailyLine(ah, d)
  local parts = { ah, d.day, d.id }
  for _, name in ipairs(DAILY_FIELDS) do parts[#parts + 1] = math.floor(d[name] + 0.5) end
  return table.concat(parts, ",")
end

-- Loading and adding -------------------------------------------------------------------

local function IndexScan(ah, r)
  local list = List(ns.index, ah, r.id)
  list[#list + 1] = r
  if r.t > (ns.lastScan[ah] or 0) then ns.lastScan[ah] = r.t end
end

-- Builds the in-memory indexes from the saved lines. Called at login and after a trim.
function ns:LoadData()
  wipe(self.index)
  wipe(self.dailyIndex)
  wipe(self.eventIndex)
  wipe(self.lastScan)
  wipe(self.ladders)
  for _, line in ipairs(self.db.log) do
    local ah, r, ladder = ParseScan(line)
    if r.t then
      IndexScan(ah, r)
      ns.SetLadder(ah, r.id, r.t, ladder)
    end
  end
  for _, line in ipairs(self.db.watchEvents) do
    local ah, e = ParseEvent(line)
    if e.t then
      local list = List(self.eventIndex, ah, e.id)
      list[#list + 1] = e
    end
  end
  for _, line in ipairs(self.db.daily) do
    local ah, d = ParseDaily(line)
    if d.day then
      local list = List(self.dailyIndex, ah, d.id)
      list[#list + 1] = d
    end
  end
  self:LoadImported()
  for _, byItem in pairs(self.dailyIndex) do
    for _, list in pairs(byItem) do table.sort(list, function(a, b) return a.day < b.day end) end
  end
  self:NotifyChanged()
end

-- Blizzard API prices from ImportedPrices.lua (tools/profscan_db.py addon-export):
-- hourly snapshots join the scan records, daily summaries fill days you have
-- no scans of your own for. Nothing of this is written to SavedVariables.
function ns:LoadImported()
  local imp = self.IMPORTED
  if not (imp and imp.ah) then return end
  for id, text in pairs(imp.scans or {}) do
    local list = List(self.index, imp.ah, id)
    for t, min, qty in text:gmatch("(%d+),(%d+),(%d+)") do
      list[#list + 1] = { t = tonumber(t), id = id, min = tonumber(min), qty = tonumber(qty), imported = true }
    end
    table.sort(list, function(a, b) return a.t < b.t end)
  end
  for id, text in pairs(imp.ladders or {}) do -- "time;price:qty/price:qty/..."
    local t, levels = text:match("^(%d+);(.*)$")
    if t then ns.SetLadder(imp.ah, id, tonumber(t), levels) end
  end
  for id, text in pairs(imp.daily or {}) do
    local have = {}
    for _, r in ipairs(List(self.index, imp.ah, id)) do have[ns.DayOf(r.t)] = true end
    local list = List(self.dailyIndex, imp.ah, id)
    for _, d in ipairs(list) do have[d.day] = true end
    for day, scans, low, med, high, qty in text:gmatch("(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)") do
      day = tonumber(day)
      if not have[day] then
        list[#list + 1] = {
          day = day, id = id, t = day * DAY + DAY / 2, scans = tonumber(scans), low = tonumber(low),
          median = tonumber(med), high = tonumber(high), qty = tonumber(qty),
          watchSec = 0, buys = 0, bought = 0, listed = 0, removed = 0, imported = true,
        }
      end
    end
  end
end

-- Units sold per day: what watch mode measured (7 days), else the Blizzard
-- API estimate from the database. Returns value, "watch" | "api".
function ns:SoldPerDay(id)
  local w = self:GetWatchStats(id, 7)
  if w then return w.soldPerDay, "watch" end
  local imp = self.IMPORTED
  local est = imp and imp.ah == self.ahKey and imp.sold and imp.sold[id]
  if est then return est, "api" end
end

-- "123" for measured, "~123" for estimated, "-" for unknown.
function ns.SoldText(value, source)
  if not value then return "-" end
  return (source == "api" and "~" or "") .. ("%d"):format(value + 0.5)
end

function ns:AddRecord(ah, t, id, min, qty, ladder)
  self.db.log[#self.db.log + 1] = ("%s,%d,%d,%d,%d,%s"):format(ah, t, id, min, qty, ladder)
  IndexScan(ah, { t = t, id = id, min = min, qty = qty })
  ns.SetLadder(ah, id, t, ladder)
  self:NotifyChanged()
end

function ns:AddEvent(ah, id, e)
  local log = self.db.watchEvents
  log[#log + 1] = ("%s,%d,%d,%s,%d,%d,%d,%d,%d"):format(
    ah, e.t, id, e.kind, e.qty, e.low or 0, e.high or 0, e.levels or 0, e.vwap or 0)
  local list = List(self.eventIndex, ah, id)
  list[#list + 1] = { t = e.t, id = id, kind = e.kind, qty = e.qty, low = e.low, high = e.high, levels = e.levels, vwap = e.vwap }
end

function ns:AddCoverage(ah, id, t, seconds)
  local cov = self.db.coverage
  cov[ah] = cov[ah] or {}
  cov[ah][id] = cov[ah][id] or {}
  local day = ns.DayOf(t)
  cov[ah][id][day] = (cov[ah][id][day] or 0) + seconds
end

-- Reading ------------------------------------------------------------------------------

local function Median(values)
  if #values == 0 then return nil end
  table.sort(values)
  local mid = math.floor((#values + 1) / 2)
  if #values % 2 == 1 then return values[mid] end
  return math.floor((values[mid] + values[mid + 1]) / 2)
end
ns.Median = Median

-- Price history of an item on the current auction house since `since` (unix
-- time, nil = everything): { { t, v = lowest price (0 = none listed), q = quantity,
-- daily = true for trimmed days, low, high }, ... } oldest first.
function ns:GetSeries(id, since)
  since = since or 0
  local points = {}
  local daily = self.dailyIndex[self.ahKey] and self.dailyIndex[self.ahKey][id]
  for _, d in ipairs(daily or {}) do
    if d.t >= since and d.scans > 0 then
      points[#points + 1] = { t = d.t, v = d.median, q = d.qty, low = d.low, high = d.high, daily = true }
    end
  end
  local raw = self.index[self.ahKey] and self.index[self.ahKey][id]
  for _, r in ipairs(raw or {}) do
    if r.t >= since then points[#points + 1] = { t = r.t, v = r.min, q = r.qty } end
  end
  table.sort(points, function(a, b) return a.t < b.t end)
  return points
end

-- Newest known price levels of an item: { { price, qty }, ... } cheapest first, and
-- their time. A watched item's live order book wins when it is newer.
local parsed = {} -- [ah .. id] = { t =, levels = } parse cache
function ns:Ladder(id)
  local book = self.books and self.books[id]
  local stored = self.ladders[self.ahKey] and self.ladders[self.ahKey][id]
  if book and book.t and (not stored or book.t >= stored.t) and self:IsWatching() then
    local levels = {}
    for i, level in ipairs(book.levels) do levels[i] = { level.price, level.qty } end
    return levels, book.t
  end
  if not stored then return nil end
  local key = self.ahKey .. id
  local cache = parsed[key]
  if not cache or cache.t ~= stored.t then
    local levels = {}
    for price, qty in stored.text:gmatch("(%d+):(%d+)") do levels[#levels + 1] = { tonumber(price), tonumber(qty) } end
    cache = { t = stored.t, levels = levels }
    parsed[key] = cache
  end
  return cache.levels, cache.t
end

-- Latest lowest price seen (skipping scans where nothing was listed), and when.
function ns:LatestAHPrice(id)
  local raw = self.index[self.ahKey] and self.index[self.ahKey][id]
  if raw then
    for i = #raw, 1, -1 do
      if raw[i].min > 0 then return raw[i].min, raw[i].t end
    end
  end
  local daily = self.dailyIndex[self.ahKey] and self.dailyIndex[self.ahKey][id]
  if daily then
    for i = #daily, 1, -1 do
      if daily[i].median > 0 then return daily[i].median, daily[i].t end
    end
  end
end

-- Summary over the last `days` days (nil = all history) on the current auction house.
--   latest  newest point overall ({ t, v, q }); median/low/high of the lowest price
--   in scans where the item was listed; avgQty listed; scans counted.
function ns:GetStats(id, days)
  local all = self:GetSeries(id)
  if #all == 0 then return nil end
  local since = days and (time() - days * DAY) or 0
  local mins, qtySum, n, scans, low, high = {}, 0, 0, 0, nil, nil
  for _, p in ipairs(all) do
    if p.t >= since then
      n = n + 1
      qtySum = qtySum + p.q
      if p.v > 0 then
        mins[#mins + 1] = p.v
        local pl, ph = p.low or p.v, p.high or p.v
        if pl > 0 and (not low or pl < low) then low = pl end
        if not high or ph > high then high = ph end
      end
    end
  end
  local latest = all[#all]
  return {
    latest = { t = latest.t, min = latest.v, qty = latest.q },
    median = Median(mins), low = low, high = high,
    avgQty = n > 0 and qtySum / n or 0,
    scans = n,
  }
end

-- What watch mode saw for an item over the last `days` days (nil = all).
function ns:GetWatchStats(id, days)
  local ah = self.ahKey
  local since = days and (time() - days * DAY) or 0
  local sinceDay = ns.DayOf(since)
  local s = { seconds = 0, buys = 0, bought = 0, listed = 0, removed = 0, sizes = {}, maxLevels = 0 }
  local cov = self.db.coverage[ah] and self.db.coverage[ah][id]
  for day, sec in pairs(cov or {}) do
    if day >= sinceDay then s.seconds = s.seconds + sec end
  end
  for _, e in ipairs(self.eventIndex[ah] and self.eventIndex[ah][id] or {}) do
    if e.t >= since then
      if e.kind == "buy" then
        s.buys = s.buys + 1
        s.bought = s.bought + e.qty
        s.sizes[#s.sizes + 1] = e.qty
        if e.levels > s.maxLevels then s.maxLevels = e.levels end
        s.lastBuy = e
      elseif e.kind == "listed" then
        s.listed = s.listed + e.qty
      else
        s.removed = s.removed + e.qty
      end
    end
  end
  for _, d in ipairs(self.dailyIndex[ah] and self.dailyIndex[ah][id] or {}) do
    if d.day >= sinceDay then
      s.seconds = s.seconds + d.watchSec
      s.buys, s.bought = s.buys + d.buys, s.bought + d.bought
      s.listed, s.removed = s.listed + d.listed, s.removed + d.removed
    end
  end
  if s.seconds < 1800 then return nil end -- under 30 minutes watched: rates would be mostly noise
  local days_ = s.seconds / DAY
  s.hours = s.seconds / 3600
  s.soldPerDay = s.bought / days_
  s.buysPerDay = s.buys / days_
  s.medianSize = Median(s.sizes)
  s.maxSize = #s.sizes > 0 and math.max(unpack(s.sizes)) or nil
  return s
end

-- Trimming -----------------------------------------------------------------------------

-- Folds everything older than `days` days into daily lines and removes the raw
-- records. With dryRun it only counts. Returns a summary table.
function ns:Trim(days, dryRun)
  local db = self.db
  local cutoffDay = ns.DayOf(time()) - days
  local cutoff = cutoffDay * DAY
  local agg, keys = {}, {}
  local function A(ah, day, id)
    local k = ah .. "," .. day .. "," .. id
    local a = agg[k]
    if not a then
      a = { ah = ah, day = day, id = id, scans = 0, mins = {}, qtySum = 0,
            watchSec = 0, buys = 0, bought = 0, listed = 0, removed = 0 }
      agg[k] = a
      keys[#keys + 1] = k
    end
    return a
  end
  local result = { scans = 0, events = 0, polls = 0, coverage = 0 }

  local keptLog = {}
  for _, line in ipairs(db.log) do
    local ah, r = ParseScan(line)
    if r.t and r.t < cutoff then
      local a = A(ah, ns.DayOf(r.t), r.id)
      a.scans = a.scans + 1
      a.qtySum = a.qtySum + r.qty
      if r.min > 0 then a.mins[#a.mins + 1] = r.min end
      result.scans = result.scans + 1
    else
      keptLog[#keptLog + 1] = line
    end
  end

  local keptEvents = {}
  for _, line in ipairs(db.watchEvents) do
    local ah, e = ParseEvent(line)
    if e.t and e.t < cutoff then
      local a = A(ah, ns.DayOf(e.t), e.id)
      if e.kind == "buy" then
        a.buys, a.bought = a.buys + 1, a.bought + e.qty
      elseif e.kind == "listed" then
        a.listed = a.listed + e.qty
      else
        a.removed = a.removed + e.qty
      end
      result.events = result.events + 1
    else
      keptEvents[#keptEvents + 1] = line
    end
  end

  for ah, byItem in pairs(db.coverage) do
    for id, byDay in pairs(byItem) do
      for day, sec in pairs(byDay) do
        if day < cutoffDay then
          A(ah, day, id).watchSec = A(ah, day, id).watchSec + sec
          result.coverage = result.coverage + 1
          if not dryRun then byDay[day] = nil end
        end
      end
    end
  end

  -- Watch polls: drop old ones, then any deltas left without their starting
  -- "S" line (a session cut in half), which could not be replayed.
  local keptPolls, started = {}, {}
  for _, line in ipairs(db.watchLog) do
    local ah, t, id, kind = line:match("^([^,]*),(%d+),(%d+),([SFD=])")
    t = tonumber(t)
    local key = ah and (ah .. "," .. id)
    if t and t >= cutoff and (kind == "S" or started[key]) then
      if kind == "S" then started[key] = true end
      keptPolls[#keptPolls + 1] = line
    else
      result.polls = result.polls + 1
    end
  end
  result.days = #keys
  if dryRun then return result end

  -- merge into existing daily lines
  local existing = {}
  for i, line in ipairs(db.daily) do
    local ah, d = ParseDaily(line)
    existing[ah .. "," .. d.day .. "," .. d.id] = { i = i, d = d }
  end
  for _, k in ipairs(keys) do
    local a = agg[k]
    table.sort(a.mins)
    local new = {
      day = a.day, id = a.id, scans = a.scans,
      low = a.mins[1] or 0, median = Median(a.mins) or 0, high = a.mins[#a.mins] or 0,
      qty = a.scans > 0 and a.qtySum / a.scans or 0,
      watchSec = a.watchSec, buys = a.buys, bought = a.bought, listed = a.listed, removed = a.removed,
    }
    local old = existing[k]
    if old then
      local d = old.d
      local scans = d.scans + new.scans
      if scans > 0 then d.qty = (d.qty * d.scans + new.qty * new.scans) / scans end
      if new.scans > d.scans then d.median = new.median end
      if new.low > 0 and (d.low == 0 or new.low < d.low) then d.low = new.low end
      if new.high > d.high then d.high = new.high end
      d.scans = scans
      for _, f in ipairs({ "watchSec", "buys", "bought", "listed", "removed" }) do d[f] = d[f] + new[f] end
      db.daily[old.i] = DailyLine(a.ah, d)
    else
      db.daily[#db.daily + 1] = DailyLine(a.ah, new)
    end
  end
  db.log, db.watchEvents, db.watchLog = keptLog, keptEvents, keptPolls
  self:LoadData()
  return result
end

-- Formatting ---------------------------------------------------------------------------

local function Money(copper)
  if not copper or copper <= 0 then return "-" end
  copper = math.floor(copper + 0.5)
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  if g > 0 then return ("|cffffd700%dg|r |cffc7c7cf%02ds|r"):format(g, s) end
  if s > 0 then return ("|cffc7c7cf%ds|r |cffeda55f%02dc|r"):format(s, c) end
  return ("|cffeda55f%dc|r"):format(c)
end
ns.Money = Money

-- Compact money for axis labels and narrow columns: 12.3g, 45s, 7c.
function ns.ShortMoney(copper)
  if not copper or copper <= 0 then return "-" end
  if copper >= 100000 then return ("%dg"):format(copper / 10000 + 0.5) end
  if copper >= 10000 then return ("%.1fg"):format(copper / 10000) end
  if copper >= 100 then return ("%ds"):format(copper / 100 + 0.5) end
  return ("%dc"):format(copper + 0.5)
end

local function Age(t)
  local s = time() - t
  if s < 3600 then return math.floor(s / 60) .. "m" end
  if s < DAY then return math.floor(s / 3600) .. "h" end
  return math.floor(s / DAY) .. "d"
end
ns.Age = Age

local function Label(id)
  local _, link = ns.GetItemInfo(id)
  return link or ns.db.names[id] or ("item:" .. id)
end

-- Chat commands ------------------------------------------------------------------------

function ns:PrintDeals(days)
  local rows = {}
  for _, id in ipairs(self.items) do
    local st = self:GetStats(id, days)
    if st and st.median and st.latest.min > 0 and st.scans >= 3 then
      rows[#rows + 1] = { id = id, st = st, ratio = st.latest.min / st.median }
    end
  end
  table.sort(rows, function(a, b) return a.ratio < b.ratio end)
  self.Print(("Cheapest now vs %d-day median on %s:"):format(days, self.ahKey))
  if #rows == 0 then
    print("  Not enough data yet; items need at least 3 scans.")
  end
  for i = 1, math.min(10, #rows) do
    local row = rows[i]
    print(("  %s %s  (median %s, %d%%)"):format(
      Label(row.id), Money(row.st.latest.min), Money(row.st.median), math.floor(row.ratio * 100 + 0.5)))
  end
end

function ns:PrintItemStats(id)
  if not id then return self.Print("Usage: /pscan stats <item link or ID>") end
  local week, month = self:GetStats(id, 7), self:GetStats(id, 30)
  if not week then return self.Print(Label(id) .. ": no data on " .. self.ahKey .. " yet.") end
  local r = week.latest
  self.Print(Label(id))
  print(("  Last scan %s ago: %s, %d listed"):format(Age(r.t), Money(r.min), r.qty))
  print(("  7 days: median %s, avg %d listed, %d scans"):format(Money(week.median), week.avgQty, week.scans))
  print(("  30 days: median %s, avg %d listed, %d scans"):format(Money(month.median), month.avgQty, month.scans))
end

-- Tooltips -----------------------------------------------------------------------------

local function AddTooltipLines(tooltip, id, link)
  if not (id and ns.db) then return end
  -- average disenchant value, for any gear that disenchants (Disenchant.lua)
  local deLeft, deRight = ns:DisenchantTooltip(id, link)
  if deLeft then tooltip:AddDoubleLine("ProfScan " .. deLeft:lower(), deRight, 0.2, 1, 0.6, 1, 1, 1) end
  if not (ns.watched[id] or ns:IsFocusScan(id)) then return end
  local st = ns:GetStats(id, 7)
  if not st then
    tooltip:AddLine("ProfScan: not scanned yet", 0.6, 0.6, 0.6)
    return
  end
  local r = st.latest
  tooltip:AddDoubleLine("ProfScan lowest (" .. Age(r.t) .. " ago)", Money(r.min), 0.2, 1, 0.6, 1, 1, 1)
  tooltip:AddDoubleLine("7-day median", Money(st.median), 0.2, 1, 0.6, 1, 1, 1)
  tooltip:AddDoubleLine("Listed now / 7-day avg", ("%d / %d"):format(r.qty, st.avgQty + 0.5), 0.2, 1, 0.6, 1, 1, 1)
  local sold, via = ns:SoldPerDay(id)
  if sold then
    tooltip:AddDoubleLine(via == "watch" and "Sold per day (watched)" or "Sold per day (API estimate)",
      ns.SoldText(sold, via), 0.2, 1, 0.6, 1, 1, 1)
  end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if tooltip == GameTooltip or tooltip == ItemRefTooltip then
      AddTooltipLines(tooltip, data and data.id, data and data.hyperlink)
    end
  end)
else
  local function OnTooltipSetItem(tooltip)
    local _, link = tooltip:GetItem()
    AddTooltipLines(tooltip, link and tonumber(link:match("item:(%d+)")), link)
  end
  GameTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
  ItemRefTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
end

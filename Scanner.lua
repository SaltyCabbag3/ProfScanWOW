local _, ns = ...

--[[
  Talking to the auction house

  Everything goes through one request at a time ("req"). A request is a job
  table: { kind = "batch" | "commodity", owner = "scan" | "watch", ... ,
  onResult = function(job, data), onFail = function(job) }. The driver below
  sends it when the auction house throttle allows, resends it if the server
  drops it, fails, or does not answer in time, and gives up after MAX_TRIES.
  When no request is pending it asks the running scan for its next job, and
  when there is no scan, watch mode (Watch.lua).

  Quick scan: C_AuctionHouse.SearchForItemKeys takes a whole list of items and
  answers with one row per item (lowest price + total quantity listed). One
  request covers ~50 items.

  Deep scan: after the quick scan, one SendSearchQuery per commodity, reading
  the cheapest listings to build a price ladder ("price:quantity" levels).
]]

local REQUEST_TIMEOUT = 10 -- seconds to wait for an answer before resending
local MAX_TRIES = 3        -- sends per request before giving up on it
local KEY_INFO_WAIT = 5    -- seconds to wait for uncached item info before searching anyway
local MAX_OWNERS = 3       -- seller names kept per price level

local PRICE_SORT = {
  { sortOrder = Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0, reverseSort = false },
}

local req         -- the request being sent or waited on
local scan        -- state of the running scan, nil when idle
ns.ahOpen = false

local driver = CreateFrame("Frame")
driver:Hide()

local function Key(id)
  return C_AuctionHouse.MakeItemKey(id)
end

-- Item key info is the auction house's own item cache. Searches for items that
-- are not in it yet are often ignored, so we ask early and wait for it.
local function KeyInfo(id)
  return C_AuctionHouse.GetItemKeyInfo(Key(id))
end
ns.KeyInfo = KeyInfo

local function JobReady(job)
  if job.kind == "commodity" then return KeyInfo(job.id) ~= nil end
  for _, id in ipairs(job.ids) do
    if not KeyInfo(id) then return false end
  end
  return true
end

local function SendJob(job)
  if job.kind == "batch" then
    local keys = {}
    for i, id in ipairs(job.ids) do keys[i] = Key(id) end
    C_AuctionHouse.SearchForItemKeys(keys, PRICE_SORT)
  else
    C_AuctionHouse.SendSearchQuery(Key(job.id), PRICE_SORT, false)
  end
end

-- Forgets the pending request if it belongs to `owner`, e.g. when a scan is stopped.
function ns:DropRequest(owner)
  if req and req.owner == owner then req = nil end
end

--[[
  Reads the loaded commodity listings (cheapest first) into an order book:
    book.levels  = { { price =, qty =, tl = seconds left (lowest at that price), owners = {...} }, ... }
    book.byPrice = [price] = level
    book.min     = lowest price listed (0 if none)
    book.total   = total quantity listed, including listings not loaded
    book.cap     = 0 if the whole book is here; otherwise only prices below
                   cap are complete, and nothing at or above it is included
]]
function ns.ReadBook(itemID, maxLevels)
  local levels, byPrice, cap, first = {}, {}, nil, nil
  for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0 do
    local row = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if row then
      first = first or row.unitPrice
      local level = byPrice[row.unitPrice]
      if not level then
        if #levels >= maxLevels then
          cap = row.unitPrice
          break
        end
        level = { price = row.unitPrice, qty = 0, owners = {} }
        levels[#levels + 1], byPrice[row.unitPrice] = level, level
      end
      level.qty = level.qty + row.quantity
      local tl = row.timeLeftSeconds
      if tl and (not level.tl or tl < level.tl) then level.tl = tl end
      for _, owner in ipairs(row.owners or {}) do
        owner = owner:gsub("[,:/+]", "")
        if #level.owners < MAX_OWNERS and not tContains(level.owners, owner) then
          level.owners[#level.owners + 1] = owner
        end
      end
    end
  end
  if not cap and #levels > 0 and not C_AuctionHouse.HasFullCommoditySearchResults(itemID) then
    -- the last price level may continue in rows that were not sent; leave it out
    local last = table.remove(levels)
    byPrice[last.price] = nil
    cap = last.price
  end
  return {
    levels = levels, byPrice = byPrice, cap = cap or 0, min = first or 0,
    total = C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID) or 0,
  }
end

-- Scanning ---------------------------------------------------------------------

local function BatchResult(job, results)
  for _, r in ipairs(results) do
    local id = r.itemKey.itemID
    local cur = scan.results[id] or { min = 0, qty = 0 }
    local price = r.minPrice or 0
    if price > 0 and (cur.min == 0 or price < cur.min) then cur.min = price end
    cur.qty = cur.qty + (r.totalQuantity or 0)
    scan.results[id] = cur
  end
  for id in pairs(job.set) do scan.covered[id] = true end
end

local function DeepResult(job, book)
  local parts = {}
  for i = 1, math.min(#book.levels, ns.db.settings.ladderDepth) do
    local level = book.levels[i]
    parts[i] = level.price .. ":" .. level.qty
  end
  scan.results[job.id] = { min = book.min, qty = book.total, ladder = table.concat(parts, "/") }
end

local function ScanFail()
  scan.failed = scan.failed + 1
end

function ns:StartScan(deep)
  if not self.ahOpen then return self.Print("Open the auction house first.") end
  if scan then return self.Print("A scan is already running. /pscan stop cancels it.") end
  if not (C_AuctionHouse and C_AuctionHouse.SearchForItemKeys) then
    return self.Print("This client has no C_AuctionHouse.SearchForItemKeys, so scanning is unavailable.")
  end

  for _, id in ipairs(self.items) do KeyInfo(id) end -- start loading anything not cached yet

  local jobs, size = {}, self.db.settings.batchSize
  for i = 1, #self.items, size do
    local ids, set = {}, {}
    for j = i, math.min(i + size - 1, #self.items) do
      ids[#ids + 1] = self.items[j]
      set[self.items[j]] = true
    end
    jobs[#jobs + 1] = { kind = "batch", owner = "scan", ids = ids, set = set, onResult = BatchResult, onFail = ScanFail }
  end
  if deep then
    for _, id in ipairs(self.items) do
      jobs[#jobs + 1] = {
        kind = "commodity", owner = "scan", id = id, levels = self.db.settings.ladderDepth,
        onResult = DeepResult, onFail = ScanFail,
      }
    end
  end

  scan = {
    jobs = jobs, pos = 0, key = self.ahKey, stamp = time(), started = GetTime(), deep = deep,
    results = {}, -- [itemID] = { min =, qty =, ladder = }
    covered = {}, -- [itemID] = true once a batch containing it came back
    failed = 0,
  }
  self.Print(("Scanning %d items%s..."):format(#self.items, deep and " (deep)" or ""))
  self:NotifyChanged()
end

function ns:StopScan(reason)
  if scan then self:FinishScan(reason) end
end

function ns:IsScanning()
  return scan ~= nil
end

function ns:ScanStatus()
  if scan then return ("Scanning%s... %d/%d"):format(scan.deep and " (deep)" or "", scan.pos, #scan.jobs) end
end

local function NextScanJob()
  local s = scan
  while true do
    s.pos = s.pos + 1
    local job = s.jobs[s.pos]
    if not job then
      ns:FinishScan()
      return nil
    end
    if job.kind == "batch" then return job end
    -- Deep job: only commodities (stackable goods) have a single price ladder,
    -- and there is nothing to read for items the quick scan found unlisted.
    local info, quick = KeyInfo(job.id), s.results[job.id]
    if info and info.isCommodity and not (s.covered[job.id] and not (quick and quick.qty > 0)) then
      return job
    end
  end
end

function ns:FinishScan(reason)
  local s = scan
  scan = nil
  self:DropRequest("scan")
  local saved = 0
  for _, id in ipairs(self.items) do
    local r = s.results[id]
    if r or s.covered[id] then
      r = r or { min = 0, qty = 0 } -- searched but nothing listed
      self:ItemName(id)
      self:AddRecord(s.key, s.stamp, id, r.min, r.qty, r.ladder or "")
      saved = saved + 1
    end
  end
  self.Print(("Scan %s: %d items saved in %.1fs%s."):format(
    reason or "done", saved, GetTime() - s.started,
    s.failed > 0 and (", " .. s.failed .. " requests failed") or ""))
  self:NotifyChanged()
end

-- Driver -------------------------------------------------------------------------

driver:SetScript("OnUpdate", function()
  if not req then
    local job = (scan and NextScanJob()) or ns:NextWatchJob()
    if not job then return end
    job.tries, job.queuedAt, job.state = 0, GetTime(), "send"
    req = job
  end
  local now = GetTime()
  if req.state == "send" then
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then return end
    if not JobReady(req) and now - req.queuedAt < KEY_INFO_WAIT then return end
    req.tries = req.tries + 1
    if req.tries > MAX_TRIES then
      local job = req
      req = nil
      if job.onFail then job:onFail() end
      return
    end
    SendJob(req)
    req.state, req.sentAt = "wait", now
  elseif now - req.sentAt > REQUEST_TIMEOUT then
    req.state = "send" -- no answer, send it again
  end
end)

local function Waiting(kind)
  return req and req.state == "wait" and req.kind == kind
end

local function Resend()
  if req and req.state == "wait" then req.state = "send" end
end

-- Results --------------------------------------------------------------------------

function ns:AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
  if not Waiting("batch") then return end
  local results = C_AuctionHouse.GetBrowseResults()
  for _, r in ipairs(results) do
    -- Rows for items we did not ask for mean this answer belongs to another
    -- search (the default UI's favorites list, a manual search). Keep waiting;
    -- the timeout resends ours if needed.
    if not (r.itemKey and req.set[r.itemKey.itemID]) then return end
  end
  if not C_AuctionHouse.HasFullBrowseResults() then
    C_AuctionHouse.RequestMoreBrowseResults()
    req.sentAt = GetTime()
    return
  end
  local job = req
  req = nil
  job:onResult(results)
end
ns.AUCTION_HOUSE_BROWSE_RESULTS_ADDED = ns.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED

function ns:COMMODITY_SEARCH_RESULTS_UPDATED(itemID)
  if not (Waiting("commodity") and req.id == itemID) then return end
  -- The server sometimes answers with an empty list for items that do have
  -- listings; treat that as a failed request and search again.
  if (C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0) == 0
      and (C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID) or 0) > 0 then
    return Resend()
  end
  local job = req
  req = nil
  job:onResult(ns.ReadBook(itemID, job.levels))
end

-- Failures and auction house open/close ---------------------------------------

ns.AUCTION_HOUSE_BROWSE_FAILURE = Resend
ns.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED = Resend

function ns:AUCTION_HOUSE_SHOW()
  self.ahOpen = true
  self.ahKey = self:CurrentAHKey()
  for _, id in ipairs(self.items) do KeyInfo(id) end
  for _, id in ipairs(self.db.settings.focus) do KeyInfo(id) end
  driver:Show()
  self:ResumeWatchForAH()
  if self.OnAuctionHouseShow then self:OnAuctionHouseShow() end
  if self.db.settings.autoScan then
    -- give the default UI a moment to run its own opening search first
    C_Timer.After(3, function() if ns.ahOpen then ns:StartScan(false) end end)
  end
  self:NotifyChanged()
end

function ns:AUCTION_HOUSE_CLOSED()
  if not self.ahOpen then return end
  self.ahOpen = false
  self:StopScan("stopped (auction house closed)")
  self:PauseWatchForAH()
  req = nil
  driver:Hide()
  self:NotifyChanged()
end

for _, event in ipairs({
  "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
  "AUCTION_HOUSE_BROWSE_FAILURE", "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
  "COMMODITY_SEARCH_RESULTS_UPDATED",
}) do
  ns:RegisterEvent(event)
end

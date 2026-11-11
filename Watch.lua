local _, ns = ...

--[[
  Watch mode

  Polls the order book of each item on the focus list (settings.focus) every
  settings.watchInterval seconds while the auction house is open, and logs how
  the book changed. Only commodities (stackable goods) can be watched.
  Polls are also written to the price history (ProfScanDB.log, like a deep
  scan) when the book changed, or every 10 minutes if it didn't, so recipe
  costs and charts always use the newest price from scans or watching.

  ProfScanDB.watchLog holds one line per poll:
      "<ah key>,<unix time>,<itemID>,<type>,<total qty>,<cap>,<levels>"
  type  S  first look this session: <levels> is the whole book, nothing to compare with
        F  whole book again (the loaded range changed), compare with the previous poll
        D  only the price levels that changed since the previous poll
        =  nothing changed
  cap   0 if the whole book was loaded, otherwise only prices below cap are known
  level "price:qty:minutesLeft:seller+seller" (cheapest first); "price:0" in a
        D line means that price level is gone

  Telling trades apart from cancels

  Buying a commodity always fills from the cheapest listing upwards. So
  between two polls a purchase shows up as quantity disappearing from the
  bottom of the book in an unbroken run: whole cheapest levels gone, maybe the
  next one partly. Anything that disappears above an untouched level cannot
  have been bought: it was cancelled or expired. On top of that:
    - a level whose listings were about to run out (time left <= the time
      between polls, plus a margin) and is now gone counts as expired;
    - a level whose sellers all added listings elsewhere in the same poll
      counts as a cancel-and-repost (undercutting), not a purchase.
  Cancelling the cheapest listing without reposting still looks like a buy,
  and two purchases between polls look like one bigger one, so poll busy items
  often. tools/profscan_watch.py applies the same rules to the whole log.
]]

local EXPIRY_MARGIN = 60  -- seconds
local MAX_ACTIVITY = 100  -- events kept per item for the window

local watch               -- running watch session, nil when off
ns.books = {}             -- [itemID] = last book seen this session
ns.activity = {}          -- [itemID] = { event, ... } oldest first, this session
ns.firstSeen = {}         -- [itemID] = time of the first poll this session
local lastRecord = {}     -- [itemID] = time a poll was last written as a price record

local RECORD_EVERY = 600  -- seconds: an unchanged book is still recorded this often

-- Focus list -----------------------------------------------------------------------

function ns:IsFocus(id)
  return tContains(self.db.settings.focus, id)
end

function ns:ToggleFocus(id)
  local focus = self.db.settings.focus
  for i, fid in ipairs(focus) do
    if fid == id then
      table.remove(focus, i)
      self.Print("Stopped watching " .. (self:ItemName(id) or id) .. ".")
      return self:NotifyChanged()
    end
  end
  focus[#focus + 1] = id
  if self.ahOpen then self.KeyInfo(id) end
  self.Print("Watching " .. (self:ItemName(id) or id) .. ".")
  self:NotifyChanged()
end

-- Empties the watch list (stopping watch mode if it runs). The data already
-- recorded for those items stays.
function ns:ClearFocus()
  local n = #self.db.settings.focus
  self:StopWatch("watch list cleared")
  wipe(self.db.settings.focus)
  self.Print(("Watch list cleared (%d items removed). Their recorded data is kept."):format(n))
  self:NotifyChanged()
end

StaticPopupDialogs["PROFSCAN_CLEAR_FOCUS"] = {
  text = "ProfScan: remove all %d items from the watch list?\n\nWhat watch mode already recorded for them is kept.",
  button1 = YES,
  button2 = NO,
  OnAccept = function() ns:ClearFocus() end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

function ns:ConfirmClearFocus()
  local n = #self.db.settings.focus
  if n == 0 then return self.Print("The watch list is already empty.") end
  StaticPopup_Show("PROFSCAN_CLEAR_FOCUS", n)
end

-- Adds several items to the focus list; returns how many were new.
function ns:AddFocus(ids)
  local added = 0
  for _, id in ipairs(ids) do
    if id and id > 0 and not self:IsFocus(id) then
      local focus = self.db.settings.focus
      focus[#focus + 1] = id
      if self.ahOpen then self.KeyInfo(id) end
      added = added + 1
    end
  end
  self:NotifyChanged()
  return added
end

-- Book changes -----------------------------------------------------------------------

local function Token(level)
  return ("%d:%d:%s:%s"):format(level.price, level.qty,
    level.tl and math.floor(level.tl / 60) or "", table.concat(level.owners, "+"))
end

local function WholeBook(book)
  local parts = {}
  for i, level in ipairs(book.levels) do parts[i] = Token(level) end
  return table.concat(parts, "/")
end

local function Changes(prev, book)
  local parts = {}
  for _, level in ipairs(book.levels) do
    local old = prev.byPrice[level.price]
    if not old or old.qty ~= level.qty then parts[#parts + 1] = Token(level) end
  end
  for _, level in ipairs(prev.levels) do
    if not book.byPrice[level.price] then parts[#parts + 1] = level.price .. ":0" end
  end
  return table.concat(parts, "/")
end

local function AllIn(names, set)
  if #names == 0 then return false end
  for _, name in ipairs(names) do
    if not set[name] then return false end
  end
  return true
end

-- Compares two polls of one item and returns what happened in between, as a
-- list of events: buy, expired, repost, removed (cancel or expiry), listed.
function ns.Classify(prev, cur, elapsed)
  local cap
  if prev.cap == 0 then cap = cur.cap
  elseif cur.cap == 0 then cap = prev.cap
  else cap = math.min(prev.cap, cur.cap) end
  local function known(price) return cap == 0 or price < cap end

  local addedBy, listed, listedLow = {}, 0, nil
  for _, level in ipairs(cur.levels) do
    if not known(level.price) then break end
    local old = prev.byPrice[level.price]
    local added = level.qty - (old and old.qty or 0)
    if added > 0 then
      listed = listed + added
      listedLow = listedLow or level.price
      for _, owner in ipairs(level.owners) do addedBy[owner] = true end
    end
  end

  local buy = { kind = "buy", qty = 0, cost = 0, levels = 0 }
  local expired, reposted, removed = 0, 0, 0
  local bottom = true -- still in the unbroken run from the cheapest level up
  for _, level in ipairs(prev.levels) do
    if not known(level.price) then break end
    local now = cur.byPrice[level.price]
    local left = now and now.qty or 0
    local gone = level.qty - left
    if gone <= 0 then
      bottom = false
    elseif left == 0 and level.tl and level.tl - elapsed <= EXPIRY_MARGIN then
      expired = expired + gone
    elseif left == 0 and AllIn(level.owners, addedBy) then
      reposted = reposted + gone
    elseif bottom then
      buy.qty = buy.qty + gone
      buy.cost = buy.cost + gone * level.price
      buy.levels = buy.levels + 1
      buy.low = buy.low or level.price
      buy.high = level.price
      if left > 0 then bottom = false end -- the buyer stopped inside this level
    else
      removed = removed + gone
    end
  end

  local events = {}
  if buy.qty > 0 then
    buy.vwap = math.floor(buy.cost / buy.qty + 0.5)
    events[#events + 1] = buy
  end
  if expired > 0 then events[#events + 1] = { kind = "expired", qty = expired } end
  if reposted > 0 then events[#events + 1] = { kind = "repost", qty = reposted } end
  if removed > 0 then events[#events + 1] = { kind = "removed", qty = removed } end
  if listed > 0 then events[#events + 1] = { kind = "listed", qty = listed, low = listedLow } end
  return events
end

local function AddActivity(id, event)
  local list = ns.activity[id]
  if not list then
    list = {}
    ns.activity[id] = list
  end
  list[#list + 1] = event
  if #list > MAX_ACTIVITY then table.remove(list, 1) end
end

function ns:Observe(id, book)
  local t = time()
  book.t = t
  local prev = self.books[id]
  local kind, levels
  if not prev then
    kind, levels = "S", WholeBook(book)
    self.firstSeen[id] = t
  elseif prev.cap ~= book.cap then
    kind, levels = "F", WholeBook(book)
  else
    levels = Changes(prev, book)
    kind = levels == "" and "=" or "D"
  end
  local log = self.db.watchLog
  log[#log + 1] = ("%s,%d,%d,%s,%d,%d,%s"):format(watch.key, t, id, kind, book.total, book.cap, levels)

  if prev then
    local elapsed = t - prev.t
    self:AddCoverage(watch.key, id, t, elapsed)
    for _, event in ipairs(ns.Classify(prev, book, elapsed)) do
      event.t = t
      AddActivity(id, event)
      self:AddEvent(watch.key, id, event)
    end
  end
  self.books[id] = book
  watch.polls = watch.polls + 1

  -- Also a price record, like a deep scan, so recipe costs, margins, charts and
  -- tooltips use the newest price whether it came from a scan or a watch poll.
  if kind ~= "=" or not lastRecord[id] or t - lastRecord[id] >= RECORD_EVERY then
    local parts = {}
    for i = 1, math.min(#book.levels, self.db.settings.ladderDepth) do
      parts[i] = book.levels[i].price .. ":" .. book.levels[i].qty
    end
    self:AddRecord(watch.key, t, id, book.min, book.total, table.concat(parts, "/"))
    lastRecord[id] = t
  end
  self:NotifyChanged()
end

-- Session ------------------------------------------------------------------------------

local function WatchResult(job, book)
  if watch then ns:Observe(job.id, book) end
end

function ns:StartWatch()
  if not self.ahOpen then return self.Print("Open the auction house first.") end
  if watch then return end
  if #self.db.settings.focus == 0 then
    return self.Print("Nothing to watch yet: right-click items on the Prices tab, or /pscan focus <item>.")
  end
  watch = { started = GetTime(), key = self.ahKey, next = {}, polls = 0, unsupported = {} }
  wipe(self.books)
  wipe(self.activity)
  wipe(self.firstSeen)
  self.Print(("Watching %d items every %ds. Pauses while you are AFK or the auction house is closed, "
    .. "stops after %d minutes of watching."):format(
    #self.db.settings.focus, self.db.settings.watchInterval, self.db.settings.watchMaxMinutes))
  self:NotifyChanged()
end

function ns:StopWatch(reason)
  if not watch then return end
  self.Print(("Watch stopped (%s) after %d polls."):format(reason or "stopped", watch.polls))
  watch = nil
  self:DropRequest("watch")
  self:NotifyChanged()
end

-- Closing the auction house pauses watch mode; opening it again resumes it.
-- Time spent closed does not count toward watchMaxMinutes, and the first poll
-- after resuming starts fresh (nothing is compared across the gap).
function ns:PauseWatchForAH()
  if not watch or watch.closedAt then return end
  watch.closedAt = GetTime()
  wipe(self.books)
  self.Print("Watch paused (auction house closed); it resumes when you open the auction house again.")
  self:NotifyChanged()
end

function ns:ResumeWatchForAH()
  if not (watch and watch.closedAt) then return end
  watch.started = watch.started + (GetTime() - watch.closedAt)
  watch.closedAt = nil
  watch.key = self.ahKey
  wipe(watch.next)
  wipe(self.books)
  self.Print(("Watch resumed: %d items."):format(#self.db.settings.focus))
  self:NotifyChanged()
end

function ns:ToggleWatch()
  if watch then self:StopWatch() else self:StartWatch() end
end

function ns:IsWatching()
  return watch ~= nil
end

function ns:WatchStatus()
  if not watch then return nil end
  local left = math.max(0, math.floor(self.db.settings.watchMaxMinutes - ((watch.closedAt or GetTime()) - watch.started) / 60))
  if watch.closedAt then return ("Watch paused (auction house closed): %d items, %d min left"):format(
    #self.db.settings.focus, left) end
  if watch.paused then return "Watch paused: you are AFK" end
  return ("Watching %d items, %d polls, %d min left"):format(#self.db.settings.focus, watch.polls, left)
end

-- Called by the request driver when nothing else is pending.
function ns:NextWatchJob()
  local w = watch
  if not w or w.closedAt then return nil end
  local now = GetTime()
  if now - w.started > self.db.settings.watchMaxMinutes * 60 then
    self:StopWatch("time limit reached")
    return nil
  end
  if UnitIsAFK("player") then
    if not w.paused then
      w.paused = true
      self:NotifyChanged()
    end
    return nil
  elseif w.paused then
    w.paused = false
    wipe(self.books) -- don't compare across the pause
    wipe(w.next)
  end

  local best, bestDue
  for _, id in ipairs(self.db.settings.focus) do
    local due = w.next[id] or 0
    if not w.unsupported[id] and due <= now and (not bestDue or due < bestDue) then
      best, bestDue = id, due
    end
  end
  if not best then return nil end

  local info = self.KeyInfo(best)
  if info and not info.isCommodity then
    w.unsupported[best] = true
    self.Print((self:ItemName(best) or best) .. " is not a commodity; watch mode only follows stackable goods.")
    return nil
  end
  w.next[best] = now + self.db.settings.watchInterval
  return {
    kind = "commodity", owner = "watch", id = best, levels = self.db.settings.watchLevels,
    onResult = WatchResult,
  }
end

-- Numbers for the window ----------------------------------------------------------------

function ns:WatchSummary(id)
  local book, events = self.books[id], self.activity[id] or {}
  local s = { book = book }
  if book then
    s.best, s.polled = book.min, book.t
    local depth = 0
    for _, level in ipairs(book.levels) do
      if level.price > book.min * 1.1 then break end
      depth = depth + level.qty
    end
    s.depth = depth
  end
  local now, buys, units = time(), 0, 0
  for i = #events, 1, -1 do
    local e = events[i]
    if e.kind == "buy" then
      s.lastBuy = s.lastBuy or e
      if now - e.t <= 3600 then
        buys = buys + 1
        units = units + e.qty
      end
    end
  end
  local since = self.firstSeen[id]
  local hours = since and math.min(3600, now - since) / 3600
  if hours and hours >= 0.05 then -- at least 3 minutes observed
    s.buysPerHour, s.unitsPerHour = buys / hours, units / hours
  end
  return s
end

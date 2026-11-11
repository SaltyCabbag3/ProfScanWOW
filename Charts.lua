local _, ns = ...

--[[
  A small price chart: lowest price as a gold line, quantity listed as blue
  bars along the bottom, price axis on the left, dates below. Hovering shows
  the nearest point. Points come from ns:GetSeries; trimmed days (daily
  summaries) are drawn as dots in a lighter colour. Gaps where nothing was
  listed break the line.
]]

local MAX_POINTS = 150
local LEFT, RIGHT, TOP, BOTTOM = 46, 8, 8, 18
local GRID = 4

-- Averages points into at most MAX_POINTS buckets (lowest price, average quantity).
local function Downsample(points)
  if #points <= MAX_POINTS then return points end
  local out, size = {}, #points / MAX_POINTS
  for b = 0, MAX_POINTS - 1 do
    local first, last = math.floor(b * size) + 1, math.floor((b + 1) * size)
    local t, q, v, n, daily = 0, 0, 0, 0, false
    for i = first, last do
      local p = points[i]
      t, q, n = t + p.t, q + p.q, n + 1
      if p.v > 0 and (v == 0 or p.v < v) then v = p.v end
      daily = daily or p.daily
    end
    if n > 0 then out[#out + 1] = { t = t / n, q = q / n, v = v, daily = daily } end
  end
  return out
end

function ns.UI.CreateChart(parent, width, height)
  local c = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  c:SetSize(width, height)
  c:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                  edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  c:SetBackdropColor(0.03, 0.03, 0.04, 1)
  c:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

  local plotW, plotH = width - LEFT - RIGHT, height - TOP - BOTTOM
  local plot = CreateFrame("Frame", nil, c)
  plot:SetPoint("BOTTOMLEFT", LEFT, BOTTOM)
  plot:SetSize(plotW, plotH)

  local yLabels, xLabels = {}, {}
  for i = 0, GRID do
    local y = i / GRID * plotH
    local line = plot:CreateTexture(nil, "BACKGROUND")
    line:SetColorTexture(1, 1, 1, 0.06)
    line:SetPoint("BOTTOMLEFT", 0, y)
    line:SetSize(plotW, 1)
    local label = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    label:SetPoint("RIGHT", plot, "BOTTOMLEFT", -4, y)
    yLabels[i] = label
  end
  for i, point in ipairs({ "LEFT", "CENTER", "RIGHT" }) do
    local label = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    label:SetPoint("TOP", plot, "BOTTOM" .. (point ~= "CENTER" and point or ""), 0, -3)
    label:SetJustifyH(point)
    xLabels[i] = label
  end
  xLabels[1]:ClearAllPoints()
  xLabels[1]:SetPoint("TOPLEFT", plot, "BOTTOMLEFT", 0, -3)
  xLabels[3]:ClearAllPoints()
  xLabels[3]:SetPoint("TOPRIGHT", plot, "BOTTOMRIGHT", 0, -3)

  local empty = c:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  empty:SetPoint("CENTER", plot)
  empty:SetText("No data for this period")

  local marker = plot:CreateTexture(nil, "OVERLAY")
  marker:SetColorTexture(1, 1, 1, 0.35)
  marker:SetSize(1, plotH)
  marker:Hide()

  local pools = { line = {}, bar = {}, dot = {} }
  local used = { line = 0, bar = 0, dot = 0 }
  local canLine = plot.CreateLine ~= nil

  local function Take(kind)
    used[kind] = used[kind] + 1
    local obj = pools[kind][used[kind]]
    if not obj then
      if kind == "line" then
        obj = plot:CreateLine(nil, "ARTWORK")
        obj:SetThickness(2)
        obj:SetColorTexture(1, 0.82, 0.1, 1)
      elseif kind == "bar" then
        obj = plot:CreateTexture(nil, "BORDER")
        obj:SetColorTexture(0.3, 0.55, 0.9, 0.35)
      else
        obj = plot:CreateTexture(nil, "OVERLAY")
        obj:SetSize(4, 4)
      end
      pools[kind][used[kind]] = obj
    end
    obj:Show()
    return obj
  end

  function c:SetData(points)
    for kind, pool in pairs(pools) do
      for _, obj in ipairs(pool) do obj:Hide() end
      used[kind] = 0
    end
    points = Downsample(points or {})
    self.points = points
    empty:SetShown(#points == 0)
    for i = 0, GRID do yLabels[i]:SetText("") end
    for _, label in ipairs(xLabels) do label:SetText("") end
    if #points == 0 then return end

    local t0, t1 = points[1].t, points[#points].t
    if t1 <= t0 then t0, t1 = t0 - 3600, t1 + 3600 end
    local vmin, vmax, qmax = nil, nil, 0
    for _, p in ipairs(points) do
      if p.v > 0 then
        vmin = (not vmin or p.v < vmin) and p.v or vmin
        vmax = (not vmax or p.v > vmax) and p.v or vmax
      end
      if p.q > qmax then qmax = p.q end
    end
    if vmin then
      local pad = math.max((vmax - vmin) * 0.08, vmax * 0.02, 1)
      vmin, vmax = math.max(0, vmin - pad), vmax + pad
    end
    self.scale = { t0 = t0, t1 = t1, vmin = vmin, vmax = vmax }

    local function X(t) return (t - t0) / (t1 - t0) * plotW end
    local function Y(v) return (v - vmin) / (vmax - vmin) * plotH end

    -- quantity bars (bottom 30%)
    local barW = math.max(1, plotW / #points * 0.7)
    if qmax > 0 then
      for _, p in ipairs(points) do
        if p.q > 0 then
          local bar = Take("bar")
          bar:SetSize(barW, math.max(1, p.q / qmax * plotH * 0.3))
          bar:SetPoint("BOTTOMLEFT", math.min(plotW - barW, math.max(0, X(p.t) - barW / 2)), 0)
        end
      end
    end

    -- price line and dots
    if vmin then
      local prev
      for _, p in ipairs(points) do
        if p.v > 0 then
          local x, y = X(p.t), Y(p.v)
          if prev and canLine then
            local line = Take("line")
            line:SetStartPoint("BOTTOMLEFT", plot, prev[1], prev[2])
            line:SetEndPoint("BOTTOMLEFT", plot, x, y)
          end
          if p.daily or not canLine or #points <= 40 then
            local dot = Take("dot")
            if p.daily then dot:SetColorTexture(1, 0.95, 0.6, 0.9) else dot:SetColorTexture(1, 0.82, 0.1, 1) end
            dot:SetPoint("CENTER", plot, "BOTTOMLEFT", x, y)
          end
          prev = { x, y }
        else
          prev = nil -- nothing listed: break the line
        end
      end
      for i = 0, GRID do yLabels[i]:SetText(ns.ShortMoney(vmin + (vmax - vmin) * i / GRID)) end
    end

    local span = t1 - t0
    local fmt = span > 2 * 86400 and "%d %b" or "%H:%M"
    xLabels[1]:SetText(date(fmt, t0))
    xLabels[2]:SetText(date(fmt, (t0 + t1) / 2))
    xLabels[3]:SetText(date(fmt, t1))
  end

  -- hover readout
  c:SetScript("OnUpdate", function(self)
    local pts, s = self.points, self.scale
    if not (pts and #pts > 0 and s and plot:IsMouseOver()) then
      if marker:IsShown() then
        marker:Hide()
        GameTooltip:Hide()
      end
      return
    end
    local x = GetCursorPosition() / plot:GetEffectiveScale() - plot:GetLeft()
    local t = s.t0 + x / plotW * (s.t1 - s.t0)
    local best, bestD
    for _, p in ipairs(pts) do
      local d = math.abs(p.t - t)
      if not bestD or d < bestD then best, bestD = p, d end
    end
    marker:ClearAllPoints()
    marker:SetPoint("BOTTOMLEFT", (best.t - s.t0) / (s.t1 - s.t0) * plotW, 0)
    marker:Show()
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:SetText(date("%d %b %H:%M", best.t) .. (best.daily and "  (daily summary)" or ""))
    GameTooltip:AddDoubleLine("Lowest price", ns.Money(best.v), 1, 1, 1)
    GameTooltip:AddDoubleLine("Listed", ("%d"):format(best.q + 0.5), 1, 1, 1)
    GameTooltip:Show()
  end)
  c:SetScript("OnHide", function() marker:Hide() end)

  return c
end

local _, ns = ...

--[[
  Prices for the recipe views. All per unit, in copper, on the current auction house.

  Buy price   the cheaper of the latest auction house price and a vendor's
              price. Vendor prices are learned whenever you open a merchant
              window (vials, thread, flux...), so recipes using them get a
              complete cost once you have visited the vendor.
  Sell price  the better of the auction house price after its cut (5%, 15% at
              the goblin auction houses, see ns:AHCut) and the
              price a vendor pays (from item info).
  Yield       recipes that make several items per craft (bars, grenades,
              ammo) are costed per craft and earn price x average yield.
  Bonuses     crafting bonuses you set in Craft settings (settings.bonuses, see
              ns.BONUSES below): extra results, refunded reagents, vendor
              discount, extra Merchant's Favor, faster casts.
  Crafting tree  for each reagent that can be crafted, the cheapest recipe
              making it is costed recursively (per item: craft cost / yield),
              and the cheaper of buying or crafting is chosen.
]]


-- Crafting bonuses ----------------------------------------------------------------------
-- From Forever's game data (wago.tools DB2, build 1.60.1.70888): the Legacy trade
-- tree's talents with their per-rank values, two talents that exist in the data but
-- aren't in the tree yet, and two crafting-speed effects. Gathering ones are left out.
-- settings.bonuses[key] = rank (ranked) or true (toggles); missing = off.
ns.BONUSES = {
  { key = "masterChef", name = "Master Chef", spell = 1225457, ranks = 5, per = 10, group = "Legacy talents", short = "cooking: extra results",
    what = "Cooking recipes: %d%% chance to create one extra item (one, also for recipes that make several)." },
  { key = "bartering", name = "Bartering", spell = 1225459, ranks = 2, per = 5, group = "Legacy talents", short = "cheaper vendor reagents",
    what = "Vendor prices %d%% lower (reagents bought from vendors: vials, spices, thread, flux...).",
    note = "Vendor prices ProfScan learns are what the merchant charged, so it stores them as full prices "
      .. "using this setting. Set it before visiting vendors; prices learned with a different rank fix "
      .. "themselves the next time you open that vendor." },
  { key = "performance", name = "Performance Bonus", spell = 1225456, ranks = 3, per = 5, group = "Legacy talents", short = "extra Merchant's Favor",
    what = "Crate turn-ins: %d%% chance of 100%% more Merchant's Favor (crates are priced for the average)." },
  { key = "meticulous", name = "Meticulous", spell = 1225465, value = 15, group = "In the game files, not in the tree yet",
    short = "potions, elixirs, flasks, First Aid",
    what = "%d%% chance of one extra item from First Aid recipes and Alchemy elixirs, potions, draughts and flasks "
      .. "(assumed to work like Master Chef: one item, also for recipes that make several)." },
  { key = "optimization", name = "Optimization", spell = 1225460, value = 5, group = "In the game files, not in the tree yet",
    short = "reagent refunds (Eng, BS, LW, Tailoring)",
    what = "Engineering, Blacksmithing, Leatherworking, Tailoring: %d%% chance per reagent to be refunded "
      .. "(marked not yet implemented in the game data)." },
  { key = "smelting", name = "Improved Smelting", spell = 1291915, value = 25, group = "Crafting speed", short = "faster copper/tin/bronze/silver smelts",
    what = "%d%% shorter Smelt Copper, Tin, Bronze and Silver (equip effect of item 5199).",
    note = "Only switch this on if the cast time the game shows doesn't already include it." },
  { key = "deftDigits", name = "Deft Digits", spell = 1290800, value = 75, group = "Crafting speed", short = "75% faster crafting",
    what = "Crafting %d%% faster.",
    note = "Only switch this on if the cast time the game shows doesn't already include it." },
}
local BONUS = {}
for _, b in ipairs(ns.BONUSES) do BONUS[b.key] = b end

-- The bonus's value in percent (0 when off).
function ns:BonusValue(key)
  local b, v = BONUS[key], self.db.settings.bonuses[key]
  if not v then return 0 end
  if b.ranks then return math.min(tonumber(v) or 0, b.ranks) * b.per end
  return b.value
end

local METICULOUS = { "Elixir", "Potion", "Draught", "Flask" }
local REFUND_PROFS = { Engineering = true, Blacksmithing = true, Leatherworking = true, Tailoring = true }
local SMELTS = { [2657] = true, [3304] = true, [2659] = true, [2658] = true } -- Copper, Tin, Bronze, Silver

-- Chance (0..1) of one extra item per craft from your bonuses (ns.Yield adds it).
function ns:ExtraResultChance(recipe)
  local prof = recipe.profession
  if prof == "Cooking" then return self:BonusValue("masterChef") / 100 end
  if prof == "First Aid" then return self:BonusValue("meticulous") / 100 end
  if prof == "Alchemy" and self.db.settings.bonuses.meticulous then
    local name = recipe.name or ((recipe.item or 0) > 0 and self:ItemName(recipe.item)) or ""
    for _, word in ipairs(METICULOUS) do
      if name:find(word, 1, true) then return self:BonusValue("meticulous") / 100 end
    end
  end
  return 0
end

-- Share of a recipe's reagents actually used up (1 = all; refunds lower it).
function ns:ReagentFactor(recipe)
  if REFUND_PROFS[recipe.profession] then return 1 - self:BonusValue("optimization") / 100 end
  return 1
end

-- Cast time multiplier from your crafting-speed bonuses.
function ns:CastFactor(recipe)
  local f = 1
  if SMELTS[recipe.spell] then f = f * (1 - self:BonusValue("smelting") / 100) end
  local speed = self:BonusValue("deftDigits")
  if speed > 0 then f = f / (1 + speed / 100) end
  return f
end

-- Average Merchant's Favor a crate turn-in gives, with Performance Bonus.
function ns:ExpectedFavor(favor)
  return favor and favor * (1 + self:BonusValue("performance") / 100)
end

-- Vendor prices ------------------------------------------------------------------------

-- What a vendor charges you now (stored prices are full prices; Bartering applies here).
function ns:VendorBuyPrice(id)
  local full = self.db.vendor[id]
  if not full then return nil end
  return math.max(1, math.floor(full * (1 - self:BonusValue("bartering") / 100) + 0.5))
end

local function MerchantItem(i)
  if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
    local info = C_MerchantFrame.GetItemInfo(i)
    if info then return info.price, info.stackCount, info.hasExtendedCost end
  end
  if GetMerchantItemInfo then
    local _, _, price, quantity, _, _, _, extendedCost = GetMerchantItemInfo(i)
    return price, quantity, extendedCost
  end
end

function ns:CaptureMerchant()
  for i = 1, GetMerchantNumItems() do
    local link = GetMerchantItemLink(i)
    local id = link and tonumber(link:match("item:(%d+)"))
    local price, quantity, extended = MerchantItem(i)
    if id and price and price > 0 and not extended then
      -- the merchant already took off Bartering; store the full price
      local unit = price / math.max(1, quantity or 1) / (1 - self:BonusValue("bartering") / 100)
      self.db.vendor[id] = math.floor(unit + 0.5)
    end
  end
end

local function OnMerchant()
  local ok, err = pcall(ns.CaptureMerchant, ns)
  if not ok then ns.Print("Could not read the vendor window: " .. tostring(err)) end
end
ns.MERCHANT_SHOW = OnMerchant
ns.MERCHANT_UPDATE = OnMerchant
ns:RegisterEvent("MERCHANT_SHOW")
ns:RegisterEvent("MERCHANT_UPDATE")

-- Item prices --------------------------------------------------------------------------

function ns:VendorSellPrice(id)
  local sell = select(11, ns.GetItemInfo(id))
  return sell and sell > 0 and sell or nil
end

-- Average price per item of buying `qty` on the auction house, taking the
-- cheapest listings first (price levels from deep scans, watch polls or the
-- Blizzard API). Returns price, flag:
--   nil        the known levels cover qty
--   "short"    fewer than qty at the known levels; the rest is priced at the highest known level
--   "nodepth"  no usable price levels (none known, or 6+ hours older than the latest
--              lowest price); the lowest price is used for everything
local STALE_LEVELS = 6 * 3600
function ns:DepthPrice(id, qty)
  local min, t = self:LatestAHPrice(id)
  if not min then return nil end
  if not qty or qty <= 1 then return min end
  local levels, lt = self:Ladder(id)
  if not levels or #levels == 0 or (t and lt and lt < t - STALE_LEVELS) then return min, "nodepth" end
  local got, cost = 0, 0
  for _, level in ipairs(levels) do
    local take = math.min(level[2], qty - got)
    got, cost = got + take, cost + take * level[1]
    if got >= qty then return cost / qty end
  end
  return (cost + (qty - got) * levels[#levels][1]) / qty, "short"
end

-- A price curve for buying many of an item, for planning bulk purchases:
-- { levels = { { price, qty }, ... } cheapest first, vendor = unlimited vendor price }.
-- With no usable price levels the lowest price stands for an unlimited supply.
-- Returns nil when there is no price at all.
function ns:PriceCurve(id)
  local min, t = self:LatestAHPrice(id)
  local vendor = self:VendorBuyPrice(id)
  if not min and not vendor then return nil end
  local levels, lt = self:Ladder(id)
  if min and (not levels or #levels == 0 or (t and lt and lt < t - STALE_LEVELS)) then
    levels = { { min, math.huge } }
  end
  return { levels = min and levels or {}, vendor = vendor }
end

-- Total cost of buying the first q items along a curve (each unit at the cheaper
-- of the next listing and the vendor; beyond the known levels, the highest level's price).
function ns.CurveCost(curve, q)
  local got, cost, last = 0, 0, nil
  for _, level in ipairs(curve.levels) do
    local price = curve.vendor and math.min(level[1], curve.vendor) or level[1]
    local take = math.min(level[2], q - got)
    got, cost, last = got + take, cost + take * price, price
    if got >= q then return cost end
  end
  local rest = curve.vendor or last
  if not rest then return nil end
  return cost + (q - got) * rest
end

-- Cheapest way to get `qty` (default 1): price per item, "ah" | "vendor",
-- time of the AH price, depth flag (see DepthPrice). Vendors never run out.
function ns:BuyPrice(id, qty)
  local ah, t = self:LatestAHPrice(id)
  local flag
  if ah and qty and qty > 1 then ah, flag = self:DepthPrice(id, qty) end
  local vendor = self:VendorBuyPrice(id)
  if vendor and (not ah or vendor <= ah) then return vendor, "vendor" end
  if ah then return ah, "ah", t, flag end
end

-- How many crafts a recipe is priced for at once: your setting for the recipe,
-- else settings.batchCrafts (a number, or "stack" = enough crafts for one stack
-- of the product, 1 for products that don't stack). Returns crafts, why.
function ns:BatchCrafts(recipe)
  local own = recipe.spell > 0 and self.db.batchOverride[recipe.spell]
  if own then return own, "set by you" end
  local goalCrafts = self:GoalCrafts(recipe)
  if goalCrafts then return goalCrafts, ("+%s goal"):format(ns.ShortMoney(self:ProfitGoal(recipe.profession))) end
  local default = self.db.settings.batchCrafts
  if type(default) == "number" then return default, "your default" end
  if recipe.item > 0 then
    local stack = select(8, ns.GetItemInfo(recipe.item))
    if stack and stack > 1 then
      return math.max(1, math.floor(stack / ns.Yield(recipe))), ("a stack of %d"):format(stack)
    end
  end
  return 1, "doesn't stack"
end

-- Profit goal per profession ---------------------------------------------------------------
-- settings.profitGoal[profession] = copper you want to earn with that
-- profession (0/nil = off). With a goal, a recipe is priced for the crafts it
-- takes to earn it: crafts = goal / margin per craft, where the margin (the
-- better of AH and vendor) is itself worked out for that many crafts, since
-- buying more reagents walks up the price levels. Repeated until it settles.
-- GoalCrafts returns the crafts, false when the recipe can't reach the goal
-- (no margin, or the margin vanishes as the batch grows), nil without a goal.

local GOAL_MAX_CRAFTS = 5000
local goalCache, goalGen = {}, -1

function ns:ProfitGoal(profession)
  local goal = profession and self.db.settings.profitGoal[profession]
  return goal and goal > 0 and goal or nil
end

function ns:SetProfitGoal(profession, copper)
  self.db.settings.profitGoal[profession] = copper and copper > 0 and math.floor(copper) or nil
  self:NotifyChanged()
end

local function BestMargin(e) -- selling on the AH, to a vendor, or disenchanting
  local best
  for _, m in ipairs({ e.marginAH or false, e.marginVendor or false, e.marginDE or false }) do
    if m and (not best or m > best) then best = m end
  end
  return best
end
ns.BestMargin = BestMargin

function ns:GoalCrafts(recipe)
  local goal = self:ProfitGoal(recipe.profession)
  if not goal or recipe.gathered or recipe.bundle then return nil end
  if goalGen ~= self.changeGen then
    wipe(goalCache)
    goalGen = self.changeGen
  end
  local cached = goalCache[recipe]
  if cached ~= nil then return cached end
  local n, result = 1, false
  for _ = 1, 20 do
    local margin = BestMargin(self:RecipeEconomics(recipe, n))
    if not margin or margin <= 0 then break end -- can't reach it (at this size)
    local need = math.ceil(goal / margin)
    if need <= n then
      result = n
      break
    end
    if n >= GOAL_MAX_CRAFTS then
      result = GOAL_MAX_CRAFTS
      break
    end
    n = math.min(need, GOAL_MAX_CRAFTS)
  end
  goalCache[recipe] = result
  return result
end

function ns:SetBatchOverride(spell, crafts)
  self.db.batchOverride[spell] = crafts and crafts >= 1 and math.floor(crafts) or nil
  self:NotifyChanged()
end

-- Best money for one: net price, "ah" | "vendor", the AH price before the cut.
function ns:SellPrice(id)
  local ah = self:LatestAHPrice(id)
  local net = ah and math.floor(ah * (1 - self:AHCut()))
  local vendor = self:VendorSellPrice(id)
  if vendor and (not net or vendor >= net) then return vendor, "vendor", ah end
  if net then return net, "ah", ah end
end

-- Per craft: cost of buying every reagent, items made (average), what they
-- sell for (sell = per item, revenue = per craft) and the margin.
-- Selling on the auction house and to a vendor are also worked out separately:
--   ahNet / marginAH / pctAH          AH price after the cut (5%, goblin 15%)
--   vendorSell / marginVendor / pctVendor   what a vendor pays
-- margin / marginPct are for whichever of the two pays more.
-- Reagents are priced for a whole batch (see BatchCrafts): buying 6 crafts'
-- worth walks further up the price levels than buying one. e.short / e.nodepth
-- say whether some reagent ran out of known listings / had no price levels.
function ns:RecipeEconomics(recipe, batch) -- batch: crafts to price for (default BatchCrafts)
  local e = { cost = 0, missing = 0, yield = ns.Yield(recipe) }
  if batch then
    e.batch, e.batchWhy = batch, "given"
  else
    e.batch, e.batchWhy = self:BatchCrafts(recipe)
  end
  local used = self:ReagentFactor(recipe)
  for _, reagent in ipairs(recipe.reagents) do
    local price, _, _, flag = self:BuyPrice(reagent[1], reagent[2] * used * e.batch)
    if price then e.cost = e.cost + price * reagent[2] * used else e.missing = e.missing + 1 end
    if flag == "short" then e.short = true elseif flag == "nodepth" then e.nodepth = true end
  end
  e.complete = #recipe.reagents > 0 and e.missing == 0
  if recipe.item > 0 then
    e.sell, e.sellVia, e.ahPrice = self:SellPrice(recipe.item)
    e.ahNet = e.ahPrice and math.floor(e.ahPrice * (1 - self:AHCut()))
    e.vendorSell = self:VendorSellPrice(recipe.item)
  end
  if e.sell then e.revenue = math.floor(e.sell * e.yield) end
  if e.complete and e.revenue then
    e.margin = e.revenue - e.cost
    e.marginPct = e.cost > 0 and e.margin / e.cost or nil
  end
  if e.complete and e.ahNet then
    e.marginAH = math.floor(e.ahNet * e.yield) - e.cost
    e.pctAH = e.cost > 0 and e.marginAH / e.cost or nil
  end
  if e.complete and e.vendorSell then
    e.marginVendor = math.floor(e.vendorSell * e.yield) - e.cost
    e.pctVendor = e.cost > 0 and e.marginVendor / e.cost or nil
  end
  -- disenchanting the product instead of selling it (Disenchant.lua)
  if recipe.item > 0 then e.deUnit, e.deComplete = self:DisenchantItemValue(recipe.item) end
  if e.complete and e.deUnit then
    e.marginDE = math.floor(e.deUnit * e.yield) - e.cost
    e.pctDE = e.cost > 0 and e.marginDE / e.cost or nil
  end
  e.timing = self:CraftTiming(recipe)
  local perHour = e.timing and e.timing.perHour
  if perHour then
    e.ahPerHour = e.marginAH and e.marginAH * perHour
    e.vendorPerHour = e.marginVendor and e.marginVendor * perHour
    if e.marginDE then -- each item made is also disenchanted
      local de = self:DisenchantCastTime() or 0
      e.dePerHour = e.marginDE * 3600 / (e.timing.seconds + e.yield * de)
    end
  end
  return e
end

-- Crafting speed -------------------------------------------------------------------------
-- A recipe is a spell: its cast time and cooldown come from the game's spell
-- data. Crafts per hour = 3600 / cast time.
-- Recipes with a cooldown (transmutes and the like) get no per-hour figure.

local function CastTime(spell)
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(spell)
    return info and info.castTime
  end
  if GetSpellInfo then return (select(4, GetSpellInfo(spell))) end
end

-- { cast = seconds, cooldown = seconds or nil, seconds = per craft (the cast time),
--   perHour = crafts per hour or nil } or nil when the game doesn't say.
function ns:CraftTiming(recipe)
  if not recipe or recipe.gathered or recipe.spell <= 0 then return nil end
  local cast = CastTime(recipe.spell)
  if not cast then return nil end
  local t = { cast = cast / 1000 * self:CastFactor(recipe) }
  local cooldown = GetSpellBaseCooldown and GetSpellBaseCooldown(recipe.spell)
  if cooldown and cooldown > 0 then t.cooldown = cooldown / 1000 end
  t.seconds = t.cast
  if not t.cooldown and t.seconds > 0 then t.perHour = 3600 / t.seconds end
  return t
end

-- "2d", "5h", "30m" for cooldowns.
function ns.Duration(seconds)
  if seconds >= 86400 then return ("%gd"):format(math.floor(seconds / 8640 + 0.5) / 10) end
  if seconds >= 3600 then return ("%gh"):format(math.floor(seconds / 360 + 0.5) / 10) end
  return ("%dm"):format(seconds / 60 + 0.5)
end

-- Crafting tree ------------------------------------------------------------------------

--[[
  Recipe node: { recipe, qty (crafts, may be fractional), yield (items per craft),
                 children = { item node, ... },
                 unit = cost of one craft using the best choice for every reagent,
                 complete = every reagent has a price }
  Item node:   { id, qty (total needed), per (per craft of the parent),
                 buy = average price per item for buying qty, buyVia, depth (flag, see DepthPrice),
                 craft = recipe node of the cheapest maker or nil,
                 craftUnit = cost of one item by crafting (craft.unit / craft.yield),
                 makers = how many recipes make it, bestUnit, best = "buy" | "craft" }
  `path` holds items being crafted further up, so loops (A from B, B from A) stop.
]]
local CraftItem

local function CraftRecipe(self, recipe, qty, path)
  local node = { recipe = recipe, qty = qty, yield = ns.Yield(recipe), children = {}, unit = 0,
                 complete = #recipe.reagents > 0 }
  local used = self:ReagentFactor(recipe)
  for _, reagent in ipairs(recipe.reagents) do
    local per = reagent[2] * used
    local child = CraftItem(self, reagent[1], per * qty, per, path)
    node.children[#node.children + 1] = child
    if child.bestUnit then
      node.unit = node.unit + child.bestUnit * per
    else
      node.complete = false
    end
  end
  return node
end

CraftItem = function(self, id, qty, per, path)
  local node = { id = id, qty = qty, per = per }
  local _
  node.buy, node.buyVia, _, node.depth = self:BuyPrice(id, qty)
  local makers = self.recipesByItem[id]
  if makers and not path[id] then
    path[id] = true
    local best, usable = nil, 0
    for _, maker in ipairs(makers) do
      if self:CanUseRecipe(maker) then -- craft settings: professions and recipes you'd use
        usable = usable + 1
        local c = CraftRecipe(self, maker, qty / ns.Yield(maker), path)
        c.itemUnit = c.unit / c.yield
        if not best or (c.complete and (not best.complete or c.itemUnit < best.itemUnit)) then best = c end
      end
    end
    path[id] = nil
    if best then node.craft, node.makers, node.craftUnit = best, usable, best.itemUnit end
  end
  if node.craft and node.craft.complete and (not node.buy or node.craftUnit < node.buy) then
    node.bestUnit, node.best = node.craftUnit, "craft"
  elseif node.buy then
    node.bestUnit, node.best = node.buy, "buy"
  end
  return node
end

-- The tree for one batch (default: BatchCrafts). Quantities are for the whole
-- batch; unit costs stay per craft / per item.
function ns:CraftTree(recipe, batch)
  local path = {}
  if recipe.item > 0 then path[recipe.item] = true end
  return CraftRecipe(self, recipe, batch or self:BatchCrafts(recipe), path)
end

-- Cheapest way to get `qty` (default 1) of an item: buying it, or crafting it
-- (recursively). Returns cost per item (nil if unknown), "buy" | "craft", and the item node.
function ns:BestItemCost(id, qty)
  local node = CraftItem(self, id, qty or 1, qty or 1, {})
  return node.bestUnit, node.best, node
end

-- Crafting routes --------------------------------------------------------------------------
--[[
  A route is one choice of buy or craft for every reagent in the crafting tree.
  Its cost is what gets bought; its time is every craft it involves: the
  product's own craft plus each crafted reagent's crafts (needed / items per
  craft x that recipe's cast time, so 3 bars from a 2-bar smelt is
  1.5 smelts). Crafting a reagent usually saves money but costs time, so the
  route with the best margin per craft and the one with the best margin per
  hour can differ.
  Each node keeps only the routes worth considering (no other route is both
  cheaper and faster); combining those upwards gives the product's options.
    point = { cost, time, crafted = set of item nodes crafted (as a lazy tree),
              cooldown = a crafted recipe has a cooldown, approx = some cast time unknown }
]]

local MAX_POINTS = 40

local function Prune(points)
  table.sort(points, function(a, b)
    if a.cost ~= b.cost then return a.cost < b.cost end
    return a.time < b.time
  end)
  local out, fastest = {}, math.huge
  for _, p in ipairs(points) do
    if p.time < fastest - 1e-6 then
      out[#out + 1] = p
      fastest = p.time
    end
  end
  if #out > MAX_POINTS then -- keep the extremes and an even spread in between
    local thin, step = {}, (#out - 1) / (MAX_POINTS - 1)
    for i = 0, MAX_POINTS - 1 do thin[#thin + 1] = out[math.floor(i * step + 0.5) + 1] end
    out = thin
  end
  return out
end

local function Combine(a, b)
  local out = {}
  for _, x in ipairs(a) do
    for _, y in ipairs(b) do
      out[#out + 1] = {
        cost = x.cost + y.cost, time = x.time + y.time,
        crafted = (x.crafted and y.crafted) and { x.crafted, y.crafted } or x.crafted or y.crafted,
        cooldown = x.cooldown or y.cooldown, approx = x.approx or y.approx,
      }
    end
  end
  return Prune(out)
end

local RecipeRoutes

local function ItemRoutes(self, node)
  local points = {}
  if node.buy then points[1] = { cost = node.buy * node.qty, time = 0 } end
  if node.craft then
    for _, p in ipairs(RecipeRoutes(self, node.craft)) do
      points[#points + 1] = { cost = p.cost, time = p.time, crafted = { node = node, p.crafted },
                              cooldown = p.cooldown, approx = p.approx }
    end
  end
  return Prune(points)
end

RecipeRoutes = function(self, rnode)
  local timing = self:CraftTiming(rnode.recipe)
  local seconds = timing and timing.seconds or 0 -- unknown cast time: counted as instant (approx)
  local acc = { { cost = 0, time = rnode.qty * seconds, cooldown = timing and timing.cooldown ~= nil,
                  approx = timing == nil } }
  if rnode.recipe.bundle then acc[1].time, acc[1].approx = 0, false end -- a crate fill: no craft of its own
  for _, child in ipairs(rnode.children) do
    local options = ItemRoutes(self, child)
    if #options == 0 then return {} end -- a reagent with no price and no way to make it
    acc = Combine(acc, options)
  end
  return acc
end

-- Every worthwhile route (cost, time totals) for a tree from ns:CraftTree, cheapest first.
function ns:RoutePoints(root)
  return RecipeRoutes(self, root)
end

-- A crate fill as a pseudo recipe ("make one crate from qty x item"), so the
-- crafting tree and routes work for crates too.
function ns.BundleRecipe(item, qty)
  return { spell = 0, item = 0, skill = 0, reagents = { { item, qty } }, yieldMin = 1, yieldMax = 1, bundle = true }
end

-- Flattens a point's crafted set into { [itemNode] = true }.
function ns.RouteCrafted(point)
  local set = {}
  local function Walk(t)
    if not t then return end
    if t.node then set[t.node] = true end
    for _, sub in ipairs(t) do Walk(sub) end
  end
  Walk(point.crafted)
  return set
end

-- The routes for a recipe's crafting tree (root = ns:CraftTree(recipe)): best margin and
-- best margin per hour for each way to cash in the product (AH, vendor, and disenchanting
-- when it disenchants). Returns { { key, label, sell = "ah" | "vendor" | "de", point,
-- revenue, margin, perHour }, ... } (point nil when the tree can't be priced; perHour nil
-- when not meaningful). Disenchant routes add one Disenchant cast per item made to the
-- time and assume no downtime between casts.
function ns:CraftRoutes(recipe, root, e)
  local points = RecipeRoutes(self, root)
  for _, p in ipairs(points) do -- the tree is for a whole batch; report per craft
    p.cost, p.time = p.cost / root.qty, p.time / root.qty
  end
  local cheapest = points[1]
  local function BestPerHour(revenue, extra)
    local best, bestValue
    for _, p in ipairs(points) do
      if not p.cooldown and p.time + extra > 0 then
        local value = (revenue - p.cost) / (p.time + extra)
        if not bestValue or value > bestValue then best, bestValue = p, value end
      end
    end
    -- losing money either way: per hour can't be "best", show the cheapest route instead
    if bestValue and bestValue < 0 then return cheapest end
    return best or cheapest -- a cooldown recipe: per hour doesn't apply, show the cheapest route
  end
  local routes = {}
  local sells = { "ah", "vendor" }
  if e.deUnit then sells[3] = "de" end
  local deTime = e.deUnit and (self:DisenchantCastTime() or 0) * e.yield or 0 -- disenchanting what one craft makes
  for _, sell in ipairs(sells) do
    local perItem = sell == "ah" and e.ahNet or sell == "vendor" and e.vendorSell or e.deUnit
    local revenue = perItem and math.floor(perItem * e.yield)
    local label = sell == "ah" and "AH" or sell == "vendor" and "vendor" or "disenchant"
    local extra = sell == "de" and deTime or 0
    routes[#routes + 1] = { key = sell .. "Margin", label = "Best " .. label .. " margin", sell = sell,
                            point = cheapest, revenue = revenue, extra = extra }
    routes[#routes + 1] = { key = sell .. "Hour", label = "Best " .. label .. " margin/hour", sell = sell,
                            point = revenue and BestPerHour(revenue, extra) or nil, revenue = revenue, extra = extra }
  end
  for _, r in ipairs(routes) do
    local p = r.point
    if p and r.revenue then
      r.margin = r.revenue - p.cost
      if not p.cooldown and p.time + r.extra > 0 then r.perHour = r.margin / (p.time + r.extra) * 3600 end
    end
  end
  table.sort(routes, function(a, b) -- margins (AH, vendor, DE), then per hour (AH, vendor, DE)
    local order = { ahMargin = 1, vendorMargin = 2, deMargin = 3, ahHour = 4, vendorHour = 5, deHour = 6 }
    return order[a.key] < order[b.key]
  end)
  return routes
end

-- The tree as display rows: { depth, node } for every item node, depth first.
function ns.FlattenTree(root)
  local rows = {}
  local function Walk(node, depth)
    rows[#rows + 1] = { depth = depth, node = node }
    if node.craft then
      for _, child in ipairs(node.craft.children) do Walk(child, depth + 1) end
    end
  end
  for _, child in ipairs(root.children) do Walk(child, 0) end
  return rows
end

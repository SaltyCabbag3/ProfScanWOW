local _, ns = ...

-- Extra item IDs to scan. The scan list is mostly built from the recipe and
-- trade company data (see ns:RebuildItems in Core.lua): every reagent, gathered
-- herbs and fish, and the trade company items. Anything listed here is scanned
-- as well; the groups are only for readability. Add IDs freely, then /reload.
ns.WATCH = {
  Mining = {
    2770, 2771, 2775, 2772, 2776, 7911, 3858, 10620,          -- ores
    2840, 3576, 2841, 2842, 3575, 3577, 3859, 6037, 3860, 12359, 12360, -- bars
    2835, 2836, 2838, 7912, 12365,                            -- stones
    12363,                                                    -- Arcane Crystal
  },
  Herbalism = {
    2447, 765, 2449, 785, 2450, 3356, 3818, 3821, 4625,
    8836, 8838, 8846, 13463, 13464, 13465, 13466, 13467, 13468,
  },
  Cloth = { 2589, 2592, 4306, 4338, 14047, 14256 },
  Leather = { 2318, 2319, 4234, 4304, 8170 },
  Enchanting = {
    10940, 11083, 11137, 11176, 16204,                        -- dusts
    16202, 16203,                                             -- essences
    14343, 14344,                                             -- shards
  },
  Elemental = {
    7067, 7068, 7069, 7070,                                   -- Elemental Earth/Fire/Air/Water
    7076, 7078, 7080, 7082, 12803, 12808,                     -- essences
  },
}

-- Loot pool for the building floor-scatter system (LootFloorArea markers,
-- rolled in StartMatch.lua's Spawn_Building_Loot via CrateLoot.weighted_pick
-- — same weighted-pick shape as CrateData, so it reuses that helper instead
-- of a second copy of the same 10 lines). [stated] design: this is
-- deliberately a much lower-value/lower-stakes pool than CrateData — ambient
-- loot found just by walking through a building, not from opening a crate.
-- Food/drink items (previously not obtainable anywhere in-game at all) plus
-- the Backpack and ONLY the tier 1 weapons; [stated] tier 2/3 weapons and
-- all armor stay crate-exclusive, not included here at all.
return {
	RollCount = {min = 0, max = 2}, -- placeholder, tune once tested — how many items one LootFloorArea marker rolls
	LootPool = {
		-- Food — meal tier (Value 350)
		{ItemName = "Beans Can", Weight = 10},
		{ItemName = "Bread Can", Weight = 10},
		{ItemName = "Corn Can", Weight = 10},
		{ItemName = "Green Bean Can", Weight = 10},
		{ItemName = "Green Pea Soup", Weight = 10},
		{ItemName = "Hotdog Can", Weight = 10},
		{ItemName = "Meat Can", Weight = 10},
		{ItemName = "Mushroom Soup", Weight = 10},
		{ItemName = "Tomato Can", Weight = 10},
		{ItemName = "Tuna Can", Weight = 10},
		{ItemName = "Ramen 1", Weight = 10},
		{ItemName = "Ramen 2", Weight = 10},
		{ItemName = "Ramen 3", Weight = 10},
		-- Food — snack tier (Value 180)
		{ItemName = "Apricot Can", Weight = 12},
		{ItemName = "Orange Can", Weight = 12},
		{ItemName = "Cereal 1", Weight = 12},
		{ItemName = "Cereal 2", Weight = 12},
		{ItemName = "Chips 1", Weight = 12},
		{ItemName = "Chips 2", Weight = 12},
		{ItemName = "Chips 3", Weight = 12},
		{ItemName = "Chips 4", Weight = 12},
		{ItemName = "Chocolate 1", Weight = 12},
		{ItemName = "Chocolate 2", Weight = 12},
		{ItemName = "Chocolate 3", Weight = 12},
		{ItemName = "Chocolate 4", Weight = 12},
		-- Drinks
		{ItemName = "Bloxy Cola 1", Weight = 10},
		{ItemName = "Bloxy Cola 2", Weight = 10},
		{ItemName = "Bloxy Cola 3", Weight = 10},
		{ItemName = "Bloxy Cola 4", Weight = 10},
		{ItemName = "Soda 1", Weight = 10},
		{ItemName = "Soda 2", Weight = 10},
		{ItemName = "Soda 3", Weight = 10},
		{ItemName = "Coffee", Weight = 10},
		-- Equipment — deliberately rarer than food/drink. [stated] no armor,
		-- no tier 2/3 weapons here — those stay crate-only.
		{ItemName = "Backpack", Weight = 4},
		{ItemName = "Tier 1 Mace", Weight = 5},
		{ItemName = "Tier 1 Twohanded Axe", Weight = 4},
	},
}
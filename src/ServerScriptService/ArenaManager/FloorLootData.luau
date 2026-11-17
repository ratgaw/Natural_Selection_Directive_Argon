-- Loot for LootFloorArea scatter in buildings (picked with CrateLoot.weighted_pick).
-- Lower value than crates: food, drinks, the Backpack and tier 1 weapons only.
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
		-- Rarer than food. No armor or tier 2/3 weapons (crate-only).
		{ItemName = "Backpack", Weight = 4},
		{ItemName = "Tier 1 Mace", Weight = 5},
		{ItemName = "Tier 1 Twohanded Axe", Weight = 4},
	},
}
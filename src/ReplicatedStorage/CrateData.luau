return {
	["Standard"] = {
		RollCount = {min = 2, max = 4},
		-- [stated] "add food items to... standard crates, with stack
		-- amounts from 1 to 3" -- read by CrateLoot.get_or_roll_contents
		-- whenever a roll lands on a LootPool entry with Food = true
		-- below; everything else always rolls Amount = 1.
		FoodStackRange = {min = 1, max = 3},
		LootPool = {
			{ItemName = "Gray Chestplate", Weight = 10},
			{ItemName = "Gray Greaves", Weight = 10},
			{ItemName = "Gray Helmet", Weight = 10},
			{ItemName = "Tier 1 Mace", Weight = 20},
			{ItemName = "Tier 1 Twohanded Axe", Weight = 15},
			{ItemName = "Terrain Scanner", Weight = 5},
			{ItemName = "Strength Stim", Weight = 8},
			{ItemName = "Endurance Stim", Weight = 8},
			{ItemName = "Dexterity Stim", Weight = 8},
			-- [stated] "food items added to... standard crates" -- the
			-- full Safety Certified roster from ItemData.lua (the real
			-- canned/packaged food+drink models, not the older "Canned
			-- Rations" placeholder those superseded). Deliberately leaves
			-- out Nutrient Paste (Engineered tier -- too strong for this
			-- roll), Preserved Berries (its own foraging-only acquisition
			-- path) and Spoiled Rations (a degraded-food penalty item, not
			-- a reward) and Raw Meat (has no Food field at all -- can't
			-- actually be eaten yet). Meals weighted lowest per item (more
			-- filling), snacks highest (least filling, most common),
			-- drinks in between -- every item within a category shares
			-- that category's weight so flavor variant (which can you get)
			-- is an even roll once the category itself is picked.
			-- Placeholders, tune once tested, same as every other weight
			-- in this file.
			{ItemName = "Beans Can", Weight = 2, Food = true},
			{ItemName = "Bread Can", Weight = 2, Food = true},
			{ItemName = "Corn Can", Weight = 2, Food = true},
			{ItemName = "Green Bean Can", Weight = 2, Food = true},
			{ItemName = "Green Pea Soup", Weight = 2, Food = true},
			{ItemName = "Hotdog Can", Weight = 2, Food = true},
			{ItemName = "Meat Can", Weight = 2, Food = true},
			{ItemName = "Mushroom Soup", Weight = 2, Food = true},
			{ItemName = "Tomato Can", Weight = 2, Food = true},
			{ItemName = "Tuna Can", Weight = 2, Food = true},
			{ItemName = "Ramen 1", Weight = 2, Food = true},
			{ItemName = "Ramen 2", Weight = 2, Food = true},
			{ItemName = "Ramen 3", Weight = 2, Food = true},
			{ItemName = "Apricot Can", Weight = 3, Food = true},
			{ItemName = "Orange Can", Weight = 3, Food = true},
			{ItemName = "Cereal 1", Weight = 3, Food = true},
			{ItemName = "Cereal 2", Weight = 3, Food = true},
			{ItemName = "Chips 1", Weight = 3, Food = true},
			{ItemName = "Chips 2", Weight = 3, Food = true},
			{ItemName = "Chips 3", Weight = 3, Food = true},
			{ItemName = "Chips 4", Weight = 3, Food = true},
			{ItemName = "Chocolate 1", Weight = 3, Food = true},
			{ItemName = "Chocolate 2", Weight = 3, Food = true},
			{ItemName = "Chocolate 3", Weight = 3, Food = true},
			{ItemName = "Chocolate 4", Weight = 3, Food = true},
			{ItemName = "Bloxy Cola 1", Weight = 2, Food = true},
			{ItemName = "Bloxy Cola 2", Weight = 2, Food = true},
			{ItemName = "Bloxy Cola 3", Weight = 2, Food = true},
			{ItemName = "Bloxy Cola 4", Weight = 2, Food = true},
			{ItemName = "Soda 1", Weight = 2, Food = true},
			{ItemName = "Soda 2", Weight = 2, Food = true},
			{ItemName = "Soda 3", Weight = 2, Food = true},
			{ItemName = "Coffee", Weight = 2, Food = true},
		},
	},
	["Advanced"] = {
		RollCount = {min = 2, max = 4},
		-- [stated] "stack amounts... 2 to 5 food items for advanced crates"
		FoodStackRange = {min = 2, max = 5},
		LootPool = {
			{ItemName = "Gray Chestplate", Weight = 8},
			{ItemName = "Gray Greaves", Weight = 8},
			{ItemName = "Gray Helmet", Weight = 8},
			-- [stated] Scavenger + Raider are Tier 2 armor -- placed here
			-- alongside the Tier 2 weapons below (and NOT in Standard or
			-- Elite), same crate-tier logic already used for the Mace/Axe
			-- tiers. Weights mirror Gray Armor's own Advanced-pool weight
			-- (8) for the individually-slotted Raider pieces; the Scavenger
			-- Jacket gets the same weight despite covering 2 slots at once,
			-- since a single roll of it already does the job 2 separate
			-- rolls would otherwise need to. Placeholders, tune once tested.
			{ItemName = "Scavenger Jacket", Weight = 8},
			{ItemName = "Scavenger Helmet", Weight = 8},
			{ItemName = "Raider Chestplate", Weight = 8},
			{ItemName = "Raider Greaves", Weight = 8},
			{ItemName = "Raider Helmet", Weight = 8},
			{ItemName = "Tier 2 Mace", Weight = 18},
			{ItemName = "Tier 2 Twohanded Axe", Weight = 15},
			{ItemName = "Terrain Scanner", Weight = 8},
			{ItemName = "Strength Stim", Weight = 10},
			{ItemName = "Endurance Stim", Weight = 10},
			{ItemName = "Dexterity Stim", Weight = 10},
			{ItemName = "Strength Injector", Weight = 3},
			{ItemName = "Endurance Injector", Weight = 3},
			{ItemName = "Dexterity Injector", Weight = 3},
			-- [stated] "food items added to... advanced crates" -- same
			-- roster and reasoning as Standard above, weighted up slightly
			-- (mirrors how Terrain Scanner/Stims also step up from
			-- Standard to Advanced) since Advanced's pool sits at a higher
			-- weight scale overall. Placeholders, tune once tested.
			{ItemName = "Beans Can", Weight = 3, Food = true},
			{ItemName = "Bread Can", Weight = 3, Food = true},
			{ItemName = "Corn Can", Weight = 3, Food = true},
			{ItemName = "Green Bean Can", Weight = 3, Food = true},
			{ItemName = "Green Pea Soup", Weight = 3, Food = true},
			{ItemName = "Hotdog Can", Weight = 3, Food = true},
			{ItemName = "Meat Can", Weight = 3, Food = true},
			{ItemName = "Mushroom Soup", Weight = 3, Food = true},
			{ItemName = "Tomato Can", Weight = 3, Food = true},
			{ItemName = "Tuna Can", Weight = 3, Food = true},
			{ItemName = "Ramen 1", Weight = 3, Food = true},
			{ItemName = "Ramen 2", Weight = 3, Food = true},
			{ItemName = "Ramen 3", Weight = 3, Food = true},
			{ItemName = "Apricot Can", Weight = 4, Food = true},
			{ItemName = "Orange Can", Weight = 4, Food = true},
			{ItemName = "Cereal 1", Weight = 4, Food = true},
			{ItemName = "Cereal 2", Weight = 4, Food = true},
			{ItemName = "Chips 1", Weight = 4, Food = true},
			{ItemName = "Chips 2", Weight = 4, Food = true},
			{ItemName = "Chips 3", Weight = 4, Food = true},
			{ItemName = "Chips 4", Weight = 4, Food = true},
			{ItemName = "Chocolate 1", Weight = 4, Food = true},
			{ItemName = "Chocolate 2", Weight = 4, Food = true},
			{ItemName = "Chocolate 3", Weight = 4, Food = true},
			{ItemName = "Chocolate 4", Weight = 4, Food = true},
			{ItemName = "Bloxy Cola 1", Weight = 3, Food = true},
			{ItemName = "Bloxy Cola 2", Weight = 3, Food = true},
			{ItemName = "Bloxy Cola 3", Weight = 3, Food = true},
			{ItemName = "Bloxy Cola 4", Weight = 3, Food = true},
			{ItemName = "Soda 1", Weight = 3, Food = true},
			{ItemName = "Soda 2", Weight = 3, Food = true},
			{ItemName = "Soda 3", Weight = 3, Food = true},
			{ItemName = "Coffee", Weight = 3, Food = true},
		},
	},
	["Elite"] = {
		RollCount = {min = 2, max = 4},
		LootPool = {
			{ItemName = "Tier 3 Mace", Weight = 15},
			{ItemName = "Tier 3 Twohanded Axe", Weight = 15},
			{ItemName = "Terrain Scanner", Weight = 10},
			{ItemName = "Strength Injector", Weight = 12},
			{ItemName = "Endurance Injector", Weight = 12},
			{ItemName = "Dexterity Injector", Weight = 12},
		},
	},
}
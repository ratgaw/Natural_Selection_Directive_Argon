return {
	["Gray Chestplate"] = {
		Icon = "rbxassetid://0",
		Description = "Standard-issue G.S.S infantry armor. Developed during the later half of the Fracture Wars its low material cost and simple design keep it in use 72 years later.",
		Equipable = true,
		EquipSlots = {"Torso"},
		ArmorTemplate = "Gray Armor",
		Pieces = {"Chest", "LeftShoulder", "RightShoulder"},
		Defense = 8, -- placeholder, tune alongside the other 2 pieces below
		Weight = 7, -- placeholder — Phase 2 weight system, tune alongside the rest of this file
	},
	["Gray Greaves"] = {
		Icon = "rbxassetid://0",
		Description = "Standard-issue G.S.S infantry greaves w/ belt. Prototypes of these greaves included more armor, but proved too cumbersome in testing, leading to the modern design.",
		Equipable = true,
		EquipSlots = {"Legs"},
		ArmorTemplate = "Gray Armor",
		Pieces = {"Belt", "LeftKnee", "RightKnee"},
		Defense = 6, -- placeholder
		Weight = 5, -- placeholder
	},
	["Gray Helmet"] = {
		Icon = "rbxassetid://0",
		Description = "Standard-issue G.S.S infantry helmet w/ goggles. The goggled helmet variant become the G.S.S standard after the increase of A.F.Es (Anomalous Fog Events).",
		Equipable = true,
		EquipSlots = {"Head"},
		ArmorTemplate = "Gray Armor",
		Pieces = {"Helmet"},
		Defense = 4, -- placeholder
		Weight = 3, -- placeholder
	},
	-- Scavenger Armor (Tier 2): the Jacket fills both Torso and Legs (EquipSlots
	-- {"Torso", "Legs"}) and grants MaxCarryWeightBonus to make up for covering
	-- two slots with less Defense. Tier is metadata only; Tier 2 armor goes in
	-- the Advanced crate pool. Numbers are placeholders.
	["Scavenger Jacket"] = {
		Icon = "rbxassetid://0",
		Description = "A scavenged coat, reinforced with scrap plating. Doesn't cover much, but it covers what it needs to.",
		Equipable = true,
		EquipSlots = {"Torso", "Legs"},
		ArmorTemplate = "Scavenger Armor",
		Pieces = {"Chest", "LeftShoulder", "RightShoulder", "LeftLowerSleeve", "RightLowerSleeve", "LeftLowerJacket", "RightLowerJacket", "LeftBoot", "RightBoot"},
		Tier = 2,
		Defense = 7, -- placeholder
		Weight = 8, -- placeholder
		MaxCarryWeightBonus = 10, -- placeholder -- compensates for the Jacket covering 2 slots at reduced Defense
	},
	["Scavenger Helmet"] = {
		Icon = "rbxassetid://0",
		Description = "A patched-together scavenger's helmet.",
		Equipable = true,
		EquipSlots = {"Head"},
		ArmorTemplate = "Scavenger Armor",
		Pieces = {"Helmet"},
		Tier = 2,
		Defense = 3, -- placeholder
		Weight = 2, -- placeholder
	},
	-- Raider Armor (Tier 2): three separate pieces like Gray Armor, no carry bonus.
	-- Placeholders.
	["Raider Chestplate"] = {
		Icon = "rbxassetid://0",
		Description = "Scrap plating lashed over a leather base. Heavy, crude, and it holds.",
		Equipable = true,
		EquipSlots = {"Torso"},
		ArmorTemplate = "Raider Armor",
		Pieces = {"Chest", "LeftShoulder", "RightShoulder", "LeftLowerGuard", "RightLowerGuard"},
		Tier = 2,
		Defense = 9, -- placeholder
		Weight = 9, -- placeholder
	},
	["Raider Greaves"] = {
		Icon = "rbxassetid://0",
		Description = "Matching leg plating, full coverage from hip to shin.",
		Equipable = true,
		EquipSlots = {"Legs"},
		ArmorTemplate = "Raider Armor",
		Pieces = {"LeftUpperGreaves", "RightUpperGreaves", "LeftBoot", "RightBoot"},
		Tier = 2,
		Defense = 7, -- placeholder
		Weight = 7, -- placeholder
	},
	["Raider Helmet"] = {
		Icon = "rbxassetid://0",
		Description = "A scavenged, dented helmet, welded and re-welded more than once.",
		Equipable = true,
		EquipSlots = {"Head"},
		ArmorTemplate = "Raider Armor",
		Pieces = {"Helmet"},
		Tier = 2,
		Defense = 4, -- placeholder
		Weight = 3, -- placeholder
	},
	["Terrain Scanner"] = {
		Icon = "rbxassetid://0",
		Description = "Reveals terrain data on your tactical map.",
		MinimapUpgrade = "Terrain",
		Weight = 1, -- placeholder
	},
	["Tier 1 Mace"] = {
		Icon = "rbxassetid://0",
		Description = "A crude length of pipe. Better than fists.",
		Equipable = true,
		EquipSlots = {"Weapon"},
		WeaponModel = "Tier1MacePipe",
		Damage = 12,
		Range = 8,
		ConeAngle = 100,
		AttackStaminaCost = 15,
		AttackCooldown = 0.6,
		Weight = 6, -- placeholder
	},
	["Tier 2 Mace"] = {
		Icon = "rbxassetid://0",
		Description = "A police-issue baton, solid and reliable.",
		Equipable = true,
		EquipSlots = {"Weapon"},
		WeaponModel = "Tier2MacePoliceBaton",
		Damage = 20,
		Range = 8.5,
		ConeAngle = 100,
		AttackStaminaCost = 18,
		AttackCooldown = 0.55,
		Weight = 8, -- placeholder
	},
	["Tier 3 Mace"] = {
		Icon = "rbxassetid://0",
		Description = "A flanged mace, built to crush.",
		Equipable = true,
		EquipSlots = {"Weapon"},
		WeaponModel = "Tier3MaceFlangedMace",
		Damage = 30,
		Range = 9.0,
		ConeAngle = 100,
		AttackStaminaCost = 22,
		AttackCooldown = 0.5,
		Weight = 10, -- placeholder
	},
	-- 1-handed swords: the faster, lighter counterpart to maces -- lower weight,
	-- cost, cooldown and cone, slightly less damage and range. Placeholders.
	["Tier 1 Sword"] = {
		Icon = "rbxassetid://0",
		Description = "A dulled training sword. Light and easy to swing, if not much of a weapon.",
		Equipable = true,
		EquipSlots = {"Weapon"},
		WeaponModel = "Tier1TrainingSword",
		Damage = 10,
		Range = 8.5,
		ConeAngle = 90,
		AttackStaminaCost = 12,
		AttackCooldown = 0.5,
		Weight = 5, -- placeholder
	},
	["Tier 2 Sword"] = {
		Icon = "rbxassetid://0",
		Description = "A well-kept historical blade, still sharp despite its age.",
		Equipable = true,
		EquipSlots = {"Weapon"},
		WeaponModel = "Tier2HistoricalSword",
		Damage = 17,
		Range = 9,
		ConeAngle = 90,
		AttackStaminaCost = 15,
		AttackCooldown = 0.45,
		Weight = 6, -- placeholder
	},
	["Tier 3 Sword"] = {
		Icon = "rbxassetid://0",
		Description = "A modern military-issue blade, balanced for speed as much as force.",
		Equipable = true,
		EquipSlots = {"Weapon"},
		WeaponModel = "Tier3MilitarySword",
		Damage = 26,
		Range = 9.5,
		ConeAngle = 90,
		AttackStaminaCost = 18,
		AttackCooldown = 0.4,
		Weight = 7, -- placeholder
	},
	["Tier 1 Twohanded Axe"] = {
		Icon = "rbxassetid://0",
		Description = "Used for splitting wood, it will work well enough for self defense.",
		Equipable = true,
		EquipSlots = {"Weapon"},
		WeaponModel = "Tier1AxeWoodAxe",
		Damage = 18,
		Range = 11,
		ConeAngle = 70,
		AttackStaminaCost = 27,
		AttackCooldown = 0.75,
		Weight = 9, -- placeholder
	},
	["Tier 2 Twohanded Axe"] = {
		Icon = "rbxassetid://0",
		Description = "Firefighters would use these to break through buildings, you won't need to do quite as much with this.",
		Equipable = true,
		EquipSlots = {"Weapon"},
		WeaponModel = "Tier2AxeFireaxe",
		Damage = 35,
		Range = 13,
		ConeAngle = 70,
		AttackStaminaCost = 30,
		AttackCooldown = 0.70,
		Weight = 12, -- placeholder
	},
	["Tier 3 Twohanded Axe"] = {
		Icon = "rbxassetid://0",
		Description = "The design harkens images of the executioner's axe, although executions have only been carried out via desintigration since the end of the Fracture War.",
		Equipable = true,
		EquipSlots = {"Weapon"},
		WeaponModel = "Tier3AxeMilitaryAxe",
		Damage = 45,
		Range = 15,
		ConeAngle = 70,
		AttackStaminaCost = 35,
		AttackCooldown = 0.80,
		Weight = 15, -- placeholder
	},
	-- Bows (charge-draw ranged weapons). Tier 1 is a sling, Tier 2 a recurve bow;
	-- Tier 3 (compound bow) isn't set up yet. Damage/range/accuracy live in
	-- PlayerCombat's BOW_DATA (they scale with draw time). IsRanged tells
	-- CombatInput (client) to send draw requests instead of AttackRequest.
	["Tier 1 Bow"] = {
		Icon = "rbxassetid://0",
		Description = "A simple leather sling. Takes a moment to wind up, but it'll put a stone through flesh just the same.",
		Equipable = true,
		EquipSlots = {"Weapon"},
		WeaponModel = "Sling",
		IsRanged = true,
		Weight = 2, -- placeholder
	},
	["Tier 2 Bow"] = {
		Icon = "rbxassetid://0",
		Description = "A recurve bow. Takes a moment to draw, hits harder the longer you hold it.",
		Equipable = true,
		EquipSlots = {"Weapon"},
		WeaponModel = "Empty Bow",
		IsRanged = true,
		Weight = 4, -- placeholder
	},
	["Raw Meat"] = {
		Icon = "rbxassetid://0",
		Description = "Freshly harvested meat. Needs to be cooked before eating, probably.",
		Weight = 1, -- placeholder
	},
	-- Stat-boost consumables, used via UseItemRequest. Names are placeholders.
	["Strength Stim"] = {
		Icon = "rbxassetid://0",
		Description = "A single-use combat stimulant. Permanently increases Strength by 1.",
		StatBoost = {Stat = "Strength", Amount = 1},
		Weight = 0.5, -- placeholder
	},
	["Endurance Stim"] = {
		Icon = "rbxassetid://0",
		Description = "A single-use combat stimulant. Permanently increases Endurance by 1.",
		StatBoost = {Stat = "Endurance", Amount = 1},
		Weight = 0.5, -- placeholder
	},
	["Dexterity Stim"] = {
		Icon = "rbxassetid://0",
		Description = "A single-use combat stimulant. Permanently increases Dexterity by 1.",
		StatBoost = {Stat = "Dexterity", Amount = 1},
		Weight = 0.5, -- placeholder
	},
	["Strength Injector"] = {
		Icon = "rbxassetid://0",
		Description = "A rare, concentrated dose. Permanently increases Strength by 3.",
		StatBoost = {Stat = "Strength", Amount = 3},
		Weight = 0.5, -- placeholder
	},
	["Endurance Injector"] = {
		Icon = "rbxassetid://0",
		Description = "A rare, concentrated dose. Permanently increases Endurance by 3.",
		StatBoost = {Stat = "Endurance", Amount = 3},
		Weight = 0.5, -- placeholder
	},
	["Dexterity Injector"] = {
		Icon = "rbxassetid://0",
		Description = "A rare, concentrated dose. Permanently increases Dexterity by 3.",
		StatBoost = {Stat = "Dexterity", Amount = 3},
		Weight = 0.5, -- placeholder
	},
	-- Food: Food.Tier sets the hunger cap (PlayerHunger.TIER_FLOOR), Food.Value is
	-- how much hunger it removes. Placeholders.
	["Nutrient Paste"] = {
		Icon = "rbxassetid://0",
		Description = "Engineered ration, calorie-dense and shelf-stable for decades. The only food worth eating if you want to feel GOOD, not just full.",
		Food = {Tier = "Engineered", Value = 900},
		Weight = 1, -- placeholder
	},
	["Canned Rations"] = {
		Icon = "rbxassetid://0",
		Description = "Safety-certified canned goods. Filling, nothing special.",
		Food = {Tier = "Safety Certified", Value = 350},
		Weight = 1.5, -- placeholder
	},
	["Preserved Berries"] = {
		Icon = "rbxassetid://0",
		Description = "Foraged and dried. Better than starving, not much better than that.",
		Food = {Tier = "Foraged", Value = 200},
		Weight = 0.5, -- placeholder
	},
	["Spoiled Rations"] = {
		Icon = "rbxassetid://0",
		Description = "Canned goods long past safe. Edible, if you're desperate — and it shows.",
		Food = {Tier = "Spoiled", Value = 100, SpoiledDamage = 5},
		Weight = 1.5, -- placeholder
	},
	-- Packaged food (Safety Certified): meals Value 350, snacks Value 180.
	-- Food and drinks are also equipable in the Weapon slot (WeaponModel): held in
	-- hand, left-click eats; WeaponModel also gives them a real dropped model.
	["Beans Can"] = {Icon = "rbxassetid://0", Description = "Canned beans. A field staple.", Food = {Tier = "Safety Certified", Value = 350}, Weight = 1.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "BeansCan"},
	["Bread Can"] = {Icon = "rbxassetid://0", Description = "Canned bread. Dense, heavy, filling.", Food = {Tier = "Safety Certified", Value = 350}, Weight = 1.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "BreadCan"},
	["Corn Can"] = {Icon = "rbxassetid://0", Description = "Canned corn, sweet and simple.", Food = {Tier = "Safety Certified", Value = 350}, Weight = 1.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "CornCan"},
	["Green Bean Can"] = {Icon = "rbxassetid://0", Description = "Canned green beans.", Food = {Tier = "Safety Certified", Value = 350}, Weight = 1.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "GreenBeanCan"},
	["Green Pea Soup"] = {Icon = "rbxassetid://0", Description = "Thick pea soup, straight from the can.", Food = {Tier = "Safety Certified", Value = 350}, Weight = 1.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "GreenPeaSoup"},
	["Hotdog Can"] = {Icon = "rbxassetid://0", Description = "Canned hotdogs. Better hot, edible cold.", Food = {Tier = "Safety Certified", Value = 350}, Weight = 1.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "HotdogCan"},
	["Meat Can"] = {Icon = "rbxassetid://0", Description = "Canned meat of indeterminate origin. Filling regardless.", Food = {Tier = "Safety Certified", Value = 350}, Weight = 1.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "MeatCan"},
	["Mushroom Soup"] = {Icon = "rbxassetid://0", Description = "Canned cream of mushroom soup.", Food = {Tier = "Safety Certified", Value = 350}, Weight = 1.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "MushroomSoup"},
	["Tomato Can"] = {Icon = "rbxassetid://0", Description = "Canned tomatoes.", Food = {Tier = "Safety Certified", Value = 350}, Weight = 1.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "TomatoCan"},
	["Tuna Can"] = {Icon = "rbxassetid://0", Description = "Canned tuna. Protein-dense.", Food = {Tier = "Safety Certified", Value = 350}, Weight = 1.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "TunaCan"},
	["Ramen 1"] = {Icon = "rbxassetid://0", Description = "A pack of instant ramen. Doesn't need to be hot to eat.", Food = {Tier = "Safety Certified", Value = 350}, Weight = 1.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Ramen1"},
	["Ramen 2"] = {Icon = "rbxassetid://0", Description = "A pack of instant ramen, different flavor packet.", Food = {Tier = "Safety Certified", Value = 350}, Weight = 1.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Ramen2"},
	["Ramen 3"] = {Icon = "rbxassetid://0", Description = "A pack of instant ramen, different flavor packet.", Food = {Tier = "Safety Certified", Value = 350}, Weight = 1.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Ramen3"},
	["Apricot Can"] = {Icon = "rbxassetid://0", Description = "Canned apricots in syrup. Light, sweet, not very filling.", Food = {Tier = "Safety Certified", Value = 180}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "ApricotCan"},
	["Orange Can"] = {Icon = "rbxassetid://0", Description = "Canned orange segments in syrup.", Food = {Tier = "Safety Certified", Value = 180}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "OrangeCan"},
	["Cereal 1"] = {Icon = "rbxassetid://0", Description = "A small box of cereal. Fine dry, better with milk you don't have.", Food = {Tier = "Safety Certified", Value = 180}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Cereal1"},
	["Cereal 2"] = {Icon = "rbxassetid://0", Description = "A small box of cereal, different brand.", Food = {Tier = "Safety Certified", Value = 180}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Cereal2"},
	["Chips 1"] = {Icon = "rbxassetid://0", Description = "A bag of chips. Mostly air.", Food = {Tier = "Safety Certified", Value = 180}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Chips1"},
	["Chips 2"] = {Icon = "rbxassetid://0", Description = "A bag of chips, different flavor.", Food = {Tier = "Safety Certified", Value = 180}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Chips2"},
	["Chips 3"] = {Icon = "rbxassetid://0", Description = "A bag of chips, different flavor.", Food = {Tier = "Safety Certified", Value = 180}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Chips3"},
	["Chips 4"] = {Icon = "rbxassetid://0", Description = "A bag of chips, different flavor.", Food = {Tier = "Safety Certified", Value = 180}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Chips4"},
	["Chocolate 1"] = {Icon = "rbxassetid://0", Description = "A chocolate bar. Melted and reset more than once, probably.", Food = {Tier = "Safety Certified", Value = 180}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Chocolate1"},
	["Chocolate 2"] = {Icon = "rbxassetid://0", Description = "A chocolate bar, different brand.", Food = {Tier = "Safety Certified", Value = 180}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Chocolate2"},
	["Chocolate 3"] = {Icon = "rbxassetid://0", Description = "A chocolate bar, different brand.", Food = {Tier = "Safety Certified", Value = 180}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Chocolate3"},
	["Chocolate 4"] = {Icon = "rbxassetid://0", Description = "A chocolate bar, different brand.", Food = {Tier = "Safety Certified", Value = 180}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Chocolate4"},
	-- Drinks: less hunger relief than food, plus an instant stamina restore
	-- (Food.StaminaRestore). Coffee gives the most stamina.
	["Bloxy Cola 1"] = {Icon = "rbxassetid://0", Description = "A can of Bloxy Cola.", Food = {Tier = "Safety Certified", Value = 100, StaminaRestore = 20}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "BloxyCola1"},
	["Bloxy Cola 2"] = {Icon = "rbxassetid://0", Description = "A can of Bloxy Cola, different can art.", Food = {Tier = "Safety Certified", Value = 100, StaminaRestore = 20}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "BloxyCola2"},
	["Bloxy Cola 3"] = {Icon = "rbxassetid://0", Description = "A can of Bloxy Cola, different can art.", Food = {Tier = "Safety Certified", Value = 100, StaminaRestore = 20}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "BloxyCola3"},
	["Bloxy Cola 4"] = {Icon = "rbxassetid://0", Description = "A can of Bloxy Cola, different can art.", Food = {Tier = "Safety Certified", Value = 100, StaminaRestore = 20}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "BloxyCola4"},
	["Soda 1"] = {Icon = "rbxassetid://0", Description = "A can of soda.", Food = {Tier = "Safety Certified", Value = 90, StaminaRestore = 18}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Soda1"},
	["Soda 2"] = {Icon = "rbxassetid://0", Description = "A can of soda, different flavor.", Food = {Tier = "Safety Certified", Value = 90, StaminaRestore = 18}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Soda2"},
	["Soda 3"] = {Icon = "rbxassetid://0", Description = "A can of soda, different flavor.", Food = {Tier = "Safety Certified", Value = 90, StaminaRestore = 18}, Weight = 0.5, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Soda3"},
	["Coffee"] = {Icon = "rbxassetid://0", Description = "Black coffee, gone cold. Barely fills you up, but it'll keep you moving.", Food = {Tier = "Safety Certified", Value = 60, StaminaRestore = 30}, Weight = 0.3, Equipable = true, EquipSlots = {"Weapon"}, WeaponModel = "Coffee"},
	-- Backpack: reduces inventory weight by a percentage (not worn gear), but
	-- sprinting costs more stamina. Placeholders.
	["Backpack"] = {
		Icon = "rbxassetid://0",
		Description = "A sturdy pack that reorganizes your carried gear, lightening the load — at the cost of faster stamina burn while sprinting.",
		Equipable = true,
		EquipSlots = {"Bag"},
		BackpackModel = "Backpack",
		WeightReductionPercent = 0.2,
		SprintDrainBonusPercent = 0.25,
		Weight = 2, -- placeholder — the pack itself still weighs something, halved like other equipped gear
	},
}
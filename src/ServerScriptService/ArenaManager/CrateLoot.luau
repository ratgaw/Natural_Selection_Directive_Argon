local replicated_storage = game:GetService("ReplicatedStorage")
local arena_manager_folder = script.Parent
local player_inventory = require(arena_manager_folder.Parent.PlayerInventory)
local crate_data = require(replicated_storage:WaitForChild("CrateData"))
local beacon_crate_looted = replicated_storage:WaitForChild("BeaconCrateLooted")
local CrateLoot = {}
CrateLoot.crate_contents = {}
CrateLoot.verified_crates = {} -- verified_crates[crate_instance] = true — set ONLY by the server, at spawn time
-- Marks a crate instance as legitimately spawned by the server for request checks
function CrateLoot.register_crate(crate_instance)
	CrateLoot.verified_crates[crate_instance] = true
end
function CrateLoot.is_verified(crate_instance)
	return CrateLoot.verified_crates[crate_instance] == true
end
-- Function picks items from pool with adjustable weight for rarity among items in pool.
-- Exposed as CrateLoot.weighted_pick too — StartMatch's building floor-loot
-- scatter system (FloorLootData) rolls single items the same weighted way
-- crates do, rather than duplicating this logic.
local function Weighted_Pick(pool)
	local total_weight = 0
	for _, entry in ipairs(pool) do
		total_weight += entry.Weight
	end
	local roll = math.random() * total_weight
	local cumulative = 0
	for _, entry in ipairs(pool) do
		cumulative += entry.Weight
		if roll <= cumulative then
			return entry.ItemName
		end
	end
	return pool[#pool].ItemName
end
CrateLoot.weighted_pick = Weighted_Pick
-- [stated] "stack amounts... of food items" -- a pool entry marked
-- Food = true rolls a quantity from tier_data.FoodStackRange instead of
-- always granting exactly 1. Built once per roll rather than stored on
-- the pool entries themselves, so a tier with no food entries (Elite)
-- just never has anything match and never needs a FoodStackRange at all.
local function Is_Food_Item(tier_data, item_name)
	for _, entry in ipairs(tier_data.LootPool) do
		if entry.ItemName == item_name then
			return entry.Food == true
		end
	end
	return false
end
-- function either displays or creates item pool inside crate inventory
-- Contents entries are {ItemName = ..., Amount = ...} uniformly (even
-- non-food items just get Amount = 1) rather than a mix of plain strings
-- and stacked tables -- take_item/take_all/the loot window all read one
-- shape, never two.
function CrateLoot.get_or_roll_contents(crate_instance)
	if CrateLoot.crate_contents[crate_instance] then
		return CrateLoot.crate_contents[crate_instance]
	end
	local rarity = crate_instance:GetAttribute("Rarity") or "Standard"
	local tier_data = crate_data[rarity]
	if not tier_data then
		-- [found] an unrecognized rarity means this crate can never roll
		-- anything, ever -- without this it would stay lit/pulsing
		-- forever despite always being functionally empty. Same Empty
		-- attribute every other "now empty" path below sets.
		crate_instance:SetAttribute("Empty", true)
		return {}
	end
	local roll_count = math.random(tier_data.RollCount.min, tier_data.RollCount.max)
	local contents = {}
	for i = 1, roll_count do
		local item_name = Weighted_Pick(tier_data.LootPool)
		local amount = 1
		if Is_Food_Item(tier_data, item_name) and tier_data.FoodStackRange then
			amount = math.random(tier_data.FoodStackRange.min, tier_data.FoodStackRange.max)
		end
		table.insert(contents, {ItemName = item_name, Amount = amount})
	end
	CrateLoot.crate_contents[crate_instance] = contents
	-- [stated] "crate lights to turn off if the crate inventory is empty"
	-- -- covers a crate that rolls zero items on its very first open
	-- (RollCount.min can be 0), not just one emptied out afterward by
	-- take_item/take_all below.
	if #contents == 0 then
		crate_instance:SetAttribute("Empty", true)
	end
	return contents
end
-- Grants amount of item_name to player. Every item — including minimap
-- upgrades and stat-boost items — goes into inventory the same way; a
-- minimap upgrade no longer auto-grants itself the instant it's looted.
-- Instead it sits in inventory like anything else and gets consumed
-- through the same shift-click -> UseItemRequest flow as stat-boost items
-- (RequestChecker handles the actual grant_upgrade call + client
-- notification there now).
local function Grant_Item(player, item_name, amount)
	player_inventory.add_item(player, item_name, amount)
end
-- function controls player taking item from crate. item_name alone is
-- still enough to identify which entry to take (the client only ever
-- sends the name, never an amount -- see LootWindowUI.lua) since the
-- stack size the player actually receives is resolved here from the
-- entry's own stored Amount, not anything the client claims.
function CrateLoot.take_item(crate_instance, player, item_name)
	local contents = CrateLoot.crate_contents[crate_instance]
	if not contents then
		return false
	end
	for i, entry in ipairs(contents) do
		if entry.ItemName == item_name then
			table.remove(contents, i)
			Grant_Item(player, entry.ItemName, entry.Amount)
			if #contents == 0 then
				-- [stated] "crate lights to turn off if the crate
				-- inventory is empty" -- a general-purpose attribute
				-- every crate's own CrateLights script listens for
				-- (GetAttributeChangedSignal("Empty")), independent of
				-- the beacon-only event below -- this fires for every
				-- crate type, not just the Supply Drop beacon.
				crate_instance:SetAttribute("Empty", true)
				if crate_instance:GetAttribute("IsBeacon") then
					beacon_crate_looted:FireAllClients(crate_instance)
				end
			end
			return true
		end
	end
	return false
end
function CrateLoot.take_all(crate_instance, player)
	local contents = CrateLoot.crate_contents[crate_instance]
	if not contents then
		return
	end
	for _, entry in ipairs(contents) do
		Grant_Item(player, entry.ItemName, entry.Amount)
	end
	CrateLoot.crate_contents[crate_instance] = {}
	-- Unconditional, same as the existing IsBeacon firing right below it
	-- -- take_all always results in empty contents regardless of what was
	-- there before the call.
	crate_instance:SetAttribute("Empty", true)
	if crate_instance:GetAttribute("IsBeacon") then
		beacon_crate_looted:FireAllClients(crate_instance)
	end
end
return CrateLoot
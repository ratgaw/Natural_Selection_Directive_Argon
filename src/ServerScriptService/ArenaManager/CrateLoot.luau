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
-- Weighted random pick from a pool. Also used by StartMatch's floor loot.
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
-- Food entries roll a stack size from the tier's FoodStackRange.
local function Is_Food_Item(tier_data, item_name)
	for _, entry in ipairs(tier_data.LootPool) do
		if entry.ItemName == item_name then
			return entry.Food == true
		end
	end
	return false
end
-- Returns this crate's contents, rolling them on first open.
-- Entries are always {ItemName, Amount}.
function CrateLoot.get_or_roll_contents(crate_instance)
	if CrateLoot.crate_contents[crate_instance] then
		return CrateLoot.crate_contents[crate_instance]
	end
	local rarity = crate_instance:GetAttribute("Rarity") or "Standard"
	local tier_data = crate_data[rarity]
	if not tier_data then
		-- Unknown rarity: mark empty so its lights turn off.
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
	-- Rolled nothing: mark empty.
	if #contents == 0 then
		crate_instance:SetAttribute("Empty", true)
	end
	return contents
end
-- Every item, including minimap upgrades and stat boosts, goes to inventory;
-- they're used later via UseItemRequest.
local function Grant_Item(player, item_name, amount)
	player_inventory.add_item(player, item_name, amount)
end
-- Takes one entry by name; the amount comes from the stored entry, never the client.
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
				-- "Empty" turns off the crate's lights (its CrateLights script listens for it).
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
	crate_instance:SetAttribute("Empty", true)
	if crate_instance:GetAttribute("IsBeacon") then
		beacon_crate_looted:FireAllClients(crate_instance)
	end
end
return CrateLoot
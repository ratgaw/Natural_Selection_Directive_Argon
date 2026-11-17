-- Weight. Stateless: carried and max weight are computed on demand from
-- PlayerInventory, PlayerEquipment and PlayerStats, so nothing can go stale.
-- get_tier_effects gives each tier's movement/stamina multipliers, applied in
-- RequestChecker's Sync_Movement and PlayerCombat's dodge.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local weight_updated = ReplicatedStorage:WaitForChild("WeightUpdated")
local PlayerInventory = require(ServerScriptService:WaitForChild("PlayerInventory"))
local PlayerEquipment = require(ServerScriptService:WaitForChild("PlayerEquipment"))
local PlayerStats = require(ServerScriptService:WaitForChild("PlayerStats"))
local ItemData = require(ReplicatedStorage:WaitForChild("ItemData"))
local PlayerWeight = {}
-- Max carry = base + per Strength point above 1. Placeholders.
local BASE_MAX_CARRY_WEIGHT = 40
local STRENGTH_CARRY_WEIGHT_PER_POINT = 5
-- Worn gear counts at half weight.
local EQUIPPED_WEIGHT_MULTIPLIER = 0.5
-- Tiers by percent of max carry weight; Overburdened is anything over 100%.
-- Placeholders.
local WEIGHT_TIERS = {
	{Name = "Very Light", UpperPercent = 25},
	{Name = "Standard", UpperPercent = 50},
	{Name = "Heavy", UpperPercent = 75},
	{Name = "Very Heavy", UpperPercent = 100},
	{Name = "Overburdened", UpperPercent = math.huge},
}
-- Multipliers on base values that live where they're used. Overburdened sprint
-- speed equals its walk speed, so sprinting gives no benefit. SwimRiseCost only
-- applies from Heavy up. Placeholders.
local TIER_EFFECTS = {
	["Very Light"] = {WalkSpeedMultiplier = 1.15, SprintSpeedMultiplier = 1.15, SprintDrainMultiplier = 0.5, DodgeCostMultiplier = 0.75, DodgeDistanceMultiplier = 1.25, SwimDrainMultiplier = 0.5, SwimRiseCost = 0},
	["Standard"] = {WalkSpeedMultiplier = 1.0, SprintSpeedMultiplier = 1.0, SprintDrainMultiplier = 1.0, DodgeCostMultiplier = 1.0, DodgeDistanceMultiplier = 1.0, SwimDrainMultiplier = 1.0, SwimRiseCost = 0},
	["Heavy"] = {WalkSpeedMultiplier = 0.85, SprintSpeedMultiplier = 0.8, SprintDrainMultiplier = 1.5, DodgeCostMultiplier = 1.25, DodgeDistanceMultiplier = 0.85, SwimDrainMultiplier = 1.5, SwimRiseCost = 6},
	["Very Heavy"] = {WalkSpeedMultiplier = 0.7, SprintSpeedMultiplier = 0.6, SprintDrainMultiplier = 2.0, DodgeCostMultiplier = 1.5, DodgeDistanceMultiplier = 0.7, SwimDrainMultiplier = 2.0, SwimRiseCost = 10},
	["Overburdened"] = {WalkSpeedMultiplier = 0.5, SprintSpeedMultiplier = 0.5, SprintDrainMultiplier = 3.0, DodgeCostMultiplier = 2.0, DodgeDistanceMultiplier = 0.5, SwimDrainMultiplier = 3.0, SwimRiseCost = 15},
}
-- Adds MaxCarryWeightBonus from equipped items (e.g. Scavenger Jacket), counted
-- once per item.
function PlayerWeight.get_max_carry_weight(player)
	local strength = PlayerStats.get(player, "Strength")
	local max_weight = BASE_MAX_CARRY_WEIGHT + (strength - 1) * STRENGTH_CARRY_WEIGHT_PER_POINT
	local equipped = PlayerEquipment.player_equipment[player]
	if equipped then
		local counted_items = {}
		for _, entry in pairs(equipped) do
			if not counted_items[entry.ItemName] then
				counted_items[entry.ItemName] = true
				local data = ItemData[entry.ItemName]
				if data and data.MaxCarryWeightBonus then
					max_weight = max_weight + data.MaxCarryWeightBonus
				end
			end
		end
	end
	return max_weight
end
-- Inventory weight (reduced by an equipped bag's percentage) plus worn gear at
-- half weight, counted once per item.
function PlayerWeight.get_carried_weight(player)
	local inventory_weight = 0
	local inventory = PlayerInventory.player_inventories[player]
	if inventory then
		for item_name, count in pairs(inventory) do
			local data = ItemData[item_name]
			local item_weight = (data and data.Weight) or 0
			inventory_weight = inventory_weight + item_weight * count
		end
	end
	local equipped_weight = 0
	local equipped = PlayerEquipment.player_equipment[player]
	if equipped then
		local counted_items = {}
		for _, entry in pairs(equipped) do
			if not counted_items[entry.ItemName] then
				counted_items[entry.ItemName] = true
				local data = ItemData[entry.ItemName]
				local item_weight = (data and data.Weight) or 0
				equipped_weight = equipped_weight + item_weight * EQUIPPED_WEIGHT_MULTIPLIER
			end
		end
		local bag_entry = equipped["Bag"]
		local bag_data = bag_entry and ItemData[bag_entry.ItemName]
		local reduction = (bag_data and bag_data.WeightReductionPercent) or 0
		inventory_weight = inventory_weight * (1 - reduction)
	end
	return inventory_weight + equipped_weight
end
function PlayerWeight.get_weight_percent(player)
	local max_weight = PlayerWeight.get_max_carry_weight(player)
	if max_weight <= 0 then
		return 0
	end
	return (PlayerWeight.get_carried_weight(player) / max_weight) * 100
end
function PlayerWeight.get_tier(player)
	local percent = PlayerWeight.get_weight_percent(player)
	for _, tier in ipairs(WEIGHT_TIERS) do
		if percent <= tier.UpperPercent then
			return tier.Name
		end
	end
	return WEIGHT_TIERS[#WEIGHT_TIERS].Name
end
-- Multipliers for the player's current tier.
function PlayerWeight.get_tier_effects(player)
	local tier = PlayerWeight.get_tier(player)
	return TIER_EFFECTS[tier] or TIER_EFFECTS["Standard"]
end
-- Pushes carried/max/percent/tier to the client.
function PlayerWeight.notify(player)
	weight_updated:FireClient(player, {
		Carried = PlayerWeight.get_carried_weight(player),
		Max = PlayerWeight.get_max_carry_weight(player),
		Percent = PlayerWeight.get_weight_percent(player),
		Tier = PlayerWeight.get_tier(player),
	})
end
return PlayerWeight
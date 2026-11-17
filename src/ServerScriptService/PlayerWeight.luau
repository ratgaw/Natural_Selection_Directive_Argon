-- Core data layer for the weight-based inventory system (Phase 2). Deliberately
-- stateless: unlike PlayerStats/PlayerStamina, this module keeps no per-player
-- table of its own. Carried weight and max carry weight are both derived
-- on-demand from PlayerInventory/PlayerEquipment/PlayerStats each time they're
-- asked for, so there's no cached value that can drift out of sync with an
-- inventory change, an equip/unequip, or a stat increase — whichever module
-- actually owns that state stays the single source of truth.
--
-- Movement/stamina effects per tier now live here too (get_tier_effects) —
-- actually applying them (WalkSpeed, sprint stamina drain, dodge dash
-- distance, and now water treading/sinking) happens in RequestChecker.lua's
-- Sync_Movement and PlayerCombat.lua's dodge, both of which just ask this
-- module what the current tier means.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local weight_updated = ReplicatedStorage:WaitForChild("WeightUpdated") -- needs manual creation in Studio, same outstanding step as StatsUpdated/UseItemRequest before it
local PlayerInventory = require(ServerScriptService:WaitForChild("PlayerInventory"))
local PlayerEquipment = require(ServerScriptService:WaitForChild("PlayerEquipment"))
local PlayerStats = require(ServerScriptService:WaitForChild("PlayerStats"))
local ItemData = require(ReplicatedStorage:WaitForChild("ItemData"))
local PlayerWeight = {}
-- Starting guesses — tune once tested, same as everywhere else weight-related
-- in this pass. At Strength 1 (the round-start value) max carry weight is
-- just the base; each Strength point above 1 adds one increment.
local BASE_MAX_CARRY_WEIGHT = 40
local STRENGTH_CARRY_WEIGHT_PER_POINT = 5
-- Equipped armor/weapons count at half their inventory Weight — matches the
-- design note that gear you're wearing should burden you less than the same
-- gear sitting in your pack.
local EQUIPPED_WEIGHT_MULTIPLIER = 0.5
-- 5 tiers, ordered ascending by UpperPercent (percent of max carry weight).
-- A tier applies up to and including its UpperPercent; Overburdened has no
-- upper bound and catches anything over 100%. Percentages are placeholders —
-- tune once the movement/stamina effects below have been tested.
local WEIGHT_TIERS = {
	{Name = "Very Light", UpperPercent = 25},
	{Name = "Standard", UpperPercent = 50},
	{Name = "Heavy", UpperPercent = 75},
	{Name = "Very Heavy", UpperPercent = 100},
	{Name = "Overburdened", UpperPercent = math.huge},
}
-- Per-tier gameplay multipliers, layered on top of the base values that
-- already live where they're used (RequestChecker's walk_speed/sprint_speed,
-- BASE_SPRINT_STAMINA_DRAIN, and SWIM_STAMINA_DRAIN; PlayerCombat's
-- DODGE_STAMINA_COST and BASE_DASH_DISTANCE) — the same "layer a modifier
-- on a base constant" shape PlayerEquipment.Defense already uses on raw
-- weapon damage. Placeholders, tune once tested. Overburdened's
-- SprintSpeedMultiplier deliberately matches its WalkSpeedMultiplier —
-- sprinting stops giving any real speed benefit once you're over capacity,
-- without needing to special-case rejecting the sprint toggle itself.
-- DodgeDistanceMultiplier follows the same shape as WalkSpeedMultiplier
-- (lighter = further) rather than DodgeCostMultiplier's shape (lighter =
-- cheaper) — both make a heavy loadout worse at dodging, just via cost vs.
-- distance respectively. SwimRiseCost is 0 for Very Light/Standard and only
-- kicks in at Heavy+ — matches [stated] "heavy/very heavy tiers cause
-- sinking in water requiring stamina to swim up/out" calling out those
-- tiers specifically, not all 5.
local TIER_EFFECTS = {
	["Very Light"] = {WalkSpeedMultiplier = 1.15, SprintSpeedMultiplier = 1.15, SprintDrainMultiplier = 0.5, DodgeCostMultiplier = 0.75, DodgeDistanceMultiplier = 1.25, SwimDrainMultiplier = 0.5, SwimRiseCost = 0},
	["Standard"] = {WalkSpeedMultiplier = 1.0, SprintSpeedMultiplier = 1.0, SprintDrainMultiplier = 1.0, DodgeCostMultiplier = 1.0, DodgeDistanceMultiplier = 1.0, SwimDrainMultiplier = 1.0, SwimRiseCost = 0},
	["Heavy"] = {WalkSpeedMultiplier = 0.85, SprintSpeedMultiplier = 0.8, SprintDrainMultiplier = 1.5, DodgeCostMultiplier = 1.25, DodgeDistanceMultiplier = 0.85, SwimDrainMultiplier = 1.5, SwimRiseCost = 6},
	["Very Heavy"] = {WalkSpeedMultiplier = 0.7, SprintSpeedMultiplier = 0.6, SprintDrainMultiplier = 2.0, DodgeCostMultiplier = 1.5, DodgeDistanceMultiplier = 0.7, SwimDrainMultiplier = 2.0, SwimRiseCost = 10},
	["Overburdened"] = {WalkSpeedMultiplier = 0.5, SprintSpeedMultiplier = 0.5, SprintDrainMultiplier = 3.0, DodgeCostMultiplier = 2.0, DodgeDistanceMultiplier = 0.5, SwimDrainMultiplier = 3.0, SwimRiseCost = 15},
}
-- Reads PlayerEquipment for any equipped item carrying a MaxCarryWeightBonus
-- (currently just the Scavenger Jacket — [stated] compensation for that
-- item covering both the Torso AND Legs slots at once, at correspondingly
-- less total Defense than a matched 2-slot set). Deduped by ItemName with
-- the same counted_items pattern get_carried_weight already uses below, so
-- an item spanning multiple EquipSlots (the Jacket occupies both Torso and
-- Legs) only counts its bonus once, not per slot it fills.
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
-- Sums inventory item weights (Weight * count) plus equipped items at half
-- weight. Equipped items are deduped by ItemName, same pattern as
-- PlayerEquipment.get_total_defense, so a hypothetical future item spanning
-- multiple EquipSlots isn't double-counted. [stated] Backpack: reduces how
-- much carried INVENTORY weighs by a percentage, rather than raising max
-- capacity like Strength does — kept as two separate running totals so the
-- discount only ever applies to loose inventory weight, never to gear
-- already worn (a bag doesn't lighten armor on your body).
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
-- Single lookup point for "what does this player's current tier mean
-- gameplay-wise" — callers (RequestChecker's Sync_Movement, PlayerCombat's
-- dodge) multiply their own base constant by whichever field they need,
-- rather than each keeping their own copy of the tier table.
function PlayerWeight.get_tier_effects(player)
	local tier = PlayerWeight.get_tier(player)
	return TIER_EFFECTS[tier] or TIER_EFFECTS["Standard"]
end
-- Pushes current carried/max/percent/tier to the client. Called from every
-- inventory/equipment-changing request handler in RequestChecker.lua, plus
-- DroppedItems' pickup prompt, on join, and on round reset.
function PlayerWeight.notify(player)
	weight_updated:FireClient(player, {
		Carried = PlayerWeight.get_carried_weight(player),
		Max = PlayerWeight.get_max_carry_weight(player),
		Percent = PlayerWeight.get_weight_percent(player),
		Tier = PlayerWeight.get_tier(player),
	})
end
return PlayerWeight
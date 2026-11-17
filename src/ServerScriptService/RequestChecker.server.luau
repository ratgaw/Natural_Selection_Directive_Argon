-- Setting ease of use variables
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")
local Players = game:GetService("Players")
local sprint_request = ReplicatedStorage:WaitForChild("SprintRequest")
local equip_request = ReplicatedStorage:WaitForChild("EquipRequest")
local unequip_request = ReplicatedStorage:WaitForChild("UnequipRequest")
local equipment_updated = ReplicatedStorage:WaitForChild("EquipmentUpdated")
local inventory_updated = ReplicatedStorage:WaitForChild("InventoryUpdated")
local take_crate_item_request = ReplicatedStorage:WaitForChild("TakeCrateItemRequest")
local take_all_crate_request = ReplicatedStorage:WaitForChild("TakeAllCrateRequest")
local crate_contents_updated = ReplicatedStorage:WaitForChild("CrateContentsUpdated")
local attack_request = ReplicatedStorage:WaitForChild("AttackRequest")
local block_start_request = ReplicatedStorage:WaitForChild("BlockStartRequest")
local block_stop_request = ReplicatedStorage:WaitForChild("BlockStopRequest")
local dodge_request = ReplicatedStorage:WaitForChild("DodgeRequest")
-- Bow draw: hold to charge, release to fire (PlayerCombat.start_draw/release_draw).
local draw_start_request = ReplicatedStorage:WaitForChild("DrawStartRequest")
local draw_release_request = ReplicatedStorage:WaitForChild("DrawReleaseRequest")
local use_item_request = ReplicatedStorage:WaitForChild("UseItemRequest")
local drop_item_request = ReplicatedStorage:WaitForChild("DropItemRequest")
-- Drop straight out of an equip slot (ctrl+click).
local drop_equipped_request = ReplicatedStorage:WaitForChild("DropEquippedRequest")
local minimap_upgrade_granted = ReplicatedStorage:WaitForChild("MinimapUpgradeGranted")
-- Grabbing modules for variable use
local game_data = require(script.Parent.GameData)
local PlayerInventory = require(script.Parent.PlayerInventory)
local PlayerEquipment = require(script.Parent.PlayerEquipment)
local PlayerStats = require(script.Parent.PlayerStats)
local PlayerWeight = require(script.Parent.PlayerWeight)
local DroppedItems = require(script.Parent.DroppedItems)
local PlayerHunger = require(script.Parent.PlayerHunger)
-- Shared sprint state (PlayerCombat's animation sync reads it too).
local PlayerSprint = require(script.Parent.PlayerSprint)
-- PlayerInfection lives inside the ArenaManager folder.
local PlayerInfection = require(script.Parent.ArenaManager.PlayerInfection)
local ItemData = require(ReplicatedStorage:WaitForChild("ItemData"))
local arena_manager_folder = script.Parent.ArenaManager
local CrateLoot = require(arena_manager_folder.CrateLoot)
local PlayerMinimap = require(arena_manager_folder.PlayerMinimap)
local MinimapData = require(arena_manager_folder.MinimapData)
local player_combat = require(script.Parent.PlayerCombat)
local player_stamina = require(script.Parent.PlayerStamina)
-- Walk and sprint speed variables
local walk_speed = 16
local sprint_speed = 28
-- Base sprint drain, scaled per weight tier. Placeholder.
local BASE_SPRINT_STAMINA_DRAIN = 8
-- Dexterity -> sprint speed only. Placeholder.
local DEXTERITY_SPRINT_SPEED_PER_POINT = 0.03
-- Swimming drains stamina, scaled by weight tier. Placeholder.
local SWIM_STAMINA_DRAIN = 6
-- Damage while swimming with no stamina left.
local DROWN_DAMAGE_PER_SECOND = 5
-- Endurance -> cheaper swimming (floored).
local ENDURANCE_SWIM_COST_REDUCTION_PER_POINT = 0.05
local MIN_SWIM_COST_FRACTION = 0.5
-- Maximum distance a player can be from a crate to interact with its loot
local MAX_CRATE_INTERACTION_DISTANCE = 12
local function Is_Player_Near_Crate(player, crate_instance)
	local character = player.Character
	if not character then
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local crate_position = crate_instance:GetPivot().Position
	local distance = (root.Position - crate_position).Magnitude
	return distance <= MAX_CRATE_INTERACTION_DISTANCE
end
-- Every Heartbeat: sets WalkSpeed from sprint state, weight tier, Dexterity and
-- infection, and drains sprint stamina. Stops sprinting when stamina runs out.
-- This is the only place player WalkSpeed is set during play.
local function Sync_Movement(player, dt)
	local character = player.Character
	local humanoid = character and character:FindFirstChild("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid then
		return
	end
	local effects = PlayerWeight.get_tier_effects(player)
	local dexterity_sprint_multiplier = 1 + (PlayerStats.get(player, "Dexterity") - 1) * DEXTERITY_SPRINT_SPEED_PER_POINT
	-- An equipped bag makes sprinting cost more stamina.
	local bag_entry = PlayerEquipment.player_equipment[player] and PlayerEquipment.player_equipment[player]["Bag"]
	local bag_data = bag_entry and ItemData[bag_entry.ItemName]
	local bag_sprint_drain_multiplier = 1 + ((bag_data and bag_data.SprintDrainBonusPercent) or 0)
	-- Infection slows players at later stages.
	local infection_walk_multiplier = PlayerInfection.get_stage_effects(player).WalkSpeedMultiplier
	local is_sprinting_and_moving = false
	if PlayerSprint.is_sprinting(player) then
		humanoid.WalkSpeed = sprint_speed * effects.SprintSpeedMultiplier * dexterity_sprint_multiplier * infection_walk_multiplier
		-- Only drain stamina while actually moving.
		if humanoid.MoveDirection.Magnitude > 0 then
			is_sprinting_and_moving = true
			local ok = player_stamina.drain_tick(player, BASE_SPRINT_STAMINA_DRAIN * effects.SprintDrainMultiplier * bag_sprint_drain_multiplier, dt)
			if not ok then
				PlayerSprint.set_sprinting(player, false)
				is_sprinting_and_moving = false
				humanoid.WalkSpeed = walk_speed * effects.WalkSpeedMultiplier * infection_walk_multiplier
			end
		end
	else
		humanoid.WalkSpeed = walk_speed * effects.WalkSpeedMultiplier * infection_walk_multiplier
	end
	local is_swimming = humanoid:GetState() == Enum.HumanoidStateType.Swimming
	-- Sprinting and swimming speed up hunger.
	PlayerHunger.set_active(player, "Sprint", is_sprinting_and_moving)
	PlayerHunger.set_active(player, "Swim", is_swimming)
	-- Swimming drains stamina; at zero, the player drowns. Heavy tiers also pay
	-- SwimRiseCost to move upward (detected from upward velocity).
	if is_swimming and root then
		local endurance_swim_fraction = math.max(MIN_SWIM_COST_FRACTION, 1 - (PlayerStats.get(player, "Endurance") - 1) * ENDURANCE_SWIM_COST_REDUCTION_PER_POINT)
		local swim_drain_ok = player_stamina.drain_tick(player, SWIM_STAMINA_DRAIN * effects.SwimDrainMultiplier * endurance_swim_fraction, dt)
		local current_velocity = root.AssemblyLinearVelocity
		if effects.SwimRiseCost > 0 and current_velocity.Y > 0 then
			local rise_ok = player_stamina.drain_tick(player, effects.SwimRiseCost * endurance_swim_fraction, dt)
			if not rise_ok then
				-- Can't afford to rise: cancel the upward velocity so the player sinks.
				root.AssemblyLinearVelocity = Vector3.new(current_velocity.X, 0, current_velocity.Z)
			end
		end
		if not swim_drain_ok and humanoid.Health > 0 then
			humanoid:TakeDamage(DROWN_DAMAGE_PER_SECOND * dt)
		end
	end
end
-- Hunger stage health effect: regen when Enhanced, damage when Starving.
-- There's no other health regen (the empty Health script disables Roblox's).
local function Sync_Hunger_Health(player, dt)
	local character = player.Character
	local humanoid = character and character:FindFirstChild("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local effects = PlayerHunger.get_stage_effects(player)
	local delta = (effects.HealthRegenPerSecond - effects.HealthDamagePerSecond) * dt
	if delta ~= 0 then
		humanoid.Health = math.clamp(humanoid.Health + delta, 0, humanoid.MaxHealth)
	end
end
-- Infection's Critical-stage damage.
local function Sync_Infection_Health(player, dt)
	local character = player.Character
	local humanoid = character and character:FindFirstChild("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local effects = PlayerInfection.get_stage_effects(player)
	if effects.HealthDamagePerSecond > 0 then
		humanoid:TakeDamage(effects.HealthDamagePerSecond * dt)
	end
end
-- Checking sprint requests
sprint_request.OnServerEvent:Connect(function(player, wantsToSprint)
	--Fringe error causing cases
	if typeof(wantsToSprint) ~= "boolean" then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid then
		return
	end
	-- Checking player health above 0 and that players not in countdown
	if humanoid.Health <= 0 or game_data.state == "countdown" then
		return
	end
	-- Only records intent; Sync_Movement applies the speed.
	PlayerSprint.set_sprinting(player, wantsToSprint)
end)
-- Checking equip requests
equip_request.OnServerEvent:Connect(function(player, item_name)
	print("Equip request received from", player.Name, "for", item_name)
	-- Fringe error causing cases
	if typeof(item_name) ~= "string" then
		return
	end
	local success, result = PlayerEquipment.equip_item(player, item_name)
	if success then
		equipment_updated:FireClient(player, result)
		inventory_updated:FireClient(player, PlayerInventory.player_inventories[player])
		PlayerWeight.notify(player) -- equipping moves the item from full inventory weight to half equipped weight
		player_combat.refresh_weapon_animations(player)
	else
		warn("Equip failed for", player.Name, item_name, ":", result)
	end
end)
-- Checking unequip requests
unequip_request.OnServerEvent:Connect(function(player, slot)
	-- Fringe error causing cases
	if typeof(slot) ~= "string" then
		return
	end
	local success, result = PlayerEquipment.unequip_item(player, slot)
	if success then
		equipment_updated:FireClient(player, result)
		inventory_updated:FireClient(player, PlayerInventory.player_inventories[player])
		PlayerWeight.notify(player)
		player_combat.refresh_weapon_animations(player)
	else
		warn("Unequip failed for", player.Name, slot, ":", result)
	end
end)
-- Checking requests to take a single item from a crate
take_crate_item_request.OnServerEvent:Connect(function(player, crate_instance, item_name)
	if typeof(crate_instance) ~= "Instance" or typeof(item_name) ~= "string" then
		return
	end
	if not CrateLoot.is_verified(crate_instance) then
		warn("Rejected crate item request from", player.Name, "— unverified crate instance")
		return
	end
	if not Is_Player_Near_Crate(player, crate_instance) then
		warn("Rejected crate item request from", player.Name, "— too far from crate")
		return
	end
	local success = CrateLoot.take_item(crate_instance, player, item_name)
	if success then
		crate_contents_updated:FireClient(player, crate_instance, CrateLoot.crate_contents[crate_instance])
		inventory_updated:FireClient(player, PlayerInventory.player_inventories[player])
		PlayerWeight.notify(player)
	end
end)
-- Checking requests to take everything remaining in a crate
take_all_crate_request.OnServerEvent:Connect(function(player, crate_instance)
	if typeof(crate_instance) ~= "Instance" then
		return
	end
	if not CrateLoot.is_verified(crate_instance) then
		warn("Rejected take-all request from", player.Name, "— unverified crate instance")
		return
	end
	if not Is_Player_Near_Crate(player, crate_instance) then
		warn("Rejected take-all request from", player.Name, "— too far from crate")
		return
	end
	CrateLoot.take_all(crate_instance, player)
	crate_contents_updated:FireClient(player, crate_instance, CrateLoot.crate_contents[crate_instance])
	inventory_updated:FireClient(player, PlayerInventory.player_inventories[player])
	PlayerWeight.notify(player)
end)
-- Eats one item_name. Used by UseItemRequest and by left-click while holding food.
local function Consume_Food_Item(player, item_name, data)
	PlayerHunger.eat(player, data.Food.Tier, data.Food.Value)
	if data.Food.StaminaRestore then
		player_stamina.restore(player, data.Food.StaminaRestore)
	end
	if data.Food.SpoiledDamage then
		local character = player.Character
		local humanoid = character and character:FindFirstChild("Humanoid")
		if humanoid and humanoid.Health > 0 then
			humanoid:TakeDamage(data.Food.SpoiledDamage)
		end
	end
	PlayerInventory.remove_item(player, item_name, 1)
	-- If the last one was held in the Weapon slot, clear it (clear_slot, not
	-- unequip_item, which would refund the item just eaten).
	local equipped = PlayerEquipment.player_equipment[player]
	local weapon_entry = equipped and equipped["Weapon"]
	if weapon_entry and weapon_entry.ItemName == item_name and not PlayerInventory.has_item(player, item_name, 1) then
		PlayerEquipment.clear_slot(player, "Weapon")
		player_combat.refresh_weapon_animations(player)
	end
	inventory_updated:FireClient(player, PlayerInventory.player_inventories[player])
	equipment_updated:FireClient(player, PlayerEquipment.player_equipment[player])
	PlayerWeight.notify(player)
	player_stamina.notify(player)
end
-- The next several functions are all combat based requests
attack_request.OnServerEvent:Connect(function(player)
	-- Holding food in the Weapon slot: left-click eats instead of swinging.
	local equipped = PlayerEquipment.player_equipment[player]
	local weapon_entry = equipped and equipped["Weapon"]
	local weapon_data = weapon_entry and ItemData[weapon_entry.ItemName]
	if weapon_data and weapon_data.Food then
		if PlayerInventory.has_item(player, weapon_entry.ItemName, 1) then
			Consume_Food_Item(player, weapon_entry.ItemName, weapon_data)
		end
		return
	end
	local success, result = player_combat.attack(player)
	if not success then
		warn("Attack failed for", player.Name, ":", result)
	end
end)
block_start_request.OnServerEvent:Connect(function(player)
	player_combat.start_block(player)
end)
block_stop_request.OnServerEvent:Connect(function(player)
	player_combat.stop_block(player)
end)
dodge_request.OnServerEvent:Connect(function(player)
	local success, result = player_combat.dodge(player)
	if not success then
		warn("Dodge failed for", player.Name, ":", result)
	end
end)
draw_start_request.OnServerEvent:Connect(function(player)
	local success, result = player_combat.start_draw(player)
	if not success then
		warn("Bow draw failed to start for", player.Name, ":", result)
	end
end)
draw_release_request.OnServerEvent:Connect(function(player)
	local success, result = player_combat.release_draw(player)
	if not success then
		warn("Bow draw release failed for", player.Name, ":", result)
	end
end)
-- Consumables: StatBoost items, MinimapUpgrade items and Food. Gear uses
-- EquipRequest instead.
use_item_request.OnServerEvent:Connect(function(player, item_name)
	if typeof(item_name) ~= "string" then
		return
	end
	if not PlayerInventory.has_item(player, item_name, 1) then
		warn("Use-item rejected for", player.Name, item_name, "— item not owned")
		return
	end
	local data = ItemData[item_name]
	if not data then
		warn("Use-item rejected for", player.Name, item_name, "— unknown item")
		return
	end
	local consumed = false
	if data.StatBoost then
		local success, result = PlayerStats.add_stat(player, data.StatBoost.Stat, data.StatBoost.Amount)
		if success then
			consumed = true
		else
			warn("Use-item stat boost failed for", player.Name, item_name, ":", result)
		end
	elseif data.MinimapUpgrade then
		PlayerMinimap.grant_upgrade(player, data.MinimapUpgrade)
		-- The Terrain upgrade also needs the minimap snapshot.
		if data.MinimapUpgrade == "Terrain" then
			minimap_upgrade_granted:FireClient(player, "Terrain", MinimapData.get_snapshot())
		else
			minimap_upgrade_granted:FireClient(player, data.MinimapUpgrade)
		end
		consumed = true
	elseif data.Food then
		-- Consume_Food_Item does its own removal and updates.
		Consume_Food_Item(player, item_name, data)
		return
	else
		warn("Use-item rejected for", player.Name, item_name, "— not a usable item")
	end
	if consumed then
		PlayerInventory.remove_item(player, item_name, 1)
		inventory_updated:FireClient(player, PlayerInventory.player_inventories[player])
		-- Strength/Endurance boosts change max carry weight and max stamina.
		PlayerWeight.notify(player)
		player_stamina.notify(player)
	end
end)
-- DroppedItems.drop_item checks ownership and clamps amount. nil amount drops
-- everything owned of that item.
drop_item_request.OnServerEvent:Connect(function(player, item_name, amount)
	if typeof(item_name) ~= "string" then
		return
	end
	if amount ~= nil and (typeof(amount) ~= "number" or amount <= 0) then
		return
	end
	local success, result = DroppedItems.drop_item(player, item_name, amount)
	if success then
		inventory_updated:FireClient(player, PlayerInventory.player_inventories[player])
		PlayerWeight.notify(player)
	else
		warn("Drop failed for", player.Name, item_name, ":", result)
	end
end)
-- Unequip and drop in one server step.
drop_equipped_request.OnServerEvent:Connect(function(player, slot)
	if typeof(slot) ~= "string" then
		return
	end
	local equipped = PlayerEquipment.player_equipment[player]
	local entry = equipped and equipped[slot]
	if not entry then
		warn("Drop-equipped failed for", player.Name, slot, ": nothing equipped")
		return
	end
	local item_name = entry.ItemName
	local unequip_success, unequip_result = PlayerEquipment.unequip_item(player, slot)
	if not unequip_success then
		warn("Drop-equipped failed for", player.Name, slot, ":", unequip_result)
		return
	end
	equipment_updated:FireClient(player, PlayerEquipment.player_equipment[player])
	PlayerWeight.notify(player)
	player_combat.refresh_weapon_animations(player)
	-- Drop exactly the one unit unequip_item just returned, not other copies.
	local drop_success, drop_result = DroppedItems.drop_item(player, item_name, 1)
	if drop_success then
		inventory_updated:FireClient(player, PlayerInventory.player_inventories[player])
	else
		warn("Drop-equipped failed for", player.Name, slot, "(after unequip):", drop_result)
	end
end)
run_service.Heartbeat:Connect(function(dt)
	player_stamina.regen_tick(dt)
	for player in pairs(player_combat.blocking_players) do
		player_combat.block_tick(player, dt)
	end
	for _, player in ipairs(Players:GetPlayers()) do
		Sync_Movement(player, dt)
		PlayerHunger.hunger_tick(player, dt)
		Sync_Hunger_Health(player, dt)
		PlayerInfection.infection_tick(player, dt)
		Sync_Infection_Health(player, dt)
	end
end)
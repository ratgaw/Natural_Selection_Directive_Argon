-- Setting ease of use variables
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")
local Players = game:GetService("Players")
local sprint_request = ReplicatedStorage:WaitForChild("SprintRequest")
local match_started = ReplicatedStorage:WaitForChild("MatchStarted")
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
-- [stated] "Hold to charge, release to fire" bow draw -- mirrors
-- block_start_request/block_stop_request's own shape exactly, just for
-- PlayerCombat.start_draw/release_draw instead. Needs manual creation in
-- ReplicatedStorage, same outstanding step as every other new remote.
local draw_start_request = ReplicatedStorage:WaitForChild("DrawStartRequest")
local draw_release_request = ReplicatedStorage:WaitForChild("DrawReleaseRequest")
local use_item_request = ReplicatedStorage:WaitForChild("UseItemRequest")
local drop_item_request = ReplicatedStorage:WaitForChild("DropItemRequest")
-- [stated] "ctrl + left clicking items in a player's hotbar/equipped
-- armor/inventory to drop that item/stack of items" -- new remote for
-- dropping something straight out of an equip slot; needs manual creation
-- in ReplicatedStorage (same as InfectionUpdated before it).
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
-- [stated/found] "is this player sprinting right now" used to live only as
-- a private local table in this file -- moved into its own tiny module so
-- PlayerCombat.lua's upper-body Move animation sync can read the SAME real
-- sprint intent directly, instead of inferring it from Roblox's own
-- default walk/run animation blend weights (which turned out to misread
-- ordinary walking as mostly "run" once PlayerWeight drops a player's
-- effective WalkSpeed well below its Default of 16 -- see PlayerSprint.lua).
local PlayerSprint = require(script.Parent.PlayerSprint)
-- [stated/found] PlayerInfection actually lives INSIDE the ArenaManager
-- folder in Studio (confirmed from an Explorer screenshot), not as a
-- direct ServerScriptService child like PlayerHunger/PlayerStats/etc. —
-- script.Parent.PlayerInfection was silently wrong (would hang forever on
-- WaitForChild). [stated] already hand-patched this in Studio; fixing it
-- here too so redelivering this file doesn't clobber that fix.
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
local movement_locked = false
-- Base sprint stamina drain — didn't exist before the weight system;
-- PlayerWeight.get_tier_effects scales this per-tier the same way it
-- scales walk/sprint speed. Placeholder, tune once tested.
local BASE_SPRINT_STAMINA_DRAIN = 8
-- [stated] "Dexterity -> top sprint speed" — only sprint, not the base walk
-- speed, matches the "top sprint speed" wording. Placeholder, tune once
-- tested.
local DEXTERITY_SPRINT_SPEED_PER_POINT = 0.03
-- [stated] "treading/swimming continuously costs stamina" — base cost,
-- scaled per tier by PlayerWeight's SwimDrainMultiplier the same shape as
-- sprint. Placeholder, tune once tested.
local SWIM_STAMINA_DRAIN = 6
-- [stated] "player takes damage once stamina fully drains while in water"
local DROWN_DAMAGE_PER_SECOND = 5
-- [stated] "Endurance -> cheaper swim stamina" — was flagged deferred while
-- wiring the other stat effects since there was no swim stamina cost yet
-- to make cheaper; now that one exists, this closes that gap. Same floored
-- shape as Endurance's other cost reductions.
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
-- Continuously keeps WalkSpeed (and, while sprinting, stamina) in sync
-- with the player's CURRENT weight tier — a toggle-time-only speed set
-- would go stale the instant an equip/drop/pickup/use-item changes their
-- tier mid-sprint or mid-walk. Runs every Heartbeat for every player with
-- a character, the same reasoning PlayerCombat.block_tick exists instead
-- of charging block's stamina cost once at press-down. Auto-stops sprint
-- (falls back to walk speed) once stamina runs out, same pattern as
-- block_tick's own drain-to-zero handling.
local function Sync_Movement(player, dt)
	local character = player.Character
	local humanoid = character and character:FindFirstChild("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid then
		return
	end
	local effects = PlayerWeight.get_tier_effects(player)
	local dexterity_sprint_multiplier = 1 + (PlayerStats.get(player, "Dexterity") - 1) * DEXTERITY_SPRINT_SPEED_PER_POINT
	-- [stated] Backpack trade-off: the same slot that discounts carried
	-- weight (PlayerWeight.get_carried_weight) also burns MORE stamina
	-- while sprinting — a bag equipped, not one merely owned, so this
	-- reads the live equipped table each tick same as everything else here.
	local bag_entry = PlayerEquipment.player_equipment[player] and PlayerEquipment.player_equipment[player]["Bag"]
	local bag_data = bag_entry and ItemData[bag_entry.ItemName]
	local bag_sprint_drain_multiplier = 1 + ((bag_data and bag_data.SprintDrainBonusPercent) or 0)
	-- Animal Frenzy's parasite: Spreading/Critical infection stages slow a
	-- player down same as an Overburdened weight tier would — applied
	-- multiplicatively alongside everything else here since Sync_Movement
	-- is the one place WalkSpeed ever gets set.
	local infection_walk_multiplier = PlayerInfection.get_stage_effects(player).WalkSpeedMultiplier
	local is_sprinting_and_moving = false
	if PlayerSprint.is_sprinting(player) then
		humanoid.WalkSpeed = sprint_speed * effects.SprintSpeedMultiplier * dexterity_sprint_multiplier * infection_walk_multiplier
		-- Only actually spend stamina while genuinely moving — holding
		-- shift while standing still (e.g. browsing the inventory, or just
		-- standing around) isn't sprinting yet, even though the server has
		-- already recorded the sprint request. GeneralPlayerSettings.lua
		-- also stops sending sprint requests at all while the inventory is
		-- open; this is a second, independent guard against draining
		-- stamina for a player who isn't actually moving.
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
	-- Both continuous hunger-speeding actions PlayerHunger doesn't already
	-- own a better hook point for — mirrors the same sprint condition above
	-- (same reasoning: standing still holding shift doesn't count).
	PlayerHunger.set_active(player, "Sprint", is_sprinting_and_moving)
	PlayerHunger.set_active(player, "Swim", is_swimming)
	-- Water/swim system — [stated] "treading/swimming continuously costs
	-- stamina" (base drain, scaled per tier) and "player takes damage once
	-- stamina fully drains while in water" (drowning). Heavy/Very Heavy
	-- tiers additionally have to pay SwimRiseCost on top of the base drain
	-- to rise — [stated] "heavy/very heavy tiers cause sinking in water
	-- requiring stamina to swim up/out". Rising is detected off vertical
	-- velocity (root.AssemblyLinearVelocity.Y > 0) rather than a dedicated
	-- swim-up remote, since none exists — this catches both the player's
	-- own paddling and Roblox's default buoyancy nudging them upward.
	if is_swimming and root then
		local endurance_swim_fraction = math.max(MIN_SWIM_COST_FRACTION, 1 - (PlayerStats.get(player, "Endurance") - 1) * ENDURANCE_SWIM_COST_REDUCTION_PER_POINT)
		local swim_drain_ok = player_stamina.drain_tick(player, SWIM_STAMINA_DRAIN * effects.SwimDrainMultiplier * endurance_swim_fraction, dt)
		local current_velocity = root.AssemblyLinearVelocity
		if effects.SwimRiseCost > 0 and current_velocity.Y > 0 then
			local rise_ok = player_stamina.drain_tick(player, effects.SwimRiseCost * endurance_swim_fraction, dt)
			if not rise_ok then
				-- Can't afford to rise this tick — cancel the upward
				-- velocity so an out-of-stamina heavy player actually
				-- sinks instead of floating up for free.
				root.AssemblyLinearVelocity = Vector3.new(current_velocity.X, 0, current_velocity.Z)
			end
		end
		if not swim_drain_ok and humanoid.Health > 0 then
			humanoid:TakeDamage(DROWN_DAMAGE_PER_SECOND * dt)
		end
	end
end
-- Applies the current hunger stage's passive health regen/damage — only
-- Enhanced (regen) and Starving (damage) actually have nonzero values
-- today, everything in between is a no-op. This is also the entire reason
-- characters don't otherwise regen health on their own ([stated] design:
-- healing mainly comes from medkits, rarely from high-tier/Enhanced food)
-- — there's no other health regen anywhere in this codebase to conflict
-- with. Setting Health to 0 here fires Humanoid.Died the same as any other
-- damage source, so starving can kill a player same as anything else.
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
-- Same shape as Sync_Hunger_Health, for the parasite's Critical-stage
-- damage — kept as its own function/effects lookup rather than folding
-- into Sync_Hunger_Health since infection and hunger are unrelated systems
-- that just happen to both tick health; only Critical has a nonzero
-- HealthDamagePerSecond today (Early Infection/Spreading are movement-only).
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
	-- Recording the requesting player's sprint intent — actually applying
	-- the speed (at whatever the player's current weight tier allows)
	-- happens continuously in Sync_Movement below, not here, so there's
	-- only one place that ever sets WalkSpeed.
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
-- Consumes 1 of item_name for its Food effect. Shared by UseItemRequest's
-- Food branch (below) and AttackRequest's "you're holding food instead of a
-- weapon" branch (right below this) — eating works the same way regardless
-- of which input triggered it, since the server decides what's equipped
-- either way, not the client.
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
	-- [stated/found] eating the last one of a stack that's also equipped
	-- into the Weapon hand-slot (selected off the hotbar) needs that slot
	-- cleared too, or the player keeps visually holding/being "equipped
	-- with" an item they now own zero of. clear_slot (NOT unequip_item) —
	-- unequip_item refunds 1 to inventory, which would undo the very item
	-- just eaten here.
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
	-- [stated] selecting a food item from the hotbar equips it into the same
	-- Weapon hand-slot a real weapon would (see EquipSlots on food ItemData
	-- entries) — so a left-click/AttackRequest while holding one means "eat
	-- it", not "swing". Decided off the server's own equipped-item state,
	-- not a client-sent flag, same as every other request this file gates.
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
-- Checking requests to consume an item for its effect: stat-boost crate
-- items (ItemData.StatBoost = {Stat=..., Amount=...}), minimap upgrades
-- (ItemData.MinimapUpgrade = upgrade name), and now food (ItemData.Food =
-- {Tier=..., Value=..., SpoiledDamage=...?}). Armor/weapons are
-- deliberately NOT handled here — those stay on EquipRequest.
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
		-- Terrain also needs a snapshot sent along so the newly-unlocked
		-- reveal can render immediately — same special case CrateLoot's
		-- old instant-grant-on-pickup path used to handle, moved here now
		-- that granting happens on consume instead of on pickup.
		if data.MinimapUpgrade == "Terrain" then
			minimap_upgrade_granted:FireClient(player, "Terrain", MinimapData.get_snapshot())
		else
			minimap_upgrade_granted:FireClient(player, data.MinimapUpgrade)
		end
		consumed = true
	elseif data.Food then
		-- Consume_Food_Item does its own remove_item + client notifies (it
		-- also has to check whether this empties a stack that's currently
		-- equipped in the Weapon hand-slot), so this returns immediately
		-- rather than falling through to the shared "if consumed" tail below.
		Consume_Food_Item(player, item_name, data)
		return
	else
		warn("Use-item rejected for", player.Name, item_name, "— not a usable item")
	end
	if consumed then
		PlayerInventory.remove_item(player, item_name, 1)
		inventory_updated:FireClient(player, PlayerInventory.player_inventories[player])
		-- Also covers the StatBoost branch: a Strength gain raises max carry
		-- weight, and an Endurance gain raises max stamina, so both pushes
		-- can shift even though carried weight/current stamina themselves
		-- didn't change.
		PlayerWeight.notify(player)
		player_stamina.notify(player)
	end
end)
-- Checking requests to drop an item onto the ground — DroppedItems.drop_item
-- does its own ownership check (and clamps amount to what's actually
-- owned) via PlayerInventory, so there's nothing extra to validate here
-- beyond argument types. amount is optional -- nil drops everything owned
-- (whole-panel drag-out with no specific slot in mind); the client's
-- per-slot drop gestures (ctrl+click, shift+right-click, drag-a-single-
-- slot-out) now pass that SLOT's own amount instead, per [stated] — see
-- DroppedItems.drop_item's own comment for why dropping the full owned
-- amount unconditionally was wrong.
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
-- Checking requests to drop whatever's currently equipped in a given slot
-- straight to the ground -- unequip + drop as ONE atomic server step
-- (rather than the client firing UnequipRequest then DropItemRequest back
-- to back and relying on those two separate remotes being processed in
-- that order), since DroppedItems.drop_item only finds an item sitting in
-- the player's OWN inventory, and an equipped item isn't there yet.
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
	-- Exactly 1 -- that's what unequip_item just added back, and it's ALL
	-- that should hit the ground. [stated/found] this was a real bug before
	-- the amount parameter existed: drop_item defaulted to the player's
	-- FULL owned amount for item_name, which would also sweep up any other
	-- separate copy of the same item already sitting in inventory (e.g. one
	-- Mace equipped, a second Mace already in the bag) right along with the
	-- one actually being dropped here.
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
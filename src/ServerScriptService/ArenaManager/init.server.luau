-- Setting ease of use variables for studio functions for later use
local RS = game:GetService("ReplicatedStorage")
local players = game:GetService("Players")
local current_players = players:GetPlayers()
-- Grabbing signals as variables
local start_match_sig = RS:WaitForChild("GenerateArena")
local inventory_update_sig = RS:WaitForChild("InventoryUpdated")
local equipment_update_sig = RS:WaitForChild("EquipmentUpdated")
-- /dev flight runs client-side (DevFlyController); this toggles it.
local dev_fly_toggled = RS:WaitForChild("DevFlyToggled")
-- Grabbing modules as variables
local start_match = require(script.StartMatch)
local player_death = require(script.PlayerDeath)
local game_data = require(script.Parent.GameData)
local player_inventory = require(script.Parent.PlayerInventory)
local player_equipment = require(script.Parent.PlayerEquipment)
local player_minimap = require(script.PlayerMinimap)
local player_combat = require(script.Parent:WaitForChild("PlayerCombat"))
local player_stamina = require(script.Parent:WaitForChild("PlayerStamina"))
local player_stats = require(script.Parent:WaitForChild("PlayerStats"))
local player_weight = require(script.Parent:WaitForChild("PlayerWeight"))
local player_hunger = require(script.Parent:WaitForChild("PlayerHunger"))
local player_infection = require(script:WaitForChild("PlayerInfection"))
local events_folder = script:WaitForChild("ArenaEvents")
local zombie_event = require(events_folder:WaitForChild("ZombieEvent"))
local supply_drop_event = require(events_folder:WaitForChild("SupplyDropEvent"))
local animal_frenzy_event = require(events_folder:WaitForChild("AnimalFrenzyEvent"))
local forest_fire_event = require(events_folder:WaitForChild("ForestFireEvent"))
local flood_event = require(events_folder:WaitForChild("FloodEvent"))
local acid_rain_event = require(events_folder:WaitForChild("AcidRainEvent"))
local arena_event_scheduler = require(events_folder:WaitForChild("ArenaEventScheduler"))
-- Fall damage beyond SAFE distance scales linearly; Endurance reduces it.
-- Placeholders.
local FALL_DAMAGE_SAFE_DISTANCE = 20 -- studs
local FALL_DAMAGE_PER_STUD = 2
local ENDURANCE_FALL_DAMAGE_REDUCTION_PER_POINT = 0.05
local MAX_FALL_DAMAGE_REDUCTION = 0.6
-- Registers every event into the shared scheduler's pool — runs once, at
-- script load, not per-match-start.
arena_event_scheduler.register_event("Zombies", zombie_event.trigger)
arena_event_scheduler.register_event("Supply Drop", supply_drop_event.trigger)
arena_event_scheduler.register_event("Animal Frenzy", animal_frenzy_event.trigger)
arena_event_scheduler.register_event("Forest Fire", forest_fire_event.trigger)
arena_event_scheduler.register_event("Flood", flood_event.trigger)
arena_event_scheduler.register_event("Acid Rain", acid_rain_event.trigger)
-- TESTING ONLY chat commands. Keys have no leading "/" (it's stripped from the
-- message, since pressing / to open chat may or may not include it). Uses the
-- legacy Player.Chatted signal; switch to TextChatService if that stops firing.
-- /dev toggles invincibility, extra speed, flight and no hunger.
local dev_mode_players = {} -- [player] = true while /dev is active
local function Set_Dev_Mode(player, enabled)
	dev_mode_players[player] = enabled or nil
	-- RequestChecker's Sync_Movement reads this attribute for the dev walk speed.
	player:SetAttribute("DevMode", enabled or nil)
	player_combat.set_dev_invulnerable(player, enabled)
	player_hunger.set_immune(player, enabled)
	dev_fly_toggled:FireClient(player, enabled)
end
local DEBUG_COMMANDS = {
	forestfire = function(player)
		local found = arena_event_scheduler.force_trigger("Forest Fire", game_data)
		if not found then
			warn("[ArenaManager] /forestfire: no event registered under the exact name 'Forest Fire'")
		end
	end,
	-- Names must match the register_event names exactly.
	zombies = function(player)
		local found = arena_event_scheduler.force_trigger("Zombies", game_data)
		if not found then
			warn("[ArenaManager] /zombies: no event registered under the exact name 'Zombies'")
		end
	end,
	animalfrenzy = function(player)
		local found = arena_event_scheduler.force_trigger("Animal Frenzy", game_data)
		if not found then
			warn("[ArenaManager] /animalfrenzy: no event registered under the exact name 'Animal Frenzy'")
		end
	end,
	flood = function(player)
		local found = arena_event_scheduler.force_trigger("Flood", game_data)
		if not found then
			warn("[ArenaManager] /flood: no event registered under the exact name 'Flood'")
		end
	end,
	acidrain = function(player)
		local found = arena_event_scheduler.force_trigger("Acid Rain", game_data)
		if not found then
			warn("[ArenaManager] /acidrain: no event registered under the exact name 'Acid Rain'")
		end
	end,
	dev = function(player)
		Set_Dev_Mode(player, not dev_mode_players[player])
	end,
}
game_data.participants = {}
for _, p in ipairs(current_players) do
	game_data.participants[p] = true
end
-- TESTING ONLY: seeds the zombie appearance pool with your own character.
-- Remove once zombies are confirmed working.
local eliminated_appearances = require(script:WaitForChild("EliminatedAppearances"))
-- Test function for giving players items
local function test_give_item(player, item_name, amount)
	local inventory = player_inventory.add_item(player, item_name, amount)
	inventory_update_sig:FireClient(player, inventory)
end
-- Generates arena then starts match upon recieving the arena generation signal
start_match_sig.OnServerEvent:Connect(function(player)
	if game_data.mapgenerated == true then
		return
	else
		game_data.mapgenerated = true
		current_players = players:GetPlayers()
		game_data.participants = {}
		for _, p in ipairs(current_players) do
			game_data.participants[p] = true
		end
		-- Each participant starts the round with base stats, an empty inventory and no
		-- gear (remove_equipment first so worn parts are actually detached).
		for p in pairs(game_data.participants) do
			player_equipment.remove_equipment(p)
			player_equipment.new_equipment(p)
			player_inventory.new_inventory(p)
			player_stats.new_player(p)
			player_hunger.new_player(p)
			-- Same reasoning as PlayerHunger — a leftover infection from a
			-- previous round shouldn't carry into a fresh one.
			player_infection.new_player(p)
			equipment_update_sig:FireClient(p, player_equipment.player_equipment[p])
			inventory_update_sig:FireClient(p, player_inventory.player_inventories[p])
			-- PlayerWeight has no state; just re-notify after the reset.
			player_weight.notify(p)
		end
		start_match.Generate(game_data)
		game_data.state = "countdown"
		start_match.Start_Match(game_data)
		game_data.state = "matchinprogress"
		arena_event_scheduler.start(game_data)
	end
end)
-- Controlling where players spawn/respawn at and creates new inventory for each connecting player
players.PlayerAdded:Connect(function(player)
	game_data.spectators[player] = true
	player_inventory.new_inventory(player)
	player_equipment.new_equipment(player)
	player_minimap.new_player(player)
	player_stamina.new_player(player)
	player_stats.new_player(player)
	player_weight.notify(player) -- initial push so the client isn't blank
	player_hunger.new_player(player)
	player_infection.new_player(player)
	player.Chatted:Connect(function(message)
		local normalized = message:lower():gsub("^/", "")
		local handler = DEBUG_COMMANDS[normalized]
		if handler then
			handler(player)
		end
	end)
	player.CharacterAdded:Connect(function(character)
		task.wait(0.1)
		-- Test functions to give players items in inventory for troubleshooting
		test_give_item(player, "Tier 1 Twohanded Axe", 1)
		test_give_item(player, "Tier 2 Twohanded Axe", 1)
		test_give_item(player, "Tier 3 Twohanded Axe", 1)
		test_give_item(player, "Tier 1 Mace", 1)
		test_give_item(player, "Tier 2 Mace", 1)
		test_give_item(player, "Tier 3 Mace", 1)
		test_give_item(player, "Tier 2 Bow", 1)
		task.wait(10.0) -- let equipment finish applying first
		eliminated_appearances.capture(player, character)
		print("Cataloged appearance for zombies.")
		if game_data.spectators[player] then
			player_death.sendtolobby(character, game_data)
		end
		local humanoid = character:WaitForChild("Humanoid")
		local root = character:WaitForChild("HumanoidRootPart")
		-- Y where the current freefall began; nil when not falling.
		local freefall_start_y = nil
		-- Jumping pulses hunger; Freefall/Landed drive fall damage.
		humanoid.StateChanged:Connect(function(_, new_state)
			if new_state == Enum.HumanoidStateType.Jumping then
				player_hunger.pulse(player)
			elseif new_state == Enum.HumanoidStateType.Freefall then
				freefall_start_y = root.Position.Y
			elseif new_state == Enum.HumanoidStateType.Landed then
				if freefall_start_y then
					local fall_distance = freefall_start_y - root.Position.Y
					if fall_distance > FALL_DAMAGE_SAFE_DISTANCE and humanoid.Health > 0 and not player_combat.is_invulnerable(player) then
						local raw_damage = (fall_distance - FALL_DAMAGE_SAFE_DISTANCE) * FALL_DAMAGE_PER_STUD
						local endurance = player_stats.get(player, "Endurance")
						local reduction = math.min((endurance - 1) * ENDURANCE_FALL_DAMAGE_REDUCTION_PER_POINT, MAX_FALL_DAMAGE_REDUCTION)
						humanoid:TakeDamage(raw_damage * (1 - reduction))
					end
					freefall_start_y = nil
				end
			end
		end)
		--Listening for player death and executing eliminate player function
		humanoid.Died:Connect(function()
			if game_data.participants[player] then
				player_death.eliminateplayer(player, game_data)
				player_minimap.remove_player(player)
			else
				game_data.spectators[player] = true
			end
		end)
	end)
end)
-- Cleans up various lists and inventory on player disconnect
players.PlayerRemoving:Connect(function(player)
	player_inventory.remove_inventory(player)
	player_equipment.remove_equipment(player)
	player_minimap.remove_player(player)
	player_combat.remove_player(player)
	player_stamina.remove_player(player)
	player_stats.remove_player(player)
	player_hunger.remove_player(player)
	player_infection.remove_player(player)
	player_death.disconnectplayer(player, game_data)
	dev_mode_players[player] = nil
end)
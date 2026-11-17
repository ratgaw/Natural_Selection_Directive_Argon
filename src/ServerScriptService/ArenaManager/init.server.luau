-- Setting ease of use variables for studio functions for later use
local RS = game:GetService("ReplicatedStorage")
local players = game:GetService("Players")
local current_players = players:GetPlayers()
-- Grabbing signals as variables
local start_match_sig = RS:WaitForChild("GenerateArena")
local inventory_update_sig = RS:WaitForChild("InventoryUpdated")
local equipment_update_sig = RS:WaitForChild("EquipmentUpdated")
-- [stated] "/dev text command... can fly" -- the actual flight physics
-- live client-side (DevFlyController.lua, StarterPlayerScripts, same
-- "client owns its own character's movement by default" model normal
-- WASD movement already relies on) -- this just tells that player's own
-- client to turn it on/off. Needs manual creation in ReplicatedStorage,
-- same outstanding step as every other new remote this project.
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
-- [stated] "forest fire event... lasting damage to the trees... persist
-- throughout the match, dealing damage to players... random tree trunks
-- falling near the players" -- ForestFireEvent.lua needs to actually be
-- placed in ArenaEvents in Studio, same outstanding manual step every new
-- module/event in this project has needed.
local forest_fire_event = require(events_folder:WaitForChild("ForestFireEvent"))
-- [stated] "I now want to add a new event, the flood" -- same outstanding
-- manual step as every other new event module: FloodEvent.lua needs to
-- actually be placed in ArenaEvents in Studio (ServerScriptService >
-- ArenaManager > ArenaEvents, alongside the other four) before this
-- WaitForChild resolves.
local flood_event = require(events_folder:WaitForChild("FloodEvent"))
local arena_event_scheduler = require(events_folder:WaitForChild("ArenaEventScheduler"))
-- Fall damage — didn't exist anywhere in the codebase before this, needed
-- to exist before [stated] "Endurance -> reduced fall damage" had anything
-- to reduce. No damage below SAFE_FALL_DISTANCE; above it, damage scales
-- linearly with how far past that the character fell. Placeholders, tune
-- once tested.
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
-- [stated] "a command to manually launch the forest fire event so I can
-- test it faster than waiting for it to naturally occur" -- TESTING ONLY,
-- same spirit as test_give_item/the eliminated_appearances self-seed
-- below. Keyed by the exact lowercased message so new debug commands are
-- just another table entry, no new if/elseif chain needed. Wired to each
-- player's own Chatted event further down (Players.PlayerAdded) rather
-- than a Players-level signal -- Chatted only exists per-Player.
-- Player.Chatted is the LEGACY chat signal -- it still fires through
-- TextChatService's default legacy-chat bridge in most experiences, but
-- if this game has that bridge turned off, nothing typed in chat will
-- reach this; swap to TextChatService.MessageReceived instead if so.
-- [found] this is an actual in-game CHAT command, typed in the chat
-- window during a live test -- NOT something to paste into Studio's
-- Command Bar (that runs Lua, and "/forestfire" isn't valid Lua). Keys
-- have no leading "/" -- the handler below strips one off the incoming
-- message before matching, since opening chat by pressing the "/" key
-- itself consumes that character as the "open chat" hotkey rather than
-- sending it as part of the message, so what actually arrives can be
-- either "/forestfire" or just "forestfire" depending on how chat was
-- opened. Typing the key WITH its own leading slash here would only ever
-- match the first case.
-- [stated] "/dev text command that would make my character invincible,
-- faster, and can fly, along with never getting hungry" -- TESTING ONLY,
-- same spirit as the rest of this block. A toggle rather than a one-shot
-- (typing it again turns everything back off), so dev_mode_players tracks
-- who currently has it on; everything else (invincibility, hunger) is
-- just a flag flip on another module, but WalkSpeed needs its own
-- continuous reassertion below since Countdown_Player_Movement/
-- Freeze_Players (arena event cinematic pans) both stomp WalkSpeed back
-- to the normal value periodically, independent of dev mode.
local dev_mode_players = {} -- [player] = true while /dev is active
local DEV_WALK_SPEED = 50
local NORMAL_WALK_SPEED = 16
local function Set_Dev_Mode(player, enabled)
	dev_mode_players[player] = enabled or nil
	player_combat.set_dev_invulnerable(player, enabled)
	player_hunger.set_immune(player, enabled)
	dev_fly_toggled:FireClient(player, enabled)
	if not enabled then
		local character = player.Character
		local humanoid = character and character:FindFirstChild("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = NORMAL_WALK_SPEED
		end
	end
end
-- Keeps DEV_WALK_SPEED actually sticking for as long as dev mode is on --
-- a single set on toggle-in would otherwise get silently overwritten the
-- next time Countdown_Player_Movement or an arena event's Freeze_Players
-- runs, since neither of those knows or cares about dev mode.
task.spawn(function()
	while true do
		for player in pairs(dev_mode_players) do
			local character = player.Character
			local humanoid = character and character:FindFirstChild("Humanoid")
			if humanoid and humanoid.WalkSpeed ~= DEV_WALK_SPEED then
				humanoid.WalkSpeed = DEV_WALK_SPEED
			end
		end
		task.wait(0.5)
	end
end)
local DEBUG_COMMANDS = {
	forestfire = function(player)
		print("[ForestFireDebug] /forestfire command received from " .. player.Name .. ", game_data.state=" .. tostring(game_data.state) .. ", origin trees on game_data: " .. tostring(game_data.forest_fire_origin_trees and #game_data.forest_fire_origin_trees or "nil"))
		local found = arena_event_scheduler.force_trigger("Forest Fire", game_data)
		print("[ForestFireDebug] force_trigger('Forest Fire') returned: " .. tostring(found) .. " (false means no event was registered under that exact name)")
	end,
	-- [stated] "a / text command for both the animal frenzy event and the
	-- zombie event so I can manually trigger them for testing" -- same
	-- force_trigger/ArenaEventScheduler pattern as /forestfire above, just
	-- pointed at the other two event names exactly as register_event
	-- spelled them further up ("Zombies", "Animal Frenzy") -- force_trigger
	-- matches by that exact string, so these have to agree with it.
	zombies = function(player)
		print("[ArenaManager DEBUG] /zombies command received from " .. player.Name .. ", game_data.state=" .. tostring(game_data.state))
		local found = arena_event_scheduler.force_trigger("Zombies", game_data)
		print("[ArenaManager DEBUG] force_trigger('Zombies') returned: " .. tostring(found) .. " (false means no event was registered under that exact name)")
	end,
	animalfrenzy = function(player)
		print("[ArenaManager DEBUG] /animalfrenzy command received from " .. player.Name .. ", game_data.state=" .. tostring(game_data.state))
		local found = arena_event_scheduler.force_trigger("Animal Frenzy", game_data)
		print("[ArenaManager DEBUG] force_trigger('Animal Frenzy') returned: " .. tostring(found) .. " (false means no event was registered under that exact name)")
	end,
	-- [stated] same "test it faster than waiting for it to naturally occur"
	-- need as the three above, now that Flood is registered -- matches
	-- "Flood" exactly as spelled in the register_event call further up.
	flood = function(player)
		print("[ArenaManager DEBUG] /flood command received from " .. player.Name .. ", game_data.state=" .. tostring(game_data.state))
		local found = arena_event_scheduler.force_trigger("Flood", game_data)
		print("[ArenaManager DEBUG] force_trigger('Flood') returned: " .. tostring(found) .. " (false means no event was registered under that exact name)")
	end,
	dev = function(player)
		Set_Dev_Mode(player, not dev_mode_players[player])
	end,
}
game_data.participants = {}
for _, p in ipairs(current_players) do
	game_data.participants[p] = true
end
-- TESTING ONLY — seeds the zombie appearance pool with your own live
-- character, so you can verify appearance capture works without needing
-- to actually die first. Remove once zombies are confirmed working.
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
		-- Every participant starts the new round with 1/1/1 stats, an
		-- empty inventory, and no equipped gear — remove_equipment first
		-- so any currently-worn armor/weapon parts actually get detached
		-- from the character, not just cleared from data; new_equipment
		-- then resets the (now-empty) equipped table itself.
		for p in pairs(game_data.participants) do
			player_equipment.remove_equipment(p)
			player_equipment.new_equipment(p)
			player_inventory.new_inventory(p)
			player_stats.new_player(p)
			-- Hunger resets to Normal every round same as stats/inventory —
			-- unlike PlayerWeight it IS stateful, so this needs an actual
			-- new_player call, not just a re-notify.
			player_hunger.new_player(p)
			-- Same reasoning as PlayerHunger — a leftover infection from a
			-- previous round shouldn't carry into a fresh one.
			player_infection.new_player(p)
			equipment_update_sig:FireClient(p, player_equipment.player_equipment[p])
			inventory_update_sig:FireClient(p, player_inventory.player_inventories[p])
			-- PlayerWeight keeps no state of its own (see its file header) so
			-- there's no new_player call to make here — just re-notify now
			-- that inventory/equipment/stats have all been wiped for the round.
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
	player_weight.notify(player) -- stateless module, see PlayerWeight's file header — just an initial push so the client isn't blank
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
		-- Tracks the Y position a freefall started at, so Landed can work
		-- out how far the character actually fell. Reset to nil whenever a
		-- freefall isn't currently in progress, so a Landed with nothing to
		-- compare against (e.g. this connection firing mid-fall on rejoin)
		-- can't apply damage off a bogus baseline.
		local freefall_start_y = nil
		-- [stated] jumping is one of the actions that speeds up hunger — no
		-- dedicated "jump" remote/request exists (jumping is Roblox's own
		-- default movement, not something this project's networking touches),
		-- so this is the actual moment a jump starts: Humanoid's own
		-- StateChanged firing into its built-in Jumping state. Freefall/
		-- Landed (also built-in Humanoid states) are reused here for fall
		-- damage — [stated] "Endurance -> reduced fall damage" needed a fall
		-- damage system to exist at all first, since there wasn't one.
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
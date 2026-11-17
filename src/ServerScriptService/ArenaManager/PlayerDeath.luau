local PlayerDeath = {}

local lobby_folder = workspace:WaitForChild("Lobby")
local lobby_spawn = lobby_folder:WaitForChild("LobbySpawn")

local server_script_service = game:GetService("ServerScriptService")
local player_inventory = require(server_script_service:WaitForChild("PlayerInventory"))
local player_equipment = require(server_script_service:WaitForChild("PlayerEquipment"))
local player_combat = require(server_script_service:WaitForChild("PlayerCombat"))
local eliminated_appearances = require(server_script_service:WaitForChild("ArenaManager"):WaitForChild("EliminatedAppearances"))

function PlayerDeath.sendtolobby(character, game_data)
	character:PivotTo(lobby_spawn.CFrame + Vector3.new(0, 5, 0))
end

function PlayerDeath.eliminateplayer(player, game_data)
	game_data.participants[player] = nil
	game_data.spectators[player] = true

	-- Capture appearance BEFORE LoadCharacter destroys it, for zombies later.
	local character = player.Character
	if character then
		eliminated_appearances.capture(player, character)
	end

	player_inventory.remove_inventory(player)
	player_inventory.new_inventory(player)
	player_equipment.remove_equipment(player)
	player_equipment.new_equipment(player)
	player_combat.remove_player(player)

	player:LoadCharacter()
end

function PlayerDeath.disconnectplayer(player, game_data)
	game_data.participants[player] = nil
	game_data.spectators[player] = nil
end

return PlayerDeath
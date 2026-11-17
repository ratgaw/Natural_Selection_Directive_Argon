-- Setting ease of use variables for studio functions for later use
local players = game:GetService("Players")

-- Grabbing modules and assigning to variables
local player_defaults = require(script.JoinedPlayerDefaults)

-- Sets default speed and POV for players upon connecting to game
players.PlayerAdded:Connect(function(player)

	player.CharacterAdded:Connect(function(character)
		player_defaults.defaultspeed(character)
	end)

	player_defaults.defaultpov(player)
end)
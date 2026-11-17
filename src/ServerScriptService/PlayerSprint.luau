-- Whether each player is currently sprinting, from their real sprint request.
-- Shared by RequestChecker (movement) and PlayerCombat (animation sync), which
-- can't infer it from Roblox's walk/run blend once weight lowers WalkSpeed.
local PlayerSprint = {}
local sprinting_players = {}
-- Set by RequestChecker only: the client's request, or out-of-stamina cancel.
function PlayerSprint.set_sprinting(player, is_sprinting)
	sprinting_players[player] = is_sprinting or nil
end
function PlayerSprint.is_sprinting(player)
	return sprinting_players[player] == true
end
function PlayerSprint.remove_player(player)
	sprinting_players[player] = nil
end
return PlayerSprint

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local stats_updated = ReplicatedStorage:WaitForChild("StatsUpdated")
local PlayerStats = {}
PlayerStats.player_stats = {} -- [player] = {Strength = n, Endurance = n, Dexterity = n}
local BASE_STAT_VALUE = 1
local VALID_STATS = {
	Strength = true,
	Endurance = true,
	Dexterity = true,
}
local function Fire_Update(player, data)
	stats_updated:FireClient(player, {
		Strength = data.Strength,
		Endurance = data.Endurance,
		Dexterity = data.Dexterity,
	})
end
-- Resets a player to base stats (1/1/1). Called on join and at match start.
function PlayerStats.new_player(player)
	local data = {
		Strength = BASE_STAT_VALUE,
		Endurance = BASE_STAT_VALUE,
		Dexterity = BASE_STAT_VALUE,
	}
	PlayerStats.player_stats[player] = data
	Fire_Update(player, data)
end
function PlayerStats.remove_player(player)
	PlayerStats.player_stats[player] = nil
end
function PlayerStats.get(player, stat_name)
	local data = PlayerStats.player_stats[player]
	if not data then
		return BASE_STAT_VALUE
	end
	return data[stat_name] or BASE_STAT_VALUE
end
-- Raises one stat (stat-boost items). Doesn't check ownership -- the caller
-- (UseItemRequest) validates and consumes the item.
function PlayerStats.add_stat(player, stat_name, amount)
	if not VALID_STATS[stat_name] then
		return false, "invalid stat name"
	end
	local data = PlayerStats.player_stats[player]
	if not data then
		return false, "player has no stat data"
	end
	data[stat_name] = data[stat_name] + amount
	Fire_Update(player, data)
	return true
end
return PlayerStats

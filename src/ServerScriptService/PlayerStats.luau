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
-- Resets a player to base stats (1/1/1). Intended to be called both once
-- on PlayerAdded AND again at the start of every new round, since stats
-- are meant to reset each round rather than persist across them — see
-- open question about exactly where round-start currently lives.
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
function PlayerStats.get_all(player)
	local data = PlayerStats.player_stats[player]
	if not data then
		return {Strength = BASE_STAT_VALUE, Endurance = BASE_STAT_VALUE, Dexterity = BASE_STAT_VALUE}
	end
	return {Strength = data.Strength, Endurance = data.Endurance, Dexterity = data.Dexterity}
end
-- Increases a single stat by amount — used by rare crate stat-boost
-- items. Server-authoritative in the sense that this function is the
-- only place stat totals change, but it does NOT itself check inventory
-- ownership or consume an item; the caller (the UseItemRequest handler,
-- once that exists) is responsible for validating the request first.
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

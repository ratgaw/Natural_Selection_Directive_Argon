local PlayerMinimap = {}
PlayerMinimap.player_upgrades = {} -- player_upgrades[player] = {Terrain = true, ...}

function PlayerMinimap.new_player(player)
	PlayerMinimap.player_upgrades[player] = {}
end

function PlayerMinimap.remove_player(player)
	PlayerMinimap.player_upgrades[player] = nil
end

function PlayerMinimap.grant_upgrade(player, upgrade_name)
	local upgrades = PlayerMinimap.player_upgrades[player]
	if not upgrades then
		return
	end
	upgrades[upgrade_name] = true
end

function PlayerMinimap.has_upgrade(player, upgrade_name)
	local upgrades = PlayerMinimap.player_upgrades[player]
	return upgrades and upgrades[upgrade_name] == true
end

return PlayerMinimap

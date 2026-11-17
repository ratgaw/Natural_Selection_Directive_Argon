local MinimapData = {}
MinimapData.terrain_snapshot = nil -- set once per match by StartMatch.Generate

function MinimapData.set_snapshot(snapshot)
	MinimapData.terrain_snapshot = snapshot
end

function MinimapData.get_snapshot()
	return MinimapData.terrain_snapshot
end

return MinimapData
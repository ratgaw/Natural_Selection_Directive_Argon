local JoinedPlayerDefaults = {}

local walk_speed = 16

function JoinedPlayerDefaults.defaultspeed(player)
	local humanoid = player:WaitForChild("Humanoid")
	humanoid.WalkSpeed = walk_speed
end

function JoinedPlayerDefaults.defaultpov(player)
	player.CameraMinZoomDistance = 0
	player.CameraMaxZoomDistance = 14
end

return JoinedPlayerDefaults
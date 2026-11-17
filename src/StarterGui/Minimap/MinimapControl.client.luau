local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")

local minimap_upgrade_granted = replicated_storage:WaitForChild("MinimapUpgradeGranted")
local beacon_crate_spawned = replicated_storage:WaitForChild("BeaconCrateSpawned")
local beacon_crate_looted = replicated_storage:WaitForChild("BeaconCrateLooted")
-- Cure stations shown as white squares (never removed).
local cure_station_spawned = replicated_storage:WaitForChild("CureStationSpawned")

local minimap_gui = script.Parent
local minimap_frame = minimap_gui:WaitForChild("MinimapFrame")
local terrain_layer = minimap_frame:WaitForChild("TerrainLayer")
local player_icon = minimap_frame:WaitForChild("PlayerIcon")
local match_started = replicated_storage:WaitForChild("MatchStarted")

local local_player = players.LocalPlayer
local map_radius = workspace:GetAttribute("MapRadius") or 350

workspace:GetAttributeChangedSignal("MapRadius"):Connect(function()
	map_radius = workspace:GetAttribute("MapRadius") or map_radius
end)

-- Turns minimap on on match start
match_started.OnClientEvent:Connect(function()
	minimap_frame.Visible = true
end)

-- Converts a world position into a minimap-space UDim2, shared by both
-- the player icon and any crate/event markers.
local function World_To_Minimap_Position(world_position)
	local offset_x = math.clamp(world_position.X / map_radius, -1, 1) * 0.5
	local offset_z = math.clamp(world_position.Z / map_radius, -1, 1) * 0.5
	return UDim2.new(0.5 + offset_x, 0, 0.5 + offset_z, 0)
end

-- Function controlling player icon on minimap
local function Update_Player_Icon()
	local character = local_player.Character
	if not character then
		return
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	player_icon.Position = World_To_Minimap_Position(root.Position)
end

run_service.Heartbeat:Connect(Update_Player_Icon)

local BIOME_COLORS = {
	Forest = Color3.fromRGB(45, 95, 40),
	Field = Color3.fromRGB(110, 165, 70),
	Mountain = Color3.fromRGB(120, 115, 110),
	Water = Color3.fromRGB(40, 90, 150),
	Settlement = Color3.fromRGB(150, 145, 135),
	Snow = Color3.fromRGB(230, 230, 235),
}
local DEFAULT_COLOR = Color3.fromRGB(80, 80, 80)

local function Build_Terrain_Grid(snapshot)
	local resolution = snapshot.resolution
	local tile_size = 1 / (resolution + 1)

	for i = 1, resolution + 1 do
		for j = 1, resolution + 1 do
			local cell = snapshot.cells[i][j]
			local tile = Instance.new("Frame")
			tile.BorderSizePixel = 0
			tile.Size = UDim2.new(tile_size, 0, tile_size, 0)
			tile.Position = UDim2.new((i - 1) * tile_size, 0, (j - 1) * tile_size, 0)
			tile.BackgroundColor3 = BIOME_COLORS[cell.biome] or DEFAULT_COLOR
			tile.Parent = terrain_layer
		end
	end
end

minimap_upgrade_granted.OnClientEvent:Connect(function(upgrade_name, snapshot)
	if upgrade_name == "Terrain" then
		terrain_layer.Visible = true
		if snapshot then
			Build_Terrain_Grid(snapshot)
		end
	end
end)

-- Beacon crate marker, visible to everyone.
local BEACON_MARKER_COLOR = Color3.fromRGB(220, 60, 40)
local beacon_markers = {} -- [crate_instance] = marker_frame

beacon_crate_spawned.OnClientEvent:Connect(function(crate_instance)
	if not crate_instance or not crate_instance.Parent then
		return
	end

	local marker = Instance.new("Frame")
	marker.Size = UDim2.fromOffset(8, 8)
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.BackgroundColor3 = BEACON_MARKER_COLOR
	marker.BorderSizePixel = 0
	marker.Position = World_To_Minimap_Position(crate_instance:GetPivot().Position)
	marker.ZIndex = 5
	marker.Parent = minimap_frame

	beacon_markers[crate_instance] = marker
end)

beacon_crate_looted.OnClientEvent:Connect(function(crate_instance)
	local marker = beacon_markers[crate_instance]
	if marker then
		marker:Destroy()
		beacon_markers[crate_instance] = nil
	end
end)

local CURE_STATION_MARKER_COLOR = Color3.fromRGB(255, 255, 255)

cure_station_spawned.OnClientEvent:Connect(function(station_instance)
	if not station_instance or not station_instance.Parent then
		return
	end

	local marker = Instance.new("Frame")
	marker.Size = UDim2.fromOffset(8, 8)
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.BackgroundColor3 = CURE_STATION_MARKER_COLOR
	marker.BorderSizePixel = 0
	marker.Position = World_To_Minimap_Position(station_instance:GetPivot().Position)
	marker.ZIndex = 5
	marker.Parent = minimap_frame
end)
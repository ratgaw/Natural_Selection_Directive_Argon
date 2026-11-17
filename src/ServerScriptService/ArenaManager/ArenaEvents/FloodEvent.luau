-- Flood event: a storm (wind that pushes players, rain, lightning, dark sky)
-- while the water level rises. The storm reverts afterwards; the water stays
-- for the rest of the match. Warnings and the camera pan are handled by
-- ArenaEventScheduler before trigger() runs. trigger() returns immediately --
-- the ~100 s sequence runs in its own thread.
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local Terrain = workspace.Terrain
local FloodEvent = {}
-- Placeholders, tune once tested.
local STORM_RISE_START_DELAY = 10 -- seconds of storm (wind/rain/lightning) before the water starts climbing -- a beat to let the storm establish first
local STORM_RISE_DURATION = 80 -- seconds for the water to climb from the map's lowest sampled point to the target level
local STORM_TAIL = 10 -- seconds the storm keeps going after the rise finishes, rather than cutting out the instant the water stops
local STORM_DURATION = STORM_RISE_START_DELAY + STORM_RISE_DURATION + STORM_TAIL
local FLOOD_LEVEL_ABOVE_AVERAGE = 5 -- target water level = average terrain height - 5
-- Target height comes from sampling the current terrain with a grid of
-- downward terrain-only raycasts.
local SAMPLE_GRID_SPACING = 100 -- studs between each height sample -- finer = more accurate average, more raycasts (~1400 at the default map radius)
-- ReadVoxels/WriteVoxels only accept resolution 4.
local TERRAIN_VOXEL_RESOLUTION = 4
-- Per-call voxel budget (Roblox's limit is roughly 4.2M); Flood_Fill_Slab splits
-- the map into chunks under this.
local MAX_VOXELS_PER_TERRAIN_CALL = 3000000
local STORM_RISE_STEP_INTERVAL = 2 -- seconds between each incremental Terrain fill while the water is climbing
local WIND_ACCELERATION = 28 -- studs/s^2, scaled by each player's mass
local WIND_GUST_MIN_STRENGTH = 0.5 -- gusts vary between this and 1.0 of WIND_ACCELERATION, not a constant steady push
local WIND_GUST_INTERVAL_MIN = 2 -- seconds between picking a new random gust direction/strength
local WIND_GUST_INTERVAL_MAX = 5
local LIGHTNING_INTERVAL_MIN = 4 -- seconds between sky flashes
local LIGHTNING_INTERVAL_MAX = 12
local LIGHTNING_FLASH_BRIGHTNESS = 6
local LIGHTNING_FLASH_DURATION = 0.12
local RAIN_HEIGHT_ABOVE_PLAYER = 40 -- studs -- rain emitter follows each player from directly overhead at this height
local RAIN_UPDATE_INTERVAL = 0.2 -- seconds between repositioning rain emitters over moving players
local RAIN_SOUND_ID = "rbxassetid://0" -- placeholder -- a looping heavy-rain ambience, fill in once picked
local THUNDER_SOUND_ID = "rbxassetid://0" -- placeholder -- a short thunder crack, fill in once picked
local RAIN_TEXTURE_ID = "rbxassetid://0" -- placeholder -- a plain white vertical streak decal reads well as falling rain, fill in once picked
-- Storm lighting. The previous Lighting values are restored when it ends.
local STORM_BRIGHTNESS = 1
local STORM_AMBIENT = Color3.fromRGB(45, 45, 50)
local STORM_OUTDOOR_AMBIENT = Color3.fromRGB(55, 55, 60)
local STORM_FOG_COLOR = Color3.fromRGB(120, 120, 130)
local STORM_FOG_END = 350
-- The flood only happens once per match.
local has_flooded = false
local storm_active = false
local wind_direction = Vector3.new(1, 0, 0)
local wind_strength = 0
-- Per-player storm effects, keyed by Player so they survive respawns. Rain
-- parts live in workspace and need manual cleanup; the wind force lives on the
-- root part and is recreated on each CharacterAdded.
local storm_rain_parts = {}
local storm_character_connections = {}
local storm_player_added_connection = nil
local terrain_raycast_params = RaycastParams.new()
terrain_raycast_params.FilterType = Enum.RaycastFilterType.Include
terrain_raycast_params.FilterDescendantsInstances = {Terrain}
-- Returns the average and minimum sampled heights: the target is based on the
-- average, and the rise starts from the minimum. nil, nil if nothing was hit.
local function Sample_Average_Terrain_Height(map_radius)
	local total, count = 0, 0
	local min_height = math.huge
	for x = -map_radius, map_radius, SAMPLE_GRID_SPACING do
		for z = -map_radius, map_radius, SAMPLE_GRID_SPACING do
			if x * x + z * z <= map_radius * map_radius then
				local result = workspace:Raycast(Vector3.new(x, 1000, z), Vector3.new(0, -2000, 0), terrain_raycast_params)
				if result then
					total += result.Position.Y
					count += 1
					if result.Position.Y < min_height then
						min_height = result.Position.Y
					end
				end
			end
		end
	end
	if count == 0 then
		return nil, nil
	end
	return total / count, min_height
end
-- Fills one chunk of the new slab, turning only Air voxels into Water so solid
-- terrain below the water line is kept.
local function Fill_Voxel_Chunk(min_corner, max_corner)
	local region = Region3.new(min_corner, max_corner):ExpandToGrid(TERRAIN_VOXEL_RESOLUTION)
	local materials, occupancies = Terrain:ReadVoxels(region, TERRAIN_VOXEL_RESOLUTION)
	local size = materials.Size
	for x = 1, size.X do
		for y = 1, size.Y do
			for z = 1, size.Z do
				if materials[x][y][z] == Enum.Material.Air then
					materials[x][y][z] = Enum.Material.Water
					occupancies[x][y][z] = 1
				end
			end
		end
	end
	Terrain:WriteVoxels(region, TERRAIN_VOXEL_RESOLUTION, materials, occupancies)
end
-- Fills one rise step's slab across the whole map in chunks that each stay
-- under MAX_VOXELS_PER_TERRAIN_CALL.
local function Flood_Fill_Slab(map_radius, bottom_y, top_y)
	local full_width = map_radius * 2
	local height_cells = math.max(1, math.ceil((top_y - bottom_y) / TERRAIN_VOXEL_RESOLUTION))
	local max_side_cells = math.max(1, math.floor(math.sqrt(MAX_VOXELS_PER_TERRAIN_CALL / height_cells)))
	local chunk_side = max_side_cells * TERRAIN_VOXEL_RESOLUTION
	local chunk_count = math.max(1, math.ceil(full_width / chunk_side))
	for chunk_x = 0, chunk_count - 1 do
		local min_x = -map_radius + chunk_x * chunk_side
		local max_x = math.min(map_radius, min_x + chunk_side)
		for chunk_z = 0, chunk_count - 1 do
			local min_z = -map_radius + chunk_z * chunk_side
			local max_z = math.min(map_radius, min_z + chunk_side)
			Fill_Voxel_Chunk(
				Vector3.new(min_x, bottom_y, min_z),
				Vector3.new(max_x, top_y, max_z)
			)
		end
	end
end
-- Raises the water from start_level to target_level in steps over
-- STORM_RISE_DURATION. workspace's "WaterLevel" attribute tracks the current
-- level and keeps the final value.
local function Rise_Water_Over_Time(map_radius, start_level, target_level)
	local total_rise = target_level - start_level
	if total_rise <= 0 then
		warn("[FloodEvent] computed target water level (", target_level, ") isn't above the map's lowest sampled point (", start_level, ") -- skipping the rise entirely")
		return
	end
	local steps = math.max(1, math.floor(STORM_RISE_DURATION / STORM_RISE_STEP_INTERVAL))
	local step_height = total_rise / steps
	local current_level = start_level
	workspace:SetAttribute("WaterLevel", current_level)
	for step = 1, steps do
		local next_level = (step == steps) and target_level or (current_level + step_height)
		Flood_Fill_Slab(map_radius, current_level, next_level)
		current_level = next_level
		workspace:SetAttribute("WaterLevel", current_level)
		task.wait(STORM_RISE_STEP_INTERVAL)
	end
	workspace:SetAttribute("FloodHasOccurred", true)
end
-- Adds one player's rain emitter and wind VectorForce. Called for everyone at
-- the start and again on respawn during the storm.
local function Setup_Storm_Player(player, character)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		warn("[FloodEvent] " .. player.Name .. "'s character has no HumanoidRootPart -- storm wind/rain skipped for them until their next spawn")
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "StormWindAttachment"
	attachment.Parent = root
	local force = Instance.new("VectorForce")
	force.Name = "StormWind"
	force.Attachment0 = attachment
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.Force = Vector3.new(0, 0, 0) -- set for real by Update_Wind_Gust's loop below
	force.Parent = root
	-- Remove the rain part from a previous character before making a new one.
	local old_rain_part = storm_rain_parts[player]
	if old_rain_part then
		old_rain_part:Destroy()
	end
	local rain_part = Instance.new("Part")
	rain_part.Name = "StormRainEmitter"
	rain_part.Size = Vector3.new(1, 1, 1)
	rain_part.Transparency = 1
	rain_part.CanCollide = false
	rain_part.CanQuery = false
	rain_part.Anchored = true
	rain_part.CFrame = CFrame.new(root.Position + Vector3.new(0, RAIN_HEIGHT_ABOVE_PLAYER, 0))
	rain_part.Parent = workspace
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = RAIN_TEXTURE_ID
	emitter.Lifetime = NumberRange.new(1.5, 2)
	emitter.Rate = 300
	emitter.Speed = NumberRange.new(80, 100)
	emitter.SpreadAngle = Vector2.new(4, 4)
	emitter.Size = NumberSequence.new(0.3)
	emitter.Transparency = NumberSequence.new(0.4)
	emitter.Acceleration = Vector3.new(0, -120, 0)
	emitter.Parent = rain_part
	local rain_sound = Instance.new("Sound")
	rain_sound.Name = "StormRainAmbience"
	rain_sound.SoundId = RAIN_SOUND_ID
	rain_sound.Looped = true
	rain_sound.Volume = 0.6
	rain_sound.Parent = rain_part
	rain_sound:Play()
	storm_rain_parts[player] = rain_part
end
-- Removes one player's rain part and wind force.
local function Teardown_Storm_Player(player)
	local rain_part = storm_rain_parts[player]
	if rain_part then
		rain_part:Destroy()
		storm_rain_parts[player] = nil
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local wind_attachment = root and root:FindFirstChild("StormWindAttachment")
	if wind_attachment then
		wind_attachment:Destroy() -- takes its child VectorForce with it
	end
end
-- Keeps each rain emitter centered over its player.
local function Update_Rain_Positions()
	for player, rain_part in pairs(storm_rain_parts) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			rain_part.CFrame = CFrame.new(root.Position + Vector3.new(0, RAIN_HEIGHT_ABOVE_PLAYER, 0))
		end
	end
end
-- Picks a new gust and applies it twice: workspace.GlobalWind (cosmetic only,
-- it never pushes players) and a VectorForce on each player scaled by their
-- mass. Walking Humanoids partly resist the push; raise WIND_ACCELERATION if
-- it feels too weak.
local function Update_Wind_Gust()
	local angle = math.random() * 2 * math.pi
	wind_direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
	wind_strength = WIND_ACCELERATION * (WIND_GUST_MIN_STRENGTH + math.random() * (1 - WIND_GUST_MIN_STRENGTH))
	workspace.GlobalWind = wind_direction * wind_strength
	for player in pairs(storm_rain_parts) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local attachment = root and root:FindFirstChild("StormWindAttachment")
		local force = attachment and attachment:FindFirstChild("StormWind")
		if force then
			force.Force = wind_direction * wind_strength * root.AssemblyMass
		end
	end
end
-- Cosmetic lightning flashes with thunder; never damages anyone.
local function Run_Lightning_Loop(thunder_sound)
	while storm_active do
		task.wait(LIGHTNING_INTERVAL_MIN + math.random() * (LIGHTNING_INTERVAL_MAX - LIGHTNING_INTERVAL_MIN))
		if not storm_active then
			break
		end
		Lighting.Brightness = LIGHTNING_FLASH_BRIGHTNESS
		thunder_sound:Play()
		task.wait(LIGHTNING_FLASH_DURATION)
		if storm_active then
			Lighting.Brightness = STORM_BRIGHTNESS
		end
	end
end
-- Runs the temporary storm for every current and joining player, then restores
-- the lighting. Doesn't touch the water.
local function Start_Storm(duration)
	storm_active = true
	local original_lighting = {
		Brightness = Lighting.Brightness,
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		FogColor = Lighting.FogColor,
		FogEnd = Lighting.FogEnd,
	}
	Lighting.Brightness = STORM_BRIGHTNESS
	Lighting.Ambient = STORM_AMBIENT
	Lighting.OutdoorAmbient = STORM_OUTDOOR_AMBIENT
	Lighting.FogColor = STORM_FOG_COLOR
	Lighting.FogEnd = STORM_FOG_END
	local thunder_sound = Instance.new("Sound")
	thunder_sound.Name = "StormThunder"
	thunder_sound.SoundId = THUNDER_SOUND_ID
	thunder_sound.Volume = 1
	thunder_sound.Parent = SoundService
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			Setup_Storm_Player(player, player.Character)
		end
		storm_character_connections[player] = player.CharacterAdded:Connect(function(character)
			if storm_active then
				Setup_Storm_Player(player, character)
			end
		end)
	end
	storm_player_added_connection = Players.PlayerAdded:Connect(function(player)
		storm_character_connections[player] = player.CharacterAdded:Connect(function(character)
			if storm_active then
				Setup_Storm_Player(player, character)
			end
		end)
	end)
	task.spawn(Run_Lightning_Loop, thunder_sound)
	task.spawn(function()
		while storm_active do
			Update_Wind_Gust()
			task.wait(WIND_GUST_INTERVAL_MIN + math.random() * (WIND_GUST_INTERVAL_MAX - WIND_GUST_INTERVAL_MIN))
		end
	end)
	task.spawn(function()
		while storm_active do
			Update_Rain_Positions()
			task.wait(RAIN_UPDATE_INTERVAL)
		end
	end)
	task.delay(duration, function()
		storm_active = false
		Lighting.Brightness = original_lighting.Brightness
		Lighting.Ambient = original_lighting.Ambient
		Lighting.OutdoorAmbient = original_lighting.OutdoorAmbient
		Lighting.FogColor = original_lighting.FogColor
		Lighting.FogEnd = original_lighting.FogEnd
		workspace.GlobalWind = Vector3.new(0, 0, 0)
		thunder_sound:Destroy()
		if storm_player_added_connection then
			storm_player_added_connection:Disconnect()
			storm_player_added_connection = nil
		end
		for player, connection in pairs(storm_character_connections) do
			connection:Disconnect()
			Teardown_Storm_Player(player)
		end
		storm_character_connections = {}
	end)
end
-- Storm, then the water rise. Runs in its own thread.
local function Run_Flood_Sequence()
	-- Warnings and lead-in already happened in the scheduler.
	Start_Storm(STORM_DURATION)
	local map_radius = workspace:GetAttribute("MapRadius") or 2100
	local average_height, min_height = Sample_Average_Terrain_Height(map_radius)
	if not average_height then
		warn("[FloodEvent] no terrain height samples collected -- skipping the water rise entirely (storm still runs)")
		return
	end
	local target_level = average_height + FLOOD_LEVEL_ABOVE_AVERAGE
	task.wait(STORM_RISE_START_DELAY)
	Rise_Water_Over_Time(map_radius, min_height, target_level)
end
function FloodEvent.trigger(game_data)
	if has_flooded then
		return
	end
	has_flooded = true
	task.spawn(Run_Flood_Sequence)
end
return FloodEvent
-- Flood arena event: a huge storm (wind that actually pushes players
-- around, rain, and lightning) rolls in over the whole map, and while it's
-- going the sea level smoothly climbs. [stated] "even after the intial
-- rise is down for the rest of the match the water level should be higher
-- than it was when the match started" -- the storm (wind/rain/lightning/
-- darkened sky) is temporary and fully reverts once it passes, but the
-- Terrain water it leaves behind is NOT reverted anywhere in this file --
-- end_storm only cleans up the atmosphere, never the water, so the map
-- stays flooded for the rest of the match exactly as asked.
-- Lives in ServerScriptService > ArenaManager > ArenaEvents, alongside
-- AnimalFrenzyEvent/ForestFireEvent/SupplyDropEvent/ZombieEvent/
-- ArenaEventScheduler, and is registered into the scheduler's pool from
-- ArenaManager.lua (the Script one level up, not a module in this
-- folder) the exact same way those four already are:
-- local flood_event = require(events_folder:WaitForChild("FloodEvent"))
-- arena_event_scheduler.register_event("Flood", flood_event.trigger)
-- ArenaEventScheduler.lua's own Run_Event already does its own
-- Send_Warnings (WARNING_LONG/WARNING_SHORT) and freeze/cinematic-pan
-- sequence BEFORE ever calling chosen.run, so trigger() below doesn't
-- fire its own EventWarning or wait out its own lead-in the way an
-- earlier version of this file did -- that would have doubled up on both.
-- trigger() only ever does real work once per match (see has_flooded
-- below) and returns almost immediately itself -- the storm/rise run in
-- their own background coroutine, so even though Run_Event already calls
-- chosen.run inside its own task.spawn+pcall, this stays safe to call
-- from anywhere (including force_trigger, and ArenaManager.lua's new
-- "/flood" debug chat command) without blocking its caller for the ~100
-- seconds the full sequence takes.
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
local FLOOD_LEVEL_ABOVE_AVERAGE = 5 -- [stated] "take the water level to that average - 5"
-- [stated] "take the height of each terrain placed during map generation,
-- find the average" -- rather than reaching into StartMatch.lua's
-- generation-time data (which this file has no access to, and which could
-- be stale against anything that reshapes terrain after generation --
-- roads, settlement flattening, ForestFireEvent, etc.), this samples the
-- ACTUAL current terrain via a grid of straight-down raycasts, same
-- Include-Terrain-only raycast shape AnimalFrenzyEvent.lua's
-- Get_Ground_Height already uses for the cure station obelisks. Same
-- result in spirit ("the average height of the terrain"), but always
-- matches what's really out there right now.
local SAMPLE_GRID_SPACING = 100 -- studs between each height sample -- finer = more accurate average, more raycasts (~1400 at the default map radius)
-- [stated/found] Studio error "Resolution has to be 4" the first time the
-- flood event actually tried to rise -- unlike FillRegion/FillBlock,
-- ReadVoxels/WriteVoxels don't accept an arbitrary resolution at all; 4
-- studs is the only legal value for either call, full stop. There's no
-- "coarser voxel for water" option here the way the old 32 assumed.
local TERRAIN_VOXEL_RESOLUTION = 4
-- With resolution forced to 4 (instead of the old 32), a single
-- ReadVoxels/WriteVoxels call over the WHOLE map width could badly exceed
-- Roblox's per-call voxel limit (community-measured at 4,194,304 voxels --
-- Roblox doesn't document an exact number) depending on map_radius and how
-- thick a given rise step ends up being. Flood_Fill_Slab below chunks the
-- fill into squares sized to stay comfortably under this budget instead,
-- so it stays correct regardless of map size -- this is the replacement
-- for what WATER_FILL_RESOLUTION used to do by being coarse.
local MAX_VOXELS_PER_TERRAIN_CALL = 3000000
local STORM_RISE_STEP_INTERVAL = 2 -- seconds between each incremental Terrain fill while the water is climbing
local WIND_ACCELERATION = 28 -- studs/s^2 -- [stated] "wind effects those be turned up enough that the player has to deal with it some" -- multiplied by each player's own AssemblyMass below so it reads as the same PUSH regardless of a given character's mass, not a fixed raw force
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
-- Darkened-storm look -- snapshotted from whatever Lighting already has
-- and restored exactly once the storm passes (see Start_Storm/End_Storm),
-- same "don't clobber the existing setup, just borrow it for a while"
-- shape AnimalFrenzy's AggroRange boost / end_frenzy revert already uses.
local STORM_BRIGHTNESS = 1
local STORM_AMBIENT = Color3.fromRGB(45, 45, 50)
local STORM_OUTDOOR_AMBIENT = Color3.fromRGB(55, 55, 60)
local STORM_FOG_COLOR = Color3.fromRGB(120, 120, 130)
local STORM_FOG_END = 350
-- The flood (storm + permanent water rise) only ever happens once per
-- match -- unlike AnimalFrenzy, there's no "fires more than once" case
-- here, and running the whole sequence twice would just mean a second,
-- redundant rise on top of an already-flooded map. Guards trigger() below
-- the same way AnimalFrenzyEvent.lua's cure_stations_spawned guards
-- Spawn_Cure_Stations against firing twice.
local has_flooded = false
local storm_active = false
local wind_direction = Vector3.new(1, 0, 0)
local wind_strength = 0
-- Per-player bookkeeping for the storm's temporary effects. Keyed by
-- Player (not Character) since a player can die and respawn mid-storm --
-- rain_parts are parented to workspace, not the character, so they
-- survive a respawn unless explicitly cleaned up here; the wind
-- Attachment/VectorForce are parented to the character's
-- HumanoidRootPart instead, so those DO get destroyed automatically the
-- moment that character is removed -- Setup_Storm_Player just needs to
-- recreate them on every CharacterAdded while the storm is still going.
local storm_rain_parts = {}
local storm_character_connections = {}
local storm_player_added_connection = nil
local terrain_raycast_params = RaycastParams.new()
terrain_raycast_params.FilterType = Enum.RaycastFilterType.Include
terrain_raycast_params.FilterDescendantsInstances = {Terrain}
-- Returns the average AND the minimum of every sampled height -- average
-- becomes the flood's target level (minus FLOOD_LEVEL_BELOW_AVERAGE), and
-- the minimum becomes where the rise visually starts from, so the water
-- climbs up from the map's actual lowest point rather than snapping into
-- existence at the target height. Returns nil, nil if nothing was hit at
-- all (shouldn't happen on a real map, but this file has no visibility
-- into whether Terrain exists yet when it's called).
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
-- Fills ONLY the thin new slab being exposed this rise step (bottom_y to
-- top_y), and only converts the AIR voxels within it to Water -- existing
-- solid terrain read back as anything else (rock, dirt, whatever) is
-- written back completely unchanged. That's deliberate: a naive
-- Terrain:FillBlock(..., Water) over this same box would overwrite solid
-- ground too, dissolving the base of any hill/mountain whose foot dips
-- below the current water line into water material straight through --
-- reading the existing voxels first and only touching the empty gaps
-- means low ground floods on TOP of its real floor instead of losing it.
-- One ReadVoxels/WriteVoxels call over a single chunk -- pulled out of
-- Flood_Fill_Slab so that function can call it once per chunk instead of
-- once over the whole map width.
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
-- Only ever asked to fill the new slab for one rise step at a time (never
-- the whole column down to some arbitrary floor), so the slab itself is
-- always thin -- but its FOOTPRINT is still the whole map, which at a
-- forced 4-stud resolution can run well past Roblox's per-call voxel
-- limit on a large map. Splits that footprint into square chunks sized so
-- each one's own ReadVoxels/WriteVoxels call stays under
-- MAX_VOXELS_PER_TERRAIN_CALL, looping Fill_Voxel_Chunk over however many
-- of those squares it takes to cover the full -map_radius..map_radius
-- extent in both X and Z.
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
-- Climbs from start_level to target_level over STORM_RISE_DURATION
-- seconds, one Flood_Fill_Slab call per STORM_RISE_STEP_INTERVAL seconds --
-- "smoothly rise" here means smoothly in the sense of steady, visible
-- progress over time, not a sub-second-tick animation; real Terrain water
-- (the whole point of using it over a cosmetic rising plane -- players can
-- actually swim in it) doesn't have a cheap way to animate any smoother
-- than incremental fills like this. workspace:SetAttribute("WaterLevel",
-- ...) is kept current throughout and left at the final target forever
-- after -- nothing in this file ever lowers it again -- so anything else
-- that wants to know "how high is the flood right now" (a future swim/
-- drown check, say) has somewhere to read it from without re-sampling
-- Terrain itself.
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
-- One player's temporary storm effects -- a rain emitter following
-- overhead, and a VectorForce on their HumanoidRootPart for the wind to
-- actually push against (the [stated] "real force on players" choice,
-- rather than just the cosmetic workspace.GlobalWind alone -- see
-- Update_Wind_Gust's own comment on why GlobalWind by itself doesn't
-- affect players at all). Called once up front for everyone already in
-- the match, and again from a CharacterAdded connection for the rest of
-- the storm so a mid-storm death/respawn doesn't leave that player
-- suddenly exempt from either effect.
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
	-- Old rain part (from a previous character, if this is a respawn) is
	-- parented to workspace rather than the character, so it survives the
	-- old character's destruction on its own -- clean it up explicitly
	-- before making the new one, same reasoning Handle_Death's dead-guard
	-- gives for not letting cleanup double up.
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
-- Reverses Setup_Storm_Player for one player -- destroys their rain part
-- (the only thing that doesn't already clean itself up) and, if their
-- current character is still around, the wind Attachment/VectorForce on
-- it too, so nobody keeps getting blown around after the storm's over.
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
-- Keeps every active rain emitter centered over its player as they move --
-- same follow-overhead shape, just X/Z tracking a moving target instead of
-- a fixed point.
local function Update_Rain_Positions()
	for player, rain_part in pairs(storm_rain_parts) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			rain_part.CFrame = CFrame.new(root.Position + Vector3.new(0, RAIN_HEIGHT_ABOVE_PLAYER, 0))
		end
	end
end
-- Picks a new random gust direction/strength and applies it both ways:
-- workspace.GlobalWind for whatever native wind-reactive visuals the map
-- might have (leaves, particles, cloth -- [stated] "if roblox has wind
-- effects those be turned up"), and a real VectorForce push on every
-- active player for the part that actually has to be dealt with. GlobalWind
-- ALONE does not push a Humanoid at all -- it's a purely cosmetic property
-- Roblox's own systems read, never applied as a physical force -- hence
-- needing the VectorForce as its own separate thing rather than relying on
-- GlobalWind to cover both. Force = direction * strength * AssemblyMass so
-- the wind reads as the same ACCELERATION on every player regardless of
-- their own mass, rather than a fixed raw force that would shove a lighter
-- character around far more than a heavier one for no in-fiction reason.
-- [known limitation, not yet confirmed] Humanoid's own walk-to-target
-- movement applies its own corrective force every physics step, which can
-- partially fight/dampen this while a player is actively walking -- the
-- push should still be clearly felt while standing still, swinging, or
-- drifting, but flag it if it reads as weaker than intended once you can
-- feel it in-game; a stronger WIND_ACCELERATION is the first thing to try.
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
-- Random sky flashes + thunder, timed together -- [stated] "atmospheric
-- only" per the earlier call on lightning: nothing here can hit or damage
-- a player, it's purely for drama. Brightness is restored to whatever the
-- darkened STORM_BRIGHTNESS currently is (not the pre-storm value -- that
-- only comes back once the whole storm ends, see End_Storm) so a flash
-- reads as a brief spike against the storm's dim baseline rather than a
-- jump back to broad daylight.
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
-- Starts the temporary half of the event (wind/rain/lightning/darkened
-- sky) for every current and future-joining player, for `duration`
-- seconds, then reverts the atmosphere back to exactly how Lighting looked
-- before this ran. Never touches the water -- that's Rise_Water_Over_Time's
-- job, called separately (and left running after this ends).
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
-- [stated] "I now want to add a new event, the flood. This should be a map
-- wide event and even after the intial rise is down for the rest of the
-- match the water level should be higher than it was when the match
-- started... there should be a huge storm with lightning and raining, and
-- then the water level should smoothly rise to a certain point." Runs in
-- its own coroutine (see the module header comment) so calling this
-- doesn't block whatever triggered it for the ~100 seconds the full
-- sequence takes.
local function Run_Flood_Sequence()
	-- ArenaEventScheduler's own Run_Event has already sent the warnings
	-- and run the freeze/pan lead-in by the time trigger() (and therefore
	-- this) ever gets called -- see the module header comment -- so the
	-- storm starts immediately here with no warning or wait of its own.
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
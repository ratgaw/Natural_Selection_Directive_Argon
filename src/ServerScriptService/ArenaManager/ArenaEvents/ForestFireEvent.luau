local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local Terrain = workspace.Terrain

local PlayerCombat = require(ServerScriptService:WaitForChild("PlayerCombat"))
local PlayerStats = require(ServerScriptService:WaitForChild("PlayerStats"))

local ForestFireEvent = {}

-- Tags must match StartMatch's (trees: FOREST_FIRE.tag, plants/rocks:
-- LIVE_PLANT_TAG/LIVE_ROCK_TAG).
local LIVE_TREE_TAG = "LiveTree"

local LIVE_PLANT_TAG = "LivePlant"

local LIVE_ROCK_TAG = "LiveRock"

-- Spread: every SPREAD_TICK_INTERVAL, each burning tree may ignite unburnt trees
-- within SPREAD_RADIUS (SPREAD_IGNITE_CHANCE each, at most MAX_IGNITIONS_PER_TICK
-- per tick) so the fire creeps outward.
local SPREAD_RADIUS = 40
local SPREAD_TICK_INTERVAL = 1
local SPREAD_IGNITE_CHANCE = 0.75
local MAX_IGNITIONS_PER_TICK = 18

-- Spread, damage and falling trunks only run for this long after the event
-- starts. Burnt trees stay burnt for the rest of the match.
local ACTIVE_BURN_DURATION = 180 -- TESTING value, tune once tested

-- Periodic damage to players near a burning tree.
local FIRE_DAMAGE_RADIUS = 12
local FIRE_DAMAGE_PER_TICK = 4
local FIRE_DAMAGE_TICK_INTERVAL = 1

-- A tree must burn this long before it can fall, and only falls toward a
-- participant within FALL_TRIGGER_RADIUS.
local MIN_BURN_BEFORE_FALL = 6
local FALL_CHECK_INTERVAL = 2
local FALL_TRIGGER_RADIUS = 20
local FALL_CHANCE_PER_CHECK = 0.15
local FALL_DURATION = 1.1
local FALL_DAMAGE = 35
local FALL_DAMAGE_RADIUS = 10 -- around where the trunk actually lands

-- Flames use built-in Fire + PointLight (+ Smoke) on an invisible anchor part.
-- The PointLight is what actually lights the area at night.
local FIRE_COLOR = Color3.fromRGB(255, 142, 36)
local FIRE_SECONDARY_COLOR = Color3.fromRGB(255, 60, 0)
-- Fire.Size is roughly flame height in studs.
local FIRE_SIZE = 22
local FIRE_HEAT = 15
local FIRE_LIGHT_BRIGHTNESS = 3
local FIRE_LIGHT_RANGE = 28
local FIRE_EFFECT_NAME = "ForestFireFlame"
local FIRE_LIGHT_NAME = "ForestFireGlow"

-- Smoke rides on the same anchor as each fire, so it moves and is destroyed
-- with it. The visibility drop near fires is done client-side in
-- ForestFireVisibility (fog changes from the server would affect everyone).
local SMOKE_COLOR = Color3.fromRGB(70, 66, 62)
local SMOKE_OPACITY = 0.55
local SMOKE_RISE_VELOCITY = 5
local SMOKE_NAME = "ForestFireSmoke"
local SMOKE_SECOND_NAME = "ForestFireSecondSmoke"
local SMOKE_GROUND_NAME = "ForestFireGroundSmoke"
-- Smoke Size relative to its fire's Size.
local SMOKE_SIZE_MULTIPLIER = 1.6

-- Tag on every currently burning fire anchor; ForestFireVisibility finds active
-- fires with it. The tag disappears when the anchor is destroyed.
local FIRE_SOURCE_TAG = "ForestFireActiveSource"

-- Chance of a second, smaller fire placed further along the trunk.
local TREE_SECOND_FIRE_CHANCE = 0.5
local TREE_SECOND_FIRE_MIN_SIZE = 8
local TREE_SECOND_FIRE_MAX_SIZE = 16
-- How far below the raycast's first hit on the tree the second fire can sit.
local TREE_SECOND_FIRE_MIN_DROP = 0
local TREE_SECOND_FIRE_MAX_DROP = 18
local SECOND_FIRE_ANCHOR_NAME = "ForestFireSecondAnchor"
local SECOND_FIRE_EFFECT_NAME = "ForestFireSecondFlame"
local SECOND_FIRE_LIGHT_NAME = "ForestFireSecondGlow"
local SECOND_FIRE_LIGHT_BRIGHTNESS = 1.5
local SECOND_FIRE_LIGHT_RANGE = 16

-- Tag for ground fires on scorched terrain, so the end-of-event cleanup can
-- find them all.
local GROUND_FIRE_TAG = "ForestFireGroundFire"
local GROUND_FIRE_SPAWN_CHANCE = 0.4
local GROUND_FIRE_MIN_SIZE = 6
local GROUND_FIRE_MAX_SIZE = 16
local GROUND_FIRE_LIGHT_BRIGHTNESS = 2
local GROUND_FIRE_LIGHT_RANGE = 20

-- Each fire's random lifetime (seconds). Decorative fires use
-- Schedule_Fire_Extinguish; the base tree fire is timed by Ignite/Extinguish_Tree
-- because it also ends that tree's damage and spread. Short lifetimes keep the
-- number of live PointLights down.
local FIRE_EXTINGUISH_MIN_TIME = 90
local FIRE_EXTINGUISH_MAX_TIME = 120

-- Both cadences as multiples of the damage tick, so one loop drives everything.
local SPREAD_TICK_TICKS = SPREAD_TICK_INTERVAL / FIRE_DAMAGE_TICK_INTERVAL
local FALL_CHECK_TICKS = FALL_CHECK_INTERVAL / FIRE_DAMAGE_TICK_INTERVAL

-- Fire and falling-trunk damage are reduced by Endurance, like fall damage.
local ENDURANCE_DAMAGE_REDUCTION_PER_POINT = 0.05
local MAX_DAMAGE_REDUCTION = 0.6
local function Apply_Environmental_Damage(player, humanoid, base_damage)
	local endurance = PlayerStats.get(player, "Endurance")
	local reduction = math.min(math.max(endurance - 1, 0) * ENDURANCE_DAMAGE_REDUCTION_PER_POINT, MAX_DAMAGE_REDUCTION)
	humanoid:TakeDamage(base_damage * (1 - reduction))
end

local function Flat_Distance(a, b)
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

-- Walks up from a hit part to the ancestor that carries the tag (tree parts can
-- be nested groups).
local function Find_Tagged_Ancestor(instance, tag)
	local current = instance
	while current and current ~= workspace do
		if CollectionService:HasTag(current, tag) then
			return current
		end
		current = current.Parent
	end
	return nil
end

-- Destroys a decorative fire anchor after a random lifetime.
local function Schedule_Fire_Extinguish(anchor)
	local lifetime = math.random(FIRE_EXTINGUISH_MIN_TIME, FIRE_EXTINGUISH_MAX_TIME)
	task.delay(lifetime, function()
		if anchor.Parent then
			anchor:Destroy()
		end
	end)
end

-- Strips leaves and blackens the trunk.
local CHAR_COLOR = Color3.fromRGB(18, 16, 15)

-- Recolors every part under root. A SurfaceAppearance makes a MeshPart ignore
-- .Color, so it's removed first; Decals/Textures get tinted too.
local function Char_Parts(root, color)
	local surface_appearances_removed = 0
	local base_parts_colored = 0
	local decals_tinted = 0
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("SurfaceAppearance") then
			descendant:Destroy()
			surface_appearances_removed += 1
		elseif descendant:IsA("BasePart") then
			descendant.Color = color
			base_parts_colored += 1
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Color3 = color
			decals_tinted += 1
		end
	end
	if root:IsA("BasePart") then
		root.Color = color
		base_parts_colored += 1
	end
	return surface_appearances_removed, base_parts_colored, decals_tinted
end

local function Char_Tree(tree_model)
	local leaves = tree_model:FindFirstChild("Leaves")
	if leaves then
		leaves:Destroy()
	else
		warn("[ForestFireEvent] Char_Tree: no 'Leaves' child found on " .. tree_model:GetFullName() .. " -- nothing to delete, tree won't visibly lose its leaves")
	end
	local trunk = tree_model:FindFirstChild("Trunk")
	if trunk then
		Char_Parts(trunk, CHAR_COLOR)
	else
		warn("[ForestFireEvent] Char_Tree: no 'Trunk' child found on " .. tree_model:GetFullName() .. " -- nothing to blacken, tree won't visibly char")
	end
end

-- Tree pivots aren't consistent across tree packs, so find the base with a
-- terrain-only raycast from high above the tree's X/Z.
local GROUND_RAYCAST_START_HEIGHT = 300 -- studs -- comfortably above anything this map's terrain generates
local GROUND_RAYCAST_DISTANCE = 600
local terrain_raycast_params = RaycastParams.new()
terrain_raycast_params.FilterType = Enum.RaycastFilterType.Include
terrain_raycast_params.FilterDescendantsInstances = {Terrain}

local function Compute_Base_Position(tree_model)
	local pivot_position = tree_model:GetPivot().Position
	local origin = Vector3.new(pivot_position.X, GROUND_RAYCAST_START_HEIGHT, pivot_position.Z)
	local result = workspace:Raycast(origin, Vector3.new(0, -GROUND_RAYCAST_DISTANCE, 0), terrain_raycast_params)
	if result then
		return result.Position
	end
	warn("[ForestFireEvent] Compute_Base_Position: ground raycast MISSED above " .. tree_model:GetFullName() .. " at X=" .. tostring(pivot_position.X) .. " Z=" .. tostring(pivot_position.Z) .. " -- falling back to the model's own pivot position, which may be unreliable for this tree type")
	return pivot_position
end

local FIRE_ANCHOR_NAME = "ForestFireAnchor"

-- Scorch footprint half-size. The scorch reads the voxels in the footprint and
-- only recolors cells that are already solid, so it follows slopes without
-- adding or removing terrain. Wide enough that neighboring trees' scorch areas
-- join up.
local SCORCH_RADIUS = 18 -- half-width/depth of the footprint, studs
local SCORCH_VERTICAL_MARGIN = 16 -- studs above/below the hit; generous so slopes fit inside
local VOXEL_RESOLUTION = 4 -- legacy Terrain's fixed voxel size -- ReadVoxels/WriteVoxels require exactly this

local SCORCH_MATERIAL = Enum.Material.Slate

-- Destroys tagged plants overlapping the scorched box.
local function Remove_Plants_In_Region(center, size)
	local overlap_params = OverlapParams.new()
	overlap_params.FilterType = Enum.RaycastFilterType.Exclude
	overlap_params.FilterDescendantsInstances = {}
	local removed_plants = {}
	local removed_count = 0
	for _, part in ipairs(workspace:GetPartBoundsInBox(CFrame.new(center), size, overlap_params)) do
		local plant = Find_Tagged_Ancestor(part, LIVE_PLANT_TAG)
		if plant and not removed_plants[plant] then
			removed_plants[plant] = true
			removed_count += 1
			plant:Destroy()
		end
	end
	return removed_count
end

-- Scorched rocks get a random gray-to-black shade (floor raised to avoid
-- near-black).
local ROCK_CHAR_MIN_BRIGHTNESS = 45 -- darkest allowed shade
local ROCK_CHAR_MAX_BRIGHTNESS = 70 -- lighter gray ceiling, unchanged
local function Random_Rock_Char_Color()
	local brightness = math.random(ROCK_CHAR_MIN_BRIGHTNESS, ROCK_CHAR_MAX_BRIGHTNESS)
	return Color3.fromRGB(brightness, brightness, brightness)
end

local function Char_Rock(rock_model)
	local color = Random_Rock_Char_Color()
	Char_Parts(rock_model, color)
end

-- Chars tagged rocks in the box; the "Scorched" attribute keeps overlapping
-- scorch areas from recoloring a rock twice.
local function Char_Rocks_In_Region(center, size)
	local overlap_params = OverlapParams.new()
	overlap_params.FilterType = Enum.RaycastFilterType.Exclude
	overlap_params.FilterDescendantsInstances = {}
	local charred_count = 0
	local seen_rocks = {}
	for _, part in ipairs(workspace:GetPartBoundsInBox(CFrame.new(center), size, overlap_params)) do
		local rock = Find_Tagged_Ancestor(part, LIVE_ROCK_TAG)
		if rock and not seen_rocks[rock] then
			seen_rocks[rock] = true
			if not rock:GetAttribute("Scorched") then
				rock:SetAttribute("Scorched", true)
				Char_Rock(rock)
				charred_count += 1
			end
		end
	end
	return charred_count
end

-- Random point inside the scorch footprint, with its own ground raycast
-- (slopes vary across the footprint).
local function Add_Random_Ground_Fire(ground_position)
	if math.random() > GROUND_FIRE_SPAWN_CHANCE then
		return
	end
	local offset_x = math.random(-SCORCH_RADIUS, SCORCH_RADIUS)
	local offset_z = math.random(-SCORCH_RADIUS, SCORCH_RADIUS)
	local probe_origin = Vector3.new(ground_position.X + offset_x, GROUND_RAYCAST_START_HEIGHT, ground_position.Z + offset_z)
	local result = workspace:Raycast(probe_origin, Vector3.new(0, -GROUND_RAYCAST_DISTANCE, 0), terrain_raycast_params)
	local spawn_position = result and result.Position or ground_position
	if not result then
		warn("[ForestFireEvent] Add_Random_Ground_Fire: ground raycast MISSED near " .. tostring(ground_position) .. " -- falling back to the scorch mark's own center position")
	end
	local anchor = Instance.new("Part")
	anchor.Name = "ForestFireGroundAnchor"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Anchored = true
	anchor.CFrame = CFrame.new(spawn_position)
	anchor.Parent = workspace
	CollectionService:AddTag(anchor, GROUND_FIRE_TAG)
	CollectionService:AddTag(anchor, FIRE_SOURCE_TAG)
	local fire_size = math.random(GROUND_FIRE_MIN_SIZE, GROUND_FIRE_MAX_SIZE)
	local fire = Instance.new("Fire")
	fire.Name = FIRE_EFFECT_NAME
	fire.Color = FIRE_COLOR
	fire.SecondaryColor = FIRE_SECONDARY_COLOR
	fire.Size = fire_size
	fire.Heat = FIRE_HEAT
	fire.Parent = anchor
	local light = Instance.new("PointLight")
	light.Name = FIRE_LIGHT_NAME
	light.Color = FIRE_COLOR
	light.Brightness = GROUND_FIRE_LIGHT_BRIGHTNESS
	light.Range = GROUND_FIRE_LIGHT_RANGE
	light.Parent = anchor
	local smoke = Instance.new("Smoke")
	smoke.Name = SMOKE_GROUND_NAME
	smoke.Color = SMOKE_COLOR
	smoke.Opacity = SMOKE_OPACITY
	smoke.RiseVelocity = SMOKE_RISE_VELOCITY
	smoke.Size = fire_size * SMOKE_SIZE_MULTIPLIER
	smoke.Parent = anchor
	Schedule_Fire_Extinguish(anchor)
end

-- ground_position is already a verified ground hit (Compute_Base_Position).
local function Add_Scorch_Mark(tree_model, ground_position)
	local region = Region3.new(
		Vector3.new(ground_position.X - SCORCH_RADIUS, ground_position.Y - SCORCH_VERTICAL_MARGIN, ground_position.Z - SCORCH_RADIUS),
		Vector3.new(ground_position.X + SCORCH_RADIUS, ground_position.Y + SCORCH_VERTICAL_MARGIN, ground_position.Z + SCORCH_RADIUS)
	):ExpandToGrid(VOXEL_RESOLUTION)
	local materials, occupancies = Terrain:ReadVoxels(region, VOXEL_RESOLUTION)
	for x = 1, materials.Size.X do
		for y = 1, materials.Size.Y do
			for z = 1, materials.Size.Z do
				if occupancies[x][y][z] > 0 then
					materials[x][y][z] = SCORCH_MATERIAL
				end
			end
		end
	end
	Terrain:WriteVoxels(region, VOXEL_RESOLUTION, materials, occupancies)
	local region_size = Vector3.new(SCORCH_RADIUS * 2, SCORCH_VERTICAL_MARGIN * 2, SCORCH_RADIUS * 2)
	Remove_Plants_In_Region(ground_position, region_size)
	Char_Rocks_In_Region(ground_position, region_size)
	Add_Random_Ground_Fire(ground_position)
end

-- Second fire: raycast down onto the tree's own geometry, then drop a random
-- distance. Its anchor is parented into the tree so it moves when the tree falls.
local function Add_Second_Fire_Effect(tree_model)
	if math.random() > TREE_SECOND_FIRE_CHANCE then
		return
	end
	local pivot_position = tree_model:GetPivot().Position
	local tree_only_params = RaycastParams.new()
	tree_only_params.FilterType = Enum.RaycastFilterType.Include
	tree_only_params.FilterDescendantsInstances = {tree_model}
	local origin = Vector3.new(pivot_position.X, GROUND_RAYCAST_START_HEIGHT, pivot_position.Z)
	local result = workspace:Raycast(origin, Vector3.new(0, -GROUND_RAYCAST_DISTANCE, 0), tree_only_params)
	if not result then
		warn("[ForestFireEvent] Add_Second_Fire_Effect: raycast never hit " .. tree_model:GetFullName() .. "'s own geometry from above -- skipping the second fire for this tree")
		return
	end
	local drop = math.random(TREE_SECOND_FIRE_MIN_DROP, TREE_SECOND_FIRE_MAX_DROP)
	local fire_position = result.Position - Vector3.new(0, drop, 0)
	local anchor = Instance.new("Part")
	anchor.Name = SECOND_FIRE_ANCHOR_NAME
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Anchored = true
	anchor.CFrame = CFrame.new(fire_position)
	anchor.Parent = tree_model
	CollectionService:AddTag(anchor, FIRE_SOURCE_TAG)
	local fire_size = math.random(TREE_SECOND_FIRE_MIN_SIZE, TREE_SECOND_FIRE_MAX_SIZE)
	local fire = Instance.new("Fire")
	fire.Name = SECOND_FIRE_EFFECT_NAME
	fire.Color = FIRE_COLOR
	fire.SecondaryColor = FIRE_SECONDARY_COLOR
	fire.Size = fire_size
	fire.Heat = FIRE_HEAT
	fire.Parent = anchor
	local light = Instance.new("PointLight")
	light.Name = SECOND_FIRE_LIGHT_NAME
	light.Color = FIRE_COLOR
	light.Brightness = SECOND_FIRE_LIGHT_BRIGHTNESS
	light.Range = SECOND_FIRE_LIGHT_RANGE
	light.Parent = anchor
	local smoke = Instance.new("Smoke")
	smoke.Name = SMOKE_SECOND_NAME
	smoke.Color = SMOKE_COLOR
	smoke.Opacity = SMOKE_OPACITY
	smoke.RiseVelocity = SMOKE_RISE_VELOCITY
	smoke.Size = fire_size * SMOKE_SIZE_MULTIPLIER
	smoke.Parent = anchor
	Schedule_Fire_Extinguish(anchor)
end

local function Add_Fire_Effect(tree_model)
	local base_position = Compute_Base_Position(tree_model)
	local anchor = Instance.new("Part")
	anchor.Name = FIRE_ANCHOR_NAME
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Anchored = true
	anchor.CFrame = CFrame.new(base_position)
	anchor.Parent = tree_model
	CollectionService:AddTag(anchor, FIRE_SOURCE_TAG)
	local fire = Instance.new("Fire")
	fire.Name = FIRE_EFFECT_NAME
	fire.Color = FIRE_COLOR
	fire.SecondaryColor = FIRE_SECONDARY_COLOR
	fire.Size = FIRE_SIZE
	fire.Heat = FIRE_HEAT
	fire.Parent = anchor
	local light = Instance.new("PointLight")
	light.Name = FIRE_LIGHT_NAME
	light.Color = FIRE_COLOR
	light.Brightness = FIRE_LIGHT_BRIGHTNESS
	light.Range = FIRE_LIGHT_RANGE
	light.Parent = anchor
	local smoke = Instance.new("Smoke")
	smoke.Name = SMOKE_NAME
	smoke.Color = SMOKE_COLOR
	smoke.Opacity = SMOKE_OPACITY
	smoke.RiseVelocity = SMOKE_RISE_VELOCITY
	smoke.Size = FIRE_SIZE * SMOKE_SIZE_MULTIPLIER
	smoke.Parent = anchor
	-- The base fire's timer is set in Ignite instead, since it ends the tree's
	-- burning state too.
	Add_Scorch_Mark(tree_model, base_position)
	Add_Second_Fire_Effect(tree_model)
end

-- Removes a tree's fire anchors (flames, light, smoke, tag). Charring and the
-- scorched ground stay.
local function Remove_Fire_Effect(tree_model)
	local anchor = tree_model:FindFirstChild(FIRE_ANCHOR_NAME)
	if anchor then
		anchor:Destroy()
	end
	-- Not every tree has a second fire.
	local second_anchor = tree_model:FindFirstChild(SECOND_FIRE_ANCHOR_NAME)
	if second_anchor then
		second_anchor:Destroy()
	end
end

-- Live, unburnt trees within SPREAD_RADIUS of position.
local function Find_Nearby_Unburnt_Trees(position)
	local overlap_params = OverlapParams.new()
	overlap_params.FilterType = Enum.RaycastFilterType.Exclude
	overlap_params.FilterDescendantsInstances = {}
	local candidates = {}
	local seen = {}
	for _, part in ipairs(workspace:GetPartBoundsInRadius(position, SPREAD_RADIUS, overlap_params)) do
		local tree_model = Find_Tagged_Ancestor(part, LIVE_TREE_TAG)
		if tree_model and not seen[tree_model] then
			seen[tree_model] = true
			if not tree_model:GetAttribute("OnFire") and not tree_model:GetAttribute("Burnt") then
				table.insert(candidates, tree_model)
			end
		end
	end
	return candidates
end

-- Tips the tree ~85 degrees toward fall_direction around the model's pivot.
-- If trees seem to rotate around their middle, check the pivot in Studio.
local function Compute_Fallen_Cframe(current_cframe, fall_direction)
	local local_fall_direction = current_cframe:VectorToObjectSpace(fall_direction)
	local tilt_x = math.rad(85) * local_fall_direction.Z
	local tilt_z = -math.rad(85) * local_fall_direction.X
	return current_cframe * CFrame.Angles(tilt_x, 0, tilt_z)
end

-- Tweens the tree over via a CFrameValue; checks damage where the trunk lands.
local function Fall_Tree_Toward(tree_model, fall_direction, game_data)
	local current_cframe = tree_model:GetPivot()
	local fallen_cframe = Compute_Fallen_Cframe(current_cframe, fall_direction)
	local cframe_value = Instance.new("CFrameValue")
	cframe_value.Value = current_cframe
	cframe_value.Changed:Connect(function(new_cframe)
		tree_model:PivotTo(new_cframe)
	end)
	local tween = TweenService:Create(
		cframe_value,
		TweenInfo.new(FALL_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{Value = fallen_cframe}
	)
	tween.Completed:Connect(function()
		cframe_value:Destroy()
		local landed_position = tree_model:GetPivot().Position
		for player in pairs(game_data.participants) do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChild("Humanoid")
			if root and humanoid and humanoid.Health > 0 and not PlayerCombat.is_invulnerable(player) then
				if Flat_Distance(root.Position, landed_position) <= FALL_DAMAGE_RADIUS then
					Apply_Environmental_Damage(player, humanoid, FALL_DAMAGE)
				end
			end
		end
	end)
	tween:Play()
end

-- Only falls when a participant is nearby.
local function Try_Fall_Tree(tree_model, game_data)
	if not tree_model.Parent or tree_model:GetAttribute("Falling") then
		return
	end
	local tree_position = tree_model:GetPivot().Position
	local nearby_player = nil
	for player in pairs(game_data.participants) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and Flat_Distance(root.Position, tree_position) <= FALL_TRIGGER_RADIUS then
			nearby_player = player
			break
		end
	end
	if not nearby_player or math.random() > FALL_CHANCE_PER_CHECK then
		return
	end
	tree_model:SetAttribute("Falling", true)
	local root = nearby_player.Character.HumanoidRootPart
	local to_player = root.Position - tree_position
	local flat_direction = Vector3.new(to_player.X, 0, to_player.Z)
	local fall_direction = flat_direction.Magnitude > 0.1 and flat_direction.Unit or Vector3.new(1, 0, 0)
	Fall_Tree_Toward(tree_model, fall_direction, game_data)
end

-- Ignites every origin tree picked by StartMatch, then runs spread, damage and
-- falling trunks off the shared burning_trees set.
function ForestFireEvent.trigger(game_data)
	local origin_trees = game_data.forest_fire_origin_trees
	if not origin_trees or #origin_trees == 0 then
		warn("[ForestFireEvent] no forest_fire_origin_trees on game_data -- StartMatch never picked any trees to start the fire from this match, skipping")
		return
	end

	local burning_trees = {} -- tree_model = true, while OnFire this match

	-- Ends one tree's burn when its timer fires: removing it from burning_trees
	-- stops its damage, spread and falling. Skips trees already burnt.
	local function Extinguish_Tree(tree_model)
		if not tree_model:GetAttribute("OnFire") then
			return
		end
		tree_model:SetAttribute("OnFire", false)
		tree_model:SetAttribute("Burnt", true)
		Remove_Fire_Effect(tree_model)
		burning_trees[tree_model] = nil
	end

	local function Ignite(tree_model)
		if not tree_model.Parent then
			warn("[ForestFireEvent] Ignite: tree_model has no Parent (already destroyed/unparented), skipping ignition")
			return
		end
		tree_model:SetAttribute("OnFire", true)
		tree_model:SetAttribute("OnFireSince", os.clock())
		Char_Tree(tree_model)
		Add_Fire_Effect(tree_model)
		burning_trees[tree_model] = true
		local burn_time = math.random(FIRE_EXTINGUISH_MIN_TIME, FIRE_EXTINGUISH_MAX_TIME)
		task.delay(burn_time, Extinguish_Tree, tree_model)
	end

	for i, origin_tree in ipairs(origin_trees) do
		if origin_tree and origin_tree.Parent then
			Ignite(origin_tree)
		else
			warn(("[ForestFireEvent] origin tree #%d invalid at trigger time (nil or no Parent)"):format(i))
		end
	end
	if not next(burning_trees) then
		warn("[ForestFireEvent] none of this match's forest_fire_origin_trees were still valid at trigger time, skipping")
		return
	end

	local function Spread_Tick()
		local newly_ignited = {}
		local seen_this_tick = {}
		local ignited_this_tick = 0
		for tree_model in pairs(burning_trees) do
			if ignited_this_tick >= MAX_IGNITIONS_PER_TICK then
				continue
			end
			local position = tree_model:GetPivot().Position
			local nearby = Find_Nearby_Unburnt_Trees(position)
			for _, candidate in ipairs(nearby) do
				if ignited_this_tick >= MAX_IGNITIONS_PER_TICK then
					break
				end
				if not seen_this_tick[candidate] and math.random() < SPREAD_IGNITE_CHANCE then
					seen_this_tick[candidate] = true
					table.insert(newly_ignited, candidate)
					ignited_this_tick += 1
				end
			end
		end
		-- Apply after the scan: adding keys during pairs() iteration is undefined.
		for _, tree_model in ipairs(newly_ignited) do
			Ignite(tree_model)
		end
	end

	local function Damage_Tick()
		for player in pairs(game_data.participants) do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChild("Humanoid")
			if root and humanoid and humanoid.Health > 0 and not PlayerCombat.is_invulnerable(player) then
				for tree_model in pairs(burning_trees) do
					if tree_model.Parent and Flat_Distance(root.Position, tree_model:GetPivot().Position) <= FIRE_DAMAGE_RADIUS then
						Apply_Environmental_Damage(player, humanoid, FIRE_DAMAGE_PER_TICK)
						break -- one tick of damage per player regardless of how many nearby trees are burning
					end
				end
			end
		end
	end

	local function Fall_Check()
		for tree_model in pairs(burning_trees) do
			local burning_since = tree_model:GetAttribute("OnFireSince") or os.clock()
			if os.clock() - burning_since >= MIN_BURN_BEFORE_FALL then
				Try_Fall_Tree(tree_model, game_data)
			end
		end
	end

	task.spawn(function()
		local burn_until = os.clock() + ACTIVE_BURN_DURATION
		local tick_count = 0
		while os.clock() < burn_until and game_data.state == "matchinprogress" do
			tick_count += 1
			Damage_Tick()
			if tick_count % SPREAD_TICK_TICKS == 0 then
				Spread_Tick()
			end
			if tick_count % FALL_CHECK_TICKS == 0 then
				Fall_Check()
			end
			task.wait(FIRE_DAMAGE_TICK_INTERVAL)
		end
		-- Window over: mark any still-burning trees Burnt and remove their flames.
		for tree_model in pairs(burning_trees) do
			if tree_model.Parent then
				tree_model:SetAttribute("OnFire", false)
				tree_model:SetAttribute("Burnt", true)
				Remove_Fire_Effect(tree_model)
			end
		end
		-- Ground fires aren't in burning_trees; find them by tag.
		for _, ground_fire_anchor in ipairs(CollectionService:GetTagged(GROUND_FIRE_TAG)) do
			ground_fire_anchor:Destroy()
		end
	end)
end

return ForestFireEvent
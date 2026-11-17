local StartMatch = {}
local replicated_storage =  game:GetService("ReplicatedStorage")
local server_storage = game:GetService("ServerStorage")
local server_script_service = game:GetService("ServerScriptService")
local lighting = game:GetService("Lighting")
local players = game:GetService("Players")
local collection_service = game:GetService("CollectionService")
-- Tags ForestFireEvent uses to find plants/rocks (keep its constants in sync).
-- Declared at file scope because Generate() is at Luau's 200-local limit.
local LIVE_PLANT_TAG = "LivePlant"
local LIVE_ROCK_TAG = "LiveRock"
local arena_manager = script.Parent
local nature_folder = server_storage:WaitForChild("Nature")
local crate_loot = require(arena_manager:WaitForChild("CrateLoot"))
local minimap_data = require(arena_manager:WaitForChild("MinimapData"))
local settlement_data = require(arena_manager:WaitForChild("SettlementData"))
local wildlife = require(arena_manager:WaitForChild("WildLifeManager"))
local day_night_weather = require(arena_manager:WaitForChild("DayNightWeather"))
local dropped_items = require(server_script_service:WaitForChild("DroppedItems"))
local player_inventory = require(server_script_service:WaitForChild("PlayerInventory"))
local player_weight = require(server_script_service:WaitForChild("PlayerWeight"))
local floor_loot_data = require(arena_manager:WaitForChild("FloorLootData"))
local match_ui_event = replicated_storage:WaitForChild("MatchUIEvent")
local match_start = replicated_storage:WaitForChild("MatchStarted")
local inventory_updated = replicated_storage:WaitForChild("InventoryUpdated")
function StartMatch.Generate(game_data)
	-- Grouped into one table to save locals (Generate() is at the 200-local limit).
	local NATURE_MODELS = {
		tree_alpine = nature_folder:WaitForChild("Trees"):WaitForChild("AlpineTree"),
		tree_birch = nature_folder:WaitForChild("Trees"):WaitForChild("Birch Tree"),
		tree_pine = nature_folder:WaitForChild("Trees"):WaitForChild("Pine Tree"),
		bush_live = nature_folder:WaitForChild("Plants"):WaitForChild("Live Bush"),
		bush_dead = nature_folder:WaitForChild("Plants"):WaitForChild("Dead"):WaitForChild("Dead Bush2"),
		plant_flowers = nature_folder:WaitForChild("Plants"):WaitForChild("Flowers"),
		plant_fern1 = nature_folder:WaitForChild("Plants"):WaitForChild("ForestFern"),
		plant_fern2 = nature_folder:WaitForChild("Plants"):WaitForChild("Fern 2"),
		water_plant_cattails = nature_folder:WaitForChild("Plants"):WaitForChild("Cat tails"),
		water_plant_grass = nature_folder:WaitForChild("Plants"):WaitForChild("Grass"),
		mulchfood_log = nature_folder:WaitForChild("Plants"):WaitForChild("Dead"):WaitForChild("Mossy Log"),
		mulchfood_stump1 = nature_folder:WaitForChild("Plants"):WaitForChild("Dead"):WaitForChild("Mossy Stump 1"),
		mulchfood_stump2 = nature_folder:WaitForChild("Plants"):WaitForChild("Dead"):WaitForChild("Mossy Stump 2"),
		rock_big_boulder = nature_folder:WaitForChild("Rocks"):WaitForChild("Big Boulder"),
		rock_big_boulder_pile = nature_folder:WaitForChild("Rocks"):WaitForChild("Big Boulder Pile"),
		rock_mossy_boulder = nature_folder:WaitForChild("Rocks"):WaitForChild("Mossy Boulder"),
		rock_small_pile = nature_folder:WaitForChild("Rocks"):WaitForChild("Small Rock Pile"),
		rock_dark = nature_folder:WaitForChild("Rocks"):WaitForChild("Dark Big Boulder"),
	}
	local tree_list = {NATURE_MODELS.tree_alpine, NATURE_MODELS.tree_birch, NATURE_MODELS.tree_pine}
	local TREE_BASE_SCALE = {
		[NATURE_MODELS.tree_alpine] = 1.3,
		[NATURE_MODELS.tree_birch] = 3.2,
		[NATURE_MODELS.tree_pine] = 3.2,
	}
	local bush_list = {NATURE_MODELS.bush_live, NATURE_MODELS.bush_dead}
	local flower_list = {NATURE_MODELS.plant_flowers}
	local fern_list = {NATURE_MODELS.plant_fern1, NATURE_MODELS.plant_fern2}
	local water_plant_list = {NATURE_MODELS.water_plant_cattails, NATURE_MODELS.water_plant_grass}
	local mulchfood_list = {NATURE_MODELS.mulchfood_log, NATURE_MODELS.mulchfood_stump1, NATURE_MODELS.mulchfood_stump2}
	local rock_list = {NATURE_MODELS.rock_big_boulder, NATURE_MODELS.rock_big_boulder_pile, NATURE_MODELS.rock_small_pile}
	local mossy_boulder_list = {NATURE_MODELS.rock_mossy_boulder}
	local crate_list = server_storage:WaitForChild("CrateList")
	local crate = crate_list:WaitForChild("LootCrate")
	local buildings_folder = server_storage:WaitForChild("Buildings")
	local apartment_2f = buildings_folder:WaitForChild("2 Floor Apartment")
	local apartment_4f = buildings_folder:WaitForChild("4 Floor Apartment")
	local unfinished_structure = buildings_folder:WaitForChild("Unfinished Structure")
	local abandoned_shop = buildings_folder:WaitForChild("Abandoned Shop")
	-- Unfinished structures don't line roads.
	local road_building_list = {apartment_2f, apartment_4f, abandoned_shop}
	local brickwork_house = buildings_folder:WaitForChild("Brickwork House")
	local deroofed_house = buildings_folder:WaitForChild("De-Roofed House")
	local mattress_house = buildings_folder:WaitForChild("Mattress House")
	local scatter_house_list = {brickwork_house, deroofed_house, mattress_house}
	local warehouse_template = buildings_folder:WaitForChild("Warehouse")
	local warehouse_list = {warehouse_template}
	-- Fallback decor; kept out of the road and fill lists.
	local large_garbage_bin = buildings_folder:WaitForChild("Large Garbage Bin")
	local garbage_bin_list = {large_garbage_bin}
	-- Every model in this folder is in rotation automatically.
	local rubble_folder = buildings_folder:WaitForChild("Rubble/Garbage")
	local rubble_list = rubble_folder:GetChildren()
	-- Villages use the rubble list minus Rubble1/Rubble2.
	local village_rubble_list = {}
	for _, model in ipairs(rubble_list) do
		if model.Name ~= "Rubble1" and model.Name ~= "Rubble2" then
			table.insert(village_rubble_list, model)
		end
	end
	-- Random props placed on PropSpawnArea markers in any building (see
	-- Populate_Building). Every model in the Props folder is in rotation.
	local PROP_SCATTER = {
		pool = buildings_folder:WaitForChild("Props"):GetChildren(),
		min = 10,
		max = 15,
	}
	local BUILDING_FACING_CORRECTION = {
		[apartment_4f] = math.rad(180),
		[warehouse_template] = math.rad(90),
	}
	local BUILDING_GROUND_CORRECTION = {
		[unfinished_structure] = -44,
		[apartment_2f] = -2,
		[apartment_4f] = 0,
		[brickwork_house] = 1.25,
		[deroofed_house] = 1.75,
		[mattress_house] = 1.5,
		[abandoned_shop] = 0
	}
	-- Uniform scale per model, applied before positioning. Unlisted models = 1.
	local MODEL_SCALE = {
		[apartment_2f] = 0.75,
		[apartment_4f] = 0.75,
	}
	-- Models use GetBoundingBox; bare parts (some rubble) use ExtentsCFrame/Size.
	local function Measure_Building(model)
		local bounds_cframe, size
		if model:IsA("Model") then
			bounds_cframe, size = model:GetBoundingBox()
		else
			bounds_cframe, size = model.ExtentsCFrame, model.ExtentsSize
		end
		local pivot = model:GetPivot()
		local bottom_y = bounds_cframe.Position.Y - size.Y / 2
		local pivot_to_bottom = pivot.Position.Y - bottom_y
		local length = math.max(size.X, size.Z)
		local depth = math.min(size.X, size.Z)
		-- The collision check assumes a building's long side is its local X. For models
		-- whose long side is Z, rotate the collision footprint (not the visual) 90 degrees.
		local footprint_offset = (size.Z > size.X) and math.rad(90) or 0
		return {pivot_to_bottom = pivot_to_bottom, length = length, depth = depth, footprint_offset = footprint_offset}
	end
	local BUILDING_METRICS = {}
	for _, model in ipairs(road_building_list) do BUILDING_METRICS[model] = Measure_Building(model) end
	for _, model in ipairs(scatter_house_list) do BUILDING_METRICS[model] = Measure_Building(model) end
	for _, model in ipairs(warehouse_list) do BUILDING_METRICS[model] = Measure_Building(model) end
	for _, model in ipairs(garbage_bin_list) do BUILDING_METRICS[model] = Measure_Building(model) end
	-- Measured separately: it isn't in any of the lists above.
	BUILDING_METRICS[unfinished_structure] = Measure_Building(unfinished_structure)
	local RUBBLE_METRICS = {}
	for _, model in ipairs(rubble_list) do RUBBLE_METRICS[model] = Measure_Building(model) end
	-- Yaw-only corrections, keyed by Name because rubble_list comes from GetChildren().
	local RUBBLE_FACING_CORRECTION_BY_NAME = {}
	-- Tilts a piece lying on its side. If it tips onto an edge instead, use the Z
	-- axis: CFrame.Angles(0, 0, math.rad(90)).
	local RUBBLE_TILT_CORRECTION_BY_NAME = {
		Trashpile2 = CFrame.Angles(math.rad(90), 0, 0),
	}
	local RUBBLE_GROUND_CORRECTION_BY_NAME = {
		Trashpile1 = 1,
		Trashpile2 = -1,
		Rubble2 = -7,
		Rubble1 = -0.5,
	}
	local RUBBLE_FACING_CORRECTION = {}
	local RUBBLE_TILT_CORRECTION = {}
	local RUBBLE_GROUND_CORRECTION = {}
	for _, model in ipairs(rubble_list) do
		if RUBBLE_FACING_CORRECTION_BY_NAME[model.Name] then
			RUBBLE_FACING_CORRECTION[model] = RUBBLE_FACING_CORRECTION_BY_NAME[model.Name]
		end
		if RUBBLE_TILT_CORRECTION_BY_NAME[model.Name] then
			RUBBLE_TILT_CORRECTION[model] = RUBBLE_TILT_CORRECTION_BY_NAME[model.Name]
		end
		if RUBBLE_GROUND_CORRECTION_BY_NAME[model.Name] then
			RUBBLE_GROUND_CORRECTION[model] = RUBBLE_GROUND_CORRECTION_BY_NAME[model.Name]
		end
	end
	local ground_sink_buffer = 1.5
	-- Resets Lighting each match. Placeholder values.
	-- Lighting.Technology can't be set from a script -- set it in Studio (ShadowMap).
	local function Configure_Lighting()
		lighting.GlobalShadows = true
		lighting.Ambient = Color3.fromRGB(90, 90, 90)
		lighting.OutdoorAmbient = Color3.fromRGB(120, 120, 120)
		lighting.ClockTime = 14
	end
	Configure_Lighting()
	day_night_weather.start()
	local terrain = workspace.Terrain
	terrain:Clear()
	local terrain_raycast_params = RaycastParams.new()
	terrain_raycast_params.FilterType = Enum.RaycastFilterType.Include
	terrain_raycast_params.FilterDescendantsInstances = {terrain}
	local size = 700
	local block_size = 6
	local map_radius = size / 2
	workspace:SetAttribute("MapRadius", map_radius * block_size)
	local wall_flats_start = map_radius * 0.85
	local wall_flats_height = 8
	local clear_wall_distance = 50
	local water_level = -18
	local forest_floor = {Enum.Material.Ground, Enum.Material.Mud, Enum.Material.LeafyGrass, Enum.Material.Grass}
	local water_floor = {Enum.Material.Mud, Enum.Material.Rock, Enum.Material.Sand}
	local mounty_floor = {Enum.Material.Rock, Enum.Material.Slate}
	local field_floor = {Enum.Material.Grass, Enum.Material.Grass, Enum.Material.Grass, Enum.Material.LeafyGrass}
	local settlement_floor = {Enum.Material.Ground, Enum.Material.Concrete, Enum.Material.Concrete, Enum.Material.Concrete,
		Enum.Material.Ground, Enum.Material.Mud, Enum.Material.Concrete}
	-- Villages: mostly dirt, some mud, a little concrete.
	local village_floor = {Enum.Material.Ground, Enum.Material.Ground, Enum.Material.Ground, Enum.Material.Ground,
		Enum.Material.Ground, Enum.Material.Mud, Enum.Material.Mud, Enum.Material.Concrete}
	local seed_x = math.random(-100000, 100000)
	local seed_z = math.random(-100000, 100000)
	local chunk_count = 0
	-- Forest fire origins: 3 distinct trees picked uniformly by reservoir sampling
	-- as trees spawn. tag must match ForestFireEvent's LIVE_TREE_TAG.
	local FOREST_FIRE = {trees_seen = 0, origin_trees = {}, origin_count = 3, tag = "LiveTree"}
	local placed_houses = {}
	local placed_building_footprints = {}
	local settlement_zones = {}
	local settlement_near_padding = 15
	-- How far past zone.flat_radius the terrain stays flat (studs), so buildings at
	-- the edge still sit on flat ground.
	local SETTLEMENT_FLAT_TERRAIN_PADDING = 60
	-- Clear gap required between settlement zones, added on top of each zone's
	-- radius so it works for both cities and villages.
	local SETTLEMENT_SEPARATION_BUFFER = 20
	local target_settlement_count = 2
	local settlement_attempts = 0
	local max_attempts = 100
	-- Small plains villages, max ~70 studs across. Sizes are in blocks (x block_size
	-- for studs).
	local VILLAGE_ZONE = {
		flat_radius_min = 15,
		flat_radius_max = 30,
		blend_min = 5,
		blend_max = 10,
		target_count = math.random(8, 12),
		attempts = 0,
		max_attempts = 300,
	}
	local min_crate_distance = 12
	local crate_spawn_chance = 0.35
	-- Short raycast for LootFloorArea scatter so items land on the marker's floor,
	-- not the roof or the floor below.
	local FLOOR_LOOT_RAY_CLEARANCE = 5
	local FLOOR_LOOT_RAY_DISTANCE = 20
	-- Rarity weights for building crates (keys must match CrateData). Supply-drop
	-- beacon crates are always Elite.
	local CRATE_RARITY_WEIGHTS = {
		{Rarity = "Standard", Weight = 70},
		{Rarity = "Advanced", Weight = 25},
		{Rarity = "Elite", Weight = 5},
	}
	local function Roll_Crate_Rarity()
		local total_weight = 0
		for _, entry in ipairs(CRATE_RARITY_WEIGHTS) do
			total_weight = total_weight + entry.Weight
		end
		local roll = math.random() * total_weight
		local cumulative = 0
		for _, entry in ipairs(CRATE_RARITY_WEIGHTS) do
			cumulative = cumulative + entry.Weight
			if roll <= cumulative then
				return entry.Rarity
			end
		end
		return CRATE_RARITY_WEIGHTS[#CRATE_RARITY_WEIGHTS].Rarity
	end
	local WILDLIFE_SPAWN_TABLE = {
		Bear    = {count = 10,  biomes = {Forest = true, Mountain = true}},
		Wolf    = {count = 15,  biomes = {Forest = true, Field = true, Mountain = true}},
		Deer    = {count = 25, biomes = {Forest = true, Field = true}},
		Rat     = {count = 30,  biomes = {Settlement = true}},
	}
	local wildlife_min_spacing = 30
	local wildlife_settlement_spacing = 10 -- rats need to fit between closely-packed settlement buildings
	local wildlife_max_attempts_per_animal = 40
	local lod_chunk_size = 2
	local lod_buffer_chunks = 1
	local lod_wall_buffer = 40
	local lod_mountain_threshold = 35
	local lod_water_buffer = 15
	local function Spawn_Ferns(center)
		local roll = math.random()
		local cluster_size
		if roll < 0.6 then
			cluster_size = math.random(4, 10)
		elseif roll < 0.9 then
			cluster_size = math.random(11, 20)
		else
			cluster_size = math.random(21, 35)
		end
		local cluster_radius = math.random(8, 24)
		for i = 1, cluster_size do
			local angle = math.random() * math.pi * 2
			local distance = math.random() * cluster_radius
			local offset = Vector3.new(
				math.cos(angle) * distance,
				0,
				math.sin(angle) * distance
			)
			local fern_choice = fern_list[math.random(#fern_list)]
			local grass = fern_choice:Clone()
			local scale = math.random(80, 130) / 100
			local rotation = math.rad(math.random(0, 360))
			grass:ScaleTo(scale)
			grass:PivotTo(
				CFrame.new(center + offset)
					* CFrame.Angles(0, rotation, 0)
			)
			grass.Parent = workspace
			collection_service:AddTag(grass, LIVE_PLANT_TAG)
		end
	end
	local function Get_Base_Ground_Offset(model)
		local _, size = model:GetBoundingBox()
		return size.Y / 2
	end
	local GROUND_OFFSET = {}
	for _, model in ipairs(flower_list) do GROUND_OFFSET[model] = Get_Base_Ground_Offset(model) end
	for _, model in ipairs(bush_list) do GROUND_OFFSET[model] = Get_Base_Ground_Offset(model) end
	for _, model in ipairs(water_plant_list) do GROUND_OFFSET[model] = Get_Base_Ground_Offset(model) end
	for _, model in ipairs(mulchfood_list) do GROUND_OFFSET[model] = Get_Base_Ground_Offset(model) end
	for _, model in ipairs(PROP_SCATTER.pool) do GROUND_OFFSET[model] = Get_Base_Ground_Offset(model) end
	local function Flat_Distance(a, b)
		return (Vector2.new(a.X, a.Z) - Vector2.new(b.X, b.Z)).Magnitude
	end
	local function Shuffle_List(list)
		for i = #list, 2, -1 do
			local j = math.random(i)
			list[i], list[j] = list[j], list[i]
		end
	end
	-- Counts a dictionary's entries (# only works on arrays).
	local function Count_Table(t)
		local count = 0
		for _ in pairs(t) do
			count += 1
		end
		return count
	end
	local function Too_Close(position, radius)
		for _, house_pos in ipairs(placed_houses) do
			if Flat_Distance(position, house_pos) < radius then
				return true
			end
		end
		return false
	end
	-- Oriented-rectangle (separating-axis) overlap test between footprints.
	-- COLLISION_BUFFER = 0 rejects only real overlaps; edge-to-edge is allowed.
	local COLLISION_BUFFER = 0
	-- exclude_index skips that footprint (used when re-checking an already
	-- recorded building).
	local function Building_Too_Close(position, half_length, half_depth, rotation, exclude_index)
		local a_len_x, a_len_z = math.cos(rotation), math.sin(rotation)
		local a_dep_x, a_dep_z = -a_len_z, a_len_x
		for i, entry in ipairs(placed_building_footprints) do
			if i ~= exclude_index then
				local buffer = COLLISION_BUFFER
				local dx = entry.position.X - position.X
				local dz = entry.position.Z - position.Z
				local b_len_x, b_len_z = math.cos(entry.rotation), math.sin(entry.rotation)
				local b_dep_x, b_dep_z = -b_len_z, b_len_x
				local function Axis_Clear(ax, az)
					local center_dist = math.abs(dx * ax + dz * az)
					local proj_a = math.abs(a_len_x * ax + a_len_z * az) * half_length + math.abs(a_dep_x * ax + a_dep_z * az) * half_depth
					local proj_b = math.abs(b_len_x * ax + b_len_z * az) * entry.half_length + math.abs(b_dep_x * ax + b_dep_z * az) * entry.half_depth
					return center_dist > proj_a + proj_b + buffer
				end
				-- Clear if any of the four axes separates the footprints.
				if not (Axis_Clear(a_len_x, a_len_z) or Axis_Clear(a_dep_x, a_dep_z) or Axis_Clear(b_len_x, b_len_z) or Axis_Clear(b_dep_x, b_dep_z)) then
					return true
				end
			end
		end
		return false
	end
	-- Returns the shared index and footprint so callers can move the building later.
	local function Record_Building(position, half_length, half_depth, rotation)
		table.insert(placed_houses, position)
		local entry = {
			position = position,
			half_length = half_length,
			half_depth = half_depth,
			rotation = rotation,
		}
		table.insert(placed_building_footprints, entry)
		return #placed_houses, entry
	end
	local function Anchor_Model(model)
		-- A bare part has no descendants, so anchor it directly.
		if model:IsA("BasePart") then
			model.Anchored = true
		end
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
			end
		end
	end
	-- Parts (or groups) named "ColorVariant" get one random shade shift per building,
	-- applied to each part's own color, so the building reads as one coherent tint.
	local COLOR_VARIANT_PART_NAME = "ColorVariant"
	-- Max shift per R/G/B channel (0-255). Placeholder.
	local COLOR_SHIFT_RANGE = 20
	-- Parts named "ColorVariant2" get one color from this palette per building.
	local COLOR_VARIANT2_PART_NAME = "ColorVariant2"
	local COLOR_VARIANT2_PALETTE = {
		Color3.fromRGB(235, 230, 215), -- soft off-white / cream
		Color3.fromRGB(215, 215, 215), -- pale concrete grey
		Color3.fromRGB(225, 210, 180), -- light sand / stucco
		Color3.fromRGB(205, 215, 220), -- pale blue-grey
		Color3.fromRGB(220, 200, 170), -- light tan
		Color3.fromRGB(212, 218, 198), -- pale sage
		Color3.fromRGB(230, 220, 210), -- light warm grey
		Color3.fromRGB(225, 198, 190), -- light dusty terracotta
	}
	local function Shift_Color(base_color, dr, dg, db)
		return Color3.fromRGB(
			math.clamp(base_color.R * 255 + dr, 0, 255),
			math.clamp(base_color.G * 255 + dg, 0, 255),
			math.clamp(base_color.B * 255 + db, 0, 255)
		)
	end
	-- Unions only show .Color when UsePartColor is true, so turn it on.
	local function Apply_Part_Color(part, color)
		if part:IsA("PartOperation") then
			part.UsePartColor = true
		end
		part.Color = color
	end
	local function Randomize_Building_Colors(model)
		local shift_r = math.random(-COLOR_SHIFT_RANGE, COLOR_SHIFT_RANGE)
		local shift_g = math.random(-COLOR_SHIFT_RANGE, COLOR_SHIFT_RANGE)
		local shift_b = math.random(-COLOR_SHIFT_RANGE, COLOR_SHIFT_RANGE)
		local variant2_color = COLOR_VARIANT2_PALETTE[math.random(#COLOR_VARIANT2_PALETTE)]
		-- Single parts shift from their own color.
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") and part.Name == COLOR_VARIANT_PART_NAME then
				Apply_Part_Color(part, Shift_Color(part.Color, shift_r, shift_g, shift_b))
			end
		end
		-- A Model named ColorVariant: every part in it gets the same final color,
		-- based on its first part, so the group reads as one repaint.
		for _, group in ipairs(model:GetDescendants()) do
			if group:IsA("Model") and group.Name == COLOR_VARIANT_PART_NAME then
				local anchor_color
				for _, part in ipairs(group:GetDescendants()) do
					if part:IsA("BasePart") then
						anchor_color = part.Color
						break
					end
				end
				if anchor_color then
					local final_color = Shift_Color(anchor_color, shift_r, shift_g, shift_b)
					for _, part in ipairs(group:GetDescendants()) do
						if part:IsA("BasePart") then
							Apply_Part_Color(part, final_color)
						end
					end
				end
			end
		end
		-- ColorVariant2: same part/group split, set to the building's palette color.
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") and part.Name == COLOR_VARIANT2_PART_NAME then
				Apply_Part_Color(part, variant2_color)
			end
		end
		for _, group in ipairs(model:GetDescendants()) do
			if group:IsA("Model") and group.Name == COLOR_VARIANT2_PART_NAME then
				for _, part in ipairs(group:GetDescendants()) do
					if part:IsA("BasePart") then
						Apply_Part_Color(part, variant2_color)
					end
				end
			end
		end
	end
	-- Crates go in their own folder, separate from buildings.
	local loot_crate_folder = Instance.new("Folder")
	loot_crate_folder.Name = "SpawnedLootCrates"
	loot_crate_folder.Parent = workspace
	-- Renamed from Spawn_Building_Loot now that it also handles the prop
	-- scatter below -- "loot" stopped covering what this does.
	local function Populate_Building(building)
		local spawned_pos = {}
		local spawned_count = 0
		-- Every placement raycast here shares one growing exclude list: all markers up
		-- front, then each crate/item/prop as it's placed, so nothing spawned earlier
		-- in the building can catch a later ray and leave items floating.
		local exclude_list = {}
		local exclude_params = RaycastParams.new()
		exclude_params.FilterType = Enum.RaycastFilterType.Exclude
		local function Refresh_Exclude()
			exclude_params.FilterDescendantsInstances = exclude_list
		end
		local function Exclude_From_Now_On(instance)
			table.insert(exclude_list, instance)
			Refresh_Exclude()
		end
		local markers = {}
		local floor_loot_markers = {}
		local prop_markers = {}
		for _, obj in ipairs(building:GetDescendants()) do
			if obj:IsA("BasePart") and (obj.Name == "CrateSpawn" or obj.Name == "LootFloorArea" or obj.Name == "PropSpawnArea") then
				-- Markers must not block the floor raycasts.
				obj.CanCollide = false
				obj.CanQuery = false
				obj.Transparency = 1
				table.insert(exclude_list, obj)
				if obj.Name == "CrateSpawn" then
					table.insert(markers, obj)
				elseif obj.Name == "LootFloorArea" then
					table.insert(floor_loot_markers, obj)
				else
					table.insert(prop_markers, obj)
				end
			end
		end
		Refresh_Exclude()
		Shuffle_List(markers)
		-- Crate counts per building Name. Unlisted buildings: no minimum, max 2.
		local BUILDING_CRATE_CONFIG = {
			["4 Floor Apartment"] = {Min = 2, Max = 5},
			["2 Floor Apartment"] = {Min = 1, Max = 3},
			["Abandoned Shop"] = {Min = 0, Max = 1},
			Warehouse = {Min = 0, Max = 4}, -- unchanged from the old special-case
			["Large Garbage Bin"] = {Min = 0, Max = 1},
			["De-Roofed House"] = {Min = 0, Max = 1},
			["Brickwork House"] = {Min = 0, Max = 1},
			["Unfinished Structure"] = {Min = 2, Max = 4},
		}
		local DEFAULT_CRATE_CONFIG = {Min = 0, Max = 2}
		local crate_config = BUILDING_CRATE_CONFIG[building.Name] or DEFAULT_CRATE_CONFIG
		local max_crates = crate_config.Max
		local min_crates = crate_config.Min
		local function Marker_Far_Enough(marker_pos)
			for _, existing_pos in ipairs(spawned_pos) do
				if Flat_Distance(marker_pos, existing_pos) < min_crate_distance then
					return false
				end
			end
			return true
		end
		-- Raycast down from the marker to the real floor and add the crate's ground
		-- offset, so crates sit on the floor.
		local function Spawn_Crate_At(marker)
			local crate_rotation = math.rad(math.random(0, 359))
			local crate_clone = crate:Clone()
			local ground_offset = Get_Base_Ground_Offset(crate_clone)
			local ray_origin = marker.Position + Vector3.new(0, FLOOR_LOOT_RAY_CLEARANCE, 0)
			local ground_result = workspace:Raycast(ray_origin, Vector3.new(0, -FLOOR_LOOT_RAY_DISTANCE, 0), exclude_params)
			local floor_y = ground_result and ground_result.Position.Y or marker.Position.Y
			local crate_position = Vector3.new(marker.Position.X, floor_y + ground_offset, marker.Position.Z)
			if not ground_result then
				warn(("[Crate] %s: raycast MISSED from %s (marker %s, marker world pos %s) -- falling back to marker height"):format(building.Name, tostring(ray_origin), marker:GetFullName(), tostring(marker.Position)))
			end
			crate_clone:PivotTo(CFrame.new(crate_position) * CFrame.Angles(0, crate_rotation, 0))
			crate_clone:SetAttribute("Rarity", Roll_Crate_Rarity())
			crate_clone.Parent = loot_crate_folder
			crate_loot.register_crate(crate_clone)
			Exclude_From_Now_On(crate_clone)
			table.insert(spawned_pos, marker.Position)
			spawned_count += 1
		end
		for _, marker in ipairs(markers) do
			if spawned_count >= max_crates then
				break
			end
			if Marker_Far_Enough(marker.Position) and math.random() < crate_spawn_chance then
				Spawn_Crate_At(marker)
			end
		end
		-- Top up to the building's minimum on remaining eligible markers.
		if spawned_count < min_crates then
			for _, marker in ipairs(markers) do
				if spawned_count >= min_crates then
					break
				end
				if Marker_Far_Enough(marker.Position) then
					Spawn_Crate_At(marker)
				end
			end
		end
		-- LootFloorArea: a flat BasePart marking a scatter area on a floor (any size or
		-- rotation). Short raycast so upper floors hit their own surface.
		if #floor_loot_markers > 0 then
			for _, marker in ipairs(floor_loot_markers) do
				local roll_count = math.random(floor_loot_data.RollCount.min, floor_loot_data.RollCount.max)
				for i = 1, roll_count do
					local half_x = marker.Size.X / 2
					local half_z = marker.Size.Z / 2
					local offset_x = (math.random() * 2 - 1) * half_x
					local offset_z = (math.random() * 2 - 1) * half_z
					local sample_position = (marker.CFrame * CFrame.new(offset_x, 0, offset_z)).Position
					local ray_origin = sample_position + Vector3.new(0, FLOOR_LOOT_RAY_CLEARANCE, 0)
					local result = workspace:Raycast(ray_origin, Vector3.new(0, -FLOOR_LOOT_RAY_DISTANCE, 0), exclude_params)
					if result then
						local item_name = crate_loot.weighted_pick(floor_loot_data.LootPool)
						local spawned_ok, item_part = dropped_items.spawn_ground_item_at(item_name, 1, result.Position)
						if spawned_ok and typeof(item_part) == "Instance" then
							Exclude_From_Now_On(item_part)
						end
					else
						warn(("[FloorLoot] %s: raycast MISSED from %s (marker %s, marker world pos %s)"):format(building.Name, tostring(ray_origin), marker:GetFullName(), tostring(marker.Position)))
					end
				end
			end
		end
		-- PropSpawnArea markers: same approach as LootFloorArea, separate pool, so loot
		-- and prop density tune independently. Kept in this function to stay under the
		-- local limit.
		if #prop_markers > 0 and #PROP_SCATTER.pool > 0 then
			for _, marker in ipairs(prop_markers) do
				local roll_count = math.random(PROP_SCATTER.min, PROP_SCATTER.max)
				for i = 1, roll_count do
					local half_x = marker.Size.X / 2
					local half_z = marker.Size.Z / 2
					local offset_x = (math.random() * 2 - 1) * half_x
					local offset_z = (math.random() * 2 - 1) * half_z
					local sample_position = (marker.CFrame * CFrame.new(offset_x, 0, offset_z)).Position
					local ray_origin = sample_position + Vector3.new(0, FLOOR_LOOT_RAY_CLEARANCE, 0)
					local result = workspace:Raycast(ray_origin, Vector3.new(0, -FLOOR_LOOT_RAY_DISTANCE, 0), exclude_params)
					if result then
						local prop_choice = PROP_SCATTER.pool[math.random(#PROP_SCATTER.pool)]
						local prop = prop_choice:Clone()
						local ground_offset = GROUND_OFFSET[prop_choice] or 0
						local rotation = math.rad(math.random(0, 359))
						prop:PivotTo(CFrame.new(result.Position + Vector3.new(0, ground_offset, 0)) * CFrame.Angles(0, rotation, 0))
						Exclude_From_Now_On(prop)
						-- Props aren't guaranteed anchored in Studio.
						Anchor_Model(prop)
						prop.Parent = building
					else
						warn(("[Props] %s: raycast MISSED from %s (marker %s, marker world pos %s)"):format(building.Name, tostring(ray_origin), marker:GetFullName(), tostring(marker.Position)))
					end
				end
			end
		end
	end
	local function Smooth_Step(t)
		t = math.clamp(t, 0, 1)
		return t * t * (3 - 2 * t)
	end
	local function Get_Settlement_Context(x, z)
		local pos = Vector2.new(x, z)
		local context = {
			in_flat_zone = false,
			near_zone = false,
			blend = 0,
			target_height = nil,
			kind = nil,
		}
		for _, zone in ipairs(settlement_zones) do
			local distance = (pos - zone.center).Magnitude
			-- Cities: flat terrain extends SETTLEMENT_FLAT_TERRAIN_PADDING past flat_radius,
			-- clamped to leave a blend ring. Villages are too small for that padding and use
			-- flat_radius directly.
			local terrain_flat_radius
			if zone.kind == "village" then
				terrain_flat_radius = zone.flat_radius
			else
				terrain_flat_radius = math.min(
					zone.flat_radius + (SETTLEMENT_FLAT_TERRAIN_PADDING / block_size),
					zone.radius - 5
				)
			end
			if distance < terrain_flat_radius then
				context.in_flat_zone = true
			end
			if distance < zone.flat_radius + settlement_near_padding then
				context.near_zone = true
			end
			if distance < zone.radius then
				local blend
				if distance < terrain_flat_radius then
					blend = 1
				else
					local t = 1 - ((distance - terrain_flat_radius) / (zone.radius - terrain_flat_radius))
					blend = Smooth_Step(t)
				end
				if blend > context.blend then
					context.blend = blend
					context.kind = zone.kind
					context.target_height =
						zone.elevation
						+ math.noise((x + seed_x) * 0.03, (z + seed_z) * 0.03) * 2
				end
			end
		end
		return context
	end
	local function Compute_Terrain_Data(x, z)
		local distance = math.sqrt(x*x + z*z)
		local normalized = distance / map_radius
		local falloff = 1 - (normalized ^ 2)
		local base_height = math.noise((x + seed_x) * 0.006, (z + seed_z) * 0.006) * 50
		local hills = math.noise((x + seed_x) * 0.025, (z + seed_z) * 0.025) * 30
		local detail = math.noise((x + seed_x) * 0.08, (z + seed_z) * 0.08) * 3
		local height = base_height + hills + detail
		local mountain_range = math.noise((x + seed_x) * 0.015, (z + seed_z) * 0.015)
		mountain_range = math.max(0, mountain_range)
		mountain_range = mountain_range^2
		local mountain_height = mountain_range * 500
		local mountain_ridge = math.noise((x + seed_x) * 0.01, (z + seed_z) * 0.01) * 40
		local mountain_details = math.noise((x + seed_x) * 0.05, (z + seed_z) * 0.05) * 10
		mountain_ridge *= mountain_range
		mountain_details *= mountain_range
		height = height + mountain_height + mountain_ridge + mountain_details
		local zone_context = Get_Settlement_Context(x, z)
		if zone_context.blend > 0 then
			height = height * (1 - zone_context.blend) + zone_context.target_height * zone_context.blend
		end
		height = height * falloff
		height = math.round(height)
		if distance > wall_flats_start then
			local t = (distance - wall_flats_start) / (map_radius - wall_flats_start)
			t = math.clamp(t, 0, 1)
			height = height * (1 - t) + wall_flats_height * t
		end
		local moisture = math.noise((x + seed_x)*0.015 + 1000, (z + seed_z)*0.015 + 1000)
		moisture += 0.1
		local forest_floor_choice = forest_floor[math.random(1,4)]
		local water_floor_choice = water_floor[math.random(1,3)]
		local mounty_floor_choice = mounty_floor[math.random(1,2)]
		local field_floor_choice = field_floor[math.random(1,4)]
		local settlement_floor_choice = settlement_floor[math.random(1,7)]
		local village_floor_choice = village_floor[math.random(1, #village_floor)]
		local material = forest_floor_choice
		local biome = "Forest"
		if zone_context.in_flat_zone then
			material = (zone_context.kind == "village") and village_floor_choice or settlement_floor_choice
			biome = "Settlement"
		elseif height >= 200 then
			material = Enum.Material.Snow
			biome = "Snow"
		elseif height > 50 then
			material = mounty_floor_choice
			biome = "Mountain"
		elseif height <= water_level + 1 then
			material = water_floor_choice
			biome = "Water"
		elseif moisture > 0.01 then
			material = field_floor_choice
			biome = "Field"
		else
			material = forest_floor_choice
			biome = "Forest"
		end
		return {
			distance = distance,
			height = height,
			material = material,
			biome = biome,
			moisture = moisture,
			zone_context = zone_context,
		}
	end
	local function Needs_Mountain_Or_Water_Detail(x, z)
		local mountain_sample = math.noise((x + seed_x) * 0.015, (z + seed_z) * 0.015)
		mountain_sample = math.max(0, mountain_sample)
		local mountain_height_estimate = (mountain_sample ^ 2) * 500
		local base_estimate = math.noise((x + seed_x) * 0.006, (z + seed_z) * 0.006) * 50
		local rough_height = base_estimate + mountain_height_estimate
		if rough_height > lod_mountain_threshold then
			return true
		end
		if rough_height < water_level + lod_water_buffer then
			return true
		end
		return false
	end
	local function Build_Detail_Map()
		local chunk_radius = math.ceil(map_radius / lod_chunk_size) + 1
		local raw_map = {}
		for cx = -chunk_radius, chunk_radius do
			raw_map[cx] = {}
			for cz = -chunk_radius, chunk_radius do
				local center_x = cx * lod_chunk_size + lod_chunk_size / 2
				local center_z = cz * lod_chunk_size + lod_chunk_size / 2
				local dist = math.sqrt(center_x * center_x + center_z * center_z)
				local needs_wall_detail = dist > (wall_flats_start - lod_wall_buffer)
				local needs_settlement_detail = Get_Settlement_Context(center_x, center_z).near_zone
				raw_map[cx][cz] = needs_wall_detail
					or needs_settlement_detail
					or Needs_Mountain_Or_Water_Detail(center_x, center_z)
			end
		end
		local dilated_map = {}
		for cx = -chunk_radius, chunk_radius do
			dilated_map[cx] = {}
			for cz = -chunk_radius, chunk_radius do
				local flagged = false
				for dx = -lod_buffer_chunks, lod_buffer_chunks do
					for dz = -lod_buffer_chunks, lod_buffer_chunks do
						local nx, nz = cx + dx, cz + dz
						if raw_map[nx] and raw_map[nx][nz] then
							flagged = true
							break
						end
					end
					if flagged then break end
				end
				dilated_map[cx][cz] = flagged
			end
		end
		return dilated_map, chunk_radius
	end
	local function Place_House(house_model, position, rotation_y, is_settlement, scale)
		local house = house_model:Clone()
		Anchor_Model(house)
		Randomize_Building_Colors(house)
		-- Scale before PivotTo: ScaleTo keeps the pivot in place, so scaling first and
		-- then moving lands the model exactly at position.
		if scale and scale ~= 1 then
			house:ScaleTo(scale)
		end
		-- Tilt correction is applied in the model's own frame, then the yaw rotation.
		local tilt_correction = RUBBLE_TILT_CORRECTION[house_model] or CFrame.new()
		local cframe_rotation = CFrame.Angles(0, rotation_y, 0) * tilt_correction
		house:PivotTo(CFrame.new(position.X, position.Y, position.Z) * cframe_rotation)
		house.Parent = workspace
		Populate_Building(house)
		-- Returned so the caller can move the clone later.
		return house
	end
	-- City layout: rows of buildings across the zone, all sharing the zone's
	-- rotation and facing. Each row's length is the circle's chord at that offset.
	-- 1. Plan_Settlement_Rows plans every row (no instancing yet).
	-- 2. One row near the middle is replaced by the road (Carve_Settlement_Road).
	-- 3. Spawn_Planned_Settlement_Buildings instances the rest.
	local BUILDING_ROW_FACING_OFFSET = math.rad(-90)
	local SETTLEMENT_ROW_GAP = 30
	local ROAD_WIDTH = 28
	-- 25% chance of a 5-10 stud gap between neighbors.
	local BUILDING_GAP_CHANCE = 0.25
	local BUILDING_GAP_MIN = 5
	local BUILDING_GAP_MAX = 10
	-- Warehouses and unfinished structures always get a 10-20 stud gap.
	local LARGE_BUILDING_GAP_MIN = 10
	local LARGE_BUILDING_GAP_MAX = 20
	local function Is_Large_Building(choice)
		return choice == warehouse_template or choice == unfinished_structure
	end
	-- 20% chance each building shifts up to 5 studs toward/away from the previous row.
	local BUILDING_STAGGER_CHANCE = 0.2
	local BUILDING_STAGGER_MAX = 5
	local function Plan_Settlement_Rows(zone, world_x, world_z, along, perp)
		local flat_radius_studs = zone.flat_radius * block_size
		local facing = zone.rotation + BUILDING_ROW_FACING_OFFSET
		local pool = {apartment_2f, apartment_4f, abandoned_shop, warehouse_template, unfinished_structure}
		local rows = {}
		local perp_offset = -flat_radius_studs
		while perp_offset < flat_radius_studs do
			local row_len_radius = math.sqrt(math.max(0, flat_radius_studs ^ 2 - perp_offset ^ 2))
			-- cursor is the row's leading edge; rows always sweep in the + direction.
			local cursor = -row_len_radius
			local row_buildings = {}
			local row_depth_total, row_count = 0, 0
			-- Pick before advancing the cursor, since the large-building gap depends on
			-- both neighbors.
			local previous_choice = nil
			while true do
				-- One pick per slot; the row ends when a pick doesn't fit.
				local choice = pool[math.random(#pool)]
				local metrics = BUILDING_METRICS[choice]
				local scale = MODEL_SCALE[choice] or 1
				local along_half = metrics.length * scale / 2
				local depth = metrics.depth * scale
				if previous_choice then
					if Is_Large_Building(choice) or Is_Large_Building(previous_choice) then
						cursor = cursor + math.random(LARGE_BUILDING_GAP_MIN, LARGE_BUILDING_GAP_MAX)
					elseif math.random() < BUILDING_GAP_CHANCE then
						cursor = cursor + math.random(BUILDING_GAP_MIN, BUILDING_GAP_MAX)
					end
				end
				local next_cursor = cursor + along_half * 2
				if next_cursor > row_len_radius then
					break
				end
				local signed_position = cursor + along_half
				local building_x = world_x + signed_position * along.X + perp_offset * perp.X
				local building_z = world_z + signed_position * along.Z + perp_offset * perp.Z
				if math.random() < BUILDING_STAGGER_CHANCE then
					local stagger = math.random(-BUILDING_STAGGER_MAX, BUILDING_STAGGER_MAX)
					building_x = building_x + stagger * perp.X
					building_z = building_z + stagger * perp.Z
				end
				local ground_result = workspace:Raycast(
					Vector3.new(building_x, 1000, building_z),
					Vector3.new(0, -2000, 0),
					terrain_raycast_params
				)
				if ground_result then
					local ground_correction = BUILDING_GROUND_CORRECTION[choice] or 0
					local ground_y = ground_result.Position.Y + metrics.pivot_to_bottom * scale - ground_sink_buffer + ground_correction
					local facing_correction = BUILDING_FACING_CORRECTION[choice] or 0
					local rotation = facing + facing_correction
					-- Large buildings get an extra random 180 flip on top of the side-of-road flip.
					if Is_Large_Building(choice) and math.random() < 0.5 then
						rotation = rotation + math.pi
					end
					table.insert(row_buildings, {
						choice = choice,
						position = Vector3.new(building_x, ground_y, building_z),
						rotation = rotation,
						scale = scale,
						half_length = along_half,
						half_depth = depth / 2,
						collision_rotation = rotation + metrics.footprint_offset,
					})
					row_depth_total = row_depth_total + depth
					row_count = row_count + 1
				end
				cursor = next_cursor
				previous_choice = choice
			end
			-- Rows advance by the previous row's average depth plus SETTLEMENT_ROW_GAP
			-- (just the gap if the row was empty, so the sweep always progresses).
			local average_depth = (row_count > 0) and (row_depth_total / row_count) or 0
			table.insert(rows, {perp_offset = perp_offset, depth = average_depth, buildings = row_buildings})
			perp_offset = perp_offset + average_depth + SETTLEMENT_ROW_GAP
		end
		return rows
	end
	-- Carves a road along the settlement's centerline, following the ground: clear
	-- above each segment to Air, Asphalt slab below.
	local function Carve_Settlement_Road(zone, world_x, world_z)
		local flat_radius_studs = zone.flat_radius * block_size
		local road_length = flat_radius_studs * 2
		local result = workspace:Raycast(
			Vector3.new(world_x, 1000, world_z),
			Vector3.new(0, -2000, 0),
			terrain_raycast_params
		)
		if not result then
			return
		end
		local road_cframe = CFrame.new(world_x, result.Position.Y, world_z) * CFrame.Angles(0, zone.rotation, 0)
		local segment_length = 10
		local segment_overlap = 5
		local segment_count = math.max(1, math.ceil(road_length / segment_length))
		for i = 0, segment_count - 1 do
			local offset_z = -road_length / 2 + segment_length / 2 + i * segment_length
			local segment_cframe = road_cframe * CFrame.new(0, 0, offset_z)
			local origin = segment_cframe.Position
			local segment_result = workspace:Raycast(
				origin + Vector3.new(0, 1000, 0),
				Vector3.new(0, -2000, 0),
				terrain_raycast_params
			)
			if segment_result then
				local flush_cframe = CFrame.new(origin.X, segment_result.Position.Y, origin.Z) * (segment_cframe - origin)
				terrain:FillBlock(
					flush_cframe * CFrame.new(0, 2, 0),
					Vector3.new(ROAD_WIDTH, 6, segment_length + segment_overlap),
					Enum.Material.Air
				)
				terrain:FillBlock(
					flush_cframe * CFrame.new(0, -2, 0),
					Vector3.new(ROAD_WIDTH, 2, segment_length + segment_overlap),
					Enum.Material.Asphalt
				)
			end
		end
	end
	-- Instances the planned buildings. Record_Building also feeds the wildlife
	-- spacing check.
	local function Spawn_Planned_Settlement_Buildings(buildings)
		for _, entry in ipairs(buildings) do
			Place_House(entry.choice, entry.position, entry.rotation, true, entry.scale)
			Record_Building(entry.position, entry.half_length, entry.half_depth, entry.collision_rotation)
			task.wait()
		end
	end
	-- Rubble scatter: walk a grid over the zone, skip cells near buildings or the
	-- road, and roll a chance per cell to drop a random piece with random yaw.
	local RUBBLE_SCATTER_GRID_STEP = 12
	local RUBBLE_SCATTER_CHANCE = 0.2
	local RUBBLE_CLEARANCE = 5
	-- Villages use a lower per-cell chance than cities. Placeholder.
	local VILLAGE_RUBBLE_SCATTER_CHANCE = 0.08
	local function Scatter_Settlement_Rubble(zone, world_x, world_z, along, perp, road_perp_offset)
		if #rubble_list == 0 then
			return
		end
		local flat_radius_studs = zone.flat_radius * block_size
		local road_half_width = ROAD_WIDTH / 2
		local scatter_wait_counter = 0
		local coord_perp = -flat_radius_studs
		while coord_perp <= flat_radius_studs do
			if math.abs(coord_perp - road_perp_offset) > road_half_width + RUBBLE_CLEARANCE then
				local coord_along_radius = math.sqrt(math.max(0, flat_radius_studs ^ 2 - coord_perp ^ 2))
				local coord_along = -coord_along_radius
				while coord_along <= coord_along_radius do
					local x = world_x + coord_along * along.X + coord_perp * perp.X
					local z = world_z + coord_along * along.Z + coord_perp * perp.Z
					if not Building_Too_Close(Vector3.new(x, 0, z), RUBBLE_CLEARANCE, RUBBLE_CLEARANCE, 0)
						and math.random() < RUBBLE_SCATTER_CHANCE then
						local ground_result = workspace:Raycast(
							Vector3.new(x, 1000, z),
							Vector3.new(0, -2000, 0),
							terrain_raycast_params
						)
						if ground_result then
							local choice = rubble_list[math.random(#rubble_list)]
							local metrics = RUBBLE_METRICS[choice]
							local ground_correction = RUBBLE_GROUND_CORRECTION[choice] or 0
							local ground_y = ground_result.Position.Y + metrics.pivot_to_bottom - ground_sink_buffer + ground_correction
							local rotation = math.rad(math.random(0, 359)) + (RUBBLE_FACING_CORRECTION[choice] or 0)
							local position = Vector3.new(x, ground_y, z)
							Place_House(choice, position, rotation, true)
							Record_Building(position, metrics.length / 2, metrics.depth / 2, rotation + metrics.footprint_offset)
							scatter_wait_counter = scatter_wait_counter + 1
							if scatter_wait_counter % 20 == 0 then
								task.wait()
							end
						end
					end
					coord_along = coord_along + RUBBLE_SCATTER_GRID_STEP
				end
			end
			coord_perp = coord_perp + RUBBLE_SCATTER_GRID_STEP
		end
	end
	local function Generate_Settlement_Structures(zone)
		local world_x = zone.center.X * block_size
		local world_z = zone.center.Y * block_size
		local along = CFrame.Angles(0, zone.rotation, 0):VectorToWorldSpace(Vector3.new(0, 0, 1))
		local perp = CFrame.Angles(0, zone.rotation, 0):VectorToWorldSpace(Vector3.new(1, 0, 0))
		local rows = Plan_Settlement_Rows(zone, world_x, world_z, along, perp)
		-- Road placement: pick the row whose center is closest to the zone center, drop
		-- its buildings, and carve the road there. That leaves an equal gap to the rows
		-- on either side.
		local flat_radius_studs = zone.flat_radius * block_size
		local road_row_index = nil
		local road_row_distance = math.huge
		for i, row in ipairs(rows) do
			local row_center = row.perp_offset + row.depth / 2
			local distance = math.abs(row_center)
			if distance < road_row_distance then
				road_row_distance = distance
				road_row_index = i
			end
		end
		local road_perp_offset = 0
		if road_row_index then
			local road_row = rows[road_row_index]
			road_perp_offset = road_row.perp_offset + road_row.depth / 2
		end
		local road_center_x = world_x + road_perp_offset * perp.X
		local road_center_z = world_z + road_perp_offset * perp.Z
		Carve_Settlement_Road(zone, road_center_x, road_center_z)
		-- Rows before the road row are rotated 180 so both sides face the road.
		local buildings = {}
		local flip_rotation = true
		for i, row in ipairs(rows) do
			if road_row_index and i == road_row_index then
				flip_rotation = false
			else
				for _, building in ipairs(row.buildings) do
					if flip_rotation then
						building.rotation = building.rotation + math.pi
						building.collision_rotation = building.collision_rotation + math.pi
					end
					table.insert(buildings, building)
				end
			end
		end
		Spawn_Planned_Settlement_Buildings(buildings)
		Scatter_Settlement_Rubble(zone, world_x, world_z, along, perp, road_perp_offset)
	end
	-- Village layout: 2 rows along zone.rotation. Each building advances by half
	-- its length plus the previous half length plus gap_buffer. Rows overshoot their
	-- chord slightly; a final bounds check removes anything poking outside.
	local VILLAGE_ROW = {
		row_count = 2,
		gap_buffer = 10,
		-- How far past the chord a village row may run. Placeholder.
		overshoot_buffer = 40,
	}
	-- Same rubble scatter as cities, on a plain world-aligned grid (no road).
	local function Scatter_Village_Rubble(zone, world_x, world_z)
		if #village_rubble_list == 0 then
			return
		end
		local flat_radius_studs = zone.flat_radius * block_size
		local scatter_wait_counter = 0
		local coord_z = -flat_radius_studs
		while coord_z <= flat_radius_studs do
			local coord_x_radius = math.sqrt(math.max(0, flat_radius_studs ^ 2 - coord_z ^ 2))
			local coord_x = -coord_x_radius
			while coord_x <= coord_x_radius do
				local x = world_x + coord_x
				local z = world_z + coord_z
				if not Building_Too_Close(Vector3.new(x, 0, z), RUBBLE_CLEARANCE, RUBBLE_CLEARANCE, 0)
					and math.random() < VILLAGE_RUBBLE_SCATTER_CHANCE then
					local ground_result = workspace:Raycast(
						Vector3.new(x, 1000, z),
						Vector3.new(0, -2000, 0),
						terrain_raycast_params
					)
					if ground_result then
						local choice = village_rubble_list[math.random(#village_rubble_list)]
						local metrics = RUBBLE_METRICS[choice]
						local ground_correction = RUBBLE_GROUND_CORRECTION[choice] or 0
						local ground_y = ground_result.Position.Y + metrics.pivot_to_bottom - ground_sink_buffer + ground_correction
						local rotation = math.rad(math.random(0, 359)) + (RUBBLE_FACING_CORRECTION[choice] or 0)
						local position = Vector3.new(x, ground_y, z)
						Place_House(choice, position, rotation, true)
						Record_Building(position, metrics.length / 2, metrics.depth / 2, rotation + metrics.footprint_offset)
						scatter_wait_counter = scatter_wait_counter + 1
						if scatter_wait_counter % 20 == 0 then
							task.wait()
						end
					end
				end
				coord_x = coord_x + RUBBLE_SCATTER_GRID_STEP
			end
			coord_z = coord_z + RUBBLE_SCATTER_GRID_STEP
		end
	end
	-- Plans one village row without instancing, so the bounds check can run first.
	-- perp_offset is this row's distance from the village center.
	local function Plan_Village_Row(zone, world_x, world_z, along, perp, perp_offset)
		local flat_radius_studs = zone.flat_radius * block_size
		local row_len_radius = math.sqrt(math.max(0, flat_radius_studs ^ 2 - perp_offset ^ 2))
		local row_start = -row_len_radius
		local distance_cap = row_len_radius * 2 + VILLAGE_ROW.overshoot_buffer
		local row_buildings = {}
		local signed_position = nil
		local previous_half_length = nil
		while true do
			local choice = scatter_house_list[math.random(#scatter_house_list)]
			local metrics = BUILDING_METRICS[choice]
			local half_length, half_depth = metrics.length / 2, metrics.depth / 2
			-- Center-to-center step = half(prev) + half(this) + gap_buffer.
			if signed_position then
				signed_position = signed_position + previous_half_length + half_length + VILLAGE_ROW.gap_buffer
			else
				signed_position = row_start + half_length
			end
			if signed_position - row_start > distance_cap then
				break
			end
			local rotation = math.rad(math.random(0, 359))
			local footprint_rotation = rotation + metrics.footprint_offset
			local building_x = world_x + signed_position * along.X + perp_offset * perp.X
			local building_z = world_z + signed_position * along.Z + perp_offset * perp.Z
			local ground_result = workspace:Raycast(
				Vector3.new(building_x, 1000, building_z),
				Vector3.new(0, -2000, 0),
				terrain_raycast_params
			)
			if ground_result then
				local ground_correction = BUILDING_GROUND_CORRECTION[choice] or 0
				local ground_y = ground_result.Position.Y + metrics.pivot_to_bottom - ground_sink_buffer + ground_correction
				table.insert(row_buildings, {
					choice = choice,
					position = Vector3.new(building_x, ground_y, building_z),
					rotation = rotation,
					half_length = half_length,
					half_depth = half_depth,
					collision_rotation = footprint_rotation,
				})
			end
			previous_half_length = half_length
		end
		return row_buildings
	end
	local function Generate_Village_Structures(zone)
		local world_x = zone.center.X * block_size
		local world_z = zone.center.Y * block_size
		local village_center = Vector3.new(world_x, 0, world_z)
		local flat_radius_studs = zone.flat_radius * block_size
		local along = CFrame.Angles(0, zone.rotation, 0):VectorToWorldSpace(Vector3.new(0, 0, 1))
		local perp = CFrame.Angles(0, zone.rotation, 0):VectorToWorldSpace(Vector3.new(1, 0, 0))
		-- Rows split the diameter into equal segments (2 rows: offsets +/- flat_radius/3).
		local placements = {}
		for i = 1, VILLAGE_ROW.row_count do
			local perp_offset = -flat_radius_studs + i * (2 * flat_radius_studs / (VILLAGE_ROW.row_count + 1))
			local row_buildings = Plan_Village_Row(zone, world_x, world_z, along, perp, perp_offset)
			for _, building in ipairs(row_buildings) do
				table.insert(placements, building)
			end
		end
		local spawned = {}
		for _, entry in ipairs(placements) do
			local house = Place_House(entry.choice, entry.position, entry.rotation, true)
			local index = Record_Building(entry.position, entry.half_length, entry.half_depth, entry.collision_rotation)
			table.insert(spawned, {house = house, index = index})
			task.wait()
		end
		-- Remove buildings with any footprint corner outside the village circle
		-- (highest index first so indices stay valid).
		local remove_indices = {}
		for _, placed in ipairs(spawned) do
			local footprint = placed_building_footprints[placed.index]
			local len_x, len_z = math.cos(footprint.rotation), math.sin(footprint.rotation)
			local dep_x, dep_z = -len_z, len_x
			local outside = false
			for _, signs in ipairs({{1, 1}, {1, -1}, {-1, 1}, {-1, -1}}) do
				local corner_x = footprint.position.X + (len_x * footprint.half_length * signs[1]) + (dep_x * footprint.half_depth * signs[2])
				local corner_z = footprint.position.Z + (len_z * footprint.half_length * signs[1]) + (dep_z * footprint.half_depth * signs[2])
				local corner_distance = Vector2.new(corner_x - village_center.X, corner_z - village_center.Z).Magnitude
				if corner_distance > flat_radius_studs then
					outside = true
				end
			end
			if outside then
				placed.house:Destroy()
				table.insert(remove_indices, placed.index)
			end
		end
		table.sort(remove_indices, function(a, b) return a > b end)
		for _, index in ipairs(remove_indices) do
			table.remove(placed_houses, index)
			table.remove(placed_building_footprints, index)
		end
		Scatter_Village_Rubble(zone, world_x, world_z)
	end
	local function Arena_Spawns(player_count)
		local spawn_folder = Instance.new("Folder")
		spawn_folder.Name = "arena_spawns"
		spawn_folder.Parent = workspace
		local radius = map_radius * block_size - 40
		for i = 1, player_count do
			local angle = (i / player_count) * math.pi * 2
			local x = math.cos(angle) * radius
			local z = math.sin(angle) * radius
			local spawn = Instance.new("SpawnLocation")
			spawn.Size = Vector3.new(8, 1, 8)
			spawn.Anchored = true
			spawn.CanCollide = true
			spawn.Neutral = true
			local result = workspace:Raycast(Vector3.new(x, 500, z), Vector3.new(0, -1000, 0))
			local y = result and result.Position.Y + 3
			spawn.CFrame = CFrame.lookAt(Vector3.new(x, y, z), Vector3.new(0, y, 0))
			spawn.Parent = spawn_folder
		end
	end
	local function Spawn_Wildlife()
		for species_name, spawn_info in pairs(WILDLIFE_SPAWN_TABLE) do
			local allow_settlement = spawn_info.biomes.Settlement
			local spacing = allow_settlement and wildlife_settlement_spacing or wildlife_min_spacing
			local spawned = 0
			local attempts = 0
			local attempt_cap = spawn_info.count * wildlife_max_attempts_per_animal
			while spawned < spawn_info.count and attempts < attempt_cap do
				attempts += 1
				local x = math.random(-map_radius, map_radius)
				local z = math.random(-map_radius, map_radius)
				local distance = math.sqrt(x * x + z * z)
				if distance <= map_radius - (clear_wall_distance / block_size) then
					local data = Compute_Terrain_Data(x, z)
					if spawn_info.biomes[data.biome] and (allow_settlement or not data.zone_context.near_zone) then
						local world_x = x * block_size
						local world_z = z * block_size
						local world_pos = Vector3.new(world_x, 0, world_z)
						if not Too_Close(world_pos, spacing) then
							wildlife.spawn_animal(species_name, world_x, world_z)
							Record_Building(world_pos, 0, 0, 0)
							spawned += 1
						end
					end
				end
				if attempts % 20 == 0 then
					task.wait()
				end
			end
		end
	end
	-- Keep settlements (including their blend ring) this far inside the wall
	-- flattening ring, so they stay off the wall and away from the spawn ring.
	local SETTLEMENT_WALL_BUFFER = 50
	-- True if the candidate would be too close to any existing city or village.
	local function Settlement_Overlaps_Existing(candidate_center, candidate_radius)
		for _, zone in ipairs(settlement_zones) do
			if (candidate_center - zone.center).Magnitude < (candidate_radius + zone.radius + SETTLEMENT_SEPARATION_BUFFER) then
				return true
			end
		end
		return false
	end
	while #settlement_zones < target_settlement_count and settlement_attempts < max_attempts do
		settlement_attempts += 1
		local angle = math.random() * math.pi * 2
		local flat_radius = math.random(75, 100)
		local radius = flat_radius + math.random(25, 50)
		-- Clamp the distance so the settlement's edge can't reach the wall buffer.
		local max_dist = math.min(map_radius * 0.65, (wall_flats_start - SETTLEMENT_WALL_BUFFER) - radius)
		local dist = math.random(map_radius * 0.25, max_dist)
		local center_x = math.cos(angle) * dist
		local center_z = math.sin(angle) * dist
		local candidate_center = Vector2.new(center_x, center_z)
		if not Settlement_Overlaps_Existing(candidate_center, radius) then
			table.insert(settlement_zones, {
				center = Vector2.new(center_x, center_z),
				flat_radius = flat_radius,
				radius = radius,
				elevation = math.random(8, 22),
				rotation = math.rad(math.random(0, 359)),
				kind = "large",
			})
		end
	end
	-- Villages must be on plains: check the biome at the center and the 4 edge
	-- points (also rejects spots too near another settlement).
	local function Village_Site_Is_Plains(center_x, center_z, flat_radius_blocks)
		local offsets = {{0, 0}, {flat_radius_blocks, 0}, {-flat_radius_blocks, 0}, {0, flat_radius_blocks}, {0, -flat_radius_blocks}}
		for _, offset in ipairs(offsets) do
			local sample = Compute_Terrain_Data(center_x + offset[1], center_z + offset[2])
			if sample.biome ~= "Field" then
				return false
			end
		end
		return true
	end
	local villages_placed = 0
	while villages_placed < VILLAGE_ZONE.target_count and VILLAGE_ZONE.attempts < VILLAGE_ZONE.max_attempts do
		VILLAGE_ZONE.attempts += 1
		local flat_radius = VILLAGE_ZONE.flat_radius_min + math.random() * (VILLAGE_ZONE.flat_radius_max - VILLAGE_ZONE.flat_radius_min)
		local radius = flat_radius + VILLAGE_ZONE.blend_min + math.random() * (VILLAGE_ZONE.blend_max - VILLAGE_ZONE.blend_min)
		local angle = math.random() * math.pi * 2
		local max_dist = math.min(map_radius * 0.8, (wall_flats_start - SETTLEMENT_WALL_BUFFER) - radius)
		local min_dist = map_radius * 0.1
		local dist = min_dist + math.random() * (max_dist - min_dist)
		local center_x = math.cos(angle) * dist
		local center_z = math.sin(angle) * dist
		local candidate_center = Vector2.new(center_x, center_z)
		if not Settlement_Overlaps_Existing(candidate_center, radius) and Village_Site_Is_Plains(center_x, center_z, flat_radius) then
			table.insert(settlement_zones, {
				center = candidate_center,
				flat_radius = flat_radius,
				radius = radius,
				elevation = math.random(8, 22),
				rotation = math.rad(math.random(0, 359)),
				kind = "village",
			})
			villages_placed = villages_placed + 1
		end
	end
	settlement_data.set_data(settlement_zones, block_size)
	local detail_map, chunk_radius = Build_Detail_Map()
	-- No plants in mountains (height > 50), underwater, or in the spawn rim
	-- (only sparse dead stumps/bushes there).
	local MOUNTAIN_PLANT_CEILING = 50
	local RIM_DEAD_DECOR_CHANCE = 0.004
	local min_height = -60
	-- Forageable bushes: some live bushes get a prompt; holding E gives 2-5
	-- Preserved Berries straight to inventory, once per bush.
	local FORAGE = {
		chance = 0.1,
		berry_min = 2,
		berry_max = 5,
		item_name = "Preserved Berries",
		hold_duration = 1,
		max_distance = 10,
		-- Shown with a Highlight overlay; destroying it restores the normal look.
		highlight_color = Color3.fromRGB(200, 30, 30),
	}
	-- Bushes can be a bare part or a Model; find a BasePart for the prompt.
	local function Get_Interactable_Part(instance)
		if instance:IsA("BasePart") then
			return instance
		end
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	-- Uses a Highlight, because tinting a textured MeshPart multiplies with the
	-- texture and barely shows.
	local function Try_Make_Bush_Forageable(bush_instance, bush_choice)
		if bush_choice ~= NATURE_MODELS.bush_live then
			return
		end
		if math.random() >= FORAGE.chance then
			return
		end
		-- Leaves1 is a prominent named part on every Live Bush.
		local leaf = bush_instance:FindFirstChild("Leaves1")
		local part = (leaf and leaf:IsA("BasePart")) and leaf or Get_Interactable_Part(bush_instance)
		if not part then
			return
		end
		local highlight = Instance.new("Highlight")
		highlight.Name = "ForageHighlight"
		highlight.FillColor = FORAGE.highlight_color
		highlight.FillTransparency = 0.3
		highlight.OutlineColor = FORAGE.highlight_color
		highlight.OutlineTransparency = 0
		-- AlwaysOnTop so the bush's own leaves don't hide the highlight.
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Adornee = part
		highlight.Parent = bush_instance
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ForagePrompt"
		prompt.ActionText = "Forage"
		prompt.ObjectText = "Bush"
		prompt.HoldDuration = FORAGE.hold_duration
		prompt.MaxActivationDistance = FORAGE.max_distance
		-- The bush's own foliage would fail the line-of-sight check.
		prompt.RequiresLineOfSight = false
		prompt.Parent = part
		local foraged = false
		prompt.Triggered:Connect(function(triggering_player)
			-- Guards against a double-grant from a trigger landing twice
			-- before Enabled=false below actually takes effect.
			if foraged then
				return
			end
			foraged = true
			prompt.Enabled = false
			highlight:Destroy()
			local berry_count = math.random(FORAGE.berry_min, FORAGE.berry_max)
			player_inventory.add_item(triggering_player, FORAGE.item_name, berry_count)
			inventory_updated:FireClient(triggering_player, player_inventory.player_inventories[triggering_player])
			player_weight.notify(triggering_player)
		end)
	end
	local function Fill_Cell(x, z, data)
		local height = data.height
		local material = data.material
		local column_height = height - min_height
		if column_height < 4 then
			column_height = 4
		end
		terrain:FillBlock(
			CFrame.new(x * block_size, min_height + column_height / 2, z * block_size),
			Vector3.new(block_size, column_height, block_size), material)
		if height <= water_level then
			local water_height = water_level - height
			terrain:FillBlock(CFrame.new(x*block_size, height + water_height / 2, z * block_size), Vector3.new(
				block_size, water_height, block_size), Enum.Material.Water)
		end
	end
	for cx = -chunk_radius, chunk_radius do
		for cz = -chunk_radius, chunk_radius do
			local chunk_needs_detail = detail_map[cx][cz]
			local chunk_x0 = cx * lod_chunk_size
			local chunk_z0 = cz * lod_chunk_size
			if chunk_needs_detail then
				for lx = 0, lod_chunk_size - 1 do
					for lz = 0, lod_chunk_size - 1 do
						local x = chunk_x0 + lx
						local z = chunk_z0 + lz
						if x >= -map_radius and x <= map_radius and z >= -map_radius and z <= map_radius then
							local data = Compute_Terrain_Data(x, z)
							if data.distance <= map_radius then
								local height = data.height
								local material = data.material
								local moisture = data.moisture
								local zone_context = data.zone_context
								local distance = data.distance
								Fill_Cell(x, z, data)
								local position = Vector3.new(x*block_size, height, z*block_size)
								if not zone_context.near_zone then
									if not Too_Close(position, 60) then
										local distance_to_wall = map_radius - distance
										if height > water_level and height <= water_level + 3 and distance <= wall_flats_start and math.random() < 0.06 then
											local water_plant_choice = water_plant_list[math.random(#water_plant_list)]
											local water_plant = water_plant_choice:Clone()
											local water_plant_scale = math.random(80, 120) / 100
											water_plant:ScaleTo(water_plant_scale)
											local ground_offset = GROUND_OFFSET[water_plant_choice] * water_plant_scale
											water_plant:PivotTo(CFrame.new(x*block_size, height + ground_offset, z*block_size) * CFrame.Angles(0, math.rad(math.random(0, 360)), 0))
											water_plant.Parent = workspace
											collection_service:AddTag(water_plant, LIVE_PLANT_TAG)
										elseif distance_to_wall > clear_wall_distance and distance <= wall_flats_start and math.random() < 0.08
											and (material == Enum.Material.Ground or material == Enum.Material.Mud or material == Enum.Material.LeafyGrass)
											and height > (water_level + 2) then
											local roll = math.random()
											local tilt_x = math.rad(math.random(-2, 2))
											local tilt_z = math.rad(math.random(-2, 2))
											if roll > 0.8 or height <= -19 then
												tilt_x = math.rad(math.random(-10, 10))
												tilt_z = math.rad(math.random(-10, 10))
											end
											local tree_choice = tree_list[math.random(#tree_list)]
											local tree = tree_choice:Clone()
											local base_scale = TREE_BASE_SCALE[tree_choice] or 1.0
											local tree_scale = base_scale * (math.random(80, 120) / 100)
											tree:ScaleTo(tree_scale)
											tree:PivotTo(CFrame.new(x*block_size, height+23, z*block_size) * CFrame.Angles(tilt_x, 0, tilt_z))
											tree.Parent = workspace
											collection_service:AddTag(tree, FOREST_FIRE.tag)
											FOREST_FIRE.trees_seen = FOREST_FIRE.trees_seen + 1
											-- Reservoir sampling: fill the first 3, then each new tree replaces a random
											-- slot with probability origin_count / trees_seen.
											if #FOREST_FIRE.origin_trees < FOREST_FIRE.origin_count then
												table.insert(FOREST_FIRE.origin_trees, tree)
											else
												local replace_index = math.random(FOREST_FIRE.trees_seen)
												if replace_index <= FOREST_FIRE.origin_count then
													FOREST_FIRE.origin_trees[replace_index] = tree
												end
											end
										elseif moisture > 0.01 and height > water_level and height <= MOUNTAIN_PLANT_CEILING and distance <= wall_flats_start and math.random() < 0.08 then
											local flower_choice = flower_list[math.random(#flower_list)]
											local flower = flower_choice:Clone()
											local flower_scale = math.random(80, 120) / 100
											flower:ScaleTo(flower_scale)
											local ground_offset = GROUND_OFFSET[flower_choice] * flower_scale
											flower:PivotTo(CFrame.new(x*block_size, height + ground_offset, z*block_size) * CFrame.Angles(0, math.rad(math.random(0, 360)), 0))
											flower.Parent = workspace
											collection_service:AddTag(flower, LIVE_PLANT_TAG)
										elseif moisture > 0.01 and height > water_level and height <= MOUNTAIN_PLANT_CEILING and distance <= wall_flats_start and math.random() < 0.035 then
											local bush_choice = bush_list[math.random(#bush_list)]
											local bush = bush_choice:Clone()
											local bush_scale = math.random(80, 120) / 100
											bush:ScaleTo(bush_scale)
											local ground_offset = GROUND_OFFSET[bush_choice] * bush_scale
											bush:PivotTo(CFrame.new(x*block_size, height + ground_offset, z*block_size))
											bush.Parent = workspace
											collection_service:AddTag(bush, LIVE_PLANT_TAG)
											Try_Make_Bush_Forageable(bush, bush_choice)
										elseif height > water_level and height <= MOUNTAIN_PLANT_CEILING and distance <= wall_flats_start and math.random() < 0.01 then
											local bush_choice = bush_list[math.random(#bush_list)]
											local bush = bush_choice:Clone()
											local bush_scale = math.random(100, 200) / 100
											bush:ScaleTo(bush_scale)
											bush:PivotTo(CFrame.new(x*block_size, height+2, z*block_size))
											bush.Parent = workspace
											collection_service:AddTag(bush, LIVE_PLANT_TAG)
											Try_Make_Bush_Forageable(bush, bush_choice)
										elseif moisture <= 0.3 and height > (water_level+1) and height < 25 and distance <= wall_flats_start and math.random() < 0.008 then
											local mulch_choice = mulchfood_list[math.random(#mulchfood_list)]
											local mulch = mulch_choice:Clone()
											local mulch_scale = math.random(80, 120) / 100
											mulch:ScaleTo(mulch_scale)
											local ground_offset = GROUND_OFFSET[mulch_choice] * mulch_scale
											mulch:PivotTo(CFrame.new(x*block_size, height + ground_offset, z*block_size) * CFrame.Angles(0, math.rad(math.random(0, 360)), 0))
											mulch.Parent = workspace
										elseif moisture <= 0.3 and height > (water_level+1) and height < 25 and distance <= wall_flats_start and math.random() < 0.006 then
											Spawn_Ferns(Vector3.new(x*block_size, height+2, z*block_size))
										elseif distance > wall_flats_start and height > water_level + 1 and math.random() < RIM_DEAD_DECOR_CHANCE then
											-- Spawn rim: only dead stumps or the dead bush, never the live bush.
											local dead_choice
											if math.random() < 0.5 then
												dead_choice = mulchfood_list[math.random(#mulchfood_list)]
											else
												dead_choice = NATURE_MODELS.bush_dead
											end
											local dead_clone = dead_choice:Clone()
											local dead_scale = math.random(80, 120) / 100
											dead_clone:ScaleTo(dead_scale)
											local ground_offset = GROUND_OFFSET[dead_choice] * dead_scale
											dead_clone:PivotTo(CFrame.new(x*block_size, height + ground_offset, z*block_size) * CFrame.Angles(0, math.rad(math.random(0, 360)), 0))
											dead_clone.Parent = workspace
										elseif math.random() < (height > 50 and 0.015 or 0.001) then
											local rock_choice = rock_list[math.random(#rock_list)]
											local rock = rock_choice:Clone()
											local rock_scale = math.random(70, 140) / 100
											rock:ScaleTo(rock_scale)
											if height > 50 then
												rock = NATURE_MODELS.rock_dark:Clone()
												local rock_scale = math.random(70, 140) / 100
												rock:ScaleTo(rock_scale)
											end
											rock:PivotTo(CFrame.new(x*block_size, height, z*block_size) * CFrame.Angles(0, math.rad(math.random(0, 360)), 0))
											rock.Parent = workspace
											collection_service:AddTag(rock, LIVE_ROCK_TAG)
										elseif height <= 50 and math.random() < 0.006 then
											local mossy_boulder = mossy_boulder_list[1]:Clone()
											local mossy_boulder_scale = math.random(70, 140) / 100
											mossy_boulder:ScaleTo(mossy_boulder_scale)
											mossy_boulder:PivotTo(CFrame.new(x*block_size, height, z*block_size) * CFrame.Angles(0, math.rad(math.random(0, 360)), 0))
											mossy_boulder.Parent = workspace
											collection_service:AddTag(mossy_boulder, LIVE_ROCK_TAG)
										end
									end
								end
								chunk_count += 1
							end
						end
					end
				end
			else
				local center_x = chunk_x0 + lod_chunk_size / 2
				local center_z = chunk_z0 + lod_chunk_size / 2
				local distance = math.sqrt(center_x*center_x + center_z*center_z)
				if distance <= map_radius then
					local data = Compute_Terrain_Data(center_x, center_z)
					local height = data.height
					local material = data.material
					local column_height = height - min_height
					if column_height < 4 then
						column_height = 4
					end
					local chunk_world_size = lod_chunk_size * block_size
					terrain:FillBlock(
						CFrame.new(center_x * block_size, min_height + column_height / 2, center_z * block_size),
						Vector3.new(chunk_world_size, column_height, chunk_world_size), material)
					if height <= water_level then
						local water_height = water_level - height
						terrain:FillBlock(
							CFrame.new(center_x*block_size, height + water_height / 2, center_z*block_size),
							Vector3.new(chunk_world_size, water_height, chunk_world_size), Enum.Material.Water)
					end
				end
				chunk_count += 1
			end
			if chunk_count % 200 == 0 then
				task.wait()
			end
		end
	end
	local snapshot_resolution = 40
	local snapshot_cells = {}
	for i = 1, snapshot_resolution + 1 do
		local row = {}
		for j = 1, snapshot_resolution + 1 do
			local sx = ((i - 1) / snapshot_resolution - 0.5) * 2 * map_radius
			local sz = ((j - 1) / snapshot_resolution - 0.5) * 2 * map_radius
			local data = Compute_Terrain_Data(sx, sz)
			row[j] = {
				biome = data.biome,
			}
		end
		snapshot_cells[i] = row
	end
	minimap_data.set_snapshot({
		resolution = snapshot_resolution,
		cells = snapshot_cells,
		map_radius = map_radius,
	})
	for _, zone in ipairs(settlement_zones) do
		if zone.kind == "village" then
			Generate_Village_Structures(zone)
		else
			Generate_Settlement_Structures(zone)
		end
		task.wait()
	end
	Spawn_Wildlife()
	local function Generate_Arena_Walls()
		local wall_radius = map_radius * block_size
		local wall_height = 500
		local lip_height = 50
		local wall_thickness = 30
		local thin_wall_thickness = 10
		local segments = 100
		local thin_segments = 200
		for i = 1, segments do
			local angle = (i / segments) * math.pi * 2
			local x = math.cos(angle) * wall_radius
			local z = math.sin(angle) * wall_radius
			local wall = Instance.new("Part")
			wall.Anchored = true
			wall.Material = Enum.Material.Concrete
			wall.Color = Color3.fromRGB(200, 200, 200)
			wall.Size = Vector3.new(wall_thickness, wall_height, 80)
			wall.CFrame = CFrame.new(x, (wall_height / 2) - 100, z) * CFrame.Angles(0, -angle, 0)
			wall.Parent = workspace
		end
		for i = 1, thin_segments do
			local angle = (i / thin_segments) * math.pi * 2
			local x = math.cos(angle) * wall_radius
			local z = math.sin(angle) * wall_radius
			local wall = Instance.new("Part")
			wall.Anchored = true
			wall.Material = Enum.Material.Asphalt
			wall.Color = Color3.fromRGB(140, 140, 140)
			wall.Size = Vector3.new(thin_wall_thickness, wall_height, 80)
			wall.CFrame = CFrame.new(x, (wall_height / 2) - 100, z) * CFrame.Angles(0, -angle, 0)
			wall.Parent = workspace
		end
		for i = 1, thin_segments do
			local angle = (i / thin_segments) * math.pi * 2
			local x = math.cos(angle) * wall_radius
			local z = math.sin(angle) * wall_radius
			local wall = Instance.new("Part")
			wall.Anchored = true
			wall.Material = Enum.Material.Concrete
			wall.Color = Color3.fromRGB(200, 200, 200)
			wall.Size = Vector3.new(wall_thickness, lip_height, 80)
			wall.CFrame = CFrame.new(x, wall_height - 100, z) * CFrame.Angles(0, -angle, 0)
			wall.Parent = workspace
		end
	end
	Generate_Arena_Walls()
	Arena_Spawns(Count_Table(game_data.participants))
	local spawns = workspace.arena_spawns:GetChildren()
	for i, player in ipairs(game.Players:GetPlayers()) do
		if player.Character and spawns[i] then
			player.Character:PivotTo(spawns[i].CFrame + Vector3.new(0, 4, 0))
		end
	end
	-- Handed to ForestFireEvent through game_data.
	game_data.forest_fire_origin_trees = FOREST_FIRE.origin_trees
end
local function Countdown_Player_Movement(player, enabled)
	local walk_speed = 16
	local jump_height = 7.2
	local character = player.Character
	local humanoid = character:FindFirstChild("Humanoid")
	if not character then
		return
	end
	if not humanoid then
		return
	end
	if enabled then
		humanoid.WalkSpeed = walk_speed
		humanoid.JumpHeight = jump_height
	else
		humanoid.WalkSpeed = 0
		humanoid.JumpHeight = 0
	end
end
function StartMatch.Start_Match(game_data)
	game_data.spectators = {}
	for player in pairs(game_data.participants) do
		if player.Character then
			Countdown_Player_Movement(player, false)
		end
	end
	match_ui_event:FireAllClients("Start Match", 10)
	task.wait(10)
	match_ui_event:FireAllClients("Match Started")
	for player in pairs(game_data.participants) do
		Countdown_Player_Movement(player, true)
	end
	match_start:FireAllClients()
	print("Match started")
end
return StartMatch
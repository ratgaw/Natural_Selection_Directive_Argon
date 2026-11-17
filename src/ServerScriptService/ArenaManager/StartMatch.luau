local StartMatch = {}
local replicated_storage =  game:GetService("ReplicatedStorage")
local server_storage = game:GetService("ServerStorage")
local server_script_service = game:GetService("ServerScriptService")
local lighting = game:GetService("Lighting")
local players = game:GetService("Players")
local collection_service = game:GetService("CollectionService")
-- [stated] "is it possible to remove all plants that's touching the
-- replaced terrain?" / "add these boulders to the models that get changed
-- when near the flames" -- ForestFireEvent.lua needs tags to find plants/
-- rocks the same way it already finds trees via LIVE_TREE_TAG, read by its
-- own LIVE_PLANT_TAG/LIVE_ROCK_TAG constants (keep both in sync if these
-- ever change). Declared at file scope rather than inside Generate() --
-- Generate() is already right at Luau's 200-local-per-function ceiling, so
-- adding these as locals INSIDE it (which is where they lived originally)
-- tips it over into a real compile error; as upvalues captured from here
-- instead, they don't count against that limit.
local LIVE_PLANT_TAG = "LivePlant"
local LIVE_ROCK_TAG = "LiveRock"
local current_players = players:GetPlayers()
local arena_manager = script.Parent
local nature_folder = server_storage:WaitForChild("Nature")
local crate_loot = require(arena_manager:WaitForChild("CrateLoot"))
local minimap_data = require(arena_manager:WaitForChild("MinimapData"))
local settlement_data = require(arena_manager:WaitForChild("SettlementData"))
local wildlife = require(arena_manager:WaitForChild("WildLifeManager"))
-- [stated] "implement a day/night cycle, along with a randomized weather
-- cycle" -- a ModuleScript sibling of this one under ArenaManager, same
-- require convention as WildLifeManager above. Needs to actually be
-- placed there in Studio, same outstanding manual step every new module/
-- remote in this project has needed.
local day_night_weather = require(arena_manager:WaitForChild("DayNightWeather"))
local dropped_items = require(server_script_service:WaitForChild("DroppedItems"))
-- [stated] berries foraged from a bush go straight into the player's
-- inventory (PlayerInventory.add_item(player, item_name, amount)) rather
-- than dropping as a ground pickup like crate/floor loot does.
local player_inventory = require(server_script_service:WaitForChild("PlayerInventory"))
-- [found] RequestChecker.lua also calls PlayerWeight.notify(player) after
-- every single inventory grant (berries carry Weight=0.5 in ItemData) --
-- without it, carried weight would silently go stale until some other,
-- unrelated action happened to refresh it.
local player_weight = require(server_script_service:WaitForChild("PlayerWeight"))
-- FloorLootData lives under ArenaManager (a sibling of CrateLoot/StartMatch
-- itself), not ReplicatedStorage like CrateData — matches where it's
-- actually placed in Studio, not the CrateData convention.
local floor_loot_data = require(arena_manager:WaitForChild("FloorLootData"))
local match_ui_event = replicated_storage:WaitForChild("MatchUIEvent")
local match_start = replicated_storage:WaitForChild("MatchStarted")
-- [found] RequestChecker.lua fires this after every single PlayerInventory
-- mutation (equip/unequip, crate takes, use-item, drops) -- it's what the
-- inventory UI actually listens to for refreshing, and PlayerInventory.lua
-- itself never fires it. Forage needs the same follow-up fire or the grant
-- lands in the data table but never reaches the player's screen.
local inventory_updated = replicated_storage:WaitForChild("InventoryUpdated")
function StartMatch.Generate(game_data)
	-- All the individual nature-model references used to be their own
	-- locals (tree_model1, bush_model1, rock_model_dark, etc.) -- grouped
	-- into one table so this whole section only costs 1 local against
	-- Generate's 200-local cap instead of ~19. tree_model5 (DeadTree) was
	-- never referenced anywhere else, so it's dropped rather than ported.
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
	-- [stated] unfinished_structure doesn't line roads -- left out of
	-- road_building_list here regardless of whatever the next interior-
	-- fill design ends up looking like.
	local road_building_list = {apartment_2f, apartment_4f, abandoned_shop}
	local brickwork_house = buildings_folder:WaitForChild("Brickwork House")
	local deroofed_house = buildings_folder:WaitForChild("De-Roofed House")
	local mattress_house = buildings_folder:WaitForChild("Mattress House")
	local scatter_house_list = {brickwork_house, deroofed_house, mattress_house}
	local warehouse_template = buildings_folder:WaitForChild("Warehouse")
	local warehouse_list = {warehouse_template}
	-- [stated] "utilize the large garbage bins as a replacement if using a
	-- smaller building doesn't work" -- its own single-model list, kept
	-- separate the same way warehouse_list is, so it never lines roads and
	-- never competes as a normal fill/fallback pick -- it was only ever
	-- placed by the (now wiped) dead-slot clustering pass, kept around
	-- as a candidate for whatever decor approach the new design uses.
	local large_garbage_bin = buildings_folder:WaitForChild("Large Garbage Bin")
	local garbage_bin_list = {large_garbage_bin}
	-- [stated] "I've added multiple rubble piles/trash piles that I
	-- want to add to the empty slots that didn't get filled with
	-- buildings" -- GetChildren() rather than naming each one by hand
	-- like every other building list here, since this is explicitly an
	-- open-ended pile the user will keep adding more pieces to -- any
	-- model dropped into this folder is automatically in rotation with
	-- no script change needed.
	local rubble_folder = buildings_folder:WaitForChild("Rubble/Garbage")
	local rubble_list = rubble_folder:GetChildren()
	-- [stated] "remove both rubble piles from the spawn pool for the
	-- villages" -- Rubble1/Rubble2 (the two pieces RUBBLE_GROUND_
	-- CORRECTION_BY_NAME below already singles out by name) stay in the
	-- city's rubble_list untouched; villages get this filtered copy
	-- instead, built once here rather than re-filtered on every village.
	local village_rubble_list = {}
	for _, model in ipairs(rubble_list) do
		if model.Name ~= "Rubble1" and model.Name ~= "Rubble2" then
			table.insert(village_rubble_list, model)
		end
	end
	-- [stated] "I've got a prop folder within the buildings folder which
	-- has props I would want to place randomly throughout the multiple
	-- levels of the unfinished structure... would this be a similar case
	-- to the lootfloorareas... several invisible areas where I would want
	-- props spawned" -- same open-ended-folder convention as rubble_list
	-- above (GetChildren() once here, so anything dropped into Props
	-- later is automatically in rotation), grouped with the roll-count
	-- into one table -- same 1-local consolidation as every other
	-- per-feature table in this file, since Generate is already right up
	-- against the 200-local ceiling. Used inside Populate_Building below,
	-- keyed off PropSpawnArea markers the same way it already keys off
	-- LootFloorArea markers for floor loot. Not Unfinished-Structure-
	-- specific -- any building with PropSpawnArea markers picks this up.
	local PROP_SCATTER = {
		pool = buildings_folder:WaitForChild("Props"):GetChildren(),
		-- [stated] "increase the rate that props spawn" -- raised from 1-3
		-- to 2-5 per area. Still a placeholder, tune further if this
		-- still isn't enough.
		min = 10,
		max = 15,
	}
	-- [stated] "add the warehouse to the building placement list for
	-- cities, but still don't make it something to line roads" -- kept
	-- separate from road_building_list so it never lines a road frontage
	-- regardless of how the next interior-fill approach picks from it.
	-- fill_building_list/combined_scatter_list below are both currently
	-- unused leftovers from earlier placement systems -- kept defined
	-- (and measured into BUILDING_METRICS/RUBBLE_METRICS further down)
	-- in case the new design wants them, rather than re-derived later.
	local fill_building_list = {apartment_2f, apartment_4f, abandoned_shop, warehouse_template}
	local combined_scatter_list = {}
	for _, m in ipairs(scatter_house_list) do
		table.insert(combined_scatter_list, m)
		table.insert(combined_scatter_list, m)
	end
	for _, m in ipairs(warehouse_list) do
		table.insert(combined_scatter_list, m)
	end
	local BUILDING_FACING_CORRECTION = {
		[apartment_4f] = math.rad(180),
		-- [stated] "rotate all warehouses by 90 degrees for spawning"
		[warehouse_template] = math.rad(90),
	}
	local BUILDING_GROUND_CORRECTION = {
		-- [stated] "lower the unfinished structure spawn by 1"
		[unfinished_structure] = -44,
		[apartment_2f] = -2,
		[apartment_4f] = 0,
		[brickwork_house] = 1.25,
		[deroofed_house] = 1.75,
		[mattress_house] = 1.5,
		[abandoned_shop] = 0
	}
	-- Both apartment models felt too big -- shrunk uniformly via
	-- Model:ScaleTo, applied in Place_House before positioning so the scale
	-- is consistent everywhere apartment_2f/apartment_4f appear. Placeholder
	-- factors, tune to taste -- anything not listed here defaults to 1.
	local MODEL_SCALE = {
		[apartment_2f] = 0.75,
		[apartment_4f] = 0.75,
	}
	-- Branches on Instance type: Model:GetBoundingBox() handles anything
	-- inside a Model, but a bare MeshPart/Part (some Rubble/Garbage pieces
	-- have no Model wrapper) has no GetBoundingBox -- ExtentsCFrame/
	-- ExtentsSize is the BasePart equivalent, an axis-aligned world-space
	-- bounding box for just that one part.
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
		-- The SAT collision check assumes a building's long side runs along
		-- its own local/world X at zero rotation ("length axis =
		-- (cos(rotation), sin(rotation))"). A template modeled with its long
		-- side along Z instead would silently swap which direction gets the
		-- generous half_length reach and which gets the tighter half_depth.
		-- footprint_offset rotates the COLLISION-only footprint by 90
		-- degrees to correct for that, for any model where size.Z > size.X --
		-- the model's actual VISUAL rotation (facing_correction) is
		-- untouched. Applied at every Building_Too_Close/Record_Building
		-- call site.
		local footprint_offset = (size.Z > size.X) and math.rad(90) or 0
		return {pivot_to_bottom = pivot_to_bottom, length = length, depth = depth, footprint_offset = footprint_offset}
	end
	local BUILDING_METRICS = {}
	for _, model in ipairs(road_building_list) do BUILDING_METRICS[model] = Measure_Building(model) end
	for _, model in ipairs(scatter_house_list) do BUILDING_METRICS[model] = Measure_Building(model) end
	for _, model in ipairs(warehouse_list) do BUILDING_METRICS[model] = Measure_Building(model) end
	for _, model in ipairs(garbage_bin_list) do BUILDING_METRICS[model] = Measure_Building(model) end
	-- unfinished_structure isn't in any of the lists measured above (it
	-- doesn't line roads and was historically left out of selection pools
	-- entirely) -- measured explicitly here so it always has real metrics
	-- ready, regardless of what pool(s) the next placement design ends up
	-- drawing it from.
	BUILDING_METRICS[unfinished_structure] = Measure_Building(unfinished_structure)
	-- [removed] BUILDING_METRICS_BY_NAME and longest_building_length used
	-- to live here -- both only ever served the old raycast-based interior
	-- row system (resolving a raycast hit back to its metrics by name, and
	-- sizing a road-crossing search against the biggest building in
	-- storage). Neither is read by anything in the current rectangle-vs-
	-- rectangle placement system, so both were dropped rather than kept
	-- as unused scaffolding.
	local RUBBLE_METRICS = {}
	for _, model in ipairs(rubble_list) do RUBBLE_METRICS[model] = Measure_Building(model) end
	-- RUBBLE_FACING_CORRECTION_BY_NAME only spins pieces around the
	-- vertical/Y axis (yaw) -- it can't fix a piece lying tilted on its
	-- side, which needs rotation around a horizontal axis instead (see
	-- RUBBLE_TILT_CORRECTION_BY_NAME below). rubble_list is auto-populated
	-- from GetChildren() rather than named one by one, so these corrections
	-- are keyed by Name instead of by model instance.
	local RUBBLE_FACING_CORRECTION_BY_NAME = {}
	-- CFrame.Angles(math.rad(90), 0, 0) tilts a model 90 degrees around its
	-- own local X axis (same convention as DroppedItems.lua's WEAPON_FLAT_
	-- ROTATION). If a piece tips onto an edge instead of lying flat, swap
	-- the rotation to the Z axis instead: CFrame.Angles(0, 0, math.rad(90)).
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
	-- [stated] kept for whenever scatter_house_list goes back into rotation
	-- (see combined_scatter_list note above) — nothing currently reads this.
	local max_scatter_building_half_length = 0
	for _, model in ipairs(scatter_house_list) do
		max_scatter_building_half_length = math.max(max_scatter_building_half_length, BUILDING_METRICS[model].length / 2)
	end
	for _, model in ipairs(warehouse_list) do
		max_scatter_building_half_length = math.max(max_scatter_building_half_length, BUILDING_METRICS[model].length / 2)
	end
	local ground_sink_buffer = 1.5
	-- Resets Lighting every match (the whole map rebuilds from scratch
	-- anyway) so results don't depend on whatever got left tweaked in
	-- Studio. Ambient/OutdoorAmbient set the floor on how dark a shadowed
	-- surface can get; ClockTime near midday keeps shadows short and soft.
	-- Placeholder values, tune to taste.
	-- lighting.Technology can't be set here -- Roblox refuses that write
	-- from a runtime script ("lacking capability RobloxScript") and would
	-- error out of this whole function. Set it once by hand in Studio's
	-- Lighting properties instead (ShadowMap reads cleaner than Voxel on
	-- large flat surfaces like these buildings).
	local function Configure_Lighting()
		lighting.GlobalShadows = true
		lighting.Ambient = Color3.fromRGB(90, 90, 90)
		lighting.OutdoorAmbient = Color3.fromRGB(120, 120, 120)
		lighting.ClockTime = 14
	end
	Configure_Lighting()
	-- [stated] day/night + weather cycle -- stop()'s own doc comment in
	-- DayNightWeather.lua covers why this always stops the previous
	-- match's loop before starting a new one rather than just starting.
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
	local height_scale = 60
	local forest_floor = {Enum.Material.Ground, Enum.Material.Mud, Enum.Material.LeafyGrass, Enum.Material.Grass}
	local water_floor = {Enum.Material.Mud, Enum.Material.Rock, Enum.Material.Sand}
	local mounty_floor = {Enum.Material.Rock, Enum.Material.Slate}
	local field_floor = {Enum.Material.Grass, Enum.Material.Grass, Enum.Material.Grass, Enum.Material.LeafyGrass}
	local settlement_floor = {Enum.Material.Ground, Enum.Material.Concrete, Enum.Material.Concrete, Enum.Material.Concrete,
		Enum.Material.Ground, Enum.Material.Mud, Enum.Material.Concrete}
	-- [stated] "ground should be mainly dirt, with some mud and a little
	-- concrete as well" -- the small villages' own weighting (5 Ground :
	-- 2 Mud : 1 Concrete), separate from the city's concrete-heavy one.
	local village_floor = {Enum.Material.Ground, Enum.Material.Ground, Enum.Material.Ground, Enum.Material.Ground,
		Enum.Material.Ground, Enum.Material.Mud, Enum.Material.Mud, Enum.Material.Concrete}
	local seed_x = math.random(-100000, 100000)
	local seed_z = math.random(-100000, 100000)
	local chunk_count = 0
	local nature_list = {AlpineTree = true, DeadBush = true, DeadTree = true, ForestFern = true}
	-- [stated] "forest fire event... random tree trunks falling near
	-- players" / "rather than 1 point of origin make it 3 points" --
	-- reservoir-sampled (Algorithm R, k=3) during the tree spawn branch
	-- below so exactly 3 DISTINCT trees (chosen uniformly across however
	-- many end up spawning this match) become the fire's origins, with no
	-- need to track every tree placed or know the total count in advance.
	-- tag is read by ForestFireEvent.lua's own LIVE_TREE_TAG constant --
	-- keep both in sync if this ever changes.
	local FOREST_FIRE = {trees_seen = 0, origin_trees = {}, origin_count = 3, tag = "LiveTree"}
	local placed_houses = {}
	local placed_building_footprints = {}
	local settlement_zones = {}
	local settlement_near_padding = 15
	-- How far PAST zone.flat_radius (the radius building placement itself
	-- is meant to use) the terrain is held fully flat, in world studs --
	-- so a building sitting right at that boundary can still have its
	-- outer half overshoot onto solid flat ground instead of already-
	-- blending natural (sloped) terrain. Placeholder, re-tune once the
	-- new placement design knows how close to the edge buildings land.
	local SETTLEMENT_FLAT_TERRAIN_PADDING = 60
	-- [stated] "how much clear buffer should be required between any two
	-- settlement zones" -- replaces the old flat min_distance_between_
	-- settlements constant (300 blocks, sized only for two similarly-
	-- huge cities) with a buffer ON TOP OF each zone's own radius, so it
	-- scales correctly between a city (radius ~100-150 blocks) and a
	-- village (radius ~5-8 blocks) instead of either letting villages
	-- spawn far closer to a city's blend ring than intended, or (if sized
	-- for villages) barely separating two cities at all.
	local SETTLEMENT_SEPARATION_BUFFER = 20
	local target_settlement_count = 2
	local settlement_attempts = 0
	local max_attempts = 100
	-- [stated] "add 5-6 smaller settlements... located in the plains
	-- biomes... shouldn't be more than 70 studs in diameter" -- flat_
	-- radius/radius are in BLOCKS like every other zone field (×block_
	-- size for studs), so a 70-stud diameter caps flat_radius at ~5.8
	-- blocks; kept a bit under that for margin. radius adds a small
	-- blend ring on top, nowhere near a city's +25-50 block one -- a
	-- village this size doesn't need a long gradual transition.
	-- Grouped into one table so this whole village-sizing/attempt-budget
	-- set only costs 1 local against Generate's 200-local cap instead of 7.
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
	-- LootFloorArea marker scatter (see Populate_Building) — short/local
	-- raycast so it stays on whichever floor the marker sits on rather than
	-- punching up into the roof or down through a lower floor.
	local FLOOR_LOOT_RAY_CLEARANCE = 5
	local FLOOR_LOOT_RAY_DISTANCE = 20
	-- Weighted rarity roll for regular building-loot crates — must match
	-- keys in CrateData.lua. Deliberately skewed toward Standard so
	-- Advanced/Elite gear feels earned; SupplyDropEvent's beacon crate is
	-- separately guaranteed Elite regardless of this table, since it's
	-- meant to be the special one.
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
	-- Props get the same automatic bounding-box ground offset as every
	-- other scattered decoration here -- no per-model tuning table needed
	-- as long as a prop's pivot sits roughly centered in its own bounds.
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
	-- Counts entries in a dictionary-style table (keyed by non-sequential
	-- values, e.g. Player objects) — the # operator only works on plain
	-- 1-indexed arrays, so a real dictionary needs this instead.
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
	-- Full rectangle-vs-rectangle separating-axis test: both the candidate
	-- and every already-placed footprint are treated as oriented rectangles
	-- (half_length along their own rotation, half_depth perpendicular), so
	-- the check only clears a spot once there's real clearance between the
	-- two true footprints, plus COLLISION_BUFFER of margin, regardless of
	-- which way either one is facing.
	-- COLLISION_BUFFER=0 means this only rejects a REAL overlap (negative
	-- clearance) -- two footprints placed exactly edge-to-edge (the corner-
	-- jump placement's own zero-gap convention) register as just barely
	-- clear, not too close.
	local COLLISION_BUFFER = 0
	-- exclude_index skips that one entry in placed_building_footprints --
	-- used by the village separation pass below, which re-checks a
	-- building that's already recorded against every OTHER building, not
	-- against its own (stale, pre-push) footprint.
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
				-- If ANY of the four candidate axes (both rectangles' own
				-- length/depth directions) separates the two footprints with
				-- enough margin, they're not too close. Only if NONE of the
				-- four separates them do we call it an overlap.
				if not (Axis_Clear(a_len_x, a_len_z) or Axis_Clear(a_dep_x, a_dep_z) or Axis_Clear(b_len_x, b_len_z) or Axis_Clear(b_dep_x, b_dep_z)) then
					return true
				end
			end
		end
		return false
	end
	-- Returns the new entry's index (shared across placed_houses and
	-- placed_building_footprints, since both always grow together here)
	-- plus the footprint table itself, so a caller that needs to move
	-- this building later (the village separation pass below) can update
	-- both in place without having to search for it again.
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
	local function Darken_Model(model, color)
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Color = color
			end
		end
	end
	local function Anchor_Model(model)
		-- A bare MeshPart/Part (no Model wrapper, same case Measure_Building
		-- now handles above) has no descendants of its own to anchor via
		-- the loop below -- GetDescendants() only looks at children, never
		-- the instance itself -- so without this it would get cloned,
		-- parented to workspace, and immediately fall under gravity,
		-- unanchored.
		if model:IsA("BasePart") then
			model.Anchored = true
		end
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
			end
		end
	end
	-- Rename (or duplicate and rename) any part in a building model to
	-- exactly "ColorVariant" to make it eligible for per-building color
	-- variation. ONE random shift is rolled per building INSTANCE (not per
	-- part), then applied to every ColorVariant part's own authored color
	-- -- so a whole building reads as one coherent, slightly different
	-- shade rather than each part drifting independently.
	local COLOR_VARIANT_PART_NAME = "ColorVariant"
	-- How far, per R/G/B channel (0-255), the shift can go in either
	-- direction. Placeholder, tune to taste.
	local COLOR_SHIFT_RANGE = 20
	-- ColorVariant2 picks an entirely different color rather than shifting
	-- the part's own authored shade. A small curated palette of light,
	-- airy tones keeps every pick a believable material color instead of
	-- risking something saturated/neon. Placeholder palette, tune to taste.
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
	-- A Union/NegateOperation's .Color only renders when its own
	-- UsePartColor property is true -- left false (common when a union
	-- keeps each source part's color baked in per-face), setting .Color
	-- would silently do nothing. Forcing UsePartColor on for any
	-- PartOperation is safe here since this only touches parts already
	-- opted in by name (ColorVariant/ColorVariant2).
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
		-- One palette pick per building INSTANCE -- every ColorVariant2
		-- part/group in a given building lands on this SAME alternate
		-- color, reading as one coherent re-paint.
		local variant2_color = COLOR_VARIANT2_PALETTE[math.random(#COLOR_VARIANT2_PALETTE)]
		-- Individual parts named ColorVariant: each shifts from ITS OWN
		-- authored color, so two differently-colored parts (a red brick
		-- and a white window frame, say) stay visually distinct from each
		-- other -- just each nudged by the same shift.
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") and part.Name == COLOR_VARIANT_PART_NAME then
				Apply_Part_Color(part, Shift_Color(part.Color, shift_r, shift_g, shift_b))
			end
		end
		-- A GROUP (Model) named ColorVariant is handled differently from an
		-- individual part with that name: every BasePart inside the group
		-- converges on ONE identical final color, anchored off the first
		-- part found inside it -- so a whole wall segment, say, reads as a
		-- single uniform repaint instead of a patchwork of independently-
		-- shifted bricks, frames, trim, etc. Still uses the same building-
		-- wide shift, so multiple groups in one building move together.
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
		-- ColorVariant2: same individual-part-vs-group split as ColorVariant
		-- above, except every tagged part/group is set directly to the one
		-- palette color rolled for this building instance, rather than
		-- shifting from whatever its own authored color was.
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
	-- Crates spawn into their own folder rather than loose in workspace,
	-- separate from building clones. Not currently load-bearing for
	-- collision -- every ground/placement raycast in this file already
	-- uses an Include-only filter on just the terrain -- but keeps crates
	-- cleanly separated from building geometry for any raycast added later
	-- that isn't terrain-only.
	local loot_crate_folder = Instance.new("Folder")
	loot_crate_folder.Name = "SpawnedLootCrates"
	loot_crate_folder.Parent = workspace
	-- Renamed from Spawn_Building_Loot now that it also handles the prop
	-- scatter below -- "loot" stopped covering what this does.
	local function Populate_Building(building)
		local spawned_pos = {}
		local spawned_count = 0
		-- [found] "many of the loot items and crates... tend to be
		-- floating rather than actually on the floor" -- every item here
		-- already raycasts down to find the real floor (crates, floor
		-- loot, props all do), but each pass only ever excluded its OWN
		-- marker type from its own ray -- never anything already spawned
		-- by an earlier pass, or an earlier iteration of the SAME pass.
		-- In a dense multi-marker building like Unfinished Structure, a
		-- later item's downward ray can hit the TOP of an earlier crate/
		-- prop/dropped item sitting near its marker instead of reaching
		-- the floor underneath it -- which reads as floating, especially
		-- once that earlier object (a crate above all) gets picked up
		-- and vanishes out from under it. exclude_list is now ONE shared,
		-- growing list every raycast in this function reads from --
		-- seeded with every marker up front (so no marker of any of the
		-- three types can block any other pass's ray either), then every
		-- spawned crate/item/prop is appended to it (and the RaycastParams
		-- refreshed) the instant it's placed, so nothing placed earlier
		-- in this same building can ever block a later raycast again.
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
				-- [found] crates were floating -- CrateSpawn markers were
				-- never forced invisible/non-collide/non-query the way
				-- LootFloorArea/PropSpawnArea already are, so one left
				-- visible/solid in Studio stayed that way in-game, and
				-- (now that Spawn_Crate_At raycasts off it below) a solid
				-- marker sitting in the ray's path would otherwise hit
				-- itself instead of the real floor underneath it.
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
		-- [stated] "4 story buildings having a minimum of 2 crates and max
		-- of 5, 2 story apartments having a minimum of 1 crate and max of 3
		-- and shops having no minimum and a max of 1 crate" — keyed by the
		-- building's own Name, which Instance:Clone() preserves (same
		-- convention the old Warehouse-only special case already relied
		-- on). Anything not listed here (Warehouse, the scatter houses if
		-- they ever get CrateSpawn markers too) keeps the previous
		-- default — no minimum, max 2 — rather than silently picking up a
		-- min/max nobody asked for it to have.
		local BUILDING_CRATE_CONFIG = {
			["4 Floor Apartment"] = {Min = 2, Max = 5},
			["2 Floor Apartment"] = {Min = 1, Max = 3},
			["Abandoned Shop"] = {Min = 0, Max = 1},
			Warehouse = {Min = 0, Max = 4}, -- unchanged from the old special-case
			-- [stated] "include it for the crate spawn sweep with it having
			-- a minimum of 0 crates and max of 1"
			["Large Garbage Bin"] = {Min = 0, Max = 1},
			-- [stated] De-Roofed House's new Crate Spawns/CrateSpawn marker
			-- -- "max of 1 crates spawning with a minimum of 0"
			["De-Roofed House"] = {Min = 0, Max = 1},
			-- [stated] "I've fleshed out the brickwork house as well with
			-- the same crate values as the de-roofed house"
			["Brickwork House"] = {Min = 0, Max = 1},
			-- [stated] "for unfinished buildings make the minimum crate
			-- spawn 2 and max 4"
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
		-- [found] "crates... tend to be floating rather than actually on
		-- the floor" -- crates used to PivotTo marker.Position directly,
		-- with no raycast and no ground offset at all, unlike literally
		-- every other placement system in this file. A crate's pivot
		-- sitting at its own geometric center (the normal default) then
		-- floats it up by half its own height above wherever the marker
		-- itself happens to be. Fixed the same way LootFloorArea/
		-- PropSpawnArea already are: a short raycast off the marker to
		-- find the real floor underneath it (robust to the marker not
		-- being placed pixel-perfect, and to multi-level/ramp buildings
		-- like Unfinished Structure), plus the same automatic bounding-
		-- box ground offset Get_Base_Ground_Offset already gives every
		-- other piece of scattered decor.
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
			-- [found] a second crate placed near this one would otherwise
			-- raycast straight onto THIS crate's roof instead of the
			-- floor -- see the shared exclude_list note above.
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
		-- The chance-based pass above can leave a building under its
		-- configured minimum (even at zero, on bad rolls) — force
		-- additional crates onto still-eligible markers (same spacing rule,
		-- no chance check this time since these are no longer optional)
		-- until the minimum is met or there's nowhere left to put one.
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
		-- Place a BasePart named LootFloorArea flat on a room's floor in
		-- Studio (any size/rotation -- footprint read from Size/CFrame) to
		-- mark it as scatterable. Uses a SHORT raycast starting just above
		-- the marker rather than a long outdoor-style one, since on an
		-- upper floor a long-range ray would hit the roof first instead of
		-- that floor's own surface. Marker collection/CanCollide-CanQuery-
		-- Transparency forcing now happens once up front (see exclude_list
		-- above) rather than here.
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
						-- [found] a second roll landing near the first
						-- would otherwise raycast onto the first item's
						-- top instead of the floor -- see exclude_list.
						if spawned_ok and typeof(item_part) == "Instance" then
							Exclude_From_Now_On(item_part)
						end
					else
						warn(("[FloorLoot] %s: raycast MISSED from %s (marker %s, marker world pos %s)"):format(building.Name, tostring(ray_origin), marker:GetFullName(), tostring(marker.Position)))
					end
				end
			end
		end
		-- [stated] "props I would want to place randomly throughout the
		-- multiple levels of the unfinished structure... would this be a
		-- similar case to the lootfloorareas... several invisible areas
		-- where I would want props spawned and we could have the props
		-- spawned in randomly throughout those spaces" -- structurally
		-- identical to the LootFloorArea pass above (same per-marker
		-- random-point-in-footprint + short downward raycast so an upper
		-- floor hits that floor's own surface, not the roof or a floor
		-- below), just a separate marker name (PropSpawnArea) and pool
		-- (PROP_SCATTER.pool) so loot and prop density tune independently
		-- and a building can have either without the other. Folded into
		-- this same function (rather than its own, like the water-drink
		-- feature learned the hard way) since Generate is already right
		-- up against the 200-local ceiling -- these locals land in this
		-- function's own budget instead.
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
						-- [found] a second prop landing near the first
						-- would otherwise raycast onto the first prop's
						-- top instead of the floor -- see exclude_list.
						Exclude_From_Now_On(prop)
						-- Defensive, same reasoning as the LootFloorArea
						-- markers' forced CanCollide/Transparency above --
						-- Props is a brand-new folder, so unlike the
						-- long-established nature-decoration templates
						-- there's no track record every piece in it is
						-- already anchored in Studio.
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
			-- Terrain is held fully flat out to this radius, past
			-- zone.flat_radius itself -- see SETTLEMENT_FLAT_TERRAIN_PADDING
			-- above for why. Whatever fills zone.flat_radius with buildings
			-- should still bound itself by zone.flat_radius directly, so
			-- this only widens how far the guaranteed-flat ground extends
			-- past the building layout, never how far out buildings
			-- themselves get placed. Clamped a few blocks inside
			-- zone.radius so there's always at least a small blend ring
			-- left.
			--
			-- [stated] a village's own radius (~6-8 blocks total) is far
			-- too small for the city-tuned padding/clamp above -- the flat
			-- 60-stud padding alone would blow past a village's entire
			-- radius, and the "-5 blocks" clamp margin (fine when radius
			-- is 100+ blocks) would eat nearly all of it instead. Villages
			-- use their own flat_radius directly with no extra padding,
			-- relying on their (small but present) radius-flat_radius gap
			-- for the blend ring instead.
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
			-- [stated] "ground should be mainly dirt, with some mud and a
			-- little concrete" -- villages get their own weighting
			-- instead of the city's concrete-heavy one, picked via the
			-- zone kind Get_Settlement_Context now tracks.
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
		-- Scale BEFORE PivotTo: ScaleTo resizes everything around the
		-- model's current pivot without moving that pivot, so scaling first
		-- (while the clone is still sitting wherever its template lives)
		-- and then rigidly repositioning the already-scaled model lands it
		-- exactly at `position` — same as the unscaled path, just smaller.
		if scale and scale ~= 1 then
			house:ScaleTo(scale)
		end
		-- [fixed] "how can I tilt the trashpile by 90 degrees? it's
		-- spawning tilted halfway out of the ground" -- rotation_y is a
		-- single YAW angle (rotation around the vertical axis only), which
		-- can never fix a piece that's lying on the wrong SIDE to begin
		-- with -- that needs an actual tilt around a horizontal axis
		-- instead. RUBBLE_TILT_CORRECTION (built above, keyed by model
		-- instance same as every other per-model correction table) is a
		-- fixed CFrame rather than a bare angle, applied AFTER rotation_y
		-- here: world orientation ends up rotation_y∘tilt, which means the
		-- tilt is resolved in the model's OWN frame first (correcting its
		-- inherent lying-down-wrong orientation) and the already-corrected
		-- result then spins around the world vertical axis with everything
		-- else -- same order DroppedItems.lua uses for WEAPON_FLAT_ROTATION.
		-- Every other model (not in the table) gets CFrame.new() here,
		-- i.e. no change from before.
		local tilt_correction = RUBBLE_TILT_CORRECTION[house_model] or CFrame.new()
		local cframe_rotation = CFrame.Angles(0, rotation_y, 0) * tilt_correction
		house:PivotTo(CFrame.new(position.X, position.Y, position.Z) * cframe_rotation)
		house.Parent = workspace
		Populate_Building(house)
		-- Returned so a caller that may need to physically move this clone
		-- later (the village separation pass below) has the instance in
		-- hand instead of having to search workspace for it.
		return house
	end
	-- [stated] "generate rows of buildings across the settlement matching
	-- the zone's rotation angle... no space between buildings... distance
	-- between rows [is] the average depth of the previous row plus 10...
	-- find the centerline of the settlement based on the rotation angle
	-- and make a road there. [Then] check all rows for those closer than
	-- 10 studs away from the centerline road and delete those rows...
	-- no other adjustment for now" -- first real pass at the new layout,
	-- deliberately simple. One direction for the whole settlement (no
	-- mirrored sides) -- along/perp are just zone.rotation's own local
	-- Z/X, every row sweeps across the full flat-zone diameter in the
	-- same +perp direction, and every building in the settlement shares
	-- the same facing. A row's length is still bounded by the circular
	-- zone's own chord at that row's distance from center -- that's
	-- plain geometry (how wide the circle actually is there), not a
	-- collision check -- so rows near the settlement's edge are short
	-- and rows through the middle are long, same shape the circle
	-- already implies.
	--
	-- Three steps, in order, per the spec above: Plan_Settlement_Rows
	-- works out every row (and every building in it) first, raycasting
	-- ground height as it goes since that's a read, not a spawn, and
	-- hands back a list of row objects -- nothing is instanced yet.
	-- Carve_Settlement_Road then cuts the road into terrain along the
	-- same centerline the rows were planned around. Generate_Settlement_
	-- Structures itself does the "delete rows too close to the road"
	-- step -- a plain distance check between each row's own span and
	-- the road's -- before finally handing the SURVIVING rows' buildings
	-- to Spawn_Planned_Settlement_Buildings. No row gets shrunk or
	-- nudged to make room; a row that's too close is simply dropped
	-- whole.
	local BUILDING_ROW_FACING_OFFSET = math.rad(-90)
	local SETTLEMENT_ROW_GAP = 30
	local ROAD_WIDTH = 28
	-- [stated] "add a random gap between buildings with a 25% chance to
	-- occur, adding a 5 to 10 stud wide gap between buildings" -- rolled
	-- per slot-to-slot step during planning (stage 1), same place the
	-- zero-gap cursor advance already happens, so it's baked into every
	-- building's position before the spawn wave (stage 2) ever runs.
	local BUILDING_GAP_CHANCE = 0.25
	local BUILDING_GAP_MIN = 5
	local BUILDING_GAP_MAX = 10
	-- [stated] "for the warehouses and unfinished structures, guarantee
	-- they have gaps between them and the other buildings in their row
	-- with a gap of at least 10 to 20 studs" -- a GUARANTEED (not rolled)
	-- gap, used instead of the ordinary BUILDING_GAP_CHANCE roll whenever
	-- either side of a slot-to-slot step is one of these two large
	-- building types.
	local LARGE_BUILDING_GAP_MIN = 10
	local LARGE_BUILDING_GAP_MAX = 20
	local function Is_Large_Building(choice)
		return choice == warehouse_template or choice == unfinished_structure
	end
	-- [stated] "for every building in each row, add a 20% chance to have
	-- that building shift up to 5 studs towards or away from the
	-- previous row to help give a more staggered natural feel" -- a
	-- small per-building nudge along the PERP axis only (the direction
	-- between rows, not along the row itself), rolled independently for
	-- every building. Purely a position jitter on that one building's
	-- own final spot -- row.perp_offset/row.depth bookkeeping (row-to-
	-- row spacing, road-row selection) are untouched.
	local BUILDING_STAGGER_CHANCE = 0.2
	local BUILDING_STAGGER_MAX = 5
	local function Plan_Settlement_Rows(zone, world_x, world_z, along, perp)
		local flat_radius_studs = zone.flat_radius * block_size
		local facing = zone.rotation + BUILDING_ROW_FACING_OFFSET
		-- [stated] "Buildings to be generated are the shops, apartment
		-- buildings, warehouses, and unfinished structures" -- one flat
		-- pool, every slot picks any one of the four with no caps and no
		-- special handling for the warehouse/unfinished structure.
		local pool = {apartment_2f, apartment_4f, abandoned_shop, warehouse_template, unfinished_structure}
		local rows = {}
		local perp_offset = -flat_radius_studs
		while perp_offset < flat_radius_studs do
			local row_len_radius = math.sqrt(math.max(0, flat_radius_studs ^ 2 - perp_offset ^ 2))
			-- cursor is this row's own leading edge, same corner-jump
			-- convention as before -- always swept in the same (+1)
			-- direction now, since there's no dead-slot bookkeeping left
			-- that cared which way alternating rows swept.
			local cursor = -row_len_radius
			local row_buildings = {}
			local row_depth_total, row_count = 0, 0
			-- [stated] large-building gap guarantee needs to know BOTH
			-- neighbors of a slot-to-slot step before deciding the gap,
			-- so the choice is now rolled (and the gap resolved) at the
			-- TOP of the loop, before the cursor advance it depends on --
			-- previous_choice is the last slot rolled, placed or not,
			-- same as the cursor advance already ignored a failed ground
			-- raycast.
			local previous_choice = nil
			while true do
				-- One random pick per slot, no retrying a smaller one if
				-- it doesn't fit -- "no other constraints or checks" --
				-- so a row simply ends the moment its current pick can't
				-- fit in whatever chord is left.
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
					-- [stated] "have them rotate 180 randomly compared to
					-- the other buildings which are dependent on the side
					-- of the road they're on" -- warehouses/unfinished
					-- structures still get the same side-of-road 180 flip
					-- as everyone else (applied later, in Generate_
					-- Settlement_Structures), this is a SEPARATE 50/50
					-- flip layered on top of it, independent of which
					-- side of the road the row ends up on.
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
						-- footprint_offset corrects ONLY the collision/
						-- record rotation (see Measure_Building) -- the
						-- actual visual placement rotation above is
						-- untouched.
						collision_rotation = rotation + metrics.footprint_offset,
					})
					row_depth_total = row_depth_total + depth
					row_count = row_count + 1
				end
				cursor = next_cursor
				previous_choice = choice
			end
			-- [stated] "distance between rows to be the average depth of
			-- the previous row plus 10" -- a row that placed nothing
			-- still advances by SETTLEMENT_ROW_GAP alone (average_depth
			-- falls back to 0), so the sweep always makes progress and
			-- can't stall out near the circle's tapering edges.
			local average_depth = (row_count > 0) and (row_depth_total / row_count) or 0
			table.insert(rows, {perp_offset = perp_offset, depth = average_depth, buildings = row_buildings})
			perp_offset = perp_offset + average_depth + SETTLEMENT_ROW_GAP
		end
		return rows
	end
	-- [stated] "find the centerline of the settlement based on the
	-- rotation angle and make a road there" -- same per-segment flush-
	-- with-terrain carve the old road carving used (raycast each
	-- segment so the road follows uneven ground, clear the volume above
	-- to Air, fill a thin slab below with Asphalt), just rebuilt here
	-- since it's wanted again. Spans the settlement's full flat-radius
	-- diameter, same as the rows do.
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
	-- Stage 2: instance everything the planning/road/filter steps above
	-- already worked out. Record_Building still runs per placement so
	-- Spawn_Wildlife's spacing check (Too_Close, off placed_houses)
	-- keeps treating settlement buildings as occupied ground -- that's
	-- bookkeeping for a DIFFERENT system, not a constraint on this one.
	local function Spawn_Planned_Settlement_Buildings(buildings)
		for _, entry in ipairs(buildings) do
			Place_House(entry.choice, entry.position, entry.rotation, true, entry.scale)
			Record_Building(entry.position, entry.half_length, entry.half_depth, entry.collision_rotation)
			task.wait()
		end
	end
	-- [stated] "after everything has been spawned in... raycast pointing
	-- down for the whole settlement, finding regions where there aren't
	-- buildings then roll through the rubble and trash list and place
	-- them randomly throughout the settlement" -- walks a grid across
	-- the zone's own flat circle (same along/perp basis every other
	-- settlement function already uses), skipping any cell too close to
	-- an already-placed building (reusing Building_Too_Close against
	-- placed_building_footprints, which Record_Building already filled
	-- in during the building spawn wave above) or to the road strip,
	-- then rolls a chance per surviving cell to drop a random rubble/
	-- trash piece there with a fully random yaw. "Dense" density picked:
	-- a tight grid, high per-cell chance, and a small clearance margin.
	local RUBBLE_SCATTER_GRID_STEP = 12
	local RUBBLE_SCATTER_CHANCE = 0.2
	local RUBBLE_CLEARANCE = 5
	-- [stated] "reduce the rate at which garbage spawns in the villages" --
	-- same grid step/clearance as the city, just a lower per-cell chance
	-- (40% of the city's), so villages read as noticeably sparser rather
	-- than matching the city's density. Placeholder, easy to retune.
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
		-- [stated] "select 1 row near the middle of the settlement of
		-- buildings, and build the road along that... this way its
		-- distance to either row is equal and less large as it's
		-- directly between 2 rows" -- replaces the old fixed-at-zone-
		-- center road entirely. The road no longer gets carved at
		-- perp_offset 0 and then has rows checked against it for overlap
		-- -- instead, the row whose own CENTER (perp_offset + depth/2) is
		-- closest to 0 is picked first, that one row's buildings are
		-- dropped, and the road is carved centered on exactly that row's
		-- position instead of the zone's geometric center. Since the
		-- sweep already spaces every row by (previous row's average
		-- depth + SETTLEMENT_ROW_GAP), the distance from the road's
		-- center to the row immediately before and the row immediately
		-- after both work out to the same (road_row.depth / 2 + GAP) --
		-- genuinely equal on both sides, and bounded by one row's depth
		-- rather than however large a randomly-straddling deleted band
		-- happened to be.
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
		-- [stated] "rotate every building 180 before the deleted row and
		-- revert the 180 rotation for buildings after the row deletion" --
		-- the whole settlement shares one facing direction, which puts
		-- the FAR side of the road (the back half of the sweep) front-on
		-- to it already; the near side (before the selected row) faces
		-- away and needs the 180 flip instead. flip_rotation starts ON
		-- and switches OFF the moment the selected road row is reached,
		-- so every row before it gets spun 180 (both the visual rotation
		-- and its paired collision_rotation, so they stay in sync), and
		-- every row after it keeps its original, unflipped rotation.
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
	-- [stated] "let's drop all of the previous logic for the village
	-- spawning and start fresh... similar to the rows of the large
	-- settlements" -- replaces the center+ring layout entirely with a row
	-- sweep: pick a building, record its longest side (BUILDING_METRICS.
	-- length, the same field the settlement rows already use), advance
	-- half that length from the row's own starting edge, place it with a
	-- random rotation; every building after that advances by (previous
	-- building's half length + this building's half length + gap_buffer)
	-- instead, so buildings sit gap_buffer studs apart edge-to-edge. 2
	-- rows per village (row_count), aligned to the village's own
	-- zone.rotation -- the same along/perp local axes Plan_Settlement_
	-- Rows already uses, not world X/Z. Each row's distance cap is its own
	-- chord length (2x the village's flat_radius at that row's offset)
	-- plus overshoot_buffer, so a row reliably sweeps a bit past the true
	-- circular edge instead of always stopping short of it -- otherwise
	-- every building would land inside the circle by construction and the
	-- final bounds check below would never actually delete anything.
	-- [stated]: "one last check on each building identifying if any of
	-- the building is outside the settlement bounds which if it is it
	-- will be deleted" -- see the bounds-check pass at the end of
	-- Generate_Village_Structures.
	local VILLAGE_ROW = {
		row_count = 2,
		gap_buffer = 10,
		-- Placeholder magnitude for how far past a row's own chord the
		-- sweep is allowed to run before stopping -- tune if villages end
		-- up losing too many/too few buildings to the bounds check.
		overshoot_buffer = 40,
	}
	-- [stated] "add the rubble/trash spawning to the small settlements as
	-- well" -- same grid-walk/clearance/chance approach as Scatter_
	-- Settlement_Rubble above, reusing the same RUBBLE_SCATTER_* constants
	-- for consistent density, but simplified: villages have no road and no
	-- along/perp facing convention to exclude a band for, so this just
	-- walks a plain world-axis-aligned grid across the village's flat
	-- circle instead of a rotated one.
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
	-- Works out one row's buildings (position/rotation/footprint) without
	-- instancing anything yet -- same plan-then-spawn split Plan_
	-- Settlement_Rows/Spawn_Planned_Settlement_Buildings already use, so
	-- the bounds check in Generate_Village_Structures can run against
	-- every row's buildings before any of them exist in the world.
	-- perp_offset is this row's own fixed distance from village center
	-- along the perp axis (which of the row_count parallel rows this is);
	-- along/perp are the same zone.rotation-derived local axes Generate_
	-- Settlement_Structures already builds for the large settlements.
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
			-- [stated] "advance the row half of that building's length"
			-- for the first building (relative to the row's own starting
			-- point), then for every building after "add half that
			-- distance to the half distance of the current building with
			-- an addition +10... advance by that position further down
			-- the row" -- a center-to-center step of half_length(prev) +
			-- half_length(this) + gap_buffer, leaving exactly gap_buffer
			-- studs of clearance between the two footprints' facing edges.
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
		-- [stated] "2 rows in total for each village, with their starting
		-- points selected so that each row is placed equally from each
		-- other to the edge of the village" -- splits the village's full
		-- perp-axis diameter into row_count + 1 equal segments, so every
		-- row sits exactly one segment from the next (and from the two
		-- edges) -- for row_count = 2 that's perp offsets at -flat_radius/3
		-- and +flat_radius/3.
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
		-- [stated] "one last check on each building identifying if any of
		-- the building is outside the settlement bounds which if it is it
		-- will be deleted" -- checks all 4 corners of each building's own
		-- footprint (not just its center point) against the village's
		-- flat circle, so a building that's mostly inside but still pokes
		-- a corner past the edge still gets caught. Removals are
		-- collected first and applied in descending index order so an
		-- earlier removal can't shift the index a later one still needs.
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
	-- [stated] "settlements cannot spawn within a certain distance of the
	-- edges of the map... make sure the settlement doesn't clip into the
	-- walls... more fair so some players don't spawn right in front of a
	-- city while others don't" -- bounded against wall_flats_start
	-- (where terrain itself already starts flattening toward the wall)
	-- rather than the hard map_radius edge, since that ramp is already
	-- "the wall" visually and the player spawn ring (Arena_Spawns, at
	-- map_radius*block_size - 40) sits further out again -- keeping a
	-- settlement's own outer blend ring (zone.radius) inside this bound
	-- means every settlement stays off the wall's ramp AND the same
	-- minimum distance from the spawn ring, no matter which direction
	-- it ends up in. SETTLEMENT_WALL_BUFFER reuses clear_wall_distance's
	-- existing 50-block margin (same one natural decor already treats
	-- as "safely clear of the wall") but gets its own named constant --
	-- a whole settlement is a much bigger thing to keep clear than a
	-- tree, so it's worth tuning independently later.
	local SETTLEMENT_WALL_BUFFER = 50
	-- [stated] shared by both the city loop below and the village loop
	-- after it -- true when candidate_center (with its own candidate_
	-- radius) would land too close to an EXISTING zone of either kind,
	-- using each zone's own radius rather than a flat distance (see
	-- SETTLEMENT_SEPARATION_BUFFER above for why).
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
		-- Rolling radius before dist lets the DIST range itself be
		-- clamped so this settlement's outer edge (dist + radius) can
		-- never land past the wall buffer in the first place -- no
		-- separate reject-and-retry needed for that case, just a
		-- smaller candidate ring for a bigger-than-average settlement.
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
	-- [stated] "add 5-6 smaller settlements throughout the map... located
	-- in the plains biomes" -- a village candidate is checked against
	-- Compute_Terrain_Data's own height/moisture biome logic (the exact
	-- same thing that will classify this ground during the real terrain
	-- pass), sampled at the center plus the 4 cardinal edges of its flat
	-- radius so a candidate spanning a biome boundary gets rejected too,
	-- not just one whose center happens to land on plains. That same
	-- Compute_Terrain_Data call already reports biome="Settlement" for
	-- anywhere too close to an existing zone, so this also doubles as
	-- part of the separation check (on top of Settlement_Overlaps_
	-- Existing, which still runs first since it's far cheaper).
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
	-- [stated] no plants in the mountains, none underwater, and none in the
	-- flattened rim ring around the arena wall where players spawn (except
	-- a couple sparse dead stumps/dead bushes there). Matches the height>50
	-- threshold already used elsewhere for "this is mountain terrain"
	-- (mounty_floor material, dark rock choice), and wall_flats_start —
	-- already the boundary Compute_Terrain_Data flattens height toward
	-- going into the wall — for "this is the spawn rim".
	local MOUNTAIN_PLANT_CEILING = 50
	local RIM_DEAD_DECOR_CHANCE = 0.004
	local min_height = -60
	-- [stated] "a random number of bushes within the map, like crates,
	-- where holding down E allows you to forage through the bush for
	-- berries... a foraged class food item... random amount between 2-5...
	-- once a bush has been foraged it can no longer be foraged and the
	-- prompt to interact will disappear" -- only the LIVE bush variant
	-- qualifies (NATURE_MODELS.bush_live, not the dead decorative one),
	-- rolled independently each time one is about to be placed below.
	-- "Preserved Berries" is ItemData's existing Foraged-tier food entry
	-- (Value 200, Weight 0.5) whose own comment already flags it as
	-- waiting on exactly this system -- granted straight into the
	-- triggering player's inventory via PlayerInventory.add_item, per
	-- [stated] "the player would receive" (no ground-drop step).
	local FORAGE = {
		chance = 0.1,
		berry_min = 2,
		berry_max = 5,
		item_name = "Preserved Berries",
		hold_duration = 1,
		max_distance = 10,
		-- [stated] "shaded a red color, which reverts to the normal green
		-- after it's been foraged" -- see the Highlight instance in
		-- Try_Make_Bush_Forageable below: it overlays this color on top of
		-- the bush rather than touching the mesh's own material, so
		-- "reverts to normal" is just destroying the overlay.
		highlight_color = Color3.fromRGB(200, 30, 30),
	}
	-- [SettlementDebug]-style temporary counter -- see the summary print
	-- right after the terrain/decoration loop below. Safe to delete both
	-- once forageable bushes are confirmed showing up in Studio.
	local forageable_bush_count = 0
	-- 964 forageable bushes got tagged last run but none were spotted in
	-- Studio -- that count proves the server-side logic (chance roll, part
	-- lookup, tint, prompt creation) IS running, so this is narrowing down
	-- whether it's "never walked within 10 studs of one of the 964 across
	-- a 700-stud map (bushes don't spawn near settlements at all, so
	-- nothing shows up if you stayed near spawn)" vs. an actual rendering
	-- bug. Printing exact world positions for the first few lets you
	-- teleport/walk straight to a KNOWN one instead of searching blind.
	local FORAGE_SAMPLE_PRINT_LIMIT = 5
	-- Bush clones can be a bare MeshPart/Part (no Model wrapper -- same
	-- case Anchor_Model/Measure_Building already handle) or a Model, so a
	-- ProximityPrompt needs a BasePart found either way before it can be
	-- parented.
	local function Get_Interactable_Part(instance)
		if instance:IsA("BasePart") then
			return instance
		end
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	-- [stated] "the bush shows up just fine, doesn't look any different
	-- though" -- the Color3-tint approach was the bug: setting Color3 on a
	-- TEXTURED MeshPart doesn't paint over it, it MULTIPLIES with the
	-- mesh's own texture colors channel-by-channel. A mostly-green texture
	-- times a red tint lands on a barely-different dark muddy green, not
	-- red -- exactly "shows up fine, doesn't look any different". A
	-- Highlight instance sidesteps this entirely: it draws an outline/fill
	-- overlay on top of whatever the model actually looks like, completely
	-- independent of its material or texture, and needs no snapshot/
	-- restore bookkeeping -- the original mesh is never touched, so
	-- "reverts to normal" is just Destroy()ing the highlight.
	local function Try_Make_Bush_Forageable(bush_instance, bush_choice)
		if bush_choice ~= NATURE_MODELS.bush_live then
			return
		end
		if math.random() >= FORAGE.chance then
			return
		end
		-- [stated] the model's real named children are Leaves1/Leaves2/
		-- Leaves3/Branches -- the generic "first BasePart found" search
		-- landed on a part buried inside Branches (visually just a thin
		-- stick, barely visible, and likely screened by the bush's OWN
		-- other geometry from most angles -- see RequiresLineOfSight
		-- below). Leaves1 is a named, stable, visually prominent part on
		-- every Live Bush clone -- use it directly instead of guessing.
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
		-- Occluded mode only draws where the part is actually visible --
		-- same self-occlusion issue as RequiresLineOfSight above: Leaves1
		-- sitting behind the bush's OWN other leaves/branches from a given
		-- angle would render the highlight invisible even though it's
		-- genuinely there. AlwaysOnTop draws through that (and through
		-- anything else in front of it), matching the same fix already
		-- applied to the prompt for the same reason.
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		-- [stated] "can we highlight 1 of the leaf sections" -- adorning
		-- just Leaves1 (not the whole bush_instance) is what actually
		-- limits the glow to one leaf cluster rather than the whole model.
		highlight.Adornee = part
		highlight.Parent = bush_instance
		forageable_bush_count += 1
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ForagePrompt"
		prompt.ActionText = "Forage"
		prompt.ObjectText = "Bush"
		prompt.HoldDuration = FORAGE.hold_duration
		prompt.MaxActivationDistance = FORAGE.max_distance
		-- Standing right on top of the prompt's part still showed nothing
		-- last test, with color/prompt state both confirmed correct
		-- server-side -- the remaining likely explanation is the bush's
		-- OWN other branches/leaves sitting between the camera and
		-- whichever one part the prompt is parented to, failing the
		-- default line-of-sight check. A bush being forageable shouldn't
		-- depend on an unobstructed sightline through its own foliage.
		prompt.RequiresLineOfSight = false
		prompt.Parent = part
		-- Color/highlight state confirmed correct server-side last round;
		-- keeping PromptShown/PromptHidden for one more test to confirm
		-- RequiresLineOfSight=false actually fixes the no-interaction
		-- issue. Safe to delete once confirmed working.
		if forageable_bush_count <= FORAGE_SAMPLE_PRINT_LIMIT then
			local sample_index = forageable_bush_count
			print(("[Forage] sample #%d | bush=%s | part=%s | pos=%s"):format(
				sample_index,
				bush_instance:GetFullName(),
				part.Name,
				tostring(part.Position)
				))
			prompt.PromptShown:Connect(function()
				print(("[Forage] sample #%d: PromptShown"):format(sample_index))
			end)
			prompt.PromptHidden:Connect(function()
				print(("[Forage] sample #%d: PromptHidden"):format(sample_index))
			end)
		end
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
			-- [found] matches RequestChecker.lua's own convention -- every
			-- add_item/remove_item call there is immediately followed by
			-- these two, which are what the inventory UI and carried-weight
			-- display actually refresh on.
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
											-- Algorithm R, k=3: the first 3 trees seen fill the
											-- reservoir outright; every tree after that has a
											-- origin_count/trees_seen chance of bumping a
											-- uniformly-random existing slot out, which keeps the
											-- final 3 a uniform random sample of every tree placed
											-- this match, not just a bias toward whichever 3
											-- happened to spawn last.
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
											-- [stated] the spawn rim gets no plants EXCEPT a couple sparse dead
											-- stumps (mulchfood_list, already the "Dead" folder models) or the
											-- one dead bush already in bush_list (Dead Bush2) — never the live
											-- bush, so pick explicitly from mulch + that one dead bush rather
											-- than the whole bush_list.
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
	-- Temporary, same as the forageable_bush_count counter above -- tells
	-- you right in the output how many bushes this match actually made
	-- forageable, since that number isn't otherwise visible without
	-- walking the whole map. Delete both once you've confirmed it's
	-- working and happy with the count.
	print(("[Forage] %d bushes made forageable this match"):format(forageable_bush_count))
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
	-- [stated] forest fire event origins -- whichever 3 trees the
	-- reservoir sampling above landed on, handed off to
	-- ArenaEventScheduler via game_data the same way every other
	-- per-match value already crosses that boundary.
	game_data.forest_fire_origin_trees = FOREST_FIRE.origin_trees
	-- [stated] "make some test prints so we can try to diagnose this
	-- issue" -- confirms trees actually spawned and the reservoir sample
	-- actually landed on something, plus prints exact world positions so
	-- you can fly/teleport straight to a known origin instead of
	-- searching a huge map by eye. Safe to delete once the fire is
	-- confirmed visibly starting.
	print(("[ForestFireDebug] StartMatch: %d trees spawned this match, %d origin tree(s) selected"):format(FOREST_FIRE.trees_seen, #FOREST_FIRE.origin_trees))
	for i, origin_tree in ipairs(FOREST_FIRE.origin_trees) do
		print(("[ForestFireDebug]   origin #%d: %s at %s"):format(i, origin_tree:GetFullName(), tostring(origin_tree:GetPivot().Position)))
	end
end
local function Countdown_Player_Movement(player, enabled)
	local walk_speed = 16
	local sprint_speed = 28
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
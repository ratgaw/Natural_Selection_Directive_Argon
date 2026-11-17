-- Animal Frenzy: every animal turns hyper-aggressive for a while, extra
-- animals spawn, and a share of animals become permanently infected (their hits
-- infect players, see PlayerInfection). Cure stations appear the first time.
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local Terrain = workspace.Terrain
local ArenaManagerFolder = ServerScriptService:WaitForChild("ArenaManager")
local WildLifeManager = require(ArenaManagerFolder:WaitForChild("WildLifeManager"))
local SettlementData = require(ArenaManagerFolder:WaitForChild("SettlementData"))
local PlayerInfection = require(ArenaManagerFolder:WaitForChild("PlayerInfection"))
local event_warning = ReplicatedStorage:WaitForChild("EventWarning")
-- Tells clients to show each cure station on the minimap. Stations are never
-- removed, so there's no matching "removed" event.
local cure_station_spawned = ReplicatedStorage:WaitForChild("CureStationSpawned")
local AnimalFrenzyEvent = {}
-- Placeholders, tune once tested.
local FRENZY_DURATION = 45 -- seconds the non-infected animals stay hyper-aggressive
local EXTRA_SPAWN_COUNT = 8 -- reinforcements called in from the forest each trigger
-- Share of all live animals (after reinforcements) that become infected.
local INFECTED_RATIO = 0.55
local CURE_STATION_COUNT = 3
-- Reinforcement species. Must exist in WildLifeManager's WILDLIFE_STATS or
-- the spawn silently fails.
local FOREST_SPECIES = {"Bear", "Wolf", "Fox", "Deer", "Raccoon"}
-- Only spawn the cure stations once per match, even if Animal Frenzy fires
-- more than once -- "a few cure stations on the map", not a growing pile.
local cure_stations_spawned = false
-- Same tags as StartMatch/ForestFireEvent.
local LIVE_TREE_TAG = "LiveTree"
local LIVE_PLANT_TAG = "LivePlant"
-- Terrain-only raycast so stations don't land on top of trees.
local GROUND_RAYCAST_START_HEIGHT = 1000
local GROUND_RAYCAST_DISTANCE = 2000
local terrain_raycast_params = RaycastParams.new()
terrain_raycast_params.FilterType = Enum.RaycastFilterType.Include
terrain_raycast_params.FilterDescendantsInstances = {Terrain}
local function Get_Ground_Height(x, z)
	local result = workspace:Raycast(Vector3.new(x, GROUND_RAYCAST_START_HEIGHT, z), Vector3.new(0, -GROUND_RAYCAST_DISTANCE, 0), terrain_raycast_params)
	return result and result.Position.Y or nil
end
-- Walks up to the tagged ancestor (tree parts can be nested groups).
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
-- Clears tagged trees/plants around a station's spot before building it.
local CLEAR_VEGETATION_RADIUS = 10
local function Clear_Vegetation_Near(position)
	local overlap_params = OverlapParams.new()
	overlap_params.FilterType = Enum.RaycastFilterType.Exclude
	overlap_params.FilterDescendantsInstances = {}
	local removed = {}
	local removed_count = 0
	for _, part in ipairs(workspace:GetPartBoundsInRadius(position, CLEAR_VEGETATION_RADIUS, overlap_params)) do
		local plant_or_tree = Find_Tagged_Ancestor(part, LIVE_TREE_TAG) or Find_Tagged_Ancestor(part, LIVE_PLANT_TAG)
		if plant_or_tree and not removed[plant_or_tree] then
			removed[plant_or_tree] = true
			removed_count += 1
			plant_or_tree:Destroy()
		end
	end
	return removed_count
end
-- Usually near a settlement, sometimes anywhere -- where players are likely
-- to pass.
local function Get_Spawn_Point()
	local zones = SettlementData.get_zones()
	local block_size = SettlementData.get_block_size()
	if #zones > 0 and math.random() < 0.7 then
		local zone = zones[math.random(#zones)]
		local angle = math.random() * math.pi * 2
		local dist = zone.flat_radius + math.random(20, 60) -- just outside the settlement, not inside it
		return zone.center.X * block_size + math.cos(angle) * dist * block_size, zone.center.Y * block_size + math.sin(angle) * dist * block_size
	end
	local map_radius = workspace:GetAttribute("MapRadius") or 2100
	local angle = math.random() * math.pi * 2
	local dist = math.random() * map_radius * 0.9
	return math.cos(angle) * dist, math.sin(angle) * dist
end
local function Spawn_Reinforcements(count)
	for i = 1, count do
		local species = FOREST_SPECIES[math.random(#FOREST_SPECIES)]
		local x, z = Get_Spawn_Point()
		WildLifeManager.spawn_animal(species, x, z)
		task.wait(0.15)
	end
end
-- Cure station: stone pedestal, two-section metal shaft, pyramid cap, and a
-- glowing white rune strip with a light so it's visible from a distance.
local OBELISK_SHAFT_WIDTH = 4 -- width of the lower, wider shaft section
local OBELISK_LOWER_HEIGHT = 14
local OBELISK_UPPER_HEIGHT = 8 -- the narrower section the shaft steps in to
local OBELISK_CAP_HEIGHT = 5
local OBELISK_METAL_COLOR = Color3.fromRGB(58, 60, 64) -- dark weathered metal
local OBELISK_PEDESTAL_COLOR = Color3.fromRGB(45, 45, 47) -- stone base, slightly darker
local OBELISK_ACCENT_COLOR = Color3.fromRGB(255, 255, 255) -- rune strip and light
local function Build_Cure_Station(position)
	local base = Instance.new("Part")
	base.Name = "CureStation"
	base.Size = Vector3.new(8, 1.5, 8)
	base.Anchored = true
	base.CanCollide = true
	base.Material = Enum.Material.Slate
	base.Color = OBELISK_PEDESTAL_COLOR
	base.CFrame = CFrame.new(position)
	base.Parent = workspace
	-- Lower shaft section -- wider, forms the obelisk's visible base taper
	-- against the narrower upper section stacked on top of it.
	local lower_shaft = Instance.new("Part")
	lower_shaft.Name = "ObeliskLowerShaft"
	lower_shaft.Size = Vector3.new(OBELISK_SHAFT_WIDTH + 1, OBELISK_LOWER_HEIGHT, OBELISK_SHAFT_WIDTH + 1)
	lower_shaft.Anchored = true
	lower_shaft.CanCollide = true
	lower_shaft.Material = Enum.Material.Metal
	lower_shaft.Color = OBELISK_METAL_COLOR
	lower_shaft.CFrame = base.CFrame * CFrame.new(0, base.Size.Y / 2 + OBELISK_LOWER_HEIGHT / 2, 0)
	lower_shaft.Parent = base
	-- Upper shaft section -- narrower, continues the taper up to the cap.
	local upper_shaft = Instance.new("Part")
	upper_shaft.Name = "ObeliskUpperShaft"
	upper_shaft.Size = Vector3.new(OBELISK_SHAFT_WIDTH, OBELISK_UPPER_HEIGHT, OBELISK_SHAFT_WIDTH)
	upper_shaft.Anchored = true
	upper_shaft.CanCollide = true
	upper_shaft.Material = Enum.Material.Metal
	upper_shaft.Color = OBELISK_METAL_COLOR
	upper_shaft.CFrame = lower_shaft.CFrame * CFrame.new(0, OBELISK_LOWER_HEIGHT / 2 + OBELISK_UPPER_HEIGHT / 2, 0)
	upper_shaft.Parent = base
	-- SpecialMesh only changes rendering, so turn off collision on the cap.
	local cap = Instance.new("Part")
	cap.Name = "ObeliskCap"
	cap.Size = Vector3.new(OBELISK_SHAFT_WIDTH, OBELISK_CAP_HEIGHT, OBELISK_SHAFT_WIDTH)
	cap.Anchored = true
	cap.CanCollide = false
	cap.CanQuery = false
	cap.Material = Enum.Material.Metal
	cap.Color = OBELISK_METAL_COLOR
	cap.CFrame = upper_shaft.CFrame * CFrame.new(0, OBELISK_UPPER_HEIGHT / 2 + OBELISK_CAP_HEIGHT / 2, 0)
	cap.Parent = base
	local cap_mesh = Instance.new("SpecialMesh")
	cap_mesh.MeshType = Enum.MeshType.Pyramid
	cap_mesh.Parent = cap
	local rune = Instance.new("Part")
	rune.Name = "ObeliskRune"
	rune.Size = Vector3.new(0.4, OBELISK_UPPER_HEIGHT * 0.8, 0.6)
	rune.Anchored = true
	rune.CanCollide = false
	rune.CanQuery = false
	rune.Material = Enum.Material.Neon
	rune.Color = OBELISK_ACCENT_COLOR
	rune.CFrame = upper_shaft.CFrame * CFrame.new(0, 0, OBELISK_SHAFT_WIDTH / 2 + 0.05)
	rune.Parent = base
	local light = Instance.new("PointLight")
	light.Name = "ObeliskGlow"
	light.Color = OBELISK_ACCENT_COLOR
	light.Brightness = 2
	light.Range = 30
	light.Parent = rune
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Cure Infection"
	prompt.ObjectText = "Cure Station"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 2
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = base
	prompt.Triggered:Connect(function(player)
		if PlayerInfection.is_infected(player) then
			PlayerInfection.cure(player)
		end
	end)
	cure_station_spawned:FireAllClients(base)
end
local function Spawn_Cure_Stations(count)
	if cure_stations_spawned then
		return
	end
	cure_stations_spawned = true
	for i = 1, count do
		local x, z = Get_Spawn_Point()
		local y = Get_Ground_Height(x, z)
		if y then
			Clear_Vegetation_Near(Vector3.new(x, y, z))
			Build_Cure_Station(Vector3.new(x, y + 0.5, z))
		end
	end
end
local function Send_Warnings()
	for _, player in ipairs(Players:GetPlayers()) do
		event_warning:FireClient(player, "Animal Frenzy", 5)
	end
end
function AnimalFrenzyEvent.trigger(game_data)
	Send_Warnings()
	-- Spawn reinforcements first so start_frenzy includes them.
	Spawn_Reinforcements(EXTRA_SPAWN_COUNT)
	Spawn_Cure_Stations(CURE_STATION_COUNT)
	-- Counted after reinforcements, matching what start_frenzy sees.
	local alive_count = #WildLifeManager.get_active_animals()
	local infected_count = alive_count > 0 and math.max(1, math.floor(alive_count * INFECTED_RATIO)) or 0
	WildLifeManager.start_frenzy({duration = FRENZY_DURATION, infected_count = infected_count})
end
return AnimalFrenzyEvent
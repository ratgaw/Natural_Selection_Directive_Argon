-- Animal Frenzy arena event: every living animal on the map turns
-- hyper-aggressive with unlimited aggro range for a fixed duration, a
-- fresh wave of predators is called in from the forest to join the
-- rampage, and a random handful of animals come out of it PERMANENTLY
-- infected -- hyper-aggressive forever, and able to pass the infection to
-- any player they land a hit on (see PlayerInfection.lua for what being
-- infected does, and WildLifeManager.lua's Threat_Tick for the actual
-- infect-on-hit call). A few cure stations are dropped on the map the
-- first time this fires, so an infected player has somewhere to go.
-- Registered into the shared scheduler by ArenaManager.lua, same as
-- ZombieEvent/SupplyDropEvent.
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
-- [stated] "is it possible to add their locations to every player's
-- minimap as a white square icon" -- same RemoteEvent-driven marker
-- pattern MinimapControl.lua already uses for SupplyDropEvent's beacon
-- crate (BeaconCrateSpawned/BeaconCrateLooted): server fires the whole
-- station instance to every client, the client turns that into a Frame
-- positioned via the minimap's existing World_To_Minimap_Position. Add a
-- RemoteEvent named exactly "CureStationSpawned" under ReplicatedStorage
-- in Studio (same place EventWarning/MatchStarted/BeaconCrateSpawned
-- already live) -- this script only ever WaitForChild's it, same as every
-- other RemoteEvent reference in this file, it doesn't create one itself.
-- No corresponding "removed" event -- unlike the beacon crate, cure
-- stations are never destroyed once placed (Spawn_Cure_Stations only ever
-- runs once per match), so there's nothing for the minimap to ever clear.
local cure_station_spawned = ReplicatedStorage:WaitForChild("CureStationSpawned")
local AnimalFrenzyEvent = {}
-- Placeholders, tune once tested.
local FRENZY_DURATION = 45 -- seconds the non-infected animals stay hyper-aggressive
local EXTRA_SPAWN_COUNT = 8 -- reinforcements called in from the forest each trigger
-- [stated] "increase the ratio of those infected to 55% of all animals on
-- the map" -- replaces the old INFECTED_COUNT_MIN/MAX fixed 2-5 range
-- (same regardless of how many animals were actually out there) with a
-- share of whatever's currently alive, computed in trigger() below right
-- after reinforcements spawn -- so a bigger population infects more
-- animals in absolute terms, not just the same small handful every time.
local INFECTED_RATIO = 0.55
local CURE_STATION_COUNT = 3
-- Forest-flavored species only -- mirrors StartMatch's WILDLIFE_SPAWN_TABLE
-- biome tags (Bear/Wolf/Fox/Deer/Raccoon all include Forest). Buffalo and
-- Rat are Field/Settlement specialists and deliberately excluded from the
-- "more animals emerge from the forest" reinforcement wave.
local FOREST_SPECIES = {"Bear", "Wolf", "Fox", "Deer", "Raccoon"}
-- Only spawn the cure stations once per match, even if Animal Frenzy fires
-- more than once -- "a few cure stations on the map", not a growing pile.
local cure_stations_spawned = false
-- Must match LIVE_TREE_TAG/LIVE_PLANT_TAG in StartMatch.lua's spawn loops
-- (same tags ForestFireEvent.lua keys off of) -- used below by
-- Clear_Vegetation_Near to find actual tree/plant Models near a spawn
-- point, not just raw parts.
local LIVE_TREE_TAG = "LiveTree"
local LIVE_PLANT_TAG = "LivePlant"
-- [stated] "the obelisks if spawning in the woods will spawn on top of
-- the trees" -- two separate problems, both fixed here. First: this
-- raycast had NO RaycastParams at all, so it stopped at whatever it hit
-- FIRST going straight down -- a tree's canopy/trunk, a rock, anything --
-- same "ray hits the top of the tree" bug ForestFireEvent.lua's
-- Compute_Base_Position hit and fixed the same way: an Include filter
-- that can ONLY ever hit Terrain, so the obelisk's height always comes
-- from the real ground, never a tree it happened to clip on the way down.
local GROUND_RAYCAST_START_HEIGHT = 1000
local GROUND_RAYCAST_DISTANCE = 2000
local terrain_raycast_params = RaycastParams.new()
terrain_raycast_params.FilterType = Enum.RaycastFilterType.Include
terrain_raycast_params.FilterDescendantsInstances = {Terrain}
local function Get_Ground_Height(x, z)
	local result = workspace:Raycast(Vector3.new(x, GROUND_RAYCAST_START_HEIGHT, z), Vector3.new(0, -GROUND_RAYCAST_DISTANCE, 0), terrain_raycast_params)
	return result and result.Position.Y or nil
end
-- Walks up from a hit part to whichever ancestor actually carries the tag
-- -- same reasoning as ForestFireEvent.lua's own Find_Tagged_Ancestor: a
-- tree's Trunk/Leaves could themselves be Models sitting a level or two
-- below the actual tagged tree instance.
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
-- [stated] "whenever the stations spawn they will clear away all
-- vegetation within a 10 stud radius of the obelisk prior to it spawning
-- to ensure it spawns nicely" -- second half of the fix above: even with
-- the ground-height raycast now correct, a tree standing right where the
-- obelisk lands would still visually clip through its shaft. Finds every
-- tagged tree/plant Model whose parts overlap a sphere around the spawn
-- point and destroys each one once (GetPartBoundsInRadius can return
-- several parts belonging to the same Model, so this dedupes by Model
-- before destroying).
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
-- Same "mostly near a settlement, sometimes anywhere" bias ZombieEvent
-- uses for its own spawn point -- reused here so reinforcements read as
-- "coming out of the treeline near where the fight already is" rather
-- than landing evenly across the whole map, and so cure stations end up
-- somewhere players are likely to actually pass by.
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
-- [stated] "for the healing stations can we make them like metal
-- obelisks?" -- replaces the flat neon platform + glowing beam with an
-- actual tapered monument: a stone pedestal, a two-section metal shaft
-- that narrows partway up (so it genuinely reads as tapering rather than
-- just a tall box), and a 4-sided pyramid capstone (Enum.MeshType.Pyramid
-- on a plain Part -- a built-in legacy mesh shape, same "no custom asset
-- needed" approach this project already uses for Fire/Smoke, rather than
-- hand-building a point out of WedgeParts). Still deliberately simple/
-- visible rather than wired into the minimap yet -- revisit once
-- PlayerMinimap's API for a custom marker is confirmed; I don't have that
-- file in front of me to guess its shape. The glowing beam is gone (it
-- doesn't fit a metal-obelisk look), so a vertical glowing rune strip
-- embedded in the shaft's face plus a PointLight near the top take over
-- its job of staying visible/findable at a distance.
local OBELISK_SHAFT_WIDTH = 4 -- width of the lower, wider shaft section
local OBELISK_LOWER_HEIGHT = 14
local OBELISK_UPPER_HEIGHT = 8 -- the narrower section the shaft steps in to
local OBELISK_CAP_HEIGHT = 5
local OBELISK_METAL_COLOR = Color3.fromRGB(58, 60, 64) -- dark weathered metal
local OBELISK_PEDESTAL_COLOR = Color3.fromRGB(45, 45, 47) -- stone base, slightly darker
local OBELISK_ACCENT_COLOR = Color3.fromRGB(255, 255, 255) -- [stated] "change the led strip to white"
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
	-- Pyramid capstone -- CanCollide off since SpecialMesh only changes
	-- how the part RENDERS, not its physical shape; leaving collision on
	-- would hitbox the cap as if it were still a full box poking out past
	-- the visible point.
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
	-- Glowing rune strip down the upper shaft's face -- what actually
	-- keeps this findable/visible at a distance now that the old beam is
	-- gone, and still reads as "this is the cure station" via the same
	-- [stated] "change the led strip to white" -- accent color below.
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
	-- Fired once the whole obelisk is assembled, not right after `base` is
	-- created -- GetPivot() on the client just needs base.CFrame, already
	-- set at creation, but waiting until here keeps this call next to
	-- everything else that's "last thing this function does" rather than
	-- wedged in the middle of the obelisk's own part-by-part assembly.
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
	-- Reinforcements spawn BEFORE start_frenzy so they're already on the
	-- map when start_frenzy snapshots every active animal -- the fresh
	-- arrivals get swept into the same aggression/infection roll as
	-- everything already out there instead of wandering in calm.
	Spawn_Reinforcements(EXTRA_SPAWN_COUNT)
	Spawn_Cure_Stations(CURE_STATION_COUNT)
	-- Taken HERE (after reinforcements spawn, before start_frenzy) so this
	-- count matches exactly what start_frenzy is about to snapshot via its
	-- own get_active_animals() call -- same ordering the old fixed-range
	-- roll relied on, just reading the population first instead of
	-- ignoring it.
	local alive_count = #WildLifeManager.get_active_animals()
	local infected_count = alive_count > 0 and math.max(1, math.floor(alive_count * INFECTED_RATIO)) or 0
	WildLifeManager.start_frenzy({duration = FRENZY_DURATION, infected_count = infected_count})
end
return AnimalFrenzyEvent
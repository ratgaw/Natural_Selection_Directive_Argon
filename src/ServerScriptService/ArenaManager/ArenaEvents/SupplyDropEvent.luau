local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local ArenaManager = ServerScriptService:WaitForChild("ArenaManager")
local CrateLoot = require(ArenaManager:WaitForChild("CrateLoot"))
local beacon_crate_spawned = ReplicatedStorage:WaitForChild("BeaconCrateSpawned")
local SupplyDropEvent = {}

-- Starting guesses — tune once tested.
local REGULAR_CRATE_COUNT = 3
local NEAR_PLAYER_MIN_DIST = 40
local NEAR_PLAYER_MAX_DIST = 120
local BEACON_PER_PLAYERS = 10 -- one beacon crate per this many alive players
local BEACON_RARITY = "Elite" -- must exist as a key in CrateData.lua — see note below
local DROP_HEIGHT = 150 -- studs above ground the crate starts falling from
local DROP_DURATION = 6 -- seconds to reach the ground

local function Get_Crate_Template()
	return ServerStorage:WaitForChild("CrateList"):WaitForChild("LootCrate")
end

local function Get_Ground_Height(x, z)
	local result = workspace:Raycast(Vector3.new(x, 1000, z), Vector3.new(0, -2000, 0))
	return result and result.Position.Y or nil
end

local function Get_Beacon_Crate_Count(alive_count)
	return math.max(1, math.floor(alive_count / BEACON_PER_PLAYERS))
end

local function Count_Alive(game_data)
	local count = 0
	for _ in pairs(game_data.participants) do
		count += 1
	end
	return count
end

local function Get_Alive_Characters(game_data)
	local characters = {}
	for player in pairs(game_data.participants) do
		local character = player.Character
		if character and character:FindFirstChild("HumanoidRootPart") then
			table.insert(characters, character)
		end
	end
	return characters
end

-- Drops the crate from high above, prompt disabled until it lands. A parachute
-- could be attached here and removed on landing.
local function Drop_Crate(x, ground_y, z, crate)
	crate:PivotTo(CFrame.new(x, ground_y + DROP_HEIGHT, z))
	crate.Parent = workspace

	-- Disable the crate's own embedded prompt as soon as it exists, so
	-- there's no window where it's interactable mid-fall.
	task.spawn(function()
		local lower_crate = crate:WaitForChild("LowerCrate")
		local prompt = lower_crate:WaitForChild("ProximityPrompt")
		prompt.Enabled = false
	end)

	local cframe_value = Instance.new("CFrameValue")
	cframe_value.Value = crate:GetPivot()

	cframe_value.Changed:Connect(function(new_cframe)
		crate:PivotTo(new_cframe)
	end)

	local target_cframe = CFrame.new(x, ground_y, z)
	local tween = TweenService:Create(
		cframe_value,
		TweenInfo.new(DROP_DURATION, Enum.EasingStyle.Linear),
		{Value = target_cframe}
	)

	tween.Completed:Connect(function()
		cframe_value:Destroy()

		local lower_crate = crate:FindFirstChild("LowerCrate")
		local prompt = lower_crate and lower_crate:FindFirstChildOfClass("ProximityPrompt")
		if prompt then
			prompt.Enabled = true
		end
	end)

	tween:Play()
end

local function Spawn_Regular_Crate(near_position)
	local angle = math.random() * math.pi * 2
	local dist = math.random(NEAR_PLAYER_MIN_DIST, NEAR_PLAYER_MAX_DIST)
	local x = near_position.X + math.cos(angle) * dist
	local z = near_position.Z + math.sin(angle) * dist
	local y = Get_Ground_Height(x, z)
	if not y then
		return
	end

	local crate = Get_Crate_Template():Clone()
	CrateLoot.register_crate(crate)
	Drop_Crate(x, y, z, crate)
end

-- The one crate visible on every player's minimap, regardless of upgrade
-- tier — deliberately not gated, since its whole point is drawing a fight.
local function Spawn_Beacon_Crate(near_position)
	local y = Get_Ground_Height(near_position.X, near_position.Z)
	if not y then
		return
	end

	local crate = Get_Crate_Template():Clone()
	crate:SetAttribute("Rarity", BEACON_RARITY)
	crate:SetAttribute("IsBeacon", true)
	CrateLoot.register_crate(crate)
	Drop_Crate(near_position.X, y, near_position.Z, crate)

	beacon_crate_spawned:FireAllClients(crate)
end

function SupplyDropEvent.trigger(game_data)
	local characters = Get_Alive_Characters(game_data)
	if #characters == 0 then
		return
	end

	for i = 1, REGULAR_CRATE_COUNT do
		local target = characters[math.random(#characters)]
		Spawn_Regular_Crate(target.HumanoidRootPart.Position)
	end

	-- Beacon crate(s) drop at the centroid of all alive players — roughly
	-- "in the middle of the action" rather than favoring anyone specific.
	local centroid = Vector3.new(0, 0, 0)
	for _, character in ipairs(characters) do
		centroid += character.HumanoidRootPart.Position
	end
	centroid = centroid / #characters

	local beacon_count = Get_Beacon_Crate_Count(Count_Alive(game_data))
	for i = 1, beacon_count do
		Spawn_Beacon_Crate(centroid)
		task.wait(0.2)
	end
end

return SupplyDropEvent

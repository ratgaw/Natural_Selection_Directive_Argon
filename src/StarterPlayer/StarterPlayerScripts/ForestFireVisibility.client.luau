
-- Thickens fog near active forest fires for this player only. Must be client-side:
-- a server change to Lighting.FogEnd would affect every player at once.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")

-- Must match FIRE_SOURCE_TAG in ForestFireEvent.
local FIRE_SOURCE_TAG = "ForestFireActiveSource"

-- Fog is thickest within FOG_INNER_RADIUS of a fire (FogEnd = MIN_FOG_END),
-- gone beyond FOG_OUTER_RADIUS, and blends in between.
local FOG_INNER_RADIUS = 30
local FOG_OUTER_RADIUS = 100
local MIN_FOG_END = 15
local SMOKE_FOG_COLOR = Color3.fromRGB(90, 85, 80)
-- Per-second catch-up rate toward the target fog (framerate independent).
local FOG_LERP_SPEED = 3

local local_player = Players.LocalPlayer

-- The fog to return to when no fire is near.
local baseline_fog_end = Lighting.FogEnd
local baseline_fog_color = Lighting.FogColor

local function Flat_Distance(a, b)
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

-- Flat distance to the nearest active fire, or math.huge if none.
local function Distance_To_Nearest_Fire(position)
	local nearest = math.huge
	for _, anchor in ipairs(CollectionService:GetTagged(FIRE_SOURCE_TAG)) do
		if anchor:IsA("BasePart") then
			local distance = Flat_Distance(position, anchor.Position)
			if distance < nearest then
				nearest = distance
			end
		end
	end
	return nearest
end

RunService.Heartbeat:Connect(function(dt)
	local character = local_player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local distance = Distance_To_Nearest_Fire(root.Position)
	-- 0 = no smoke influence at all, 1 = fully inside the smoke
	local smoke_factor
	if distance <= FOG_INNER_RADIUS then
		smoke_factor = 1
	elseif distance >= FOG_OUTER_RADIUS then
		smoke_factor = 0
	else
		smoke_factor = 1 - (distance - FOG_INNER_RADIUS) / (FOG_OUTER_RADIUS - FOG_INNER_RADIUS)
	end
	local target_fog_end = baseline_fog_end + (MIN_FOG_END - baseline_fog_end) * smoke_factor
	local target_fog_color = baseline_fog_color:Lerp(SMOKE_FOG_COLOR, smoke_factor)
	local alpha = math.clamp(FOG_LERP_SPEED * dt, 0, 1)
	Lighting.FogEnd += (target_fog_end - Lighting.FogEnd) * alpha
	Lighting.FogColor = Lighting.FogColor:Lerp(target_fog_color, alpha)
end)
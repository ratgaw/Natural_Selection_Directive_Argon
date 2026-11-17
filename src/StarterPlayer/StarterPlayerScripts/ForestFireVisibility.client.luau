
-- LocalScript -- StarterPlayerScripts (same folder as CombatInput.lua and
-- SwingConeTelegraph.lua).
--
-- [stated] "is it possible to add smoky effects/sight limiting near the
-- active fires? I want the player to have little visibility when inside
-- the fire, with a lot of smoke effects coming off of it." The smoke
-- particles themselves (everyone sees them) are added server-side in
-- ForestFireEvent.lua, parented right alongside each Fire+PointLight pair.
-- This script is the other half: the actual sight-limiting. That has to
-- happen per-player, not server-side -- Lighting is a service every client
-- renders from its own copy of, but a SERVER script changing Lighting.FogEnd
-- replicates that change to EVERY client at once, which would blind every
-- player in the match regardless of where they are standing. A LocalScript
-- changing Lighting only ever affects the one client it's running on, which
-- is exactly "low visibility for whoever is actually near/in the fire."
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")

-- Must match FIRE_SOURCE_TAG in ForestFireEvent.lua -- tagged on the same
-- invisible anchor Part every Fire/PointLight/Smoke trio is parented to, so
-- the tag's lifetime already exactly matches "this specific fire is
-- currently burning" (it disappears the instant the anchor is destroyed,
-- whether that's Schedule_Fire_Extinguish's timer, Extinguish_Tree, or the
-- end-of-match cleanup) -- no separate state to keep in sync from here.
local FIRE_SOURCE_TAG = "ForestFireActiveSource"

-- Distance (studs, flat-ignoring-Y the same way ForestFireEvent.lua's own
-- Flat_Distance works for damage/fall checks) from the nearest active fire
-- anchor at which the smoke effect is at its strongest/weakest. Inside
-- FOG_INNER_RADIUS visibility bottoms out at MIN_FOG_END studs -- "little
-- visibility... inside the fire" -- genuinely blinding, not just hazy.
-- Beyond FOG_OUTER_RADIUS there's no effect at all. Between the two, the
-- effect blends smoothly with distance rather than snapping on/off, so it
-- reads as drifting smoke you walk into rather than a wall.
local FOG_INNER_RADIUS = 30
local FOG_OUTER_RADIUS = 100
local MIN_FOG_END = 15
local SMOKE_FOG_COLOR = Color3.fromRGB(90, 85, 80)
-- How quickly the player's actual Lighting.FogEnd/FogColor catches up to
-- the target each frame -- higher = snappier, lower = a slower, smokier
-- drift as they cross in and out of range. Expressed as a per-second rate,
-- applied against dt below, so it behaves the same regardless of framerate.
local FOG_LERP_SPEED = 3

local local_player = Players.LocalPlayer

-- Captured once, before this script ever overrides anything -- whatever
-- FogEnd/FogColor the match's own Lighting setup left in place (or
-- Roblox's own default, if nothing else sets one) is what "fully clear, no
-- fire nearby" lerps back toward, rather than hardcoding a specific
-- "normal" value that might fight with however lighting/weather/time-of-day
-- is configured elsewhere in this project.
local baseline_fog_end = Lighting.FogEnd
local baseline_fog_color = Lighting.FogColor

local function Flat_Distance(a, b)
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

-- Nearest active fire anchor's flat distance to `position`, or math.huge
-- if no forest fire event is currently running (or every fire it started
-- has since burned out) -- GetTagged naturally returns an empty list then,
-- no separate "is there even an active fire" check needed.
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
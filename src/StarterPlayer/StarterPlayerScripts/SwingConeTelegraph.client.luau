-- Ground cone showing the attack's range and angle during a swing, visible only
-- to the swinging player (it's created by this LocalScript, so it never
-- replicates). Built from a fan of thin flat "spoke" parts. Follows the player
-- every frame for the swing's length, then fades. Uses a swing-id counter to
-- know when a newer swing has replaced this one.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local equipment_updated = ReplicatedStorage:WaitForChild("EquipmentUpdated")
-- Fired at only the attacking player by PlayerCombat when a swing plays.
local swing_telegraph_event = ReplicatedStorage:WaitForChild("SwingTelegraph")
local ItemData = require(ReplicatedStorage:WaitForChild("ItemData"))
local local_player = Players.LocalPlayer
-- Placeholders, tune once tested -- same "starting guess" spirit as
-- everywhere else in this project.
local ANGULAR_STEP_DEGREES = 3 -- target spacing between spokes; smaller reads more solid
local POOL_SIZE = 40 -- enough spokes for the widest cone (100 degrees); Get_Spoke_Plan widens the step beyond that
local MIN_SPOKE_WIDTH = 0.3 -- studs, floor so a very short/narrow cone doesn't render as an invisible sliver
local SPOKE_WIDTH_SAFETY_FACTOR = 1.4 -- multiplies the exact no-gap width so float rounding never leaves a hairline gap between spokes
local SPOKE_THICKNESS = 0.05 -- studs, near-flat
-- Overlapping semi-transparent spokes brighten where they overlap; the small
-- per-spoke height stagger (SPOKE_Y_STAGGER) stops z-fighting.
local SPOKE_COLOR = Color3.fromRGB(255, 60, 60)
local SPOKE_TRANSPARENCY = 0.55
local SPOKE_Y_STAGGER = 0.001 -- studs of height difference between adjacent spokes -- imperceptible as a height gap but enough to give the renderer an unambiguous draw order
local GROUND_CLEARANCE = 0.05 -- studs above the raycast-detected ground, avoids z-fighting with the floor
local GROUND_RAYCAST_DISTANCE = 50
-- Used only if the server sends a swing length of 0.
local FALLBACK_LINGER_DURATION = 0.4
local EXTRA_LINGER_PADDING = 0.1 -- seconds added past the real swing length so the cone doesn't cut off on the exact last frame
local FADE_DURATION = 0.25 -- seconds to fade out after the linger window
local telegraph_folder = Instance.new("Folder")
telegraph_folder.Name = "SwingConeTelegraph"
telegraph_folder.Parent = Workspace
-- Spokes are built once and reused.
local spoke_pool = {}
for i = 1, POOL_SIZE do
	local spoke = Instance.new("Part")
	spoke.Name = "Spoke"
	spoke.Anchored = true
	spoke.CanCollide = false
	spoke.CanQuery = false
	spoke.CanTouch = false
	spoke.CastShadow = false
	spoke.Material = Enum.Material.Neon
	spoke.Color = SPOKE_COLOR
	spoke.Transparency = 1 -- hidden until a swing actually uses it
	spoke.Size = Vector3.new(MIN_SPOKE_WIDTH, SPOKE_THICKNESS, 1)
	spoke.Parent = telegraph_folder
	spoke_pool[i] = spoke
end
local active_tweens = {} -- [spoke] = the currently-running fade Tween, if any
local function Rotate_Around_Y(direction, angle_rad)
	return CFrame.fromAxisAngle(Vector3.new(0, 1, 0), angle_rad):VectorToWorldSpace(direction)
end
-- Spoke count and spacing for a ConeAngle, spanning edge to edge (capped at
-- POOL_SIZE).
local function Get_Spoke_Plan(cone_angle_deg)
	local count = math.floor(cone_angle_deg / ANGULAR_STEP_DEGREES) + 1
	count = math.clamp(count, 2, POOL_SIZE)
	local step_rad = math.rad(cone_angle_deg / (count - 1))
	return count, step_rad
end
local ground_raycast_params = RaycastParams.new()
ground_raycast_params.FilterType = Enum.RaycastFilterType.Exclude
-- Ground height under the root, or an estimate from HipHeight if the ray misses.
local function Get_Ground_Position(character, root, humanoid)
	ground_raycast_params.FilterDescendantsInstances = {character}
	local result = Workspace:Raycast(root.Position, Vector3.new(0, -GROUND_RAYCAST_DISTANCE, 0), ground_raycast_params)
	if result then
		return result.Position + Vector3.new(0, GROUND_CLEARANCE, 0)
	end
	local fallback_drop = humanoid.HipHeight + root.Size.Y / 2
	return root.Position - Vector3.new(0, fallback_drop, 0) + Vector3.new(0, GROUND_CLEARANCE, 0)
end
local function Hide_Spoke(spoke)
	local existing_tween = active_tweens[spoke]
	if existing_tween then
		existing_tween:Cancel()
		active_tweens[spoke] = nil
	end
	spoke.Transparency = 1
end
local current_swing_id = 0
local active_update_connection = nil -- RenderStepped connection running while a cone is actively tracking the player; nil once it's idle or fading
-- Hides every spoke (a new swing replaces the previous cone).
local function Cancel_Active_Cone()
	if active_update_connection then
		active_update_connection:Disconnect()
		active_update_connection = nil
	end
	for _, spoke in ipairs(spoke_pool) do
		Hide_Spoke(spoke)
	end
end
-- Fans the first count spokes from the player's current position and facing.
-- Returns false for a straight-up/down facing so that frame is skipped.
local function Reposition_Spokes(character, root, humanoid, range, count, step_rad, half_angle_rad)
	local forward = root.CFrame.LookVector
	local flat_forward = Vector3.new(forward.X, 0, forward.Z)
	if flat_forward.Magnitude < 0.001 then
		return false
	end
	flat_forward = flat_forward.Unit
	local base_origin = Get_Ground_Position(character, root, humanoid)
	for i = 1, count do
		local spoke = spoke_pool[i]
		-- Height stagger to avoid z-fighting.
		local origin = base_origin + Vector3.new(0, (i - 1) * SPOKE_Y_STAGGER, 0)
		local angle_offset = -half_angle_rad + (i - 1) * step_rad
		local direction = Rotate_Around_Y(flat_forward, angle_offset)
		local to_point = origin + direction * range
		-- Beam between two points: aim from origin to to_point, then move to the
		-- midpoint, so a part of length range spans exactly origin..to_point.
		spoke.CFrame = CFrame.new(origin, to_point) * CFrame.new(0, 0, -range / 2)
	end
	return true
end
-- Shows the cone for one swing, tracking the player for the linger time, then fades.
local function Show_Cone(cone_angle, range, swing_duration)
	if range <= 0 then
		return
	end
	local character = local_player.Character
	local humanoid = character and character:FindFirstChild("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then
		return
	end
	-- Swing length plus a little padding.
	local linger_duration = ((swing_duration and swing_duration > 0) and swing_duration or FALLBACK_LINGER_DURATION) + EXTRA_LINGER_PADDING
	current_swing_id += 1
	local this_swing_id = current_swing_id
	Cancel_Active_Cone() -- a new swing replaces any previous cone
	local count, step_rad = Get_Spoke_Plan(cone_angle)
	local half_angle_rad = math.rad(cone_angle) / 2
	local spoke_width = math.max(MIN_SPOKE_WIDTH, 2 * range * math.sin(step_rad / 2) * SPOKE_WIDTH_SAFETY_FACTOR)
	for i = 1, count do
		spoke_pool[i].Size = Vector3.new(spoke_width, SPOKE_THICKNESS, range)
	end
	-- Position before showing, so no frame appears at the old spot.
	if not Reposition_Spokes(character, root, humanoid, range, count, step_rad, half_angle_rad) then
		return
	end
	for i = 1, count do
		spoke_pool[i].Transparency = SPOKE_TRANSPARENCY
	end
	local start_time = os.clock()
	active_update_connection = RunService.RenderStepped:Connect(function()
		if this_swing_id ~= current_swing_id then
			return -- superseded by a newer swing; Cancel_Active_Cone already tore this one down
		end
		local current_character = local_player.Character
		local current_humanoid = current_character and current_character:FindFirstChild("Humanoid")
		local current_root = current_character and current_character:FindFirstChild("HumanoidRootPart")
		if not current_humanoid or not current_root or current_humanoid.Health <= 0 then
			Cancel_Active_Cone()
			return
		end
		if os.clock() - start_time >= linger_duration then
			active_update_connection:Disconnect()
			active_update_connection = nil
			for i = 1, count do
				local spoke = spoke_pool[i]
				local tween = TweenService:Create(spoke, TweenInfo.new(FADE_DURATION), {Transparency = 1})
				active_tweens[spoke] = tween
				tween:Play()
			end
			return
		end
		Reposition_Spokes(current_character, current_root, current_humanoid, range, count, step_rad, half_angle_rad)
	end)
end
local current_weapon_data = nil -- ItemData entry of the held weapon (nil for fists/food)
local function Refresh_From_Equipped(equipped)
	local weapon_entry = equipped and equipped["Weapon"]
	local data = weapon_entry and ItemData[weapon_entry.ItemName]
	if data and data.Range and data.ConeAngle then
		current_weapon_data = data
	else
		current_weapon_data = nil
	end
end
equipment_updated.OnClientEvent:Connect(Refresh_From_Equipped)
swing_telegraph_event.OnClientEvent:Connect(function(swing_duration)
	if not current_weapon_data then
		return -- defensive only -- the server only fires this alongside a real swing on a weapon that has Range/ConeAngle
	end
	Show_Cone(current_weapon_data.ConeAngle, current_weapon_data.Range, swing_duration)
end)
-- LocalScript. Lives under StarterPlayerScripts alongside CombatInput.lua/
-- CameraLockState.lua/GeneralPlayerSettings.lua/WeaponReticle.lua.
--
-- [stated] "display on the ground in front of the player a 2D cone
-- displaying their attack range/angle parameters when they swing a weapon.
-- This should only be visible by the player swinging the weapon." -- a
-- WORLD-SPACE ground telegraph, distinct from WeaponReticle.lua's
-- SCREEN-SPACE HUD reticle (that one is always up while a weapon's
-- equipped; this one flashes briefly on an actual swing).
--
-- "Only visible to the swinging player" needs no extra filtering code:
-- PlayerCombat.lua fires SwingTelegraph via FireClient at exactly one
-- player (never FireAllClients), and every Part this script creates is
-- created BY a LocalScript and parented to Workspace -- an Instance made
-- that way exists only in this client's own local copy of the DataModel and
-- is never replicated to the server or to any other client. Same reason
-- WeaponReticle.lua's ScreenGui is already local-only with no special code.
--
-- Shape: approximates the filled circular sector as a fan of thin radial
-- "spokes" -- ordinary flat rectangular Parts, one every few degrees across
-- the cone, each stretching from the player out to Range studs. Standard
-- sector discretization, built entirely from plain Part/CFrame math. One
-- visible simplification: each spoke has CONSTANT width along its length (a
-- real pie slice tapers to a point), so the near end by the player's feet
-- reads as a slightly blunt cluster rather than a sharp point -- cosmetic
-- only, doesn't affect the Range/ConeAngle it's communicating.
--
-- [stated/found] v1 froze the cone's position/facing at the instant the
-- swing started and never touched it again -- so it visibly stayed put at
-- the swing's starting spot instead of tracking the player through the
-- swing, and its fade-out never fired at all. Root cause of the fade bug:
-- the delayed callback decided whether it was safe to start fading by
-- comparing spoke.Transparency == SPOKE_TRANSPARENCY -- but BasePart
-- properties are stored as 32-bit floats on the engine side while Lua
-- numbers are 64-bit, so writing 0.55 in and reading it back doesn't
-- reliably round-trip to bit-identical values, and that comparison was
-- effectively always false. Rebuilt below on an explicit swing-id counter
-- instead (current_swing_id/this_swing_id) -- immune to float precision
-- entirely, since it's a plain integer equality check -- and on a
-- RenderStepped loop that re-reads the player's ground position and facing
-- every frame for LINGER_DURATION before handing off to the fade, so the
-- cone now visibly follows the player for the swing's duration instead of
-- being a single frozen snapshot.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local equipment_updated = ReplicatedStorage:WaitForChild("EquipmentUpdated")
-- Fired by PlayerCombat.lua right where the real swing animation plays
-- (after cooldown/stamina already passed), targeted at just the attacking
-- player.
local swing_telegraph_event = ReplicatedStorage:WaitForChild("SwingTelegraph")
local ItemData = require(ReplicatedStorage:WaitForChild("ItemData"))
local local_player = Players.LocalPlayer
-- Placeholders, tune once tested -- same "starting guess" spirit as
-- everywhere else in this project.
local ANGULAR_STEP_DEGREES = 3 -- target spacing between spokes; smaller reads more solid
local POOL_SIZE = 40 -- generous cap for the widest ConeAngle currently in ItemData (100°) at the step above, with headroom. If a future weapon's ConeAngle needs more spokes than this to hit ANGULAR_STEP_DEGREES, Get_Spoke_Plan below widens the step instead of leaving gaps -- bump this constant instead if you'd rather keep spokes tight on a much wider cone.
local MIN_SPOKE_WIDTH = 0.3 -- studs, floor so a very short/narrow cone doesn't render as an invisible sliver
local SPOKE_WIDTH_SAFETY_FACTOR = 1.4 -- multiplies the exact no-gap width so float rounding never leaves a hairline gap between spokes
local SPOKE_THICKNESS = 0.05 -- studs, near-flat
-- [stated/found] "fuse all of the sections... so it's all one solid shape"
-- -- the segmented look wasn't a bug so much as an inherent side effect of
-- many overlapping SEMI-TRANSPARENT coplanar Parts: alpha blending
-- compounds wherever spokes overlap (heavily near the player's feet by
-- design, less so out at the arc edge), so brightness visibly varies across
-- the fan instead of reading as one flat color -- and coplanar edges can
-- also z-fight (flicker/dark seams from the renderer being unable to
-- consistently decide which surface is "on top"). [stated] the brightness
-- fix (pushing SPOKE_TRANSPARENCY way down toward opaque) read as too
-- bright/harsh, so that part's rolled back to the original 0.55 -- SPOKE_Y_
-- STAGGER (the per-spoke height offset that kills the z-fighting specifically)
-- stays, since that was a separate, genuine rendering bug rather than a
-- brightness preference. A true single-mesh fuse is still possible via CSG
-- BasePart:UnionAsync if the remaining overlap-brightening ever bothers you
-- at this transparency -- flagged in more detail in an earlier round; say
-- the word and I'll design it properly (pre-built once per ConeAngle,
-- rescaled per swing) rather than attempt it blind.
local SPOKE_COLOR = Color3.fromRGB(255, 60, 60)
local SPOKE_TRANSPARENCY = 0.55
local SPOKE_Y_STAGGER = 0.001 -- studs of height difference between adjacent spokes -- imperceptible as a height gap but enough to give the renderer an unambiguous draw order
local GROUND_CLEARANCE = 0.05 -- studs above the raycast-detected ground, avoids z-fighting with the floor
local GROUND_RAYCAST_DISTANCE = 50
-- [stated/found] "it cuts a bit early during the swing animation" -- a
-- fixed linger duration couldn't know how long any given weapon's real
-- swing clip actually runs. Show_Cone now takes the real swing track's
-- Length (passed from PlayerCombat.lua, which already has it loaded right
-- where it plays the track) and lingers for that plus a little padding,
-- instead of a guessed constant -- FALLBACK_LINGER_DURATION only covers the
-- unexpected case that length comes in as 0 (e.g. the animation asset
-- hadn't finished loading server-side yet).
local FALLBACK_LINGER_DURATION = 0.4
local EXTRA_LINGER_PADDING = 0.1 -- seconds added past the real swing length so the cone doesn't cut off on the exact last frame
local FADE_DURATION = 0.25 -- seconds to fade out after the linger window
local telegraph_folder = Instance.new("Folder")
telegraph_folder.Name = "SwingConeTelegraph"
telegraph_folder.Parent = Workspace
-- Pre-built once and reused every swing rather than created/destroyed each
-- time -- same "build once, reuse" pattern WeaponReticle.lua already uses
-- for its dot/lines, just applied to a pool instead of two fixed Instances.
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
-- Rotates a direction vector around the world Y axis -- identical helper to
-- the one in WeaponReticle.lua (fanning the character's forward direction
-- out by the cone's half-angle); duplicated here rather than shared since
-- it's 3 lines and these are two independently-triggered scripts.
local function Rotate_Around_Y(direction, angle_rad)
	return CFrame.fromAxisAngle(Vector3.new(0, 1, 0), angle_rad):VectorToWorldSpace(direction)
end
-- How many spokes to draw and how far apart (in radians) to space them,
-- given this weapon's ConeAngle. Always spans edge-to-edge exactly (spoke 1
-- sits on one cone edge, the last sits on the other) rather than possibly
-- undershooting by a fraction of a degree. Clamped to POOL_SIZE -- see the
-- POOL_SIZE comment above for what happens if a future weapon needs more.
local function Get_Spoke_Plan(cone_angle_deg)
	local count = math.floor(cone_angle_deg / ANGULAR_STEP_DEGREES) + 1
	count = math.clamp(count, 2, POOL_SIZE)
	local step_rad = math.rad(cone_angle_deg / (count - 1))
	return count, step_rad
end
local ground_raycast_params = RaycastParams.new()
ground_raycast_params.FilterType = Enum.RaycastFilterType.Exclude
-- Finds ground level straight down from the character's root, so the cone
-- sits flush on sloped/stepped floors instead of floating or clipping --
-- falls back to an approximate foot-height offset (HipHeight + half the
-- root's own height, the standard "how far below the root is the ground"
-- math) if the raycast finds nothing within range (e.g. mid-air/jumping).
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
-- Instantly wipes whatever the previous swing was showing -- called both
-- when a brand new swing supersedes an in-progress one (fast follow-up
-- attacks) and as general cleanup. Hides every pool spoke unconditionally
-- rather than tracking "how many were active last time", which is simpler
-- and always correct.
local function Cancel_Active_Cone()
	if active_update_connection then
		active_update_connection:Disconnect()
		active_update_connection = nil
	end
	for _, spoke in ipairs(spoke_pool) do
		Hide_Spoke(spoke)
	end
end
-- Repositions the first `count` pool spokes to fan out from the player's
-- CURRENT ground position/facing -- called every RenderStepped frame while
-- a cone is live, which is what makes it track the player through the
-- swing instead of freezing at wherever they started it. Returns false on a
-- degenerate facing direction (looking straight up/down) so the caller can
-- skip rendering that frame rather than draw a broken cone.
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
		-- Tiny per-spoke height offset (SPOKE_Y_STAGGER, see its comment
		-- above) keeps adjacent spokes from being perfectly coplanar so the
		-- renderer doesn't z-fight/flicker at their shared edges.
		local origin = base_origin + Vector3.new(0, (i - 1) * SPOKE_Y_STAGGER, 0)
		local angle_offset = -half_angle_rad + (i - 1) * step_rad
		local direction = Rotate_Around_Y(flat_forward, angle_offset)
		local to_point = origin + direction * range
		-- Standard "beam between two points" idiom: CFrame.new(origin,
		-- to_point) orients so the CFrame looks from origin toward
		-- to_point, then translating -range/2 along its own local Z
		-- (equivalently +range/2 along its LookVector) slides that CFrame
		-- from origin to the midpoint -- so a Part with Size.Z = range,
		-- centered there, has one end exactly at origin and the other
		-- exactly at to_point.
		spoke.CFrame = CFrame.new(origin, to_point) * CFrame.new(0, 0, -range / 2)
	end
	return true
end
-- Starts (or restarts) the ground cone for a swing with the given
-- Range/ConeAngle. Tracks the player every frame for LINGER_DURATION, then
-- fades every active spoke out over FADE_DURATION.
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
	-- Real swing length (from PlayerCombat.lua's own loaded track) plus a
	-- touch of padding, falling back to the old fixed guess only if the
	-- server ever sends a non-positive length.
	local linger_duration = ((swing_duration and swing_duration > 0) and swing_duration or FALLBACK_LINGER_DURATION) + EXTRA_LINGER_PADDING
	current_swing_id += 1
	local this_swing_id = current_swing_id
	Cancel_Active_Cone() -- wipes any previous swing's spokes/connection/tweens instantly, so a fast follow-up swing always starts clean instead of blending with the old one
	local count, step_rad = Get_Spoke_Plan(cone_angle)
	local half_angle_rad = math.rad(cone_angle) / 2
	local spoke_width = math.max(MIN_SPOKE_WIDTH, 2 * range * math.sin(step_rad / 2) * SPOKE_WIDTH_SAFETY_FACTOR)
	for i = 1, count do
		spoke_pool[i].Size = Vector3.new(spoke_width, SPOKE_THICKNESS, range)
	end
	-- Position correctly BEFORE making anything visible, so the very first
	-- rendered frame already shows the right spot instead of a one-frame
	-- flash at wherever this spoke was left over from a previous swing.
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
-- Origin is deliberately ground-level here (via Get_Ground_Position), not
-- the chest-height offset WeaponReticle.lua projects from -- this IS the
-- ground cone, so it should sit ON the ground.
local current_weapon_data = nil -- ItemData entry of whatever's in the Weapon slot, or nil -- same tracking WeaponReticle.lua does, see its header for why Food/fists are naturally excluded/included
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
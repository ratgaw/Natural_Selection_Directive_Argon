-- LocalScript. Place under StarterPlayerScripts alongside CombatInput.lua/
-- CameraLockState.lua/GeneralPlayerSettings.lua/InfectionHUD.lua.
--
-- Shows a melee reticle whenever the player has an actual weapon equipped
-- in the Weapon slot: a center dot, plus two vertical PARALLEL lines
-- straddling it, one for each edge of the weapon's swing cone — maps
-- directly onto PlayerCombat.lua's actual hit-check (weapon_data.Range +
-- ConeAngle, see PlayerCombat.attack's windup-delay hit-check), not a
-- made-up visual, so what you see here is genuinely what determines
-- whether a swing lands.
--
-- [stated/found] first version fanned the two lines out from the center
-- dot at an angle (a wedge/"^" shape) instead of keeping them parallel —
-- [stated] "I'd prefer 2 parallel lines indicating the 2 edges of the
-- weapon's angle range" instead. Rebuilt on plain unrotated vertical bars:
-- each line's HORIZONTAL DISTANCE from center (half_gap below) stands in
-- for the cone's angular width instead of a literal rotation, which also
-- sidesteps a real Roblox quirk the rotated version ran into — GuiObject
-- Rotation pivots around the object's own geometric center regardless of
-- AnchorPoint, not around the anchor/pivot point you position it at, so a
-- Frame anchored at its near edge and then rotated doesn't swing from that
-- anchor the way it does in, say, a CFrame — it was producing the
-- oversized crossed-line look in the screenshot rather than a clean wedge.
-- Plain horizontal offsets have no such pivot ambiguity. Each line's
-- HEIGHT still stands in for Range, same normalized/schematic reasoning as
-- before (a literal world-space projection would balloon/shrink as the
-- camera zooms, see the git history on this file if you want that version
-- reasoned through again) — only now as vertical bar height instead of
-- radial length.
--
-- [stated] "scale the distance between the angle reticles so it stays
-- accurate at any POV" — first attempt used a pure FOV-to-pixel formula
-- (tan(angle)/tan(half-FOV)), which is mathematically correct for "what
-- angular fraction of the screen does this angle cover" but deliberately
-- has NO distance term, so [stated/found] it read as stuck at one width
-- no matter how far the camera zoomed in/out or whether the player was in
-- first or third person — because FieldOfView doesn't change between
-- those, only camera DISTANCE does, and that formula ignores distance
-- entirely. That's the wrong notion of "accurate" here: the swing cone is
-- anchored to the CHARACTER, not the camera, so a genuinely accurate
-- reticle has to look bigger when the camera is close (zoomed in / first
-- person) and smaller when it's far (zoomed out) — exactly like the
-- character itself does. So this now projects the ACTUAL world-space cone
-- edges (character position + facing rotated +-ConeAngle/2, out to Range
-- studs) through camera:WorldToViewportPoint every frame — see
-- Get_Cone_Screen_Gaps below — which is simply reusing the engine's own
-- projection math instead of reimplementing FOV trig by hand, so it's
-- automatically correct for any camera position, zoom distance, FOV, or
-- first/third person mode, since those are exactly the inputs that
-- projection already accounts for. The dot itself also now tracks the
-- projected center-of-aim point every frame instead of sitting at a fixed
-- screen-center, since a real projection of "straight ahead" doesn't
-- always land exactly at (0.5, 0.5) once the camera has any pitch. Only
-- each line's HORIZONTAL offset from that point is taken from the
-- projection, though — not literally drawing a line to the projected
-- point's Y as well — so the lines stay genuinely parallel/vertical per
-- [stated] preference rather than tilting with the camera's pitch.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local equipment_updated = ReplicatedStorage:WaitForChild("EquipmentUpdated")
local ItemData = require(ReplicatedStorage:WaitForChild("ItemData"))
local CameraLockState = require(script.Parent:WaitForChild("CameraLockState"))
local local_player = Players.LocalPlayer
local player_gui = local_player:WaitForChild("PlayerGui")
-- Placeholders, tune once tested. Range/ConeAngle across the
-- currently-defined weapons run roughly 8-15 studs / 70-100 degrees (see
-- ItemData) -- these map those bands onto comfortable on-screen pixel
-- bands rather than being 1:1 studs/degrees-to-pixels.
local MIN_EXPECTED_RANGE = 4 -- fists-ish, shortest reach worth showing
local MAX_EXPECTED_RANGE = 16
local MIN_LINE_HEIGHT = 30 -- pixels
local MAX_LINE_HEIGHT = 90
local MIN_HALF_GAP = 12 -- pixel floor so even a needle-narrow cone stays visible/separate from the dot
local LINE_THICKNESS = 3
local DOT_SIZE = 8
local screen_gui = Instance.new("ScreenGui")
screen_gui.Name = "WeaponReticle"
screen_gui.ResetOnSpawn = false
screen_gui.IgnoreGuiInset = true
screen_gui.Enabled = false -- nothing to aim with until a weapon's equipped
screen_gui.Parent = player_gui
local function New_Stroke(parent, thickness)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness or 1
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Transparency = 0.2
	stroke.Parent = parent
	return stroke
end
local dot = Instance.new("Frame")
dot.Name = "CenterDot"
dot.AnchorPoint = Vector2.new(0.5, 0.5)
dot.Position = UDim2.fromScale(0.5, 0.5) -- overwritten every frame once a weapon's equipped, see RenderStepped below
dot.Size = UDim2.fromOffset(DOT_SIZE, DOT_SIZE)
dot.BackgroundColor3 = Color3.new(1, 1, 1)
dot.BorderSizePixel = 0
dot.Parent = screen_gui
local dot_corner = Instance.new("UICorner")
dot_corner.CornerRadius = UDim.new(1, 0)
dot_corner.Parent = dot
New_Stroke(dot, 1)
-- Both side lines share this shape/anchor setup — a plain vertical Frame,
-- centered on the reticle's own center point both horizontally and
-- vertically, then pushed left/right by a horizontal OFFSET (never
-- rotated) so they always render as two truly parallel vertical bars, no
-- matter how far apart Update_Line pushes them. Built once here and reused
-- by Update_Line every frame rather than recreating Instances.
local function New_Line()
	local line = Instance.new("Frame")
	line.AnchorPoint = Vector2.new(0.5, 0.5)
	line.BackgroundColor3 = Color3.new(1, 1, 1)
	line.BorderSizePixel = 0
	line.Parent = screen_gui
	New_Stroke(line, 1)
	return line
end
local left_line = New_Line()
left_line.Name = "LeftLine"
local right_line = New_Line()
right_line.Name = "RightLine"
-- center is a Vector2 screen position (the projected point straight ahead
-- of the character, NOT necessarily exact screen-center — see the header
-- note on camera pitch). side is -1 (left) or 1 (right). half_gap is this
-- line's horizontal distance from that center point in pixels, straight
-- from the real world-space projection below. height is this line's
-- vertical size in pixels (stands in for Range, unchanged/schematic — see
-- the original header note, this part was never the piece the [stated]
-- POV complaint was about).
local function Update_Line(line, center, side, half_gap, height)
	line.Position = UDim2.fromOffset(center.X + side * half_gap, center.Y)
	line.Size = UDim2.fromOffset(LINE_THICKNESS, height)
end
-- Rotates a direction vector around the world Y axis — used to fan the
-- character's forward direction out by +-ConeAngle/2 to find the swing
-- cone's two edges. CFrame.fromAxisAngle builds a pure-rotation CFrame;
-- VectorToWorldSpace applies it to a direction without needing a full
-- point-in-space CFrame.
local function Rotate_Around_Y(direction, angle_rad)
	return CFrame.fromAxisAngle(Vector3.new(0, 1, 0), angle_rad):VectorToWorldSpace(direction)
end
local WEAPON_HEIGHT_OFFSET = Vector3.new(0, 1.5, 0) -- approx chest/weapon height above HumanoidRootPart
-- The real fix for "accurate at any POV": projects the ACTUAL world-space
-- cone (character position + facing rotated +-half of ConeAngle, out to
-- Range studs, horizontal-only — same flattening simplification as the
-- original design note, real targets off to the side at the same
-- elevation are what this is modeling) through the CURRENT camera via
-- WorldToViewportPoint, the same math Roblox itself uses to place
-- anything on screen. Returns nil if any of the three points project
-- behind the camera (the .Z component WorldToViewportPoint returns is
-- negative in that case) — an edge case the caller should just skip a
-- frame on rather than draw a broken reticle for.
local function Get_Cone_Screen_Gaps(root, cone_angle, range, camera)
	local forward = root.CFrame.LookVector
	local flat_forward = Vector3.new(forward.X, 0, forward.Z)
	if flat_forward.Magnitude < 0.001 then
		return nil
	end
	flat_forward = flat_forward.Unit
	local half_angle_rad = math.rad(cone_angle / 2)
	local origin = root.Position + WEAPON_HEIGHT_OFFSET
	local center_point = origin + flat_forward * range
	local left_point = origin + Rotate_Around_Y(flat_forward, half_angle_rad) * range
	local right_point = origin + Rotate_Around_Y(flat_forward, -half_angle_rad) * range
	local center_screen, center_on = camera:WorldToViewportPoint(center_point)
	local left_screen, left_on = camera:WorldToViewportPoint(left_point)
	local right_screen, right_on = camera:WorldToViewportPoint(right_point)
	if not (center_on and left_on and right_on) then
		return nil
	end
	local center = Vector2.new(center_screen.X, center_screen.Y)
	local half_gap_left = math.max(MIN_HALF_GAP, math.abs(center_screen.X - left_screen.X))
	local half_gap_right = math.max(MIN_HALF_GAP, math.abs(right_screen.X - center_screen.X))
	return center, half_gap_left, half_gap_right
end
local current_weapon_data = nil -- ItemData entry of whatever's in the Weapon slot, or nil
local function Refresh_From_Equipped(equipped)
	local weapon_entry = equipped and equipped["Weapon"]
	local data = weapon_entry and ItemData[weapon_entry.ItemName]
	-- Food/drinks also occupy the Weapon slot (see ItemData/PlayerEquipment)
	-- but have no Range/ConeAngle -- this check naturally excludes them
	-- along with bare fists (nothing equipped at all has no entry either).
	if data and data.Range and data.ConeAngle then
		current_weapon_data = data
	else
		current_weapon_data = nil
	end
	-- [stated] "lock camera-to-facing while a weapon's held" — this is
	-- already the exact check for "a real weapon, not fists/food", so it
	-- doubles as CameraLockState's trigger for that facing-lock rather than
	-- duplicating the Range/ConeAngle check a second time over there.
	CameraLockState.weapon_equipped = current_weapon_data ~= nil
end
equipment_updated.OnClientEvent:Connect(Refresh_From_Equipped)
RunService.RenderStepped:Connect(function()
	if not current_weapon_data or CameraLockState.gui_open then
		screen_gui.Enabled = false
		return
	end
	local character = local_player.Character
	local humanoid = character and character:FindFirstChild("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		screen_gui.Enabled = false
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local camera = Workspace.CurrentCamera
	if not root or not camera then
		screen_gui.Enabled = false
		return
	end
	local center, half_gap_left, half_gap_right = Get_Cone_Screen_Gaps(root, current_weapon_data.ConeAngle, current_weapon_data.Range, camera)
	if not center then
		-- Cone edges (or the character's own forward point) projected
		-- behind the camera this frame — an extreme-angle edge case, not
		-- worth showing a broken reticle for. Just skip the frame; it
		-- corrects itself the instant the projection is valid again.
		screen_gui.Enabled = false
		return
	end
	screen_gui.Enabled = true
	dot.Position = UDim2.fromOffset(center.X, center.Y)
	local normalized_range = math.clamp((current_weapon_data.Range - MIN_EXPECTED_RANGE) / (MAX_EXPECTED_RANGE - MIN_EXPECTED_RANGE), 0, 1)
	local height = MIN_LINE_HEIGHT + (MAX_LINE_HEIGHT - MIN_LINE_HEIGHT) * normalized_range
	Update_Line(left_line, center, -1, half_gap_left, height)
	Update_Line(right_line, center, 1, half_gap_right, height)
end)
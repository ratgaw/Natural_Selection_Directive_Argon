-- Melee reticle shown while a real weapon is in the Weapon slot: a dot plus two
-- parallel vertical lines marking the edges of the swing cone (the same
-- Range/ConeAngle the server hit-check uses). The line spacing comes from
-- projecting the real world-space cone edges through the camera each frame, so
-- it stays accurate at any zoom or in first person. The dot follows the
-- projected aim point; line height stands in for Range.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local equipment_updated = ReplicatedStorage:WaitForChild("EquipmentUpdated")
local ItemData = require(ReplicatedStorage:WaitForChild("ItemData"))
local CameraLockState = require(script.Parent:WaitForChild("CameraLockState"))
local local_player = Players.LocalPlayer
local player_gui = local_player:WaitForChild("PlayerGui")
-- Maps the weapons' Range/ConeAngle spread onto comfortable pixel sizes.
-- Placeholders.
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
-- A plain vertical bar, centered and pushed left/right by an offset (never
-- rotated, so the two lines stay parallel). Built once and reused.
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
-- center: projected aim point on screen. side: -1 left, 1 right.
-- half_gap: pixels from center. height: pixels (stands in for Range).
local function Update_Line(line, center, side, half_gap, height)
	line.Position = UDim2.fromOffset(center.X + side * half_gap, center.Y)
	line.Size = UDim2.fromOffset(LINE_THICKNESS, height)
end
-- Rotates a direction around world Y (used to find the cone's two edges).
local function Rotate_Around_Y(direction, angle_rad)
	return CFrame.fromAxisAngle(Vector3.new(0, 1, 0), angle_rad):VectorToWorldSpace(direction)
end
local WEAPON_HEIGHT_OFFSET = Vector3.new(0, 1.5, 0) -- approx chest/weapon height above HumanoidRootPart
-- Projects the character's position and the two cone edges (Range studs out)
-- to the screen. Returns nil if any point is behind the camera.
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
	-- Excludes food/drinks (no Range/ConeAngle) and fists.
	if data and data.Range and data.ConeAngle then
		current_weapon_data = data
	else
		current_weapon_data = nil
	end
	-- Also tells CameraLockState to lock facing to the camera while armed.
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
		-- A point projected behind the camera: skip this frame.
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
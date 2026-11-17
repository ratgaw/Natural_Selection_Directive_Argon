local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local local_player = Players.LocalPlayer
local CameraLockState = {}
CameraLockState.gui_open = false
CameraLockState.alt_held = false
CameraLockState.right_click_held = false
-- Set by WeaponReticle when a real weapon is equipped (a plain field to avoid a
-- circular require). While true, the character faces the camera.
CameraLockState.weapon_equipped = false
local current_open_gui = nil -- nil, or the key of whichever GUI is currently open
local function Recompute_Gui_Open()
	CameraLockState.gui_open = current_open_gui ~= nil
end
-- Unlock the cursor when a GUI is open or Alt+right-click is held.
local function Should_Free_Look()
	return CameraLockState.gui_open or (CameraLockState.alt_held and CameraLockState.right_click_held)
end
-- Alt alone releases the weapon facing lock (the cursor stays locked).
local function Should_Bypass_Weapon_Lock()
	return CameraLockState.gui_open or CameraLockState.alt_held
end
-- Opens gui_key if no other GUI is open. Returns false otherwise (one GUI at a time).
function CameraLockState.try_open_gui(gui_key)
	if current_open_gui ~= nil and current_open_gui ~= gui_key then
		return false
	end
	current_open_gui = gui_key
	Recompute_Gui_Open()
	CameraLockState.apply()
	return true
end
-- Only closes gui_key if it's the one open.
function CameraLockState.close_gui(gui_key)
	if current_open_gui == gui_key then
		current_open_gui = nil
		Recompute_Gui_Open()
		CameraLockState.apply()
	end
end
function CameraLockState.apply()
	if Should_Free_Look() then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	end
end
CameraLockState.apply()
-- Roblox's camera script also sets MouseBehavior, so re-apply every frame.
RunService.Heartbeat:Connect(CameraLockState.apply)

-- While armed, face the camera like Shift Lock (AutoRotate off, set rotation).
-- Runs on RenderStepped for smoothness. The facing replicates, so the server
-- hit-check uses it.
local function Update_Facing()
	local character = local_player.Character
	local humanoid = character and character:FindFirstChild("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then
		return
	end
	if not CameraLockState.weapon_equipped or Should_Bypass_Weapon_Lock() then
		humanoid.AutoRotate = true
		return
	end
	humanoid.AutoRotate = false
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local look = camera.CFrame.LookVector
	local flat_look = Vector3.new(look.X, 0, look.Z)
	if flat_look.Magnitude > 0.001 then
		root.CFrame = CFrame.new(root.Position, root.Position + flat_look)
	end
end
RunService.RenderStepped:Connect(Update_Facing)

return CameraLockState
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local local_player = Players.LocalPlayer
local CameraLockState = {}
CameraLockState.gui_open = false
CameraLockState.alt_held = false
CameraLockState.right_click_held = false
-- [stated] went swing-only, then asked to go back: "lock it has a weapon
-- equipped, for more stable combat I think it's better" — swing-only meant
-- the character was only guaranteed to face the camera for a brief window
-- around each click, so strafing/repositioning between swings (or during
-- the windup itself, if the camera kept moving after the initial turn)
-- could still drift out of sync with where the reticle was showing. Locking
-- for the whole time a weapon's out keeps facing continuously pinned to the
-- camera through an entire fight, not just each swing's own short window —
-- [stated] "more stable". Set by WeaponReticle.lua (the module that already
-- determines "is a real weapon, not fists/food, equipped" from
-- EquipmentUpdated) — kept as a plain field here rather than requiring
-- WeaponReticle back, since WeaponReticle already requires THIS module and
-- a two-way require would be circular.
CameraLockState.weapon_equipped = false
local current_open_gui = nil -- nil, or the key of whichever GUI is currently open
local function Recompute_Gui_Open()
	CameraLockState.gui_open = current_open_gui ~= nil
end
-- Used by apply() (mouse cursor lock) — a GUI is open, or the player is
-- holding the Alt+RightClick free-look override. Cursor behavior is
-- unchanged by the [stated] request below; that one only widens the bypass
-- for the WEAPON facing-lock specifically (see Should_Bypass_Weapon_Lock).
local function Should_Free_Look()
	return CameraLockState.gui_open or (CameraLockState.alt_held and CameraLockState.right_click_held)
end
-- [stated] "holding down alt will allow free cam, bypassing equipped weapon
-- cameralock" — narrower than Should_Free_Look above (which needs BOTH alt
-- AND right-click, since alt+right-click alone is a separate cursor-unlock
-- feature): here alt BY ITSELF is enough to let the camera orbit without
-- forcing the character to face it, even with a weapon out. Note this only
-- releases Update_Facing's forced rotation, not the mouse cursor lock
-- itself (apply(), above, still governs that) — the cursor stays centered
-- either way, exactly like it already does while free-looking with a bare
-- Humanoid.AutoRotate turn in effect.
local function Should_Bypass_Weapon_Lock()
	return CameraLockState.gui_open or CameraLockState.alt_held
end
-- Attempts to open the given GUI. Returns true if it successfully became
-- the open one — false if a DIFFERENT GUI is already open, in which case
-- the caller must not show its own GUI, enforcing only one open at a time.
function CameraLockState.try_open_gui(gui_key)
	if current_open_gui ~= nil and current_open_gui ~= gui_key then
		return false
	end
	current_open_gui = gui_key
	Recompute_Gui_Open()
	CameraLockState.apply()
	return true
end
-- Closes the given GUI, but only if it's actually the one currently
-- marked open — guards against a stale close call clearing a different
-- GUI that opened afterward.
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
-- Roblox's own default camera script also manages MouseBehavior (during
-- right-click-hold and first-person), independently of us — re-asserting
-- every frame is the standard way to keep our own setting winning.
RunService.Heartbeat:Connect(CameraLockState.apply)

-- Forces HumanoidRootPart's facing to match the camera, the same trick
-- Roblox's own Shift Lock uses (AutoRotate off + directly set rotation) —
-- for as long as CameraLockState.weapon_equipped is true and
-- Should_Bypass_Weapon_Lock() isn't overriding it (GUI open, or alt held by
-- itself, per [stated] above). AutoRotate is handed back the moment
-- there's no weapon, so bare-handed movement/turning stays normal (matches
-- walking direction, as it always has). RenderStepped (not Heartbeat) so
-- facing tracks the camera exactly as smoothly as the camera itself moves.
-- Because this sets the LOCAL player's own HumanoidRootPart, it replicates
-- to the server like ordinary movement, so PlayerCombat's server-side
-- hit-check (which reads this same root.CFrame.LookVector) sees the facing
-- the reticle is already showing for the whole time a weapon's equipped,
-- not just around each individual swing.
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
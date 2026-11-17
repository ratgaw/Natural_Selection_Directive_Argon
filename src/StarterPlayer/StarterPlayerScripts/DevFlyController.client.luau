-- [stated] "/dev text command... can fly" -- "classic noclip-style fly":
-- full camera-relative flight (WASD moves in whatever direction the
-- camera's facing/strafing, Space/Shift give pure vertical lift/descent),
-- gravity off entirely, but normal collision KEPT (no passing through
-- walls/terrain/buildings) -- per [stated] choice between the two.
--
-- This runs entirely client-side and does NOT wait on anything from the
-- server beyond the on/off toggle itself. Roblox gives a player's own
-- client physics ownership of their own character by default (the same
-- reason ordinary WASD movement already works this way) -- a LocalScript
-- driving a BodyVelocity on your own HumanoidRootPart replicates to the
-- server and every other client exactly like normal movement does, so
-- there's no need to round-trip camera direction/key state to the server
-- and have IT drive the movement.
--
-- humanoid.PlatformStand = true while flying: this stops the Humanoid's
-- own movement/animation state machine from fighting the BodyVelocity
-- (no walk animation churn, no built-in jump/fall handling interfering),
-- but does NOT touch collision -- the character's parts keep their normal
-- CanCollide, so flying into a wall or the ground still stops you, which
-- is exactly the "keep normal collision" behavior asked for.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local dev_fly_toggled = ReplicatedStorage:WaitForChild("DevFlyToggled")
local local_player = Players.LocalPlayer

local FLY_SPEED = 80 -- studs/sec, forward/back/strafe (camera-relative)
local VERTICAL_SPEED = 60 -- studs/sec, Space/Shift

local flying = false
local body_velocity = nil
local heartbeat_connection = nil
local held_keys = {} -- [Enum.KeyCode] = true while held

local function Update_Velocity()
	local character = local_player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not body_velocity or body_velocity.Parent ~= root then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local look = camera.CFrame.LookVector
	local right = camera.CFrame.RightVector
	local move = Vector3.new(0, 0, 0)
	if held_keys[Enum.KeyCode.W] then
		move += look
	end
	if held_keys[Enum.KeyCode.S] then
		move -= look
	end
	if held_keys[Enum.KeyCode.D] then
		move += right
	end
	if held_keys[Enum.KeyCode.A] then
		move -= right
	end
	local horizontal = move.Magnitude > 0.01 and move.Unit * FLY_SPEED or Vector3.new(0, 0, 0)
	local vertical = 0
	if held_keys[Enum.KeyCode.Space] then
		vertical += VERTICAL_SPEED
	end
	if held_keys[Enum.KeyCode.LeftShift] or held_keys[Enum.KeyCode.RightShift] then
		vertical -= VERTICAL_SPEED
	end
	-- Note: horizontal already includes whatever vertical component the
	-- camera's own look vector has (looking up while holding W lifts you)
	-- -- that's intentional, part of "classic noclip-style fly" reading
	-- the camera directly. Space/Shift's vertical is just added on top of
	-- that, not a separate axis fighting it.
	body_velocity.Velocity = Vector3.new(horizontal.X, horizontal.Y + vertical, horizontal.Z)
end

local function Start_Fly()
	if flying then
		return
	end
	local character = local_player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then
		return
	end
	flying = true
	humanoid.PlatformStand = true
	body_velocity = Instance.new("BodyVelocity")
	body_velocity.Name = "DevFlyVelocity"
	body_velocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
	body_velocity.Velocity = Vector3.new(0, 0, 0)
	body_velocity.Parent = root
	heartbeat_connection = RunService.Heartbeat:Connect(Update_Velocity)
end

local function Stop_Fly()
	if not flying then
		return
	end
	flying = false
	if heartbeat_connection then
		heartbeat_connection:Disconnect()
		heartbeat_connection = nil
	end
	if body_velocity then
		body_velocity:Destroy()
		body_velocity = nil
	end
	local character = local_player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
	end
end

UserInputService.InputBegan:Connect(function(input, game_processed_event)
	if game_processed_event then
		return
	end
	held_keys[input.KeyCode] = true
end)
UserInputService.InputEnded:Connect(function(input)
	held_keys[input.KeyCode] = false
end)

dev_fly_toggled.OnClientEvent:Connect(function(enabled)
	if enabled then
		Start_Fly()
	else
		Stop_Fly()
	end
end)

-- Dying/respawning tears down the old HumanoidRootPart (and with it, this
-- script's own BodyVelocity) regardless of what the server-side dev mode
-- flag still says -- if dev mode was left on through a death, this re-arms
-- flight on the fresh character instead of silently losing it until the
-- player retypes /dev. A short wait lets the new character's Humanoid/
-- HumanoidRootPart actually finish settling in before Start_Fly looks for
-- them.
local_player.CharacterAdded:Connect(function()
	if flying then
		flying = false -- forces Start_Fly to actually rebuild state below, rather than no-op on its own "already flying" guard
		task.wait(0.3)
		Start_Fly()
	end
end)
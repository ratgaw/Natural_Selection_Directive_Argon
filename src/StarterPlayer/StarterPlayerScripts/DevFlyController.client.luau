-- /dev flight, client-side: WASD moves relative to the camera, Space/Shift move
-- up/down, gravity off, collision kept. The client owns its character's physics,
-- so a BodyVelocity here replicates like normal movement. PlatformStand stops the
-- Humanoid fighting the BodyVelocity.
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
	-- Looking up while holding W also climbs; Space/Shift add on top.
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

-- Re-arm flight on respawn if dev mode is still on.
local_player.CharacterAdded:Connect(function()
	if flying then
		flying = false -- forces Start_Fly to actually rebuild state below, rather than no-op on its own "already flying" guard
		task.wait(0.3)
		Start_Fly()
	end
end)
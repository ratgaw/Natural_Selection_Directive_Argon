local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local event_warning = ReplicatedStorage:WaitForChild("EventWarning")
local event_announce = ReplicatedStorage:WaitForChild("EventAnnounce")

local local_player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local PAN_HEIGHT = 120
local PAN_RADIUS = 80

local warning_gui = local_player:WaitForChild("PlayerGui"):WaitForChild("MatchGui"):WaitForChild("EventWarnings")
local warning_label = warning_gui:WaitForChild("WarningText")

event_warning.OnClientEvent:Connect(function(event_name, seconds_until)
	warning_label.Text = event_name .. " in " .. seconds_until .. "s!"
	warning_gui.Enabled = true
	task.delay(seconds_until, function()
		warning_gui.Enabled = false
	end)
end)

local function Play_Cinematic_Pan(event_name, pan_duration)
	warning_gui.Enabled = false

	local character = local_player.Character
	local center = (character and character:FindFirstChild("HumanoidRootPart"))
		and character.HumanoidRootPart.Position
		or Vector3.new()

	camera.CameraType = Enum.CameraType.Scriptable

	local start_angle = math.random() * math.pi * 2
	local end_angle = start_angle + math.rad(120)

	local start_pos = center + Vector3.new(math.cos(start_angle), 0, math.sin(start_angle)) * PAN_RADIUS + Vector3.new(0, PAN_HEIGHT, 0)
	local end_pos = center + Vector3.new(math.cos(end_angle), 0, math.sin(end_angle)) * PAN_RADIUS + Vector3.new(0, PAN_HEIGHT, 0)

	camera.CFrame = CFrame.new(start_pos, center)

	local position_value = Instance.new("Vector3Value")
	position_value.Value = start_pos

	local connection
	connection = position_value.Changed:Connect(function(new_position)
		camera.CFrame = CFrame.new(new_position, center)
	end)

	local tween = TweenService:Create(
		position_value,
		TweenInfo.new(pan_duration, Enum.EasingStyle.Linear),
		{Value = end_pos}
	)

	tween.Completed:Connect(function()
		connection:Disconnect()
		position_value:Destroy()
		camera.CameraType = Enum.CameraType.Custom
	end)

	tween:Play()
end

event_announce.OnClientEvent:Connect(Play_Cinematic_Pan)
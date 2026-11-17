-- General ease of use variable settings
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local inventory = playerGui:WaitForChild("PlayerInventory&Stats")
local camera_lock_state = require(script.Parent:WaitForChild("CameraLockState"))
-- Setting varibles for hotbar initilization at match start
local hotbar = inventory:WaitForChild("HotBar")
local match_start = ReplicatedStorage:WaitForChild("MatchStarted")
-- Setting up request signal connection variables
local sprint_request = ReplicatedStorage:WaitForChild("SprintRequest")
-- Raw shift state, separate from what was last sent to the server.
local shift_held = false
local sprint_request_sent = false
local function Sync_Sprint_Request()
	-- No sprinting while a GUI is open.
	local wants_sprint = shift_held and not camera_lock_state.gui_open
	if wants_sprint ~= sprint_request_sent then
		sprint_request_sent = wants_sprint
		sprint_request:FireServer(wants_sprint)
	end
end
-- Detects user input
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	-- Controls sprint request signals via shift press
	if input.KeyCode == Enum.KeyCode.LeftShift then
		shift_held = true
		Sync_Sprint_Request()
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		shift_held = false
		Sync_Sprint_Request()
	end
end)
-- Re-check every frame to catch a GUI opening or closing while shift is held.
RunService.Heartbeat:Connect(Sync_Sprint_Request)
-- Turns on hotbar
match_start.OnClientEvent:Connect(function()
	hotbar.Visible = true
end)
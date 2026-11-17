-- LocalScript. Place under StarterPlayerScripts alongside CombatInput.lua/
-- CameraLockState.lua/GeneralPlayerSettings.lua (same "client script that
-- isn't part of the main inventory GUI tree" category as those).
--
-- Shows which stage of the Animal Frenzy parasite infection the local
-- player is on and a countdown to the next (worse) stage — [stated] ask:
-- "which stage of infection... how long until they reach the next stage,
-- with more and more effects the higher the infection stage". Built as its
-- own small ScreenGui entirely from script rather than wired into the
-- existing Inventory/Stats panel, since nothing in that GUI was earmarked
-- for infection and I don't have its Explorer layout in front of me to
-- safely reuse a slot the way the hunger stage was dropped onto the
-- existing STAMINA Stat label. Nothing here needs any manual Studio setup
-- beyond the InfectionUpdated RemoteEvent PlayerInfection.lua already
-- calls for (ReplicatedStorage, same place as EventWarning/HungerUpdated).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local infection_updated = ReplicatedStorage:WaitForChild("InfectionUpdated")
local local_player = Players.LocalPlayer
local player_gui = local_player:WaitForChild("PlayerGui")
local screen_gui = Instance.new("ScreenGui")
screen_gui.Name = "InfectionHUD"
screen_gui.ResetOnSpawn = false
screen_gui.IgnoreGuiInset = true
screen_gui.Enabled = false -- nothing to show until the first infected update
screen_gui.Parent = player_gui
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0)
panel.Position = UDim2.new(0.5, 0, 0.06, 0)
panel.Size = UDim2.new(0, 280, 0, 56)
panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
panel.BackgroundTransparency = 0.25
panel.BorderSizePixel = 0
panel.Parent = screen_gui
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = panel
-- Left accent bar — recolors per stage (yellow/orange/red from
-- PlayerInfection's INFECTION_STAGES) so severity reads at a glance even
-- before you've read the text.
local accent = Instance.new("Frame")
accent.Name = "Accent"
accent.Size = UDim2.new(0, 6, 1, 0)
accent.BorderSizePixel = 0
accent.Parent = panel
local accent_corner = Instance.new("UICorner")
accent_corner.CornerRadius = UDim.new(0, 8)
accent_corner.Parent = accent
local stage_label = Instance.new("TextLabel")
stage_label.Name = "StageLabel"
stage_label.BackgroundTransparency = 1
stage_label.Position = UDim2.new(0, 16, 0, 4)
stage_label.Size = UDim2.new(1, -24, 0, 26)
stage_label.Font = Enum.Font.SourceSansBold
stage_label.TextScaled = true
stage_label.TextXAlignment = Enum.TextXAlignment.Left
stage_label.TextColor3 = Color3.new(1, 1, 1)
stage_label.Text = "INFECTED"
stage_label.Parent = panel
local countdown_label = Instance.new("TextLabel")
countdown_label.Name = "CountdownLabel"
countdown_label.BackgroundTransparency = 1
countdown_label.Position = UDim2.new(0, 16, 0, 30)
countdown_label.Size = UDim2.new(1, -24, 0, 20)
countdown_label.Font = Enum.Font.SourceSans
countdown_label.TextScaled = true
countdown_label.TextXAlignment = Enum.TextXAlignment.Left
countdown_label.TextColor3 = Color3.fromRGB(220, 220, 220)
countdown_label.Text = ""
countdown_label.Parent = panel
infection_updated.OnClientEvent:Connect(function(update)
	if not update or not update.infected then
		screen_gui.Enabled = false
		return
	end
	screen_gui.Enabled = true
	accent.BackgroundColor3 = update.color or Color3.fromRGB(200, 200, 200)
	stage_label.Text = string.format("INFECTED — Stage %d/%d: %s", update.stage_index, update.stage_count, update.stage)
	stage_label.TextColor3 = update.color or Color3.new(1, 1, 1)
	if update.next_stage and update.seconds_to_next then
		countdown_label.Text = string.format("Worsens to %s in %ds — find a cure station", update.next_stage, math.ceil(update.seconds_to_next))
	else
		countdown_label.Text = "Find a cure station immediately"
	end
end)
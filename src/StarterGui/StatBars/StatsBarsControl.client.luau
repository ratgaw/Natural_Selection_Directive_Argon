local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")

local stamina_updated = replicated_storage:WaitForChild("StaminaUpdated")

local local_player = players.LocalPlayer
local status_bars_gui = script.Parent
local health_fill = status_bars_gui.StatsBarFrame.HealthBar.HealthFill
local stamina_fill = status_bars_gui.StatsBarFrame.StaminaBar.StaminaFill

local function Update_Health_Bar(humanoid)
	local percent = humanoid.Health / humanoid.MaxHealth
	health_fill.Size = UDim2.new(1, 0, math.clamp(percent, 0, 1), 0)
end

local function Connect_Health(character)
	local humanoid = character:WaitForChild("Humanoid")
	Update_Health_Bar(humanoid)
	humanoid.HealthChanged:Connect(function()
		Update_Health_Bar(humanoid)
	end)
	humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		Update_Health_Bar(humanoid)
	end)
end

if local_player.Character then
	Connect_Health(local_player.Character)
end
local_player.CharacterAdded:Connect(Connect_Health)

stamina_updated.OnClientEvent:Connect(function(current, max)
	local percent = current / max
	stamina_fill.Size = UDim2.new(1, 0, math.clamp(percent, 0, 1), 0)
end)
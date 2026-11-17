-- Acid rain client side: green rain around the camera, an exposure banner, and
-- a green screen tint while exposed. Everything here is local to this client;
-- damage and the exposure check are server-side in AcidRainEvent.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local acid_rain_updated = ReplicatedStorage:WaitForChild("AcidRainUpdated")
local local_player = Players.LocalPlayer
local player_gui = local_player:WaitForChild("PlayerGui")

local RAIN_HEIGHT_ABOVE_CAMERA = 30
local RAIN_COLOR = Color3.fromRGB(170, 220, 80)
local EXPOSED_COLOR = Color3.fromRGB(235, 80, 60)
local SHELTERED_COLOR = Color3.fromRGB(150, 210, 90)
local EXPOSED_TINT = Color3.fromRGB(215, 255, 175)

-- Banner
local screen_gui = Instance.new("ScreenGui")
screen_gui.Name = "AcidRainHUD"
screen_gui.ResetOnSpawn = false
screen_gui.IgnoreGuiInset = true
screen_gui.Enabled = false
screen_gui.Parent = player_gui
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0)
-- Below the InfectionHUD panel (which sits at 6%) so both can show at once.
panel.Position = UDim2.new(0.5, 0, 0.13, 0)
panel.Size = UDim2.new(0, 280, 0, 40)
panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
panel.BackgroundTransparency = 0.25
panel.BorderSizePixel = 0
panel.Parent = screen_gui
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = panel
local accent = Instance.new("Frame")
accent.Name = "Accent"
accent.Size = UDim2.new(0, 6, 1, 0)
accent.BorderSizePixel = 0
accent.BackgroundColor3 = SHELTERED_COLOR
accent.Parent = panel
local accent_corner = Instance.new("UICorner")
accent_corner.CornerRadius = UDim.new(0, 8)
accent_corner.Parent = accent
local status_label = Instance.new("TextLabel")
status_label.Name = "StatusLabel"
status_label.BackgroundTransparency = 1
status_label.Position = UDim2.new(0, 16, 0, 6)
status_label.Size = UDim2.new(1, -24, 1, -12)
status_label.Font = Enum.Font.SourceSansBold
status_label.TextScaled = true
status_label.TextXAlignment = Enum.TextXAlignment.Left
status_label.TextColor3 = Color3.new(1, 1, 1)
status_label.Text = "ACID RAIN"
status_label.Parent = panel

-- Screen tint while exposed (local Lighting child, only this client sees it).
local tint = Instance.new("ColorCorrectionEffect")
tint.Name = "AcidRainTint"
tint.TintColor = EXPOSED_TINT
tint.Saturation = -0.1
tint.Enabled = false
tint.Parent = Lighting

-- Green rain following the camera.
local rain_part = nil
local rain_connection = nil
local function Start_Rain()
	if rain_part then
		return
	end
	rain_part = Instance.new("Part")
	rain_part.Name = "AcidRainEmitter"
	rain_part.Size = Vector3.new(60, 1, 60)
	rain_part.Transparency = 1
	rain_part.CanCollide = false
	rain_part.CanQuery = false
	rain_part.CanTouch = false
	rain_part.CastShadow = false
	rain_part.Anchored = true
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "AcidRain"
	emitter.Texture = "" -- default sprite, same as DayNightWeather's rain; swap for a streak decal later
	emitter.Color = ColorSequence.new(RAIN_COLOR)
	emitter.LightEmission = 0.3
	emitter.Size = NumberSequence.new(0.18)
	emitter.Transparency = NumberSequence.new(0.3)
	emitter.Lifetime = NumberRange.new(0.8, 1)
	emitter.Speed = NumberRange.new(45, 55)
	emitter.Rate = 400
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.SpreadAngle = Vector2.new(3, 3)
	emitter.Acceleration = Vector3.new(0, -60, 0)
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.Parent = rain_part
	rain_part.Parent = workspace
	rain_connection = RunService.RenderStepped:Connect(function()
		local camera = workspace.CurrentCamera
		if camera and rain_part then
			rain_part.CFrame = CFrame.new(camera.CFrame.Position + Vector3.new(0, RAIN_HEIGHT_ABOVE_CAMERA, 0))
		end
	end)
end
local function Stop_Rain()
	if rain_connection then
		rain_connection:Disconnect()
		rain_connection = nil
	end
	if rain_part then
		rain_part:Destroy()
		rain_part = nil
	end
end

local function Set_Exposed(exposed)
	tint.Enabled = exposed
	accent.BackgroundColor3 = exposed and EXPOSED_COLOR or SHELTERED_COLOR
	status_label.TextColor3 = exposed and EXPOSED_COLOR or SHELTERED_COLOR
	status_label.Text = exposed and "ACID RAIN — EXPOSED, GET UNDER COVER" or "ACID RAIN — SHELTERED"
end

acid_rain_updated.OnClientEvent:Connect(function(update)
	if not update or not update.active then
		screen_gui.Enabled = false
		tint.Enabled = false
		Stop_Rain()
		return
	end
	Start_Rain()
	if update.exposed ~= nil then
		-- Only participants get exposure updates; spectators just see the rain.
		screen_gui.Enabled = true
		Set_Exposed(update.exposed)
	end
end)

-- Infection from Animal Frenzy's infected animals. Infection time counts up
-- while infected and moves through worse stages: more frequent stumbles, slower
-- walking, then health damage. A cure station clears it; another bite adds
-- REINFECTION_TIME_BURST. Effects are applied by RequestChecker's Heartbeat loop.
-- "Losing control" is a periodic BodyVelocity shove, since the server can't
-- override a player's own movement input.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- Create this RemoteEvent in ReplicatedStorage (same place as
-- EventWarning/HungerUpdated) — nothing creates it automatically.
local infection_updated = ReplicatedStorage:WaitForChild("InfectionUpdated")
local PlayerInfection = {}
PlayerInfection.player_infection = {} -- [player] = {infected, time, next_stumble_at, last_notify_time}
-- UpperBound is the highest time (inclusive) in each stage. Placeholders.
local INFECTION_STAGES = {
	{
		Name = "Early Infection",
		UpperBound = 30,
		StumbleIntervalMin = 6,
		StumbleIntervalMax = 10,
		StumbleForce = 40,
		WalkSpeedMultiplier = 1.0,
		HealthDamagePerSecond = 0,
		Color = Color3.fromRGB(220, 200, 60),
	},
	{
		Name = "Spreading",
		UpperBound = 75,
		StumbleIntervalMin = 4,
		StumbleIntervalMax = 7,
		StumbleForce = 60,
		WalkSpeedMultiplier = 0.85,
		HealthDamagePerSecond = 0,
		Color = Color3.fromRGB(230, 140, 40),
	},
	{
		Name = "Critical",
		UpperBound = math.huge,
		StumbleIntervalMin = 2,
		StumbleIntervalMax = 4,
		StumbleForce = 85,
		WalkSpeedMultiplier = 0.7,
		HealthDamagePerSecond = 2,
		Color = Color3.fromRGB(210, 40, 40),
	},
}
-- Getting bitten again while already infected pushes InfectionTime forward
-- by this many seconds instead of resetting or stacking a second infection.
local REINFECTION_TIME_BURST = 15
-- Safety net so an infected player who never finds/reaches a cure station
-- isn't stuck infected for the entire rest of the match.
local AUTO_CURE_TIMEOUT = 180
local NOTIFY_INTERVAL = 1 -- matches PlayerHunger's "don't spam the network" interval
local function Get_Stage_Index(elapsed)
	for index, stage in ipairs(INFECTION_STAGES) do
		if elapsed <= stage.UpperBound then
			return index
		end
	end
	return #INFECTION_STAGES
end
-- Gameplay effects of the current stage (healthy values when not infected).
local NOT_INFECTED_EFFECTS = {WalkSpeedMultiplier = 1.0, HealthDamagePerSecond = 0}
function PlayerInfection.get_stage_effects(player)
	local data = PlayerInfection.player_infection[player]
	if not data or not data.infected then
		return NOT_INFECTED_EFFECTS
	end
	return INFECTION_STAGES[Get_Stage_Index(data.time)]
end
function PlayerInfection.is_infected(player)
	local data = PlayerInfection.player_infection[player]
	return data ~= nil and data.infected
end
-- Sends the full state so the HUD needs no copy of INFECTION_STAGES.
local function Fire_Update(player, data)
	if not data.infected then
		infection_updated:FireClient(player, {infected = false})
		return
	end
	local stage_index = Get_Stage_Index(data.time)
	local stage = INFECTION_STAGES[stage_index]
	local next_stage = INFECTION_STAGES[stage_index + 1]
	infection_updated:FireClient(player, {
		infected = true,
		stage = stage.Name,
		stage_index = stage_index,
		stage_count = #INFECTION_STAGES,
		seconds_to_next = next_stage and math.max(0, stage.UpperBound - data.time) or nil,
		next_stage = next_stage and next_stage.Name or nil,
		color = stage.Color,
	})
end
function PlayerInfection.infect(player)
	local data = PlayerInfection.player_infection[player]
	if not data then
		return
	end
	if data.infected then
		-- Already infected — another bite accelerates progress instead of
		-- doing nothing or starting a second, separate infection.
		data.time += REINFECTION_TIME_BURST
		Fire_Update(player, data)
		return
	end
	data.infected = true
	data.time = 0
	local first_stage = INFECTION_STAGES[1]
	data.next_stumble_at = os.clock() + math.random(first_stage.StumbleIntervalMin, first_stage.StumbleIntervalMax)
	data.last_notify_time = os.clock()
	Fire_Update(player, data)
end
function PlayerInfection.cure(player)
	local data = PlayerInfection.player_infection[player]
	if not data or not data.infected then
		return
	end
	data.infected = false
	data.time = 0
	Fire_Update(player, data)
end
-- Resets state for a fresh round/new connection — mirrors the other
-- Player* modules' new_player convention (PlayerHunger, PlayerStats, etc.)
function PlayerInfection.new_player(player)
	PlayerInfection.player_infection[player] = {infected = false, time = 0, next_stumble_at = 0, last_notify_time = os.clock()}
end
function PlayerInfection.remove_player(player)
	PlayerInfection.player_infection[player] = nil
end
local function Stumble(character, force)
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChild("Humanoid")
	if not root or not humanoid or humanoid.Health <= 0 then
		return
	end
	local angle = math.random() * math.pi * 2
	local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local body_velocity = Instance.new("BodyVelocity")
	body_velocity.Name = "InfectionStumble"
	body_velocity.MaxForce = Vector3.new(1, 0, 1) * math.huge
	body_velocity.Velocity = direction * force
	body_velocity.Parent = root
	task.delay(0.6, function()
		body_velocity:Destroy()
	end)
end
-- Every Heartbeat: advances infection time, stumbles at the current stage's rate,
-- auto-cures after AUTO_CURE_TIMEOUT, and pushes updates.
function PlayerInfection.infection_tick(player, dt)
	local data = PlayerInfection.player_infection[player]
	if not data or not data.infected then
		return
	end
	local before_stage_index = Get_Stage_Index(data.time)
	data.time += dt
	if data.time >= AUTO_CURE_TIMEOUT then
		PlayerInfection.cure(player)
		return
	end
	local after_stage_index = Get_Stage_Index(data.time)
	local after_stage = INFECTION_STAGES[after_stage_index]
	local now = os.clock()
	if now >= data.next_stumble_at then
		local character = player.Character
		if character then
			Stumble(character, after_stage.StumbleForce)
		end
		data.next_stumble_at = now + math.random(after_stage.StumbleIntervalMin, after_stage.StumbleIntervalMax)
	end
	if after_stage_index ~= before_stage_index or now - data.last_notify_time >= NOTIFY_INTERVAL then
		data.last_notify_time = now
		Fire_Update(player, data)
	end
end
return PlayerInfection
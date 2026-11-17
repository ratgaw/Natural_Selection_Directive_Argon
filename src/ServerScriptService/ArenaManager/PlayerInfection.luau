-- Tracks players infected by the Animal Frenzy event's parasite (see
-- AnimalFrenzyEvent.lua's infected-animal roll and WildLifeManager.lua's
-- Threat_Tick -> PlayerInfection.infect hook on a landed hit). Modeled
-- directly on PlayerHunger.lua's stage/timer/NOTIFY_INTERVAL shape, since
-- this is the same kind of feature: a value that rises over time, crossing
-- fixed thresholds into worse discrete stages, with each stage's effects
-- looked up once and applied by RequestChecker's shared Heartbeat loop
-- (Sync_Movement for WalkSpeed, a new Sync_Infection_Health for damage)
-- rather than this module touching Humanoid stats directly.
--
-- Model: one per-player InfectionTime that counts UP in real seconds while
-- infected (unlike hunger there's no "curing food" that subtracts from it —
-- only a cure station, which zeroes it out entirely). INFECTION_STAGES
-- below sits on fixed time bands and gets strictly worse the longer a
-- player stays infected uncured: longer stumbles closer together, a bigger
-- WalkSpeed penalty, and — only at the final stage — steady health damage.
-- Getting bitten again while already infected doesn't reset progress or
-- start a second infection, it accelerates the existing one (see
-- REINFECTION_TIME_BURST) — more exposure should read as worse, not free.
--
-- [design note] A player's Humanoid takes its movement from their OWN
-- client every frame, so the server calling Humanoid:Move() would just
-- fight the player's own input instead of overriding it — there's no clean
-- server-side way to puppet a player's walk direction the way
-- WildlifeManager puppets an animal's. "Losing control" is implemented
-- instead as a periodic BodyVelocity shove (something the server CAN force
-- reliably) — reads as an involuntary stumble in a random direction, not a
-- forced walk. If that doesn't feel "infected" enough once you see it in
-- game, full input lockout would need a client-side companion script
-- disabling the PlayerModule's controls on InfectionUpdated — a bigger,
-- more trust-sensitive change — happy to build that instead.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- Create this RemoteEvent in ReplicatedStorage (same place as
-- EventWarning/HungerUpdated) — nothing creates it automatically.
local infection_updated = ReplicatedStorage:WaitForChild("InfectionUpdated")
local PlayerInfection = {}
PlayerInfection.player_infection = {} -- [player] = {infected, time, next_stumble_at, last_notify_time}
-- Stage bands, ordered best (just infected) to worst — same "UpperBound is
-- the highest value still inside this stage" shape as PlayerHunger's
-- HUNGER_STAGES. Critical has no upper bound (final stage, matches
-- Starving). All numbers here are placeholders, tune once tested.
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
-- Single lookup point for "what does this player's current infection stage
-- mean gameplay-wise" — mirrors PlayerHunger.get_stage_effects. Falls back
-- to a fully-healthy stand-in when not infected (or no data yet), same
-- defensive shape PlayerHunger/PlayerWeight use elsewhere.
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
-- Pushes the current infection state to the client as a single table —
-- more fields than HungerUpdated needs (stage index/count, the next
-- stage's name, a display color) so the HUD doesn't have to keep its own
-- copy of INFECTION_STAGES just to know what's coming or what color to
-- show.
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
-- Called every Heartbeat for every player, same shape as
-- PlayerHunger.hunger_tick — advances InfectionTime, fires the involuntary
-- stumble at the CURRENT stage's frequency/force (re-read every stumble so
-- escalating into a worse stage immediately speeds/strengthens it, no
-- separate re-roll needed), auto-cures past AUTO_CURE_TIMEOUT, and pushes a
-- client update on a stage change OR every NOTIFY_INTERVAL seconds
-- regardless — the countdown needs to visibly tick down same as hunger's.
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
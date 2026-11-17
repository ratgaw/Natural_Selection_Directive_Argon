-- Hunger. Each player has a hunger value that rises over time (lower = better
-- fed). Endurance slows the rise and activity speeds it up; eating lowers it.
-- Five stages, best to worst: Enhanced, Well-Fed, Normal, Hungry, Starving.
-- Only the stage name and a seconds-to-next-stage estimate go to the client.
-- Not built yet: a world event that spoils food in inventories.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local hunger_updated = ReplicatedStorage:WaitForChild("HungerUpdated")
local PlayerStats = require(script.Parent:WaitForChild("PlayerStats"))
local PlayerHunger = {}
PlayerHunger.player_hunger = {} -- [player] = {value, continuous_actions, pulse_until, last_notify_time, immune}
-- UpperBound is the highest value (inclusive) in each stage. Placeholders.
local HUNGER_STAGES = {
	{Name = "Enhanced", UpperBound = -600, StaminaRegenMultiplier = 1.5, HealthRegenPerSecond = 1, HealthDamagePerSecond = 0},
	{Name = "Well-Fed", UpperBound = -200, StaminaRegenMultiplier = 1.25, HealthRegenPerSecond = 0, HealthDamagePerSecond = 0},
	{Name = "Normal", UpperBound = 200, StaminaRegenMultiplier = 1.0, HealthRegenPerSecond = 0, HealthDamagePerSecond = 0},
	{Name = "Hungry", UpperBound = 600, StaminaRegenMultiplier = 0.65, HealthRegenPerSecond = 0, HealthDamagePerSecond = 0},
	{Name = "Starving", UpperBound = math.huge, StaminaRegenMultiplier = 0.4, HealthRegenPerSecond = 0, HealthDamagePerSecond = 2},
}
-- HungerValue rises this much per second at Endurance 1 with no activity
-- boost active, before the per-point Endurance reduction below.
local BASE_HUNGER_RATE = 1
-- Each Endurance point above 1 slows the rise by this fraction (floored).
local ENDURANCE_HUNGER_REDUCTION_PER_POINT = 0.05
local MIN_HUNGER_RATE_FRACTION = 0.3
-- Stamina-using activity (sprint, attack, jump, swim, dodge, block) speeds
-- hunger by this one shared multiplier.
local ACTIVITY_HUNGER_MULTIPLIER = 1.15
-- Instant actions (attack, jump, dodge) apply the multiplier for this many
-- seconds; sprint/block/swim apply it while active.
local ACTION_PULSE_DURATION = 2
-- How often the countdown is pushed to the client.
local NOTIFY_INTERVAL = 1
-- Best (lowest) hunger value each food tier can reach: Engineered uncapped,
-- Safety Certified -> Well-Fed, Foraged -> Normal, Spoiled -> Hungry.
local TIER_FLOOR = {
	Engineered = -math.huge,
	["Safety Certified"] = -600,
	Foraged = -200,
	Spoiled = 200,
}
local function Get_Stage(value)
	for _, stage in ipairs(HUNGER_STAGES) do
		if value <= stage.UpperBound then
			return stage
		end
	end
	return HUNGER_STAGES[#HUNGER_STAGES]
end
local function Get_Rate_Fraction(player)
	local endurance = PlayerStats.get(player, "Endurance")
	return math.max(MIN_HUNGER_RATE_FRACTION, 1 - (endurance - 1) * ENDURANCE_HUNGER_REDUCTION_PER_POINT)
end
-- Any active or recently pulsed action gives the multiplier once (no stacking).
local function Get_Activity_Multiplier(data)
	if next(data.continuous_actions) ~= nil or os.clock() < data.pulse_until then
		return ACTIVITY_HUNGER_MULTIPLIER
	end
	return 1.0
end
-- Sends the stage name and seconds to the next stage (nil at Starving),
-- projected at the current rate.
local function Fire_Update(player, data)
	local stage = Get_Stage(data.value)
	local seconds_to_next = nil
	if stage.UpperBound ~= math.huge then
		local rate = BASE_HUNGER_RATE * Get_Rate_Fraction(player) * Get_Activity_Multiplier(data)
		if rate > 0 then
			seconds_to_next = math.max(0, (stage.UpperBound - data.value) / rate)
		end
	end
	hunger_updated:FireClient(player, stage.Name, seconds_to_next)
end
function PlayerHunger.new_player(player)
	local data = {value = 0, continuous_actions = {}, pulse_until = 0, last_notify_time = os.clock()} -- starts at Normal (0 sits inside the -200..200 band)
	PlayerHunger.player_hunger[player] = data
	Fire_Update(player, data)
end
function PlayerHunger.remove_player(player)
	PlayerHunger.player_hunger[player] = nil
end
-- Gameplay effects of the player's stage (Normal if no data yet).
function PlayerHunger.get_stage_effects(player)
	local data = PlayerHunger.player_hunger[player]
	local value = data and data.value or 0
	return Get_Stage(value)
end
-- Turns a continuous action on/off (Sprint, Swim, Block). Safe every tick.
function PlayerHunger.set_active(player, action_name, is_active)
	local data = PlayerHunger.player_hunger[player]
	if not data then
		return
	end
	data.continuous_actions[action_name] = is_active or nil
end
-- Marks an instant action (attack, jump, dodge).
function PlayerHunger.pulse(player)
	local data = PlayerHunger.player_hunger[player]
	if not data then
		return
	end
	data.pulse_until = os.clock() + ACTION_PULSE_DURATION
end
-- /dev: stops hunger and resets the player to Normal.
function PlayerHunger.set_immune(player, is_immune)
	local data = PlayerHunger.player_hunger[player]
	if not data then
		return
	end
	data.immune = is_immune or nil
	if is_immune then
		data.value = 0
		Fire_Update(player, data)
	end
end
-- Every Heartbeat: raises hunger and pushes an update on stage change or every
-- NOTIFY_INTERVAL.
function PlayerHunger.hunger_tick(player, dt)
	local data = PlayerHunger.player_hunger[player]
	if not data or data.immune then
		return
	end
	local rate_fraction = Get_Rate_Fraction(player)
	local activity_multiplier = Get_Activity_Multiplier(data)
	local before_stage = Get_Stage(data.value)
	data.value = data.value + BASE_HUNGER_RATE * rate_fraction * activity_multiplier * dt
	local after_stage = Get_Stage(data.value)
	local now = os.clock()
	if after_stage.Name ~= before_stage.Name or now - data.last_notify_time >= NOTIFY_INTERVAL then
		data.last_notify_time = now
		Fire_Update(player, data)
	end
end
-- Lowers hunger by food_value, capped at the tier's floor. Returns the new
-- stage. Spoiled damage is applied by the caller (RequestChecker).
function PlayerHunger.eat(player, food_tier, food_value)
	local data = PlayerHunger.player_hunger[player]
	if not data then
		return "Normal"
	end
	local floor = TIER_FLOOR[food_tier] or -math.huge
	data.value = math.max(data.value - food_value, floor)
	local stage = Get_Stage(data.value)
	Fire_Update(player, data)
	return stage.Name
end
return PlayerHunger
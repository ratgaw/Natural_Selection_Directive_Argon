-- Core data layer for the hunger system (Phase 3). Stateful, unlike
-- PlayerWeight — hunger accumulates over time and has to persist between
-- the ticks that change it, the same shape as PlayerStamina.
--
-- Model: one per-player HungerValue that rises the hungrier a player gets
-- (lower = better fed). 5 discrete stages sit on fixed bands of that value
-- (HUNGER_STAGES below, ordered best to worst): Enhanced, Well-Fed, Normal,
-- Hungry, Starving. The value rises passively every Heartbeat (rate slowed
-- by Endurance — [[roblox-game-progression]]: "Endurance -> ... hunger
-- rate (slower increase)" — and sped up by activity, see ACTIVITY_HUNGER_
-- MULTIPLIER below) and drops when food is eaten via UseItemRequest's Food
-- branch (RequestChecker.lua), same consumption path as StatBoost/
-- MinimapUpgrade items.
--
-- Only the discrete stage NAME plus an estimated seconds-to-next-stage are
-- ever pushed to the client (HungerUpdated) — the raw numeric value stays
-- server-only. Matches the [stated] decision that hunger is not a separate
-- UI bar/meter; the countdown is a projection at the player's CURRENT rate,
-- not a stored value, so it can jump around a bit as activity starts/stops
-- — same caveat any "time to empty" estimate has.
--
-- Still NOT included (deferred):
--   - The world "spoil event" that's supposed to turn Safety Certified/
--     Foraged food already in inventory into Spoiled food — no world-event
--     system exists yet to hang it off of.
--   - Foraging (gathering Foraged-tier food from animals/plants) — no
--     foraging action exists yet; Foraged ItemData entries can still be
--     authored and handed out via crates/test-give in the meantime.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local hunger_updated = ReplicatedStorage:WaitForChild("HungerUpdated") -- needs manual creation in Studio, same outstanding step as every other new remote this project
local PlayerStats = require(script.Parent:WaitForChild("PlayerStats"))
local PlayerHunger = {}
PlayerHunger.player_hunger = {} -- [player] = {value, continuous_actions, pulse_until, last_notify_time, immune}
-- Stage bands, ordered best to worst. UpperBound is the highest HungerValue
-- (inclusive) still within that stage — Starving has no upper bound. All
-- numbers here (bounds AND effect multipliers) are placeholders, tune once
-- tested like every other numeric pass in this project.
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
-- Each Endurance point above 1 slows the rise by this fraction (e.g. 0.05
-- => Endurance 5 rises hunger at 80% of base rate). Clamped so it can never
-- reach 0 — hunger should always keep advancing, just more slowly.
local ENDURANCE_HUNGER_REDUCTION_PER_POINT = 0.05
local MIN_HUNGER_RATE_FRACTION = 0.3
-- [stated]: "just about everything if not everything that uses stamina"
-- speeds up hunger — sprinting, attacking, jumping, swimming, dodging,
-- blocking — "nothing drastic ... around x1.1 to x1.25". One shared
-- multiplier for all of them for now rather than tuning each action
-- separately; easy to split into a per-action table later if some should
-- hit harder than others.
local ACTIVITY_HUNGER_MULTIPLIER = 1.15
-- Sprinting/blocking/swimming are genuinely continuous states (something
-- else toggles them on/off via set_active, see below) but attacking/
-- jumping/dodging are instantaneous — they don't have a natural "while
-- it's happening" window, so a pulse instead applies the multiplier for
-- this many seconds after the action fires.
local ACTION_PULSE_DURATION = 2
-- Countdown display only needs to refresh about this often — matches
-- PlayerStamina's own "don't spam the network" philosophy while still
-- feeling live to whoever's watching the number tick down.
local NOTIFY_INTERVAL = 1
-- Food tier -> the best (lowest) HungerValue eating that tier's food can
-- ever push a player to, regardless of the item's own Food.Value — matches
-- the [stated] tier caps: Engineered uncapped (only tier that can reach
-- Enhanced), Safety Certified caps at Well-Fed, Foraged caps at Normal,
-- Spoiled caps at Hungry.
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
-- True while ANY continuous action is active (sprinting/blocking/swimming)
-- or an instantaneous one (attack/jump/dodge) pulsed within the last
-- ACTION_PULSE_DURATION seconds. Doesn't stack multiple simultaneous
-- actions into a bigger multiplier — matches the [stated] "nothing
-- drastic" framing better than compounding sprint+attack+jump all at once.
local function Get_Activity_Multiplier(data)
	if next(data.continuous_actions) ~= nil or os.clock() < data.pulse_until then
		return ACTIVITY_HUNGER_MULTIPLIER
	end
	return 1.0
end
-- Pushes the current stage name plus an estimated seconds-to-next-stage
-- (nil once at Starving — there's no worse stage to count down to) to the
-- client. The estimate is a straight-line projection at the CURRENT rate
-- (Endurance + whatever activity is active right now) — it's recomputed
-- fresh every call rather than stored, so it stays honest even though it
-- isn't a promise (stopping/starting an activity will shift it).
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
function PlayerHunger.get_stage(player)
	local data = PlayerHunger.player_hunger[player]
	if not data then
		return "Normal"
	end
	return Get_Stage(data.value).Name
end
-- Single lookup point for "what does this player's current hunger stage
-- mean gameplay-wise" — mirrors PlayerWeight.get_tier_effects. Callers
-- (PlayerStamina.get_regen_rate, RequestChecker's hunger health tick)
-- multiply/apply these rather than each keeping their own copy of the
-- stage table. Falls back to Normal (the default new_player value) if
-- this player has no hunger data yet, same defensive shape PlayerStamina
-- uses elsewhere.
function PlayerHunger.get_stage_effects(player)
	local data = PlayerHunger.player_hunger[player]
	local value = data and data.value or 0
	return Get_Stage(value)
end
-- Toggles a continuous hunger-speeding action on/off — Sprint (called from
-- RequestChecker.Sync_Movement, mirrors the same MoveDirection-based check
-- Sync_Movement already uses for stamina drain), Swim (also Sync_Movement,
-- off Humanoid's own built-in Swimming state — no custom water mechanic
-- needed for that part), and Block (PlayerCombat.start_block/stop_block).
-- Safe to call every tick with the current boolean state; also safe to
-- call before new_player has run (no-ops).
function PlayerHunger.set_active(player, action_name, is_active)
	local data = PlayerHunger.player_hunger[player]
	if not data then
		return
	end
	data.continuous_actions[action_name] = is_active or nil
end
-- Marks an instantaneous action (attack/jump/dodge) as having just
-- happened, so the activity multiplier applies for a short window after it
-- — called from PlayerCombat.attack/dodge and ArenaManager's per-character
-- Jumping state hookup.
function PlayerHunger.pulse(player)
	local data = PlayerHunger.player_hunger[player]
	if not data then
		return
	end
	data.pulse_until = os.clock() + ACTION_PULSE_DURATION
end
-- [stated] "/dev text command... never getting hungry" -- a standing flag
-- checked first in hunger_tick below, so HungerValue simply stops moving
-- at all (and whatever read HealthDamagePerSecond, e.g. RequestChecker's
-- hunger health tick, never sees a Starving player to damage) rather than
-- this needing to understand or duplicate the health-damage logic itself.
-- Immediately resets back to Normal on enabling, so a player who was
-- already Starving isn't still sitting in that stage (and still taking its
-- damage wherever that's read) until dev mode happens to coast them back
-- down naturally -- which it never would, since the tick is now skipped.
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
-- Called every Heartbeat for every player with hunger data — raises
-- HungerValue at a rate slowed by Endurance and sped up by whatever
-- activity is currently active. Fires a client update on a stage change OR
-- every NOTIFY_INTERVAL seconds regardless (unlike PlayerWeight/PlayerStats'
-- change-only pattern) — the countdown needs to visibly tick down even
-- while the stage itself hasn't changed yet.
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
-- Applies a food item's effect — subtracts food_value from HungerValue,
-- clamped so it can't push past that food's tier ceiling (e.g. a Safety
-- Certified item can never push a player past the Well-Fed boundary into
-- Enhanced; Engineered's TIER_FLOOR is -huge, so it never clamps).
-- Returns the resulting stage name. Any "Spoiled food deals a little
-- damage on eat" is intentionally NOT applied here — PlayerHunger has no
-- reason to know about Humanoid, so the caller (UseItemRequest's Food
-- branch in RequestChecker.lua) applies that damage itself using the
-- item's own ItemData.Food.SpoiledDamage field.
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
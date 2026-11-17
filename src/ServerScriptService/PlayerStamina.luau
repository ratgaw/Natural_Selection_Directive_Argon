local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local stamina_updated = ReplicatedStorage:WaitForChild("StaminaUpdated")
local PlayerHunger = require(script.Parent:WaitForChild("PlayerHunger"))
local PlayerStats = require(ServerScriptService:WaitForChild("PlayerStats"))
local PlayerStamina = {}
PlayerStamina.player_stamina = {} -- [player] = {current, last_spend_time} — max is no longer stored, see get_max
local BASE_MAX_STAMINA = 100
-- [stated] "Endurance -> sprint stamina duration" — implemented as a bigger
-- max pool per point rather than a sprint-specific discount, same shape as
-- PlayerWeight's Strength->carry-weight scaling. Placeholder, tune once
-- tested.
local ENDURANCE_MAX_STAMINA_PER_POINT = 10
local BASE_REGEN_RATE = 10
local BASE_REGEN_DELAY = 1
-- [stated] "faster stamina-regen-after-empty recovery" — each Endurance
-- point above 1 shortens the post-spend delay before regen kicks back in.
-- Floored so there's always SOME delay, same shape as PlayerHunger's rate
-- floor.
local ENDURANCE_REGEN_DELAY_REDUCTION_PER_POINT = 0.05
local MIN_REGEN_DELAY_FRACTION = 0.4
-- Was flat for every player before the hunger system existed. Well-Fed/
-- Enhanced speed regen up, Hungry/Starving slow it down; PlayerHunger.
-- get_stage_effects defaults to Normal (multiplier 1.0) if this player has
-- no hunger data yet, so this stays safe even if PlayerHunger.new_player
-- hasn't run. regen_tick and the client display both read through this one
-- function so they can never drift out of sync with each other.
function PlayerStamina.get_regen_rate(player)
	local hunger_effects = PlayerHunger.get_stage_effects(player)
	return BASE_REGEN_RATE * hunger_effects.StaminaRegenMultiplier
end
-- Max stamina, like PlayerWeight's max carry weight, is derived on demand
-- from Endurance rather than cached — a stat increase takes effect
-- immediately with nothing to keep in sync.
function PlayerStamina.get_max(player)
	local endurance = PlayerStats.get(player, "Endurance")
	return BASE_MAX_STAMINA + (endurance - 1) * ENDURANCE_MAX_STAMINA_PER_POINT
end
function PlayerStamina.get_regen_delay(player)
	local endurance = PlayerStats.get(player, "Endurance")
	local fraction = math.max(MIN_REGEN_DELAY_FRACTION, 1 - (endurance - 1) * ENDURANCE_REGEN_DELAY_REDUCTION_PER_POINT)
	return BASE_REGEN_DELAY * fraction
end
-- Centralizes every stamina change through one path, so the client only
-- gets a network update when the displayed (whole-number) value actually
-- changes, rather than on every single Heartbeat tick.
local function Set_Current(player, new_value, data)
	local max = PlayerStamina.get_max(player)
	new_value = math.clamp(new_value, 0, max)
	if math.floor(new_value) ~= math.floor(data.current) then
		stamina_updated:FireClient(player, new_value, max, PlayerStamina.get_regen_rate(player))
	end
	data.current = new_value
end
function PlayerStamina.new_player(player)
	local data = {current = PlayerStamina.get_max(player), last_spend_time = 0}
	PlayerStamina.player_stamina[player] = data
	-- Fire once immediately so the stats panel isn't blank until the
	-- first spend/regen tick naturally changes the floored value.
	stamina_updated:FireClient(player, data.current, PlayerStamina.get_max(player), PlayerStamina.get_regen_rate(player))
end
function PlayerStamina.remove_player(player)
	PlayerStamina.player_stamina[player] = nil
end
function PlayerStamina.get(player)
	local data = PlayerStamina.player_stamina[player]
	return data and data.current or 0
end
-- Re-pushes current/max/regen to the client without changing anything —
-- mirrors PlayerWeight.notify. Needed now that max stamina depends on
-- Endurance: a Strength/Endurance/Dexterity stim changes what "max" means
-- even when current stamina itself didn't move, so RequestChecker's
-- UseItemRequest handler calls this the same place it already calls
-- PlayerWeight.notify.
function PlayerStamina.notify(player)
	local data = PlayerStamina.player_stamina[player]
	if not data then
		return
	end
	stamina_updated:FireClient(player, data.current, PlayerStamina.get_max(player), PlayerStamina.get_regen_rate(player))
end
-- Instant stamina restore — [stated] drink items give a small immediate
-- refill instead of (or alongside) the smaller hunger relief they give
-- compared to food, so a "refreshing" drink actually feels different from
-- a "filling" meal without needing a whole separate mechanic. Clamped to
-- max the same as every other path through Set_Current.
function PlayerStamina.restore(player, amount)
	local data = PlayerStamina.player_stamina[player]
	if not data then
		return
	end
	Set_Current(player, data.current + amount, data)
end
function PlayerStamina.spend(player, amount)
	local data = PlayerStamina.player_stamina[player]
	if not data or data.current < amount then
		return false
	end
	Set_Current(player, data.current - amount, data)
	data.last_spend_time = os.clock()
	return true
end
function PlayerStamina.drain_tick(player, amount_per_second, dt)
	local data = PlayerStamina.player_stamina[player]
	if not data then
		return false
	end
	local amount = amount_per_second * dt
	if data.current < amount then
		Set_Current(player, 0, data)
		data.last_spend_time = os.clock()
		return false
	end
	Set_Current(player, data.current - amount, data)
	data.last_spend_time = os.clock()
	return true
end
function PlayerStamina.regen_tick(dt)
	local now = os.clock()
	for player, data in pairs(PlayerStamina.player_stamina) do
		local max = PlayerStamina.get_max(player)
		if now - data.last_spend_time >= PlayerStamina.get_regen_delay(player) and data.current < max then
			Set_Current(player, data.current + PlayerStamina.get_regen_rate(player) * dt, data)
		end
	end
end
return PlayerStamina
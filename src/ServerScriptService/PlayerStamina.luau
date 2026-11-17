local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local stamina_updated = ReplicatedStorage:WaitForChild("StaminaUpdated")
local PlayerHunger = require(script.Parent:WaitForChild("PlayerHunger"))
local PlayerStats = require(ServerScriptService:WaitForChild("PlayerStats"))
local PlayerStamina = {}
PlayerStamina.player_stamina = {} -- [player] = {current, last_spend_time}
local BASE_MAX_STAMINA = 100
-- Endurance -> bigger max stamina. Placeholder.
local ENDURANCE_MAX_STAMINA_PER_POINT = 10
local BASE_REGEN_RATE = 10
local BASE_REGEN_DELAY = 1
-- Endurance -> shorter delay before regen starts (floored).
local ENDURANCE_REGEN_DELAY_REDUCTION_PER_POINT = 0.05
local MIN_REGEN_DELAY_FRACTION = 0.4
-- Regen rate, scaled by hunger stage. Used by both regen_tick and the client display.
function PlayerStamina.get_regen_rate(player)
	local hunger_effects = PlayerHunger.get_stage_effects(player)
	return BASE_REGEN_RATE * hunger_effects.StaminaRegenMultiplier
end
-- Max stamina from Endurance, computed on demand.
function PlayerStamina.get_max(player)
	local endurance = PlayerStats.get(player, "Endurance")
	return BASE_MAX_STAMINA + (endurance - 1) * ENDURANCE_MAX_STAMINA_PER_POINT
end
function PlayerStamina.get_regen_delay(player)
	local endurance = PlayerStats.get(player, "Endurance")
	local fraction = math.max(MIN_REGEN_DELAY_FRACTION, 1 - (endurance - 1) * ENDURANCE_REGEN_DELAY_REDUCTION_PER_POINT)
	return BASE_REGEN_DELAY * fraction
end
-- All changes go through here; the client is only updated when the whole
-- number changes.
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
-- Re-sends current/max/regen without changing anything (e.g. after a stat boost).
function PlayerStamina.notify(player)
	local data = PlayerStamina.player_stamina[player]
	if not data then
		return
	end
	stamina_updated:FireClient(player, data.current, PlayerStamina.get_max(player), PlayerStamina.get_regen_rate(player))
end
-- Instant stamina refill (drinks). Clamped to max.
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
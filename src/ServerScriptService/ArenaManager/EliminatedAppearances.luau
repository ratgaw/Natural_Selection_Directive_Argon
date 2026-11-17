local ServerScriptService = game:GetService("ServerScriptService")
local PlayerEquipment = require(ServerScriptService:WaitForChild("PlayerEquipment"))

local EliminatedAppearances = {}
EliminatedAppearances.pool = {} -- {description = HumanoidDescription, equipped_items = {slot = item_name}}

function EliminatedAppearances.capture(player, character)
	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid then
		return
	end

	local description = humanoid:GetAppliedDescription()

	local equipped_items = {}
	local equipped = PlayerEquipment.player_equipment[player]
	if equipped then
		for slot, entry in pairs(equipped) do
			equipped_items[slot] = entry.ItemName
		end
	end

	table.insert(EliminatedAppearances.pool, {
		description = description,
		equipped_items = equipped_items,
	})
end

function EliminatedAppearances.get_pool()
	return EliminatedAppearances.pool
end

return EliminatedAppearances

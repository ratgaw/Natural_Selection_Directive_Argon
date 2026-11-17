local PlayerInventory = {}
PlayerInventory.player_inventories = {}
type inventory_slot_data = {
	ItemName: string?;
	ItemID: number?;
	ItemAmount: number?;
	StackSize: number?;
	Equipable: boolean?;
	Weight: number?;
	ArmorSlot: number?;
}
function PlayerInventory.new_inventory(player)
	PlayerInventory.player_inventories[player] = {}
end
function PlayerInventory.remove_inventory(player)
	PlayerInventory.player_inventories[player] = nil
end
function PlayerInventory.add_item(player, item_name, amount)
	amount = amount or 1
	local inventory = PlayerInventory.player_inventories[player]
	if not inventory then
		inventory = {}
		PlayerInventory.player_inventories[player] = inventory
	end
	inventory[item_name] = (inventory[item_name] or 0) + amount
	return inventory
end
function PlayerInventory.get_amount(player, item_name)
	local inventory = PlayerInventory.player_inventories[player]
	if not inventory then
		return 0
	end
	return inventory[item_name] or 0
end
function PlayerInventory.has_item(player, item_name, amount)
	amount = amount or 1
	local inventory = PlayerInventory.player_inventories[player]
	return inventory ~= nil and (inventory[item_name] or 0) >= amount
end
function PlayerInventory.remove_item(player, item_name, amount)
	amount = amount or 1
	local inventory = PlayerInventory.player_inventories[player]
	if not inventory or not inventory[item_name] then
		return false
	end
	if inventory[item_name] < amount then
		return false
	end
	inventory[item_name] -= amount
	if inventory[item_name] <= 0 then
		inventory[item_name] = nil
	end
	return true
end
return PlayerInventory
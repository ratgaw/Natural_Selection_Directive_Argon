-- Built in code functions
local replicated_storage = game:GetService("ReplicatedStorage")
local user_input_service = game:GetService("UserInputService")
local tween_service = game:GetService("TweenService")
local Players = game:GetService("Players")
local local_player = Players.LocalPlayer
local player_scripts = local_player:WaitForChild("PlayerScripts")
-- Signal calling
local inventory_updated = replicated_storage:WaitForChild("InventoryUpdated")
local equip_request = replicated_storage:WaitForChild("EquipRequest")
local unequip_request = replicated_storage:WaitForChild("UnequipRequest")
local equipment_updated = replicated_storage:WaitForChild("EquipmentUpdated")
local use_item_request = replicated_storage:WaitForChild("UseItemRequest")
local drop_item_request = replicated_storage:WaitForChild("DropItemRequest")
-- Ctrl+click drops equipped gear (see Handle_Ctrl_Click).
local drop_equipped_request = replicated_storage:WaitForChild("DropEquippedRequest")
local stats_updated = replicated_storage:WaitForChild("StatsUpdated")
local stamina_updated = replicated_storage:WaitForChild("StaminaUpdated")
local weight_updated = replicated_storage:WaitForChild("WeightUpdated")
local hunger_updated = replicated_storage:WaitForChild("HungerUpdated")
-- Item data lookup (icons, descriptions, equip info)
local item_data = require(replicated_storage:WaitForChild("ItemData"))
-- Used to only start drags while the inventory is actually open.
local camera_lock_state = require(player_scripts:WaitForChild("CameraLockState"))
-- Setting references to access inventory slots
local inventory_gui = script.Parent
local grid_area = inventory_gui.Inventory.Backpack.GridArea
local hot_bar = inventory_gui.HotBar
local inventory_slot_template = grid_area:WaitForChild("InventoryItem")
local equipment_grid = inventory_gui.Inventory.Equipment.EquipmentGrid
-- Item description / scan panel references
local description_panel = inventory_gui.Inventory.ItemDescription
local scan_icon = description_panel.ItemImage
local scan_text = description_panel.ItemText
-- Maps our abstract slot names (used server-side) to the actual GUI
-- instance names, which don't match 1:1.
local EQUIPMENT_SLOT_NAMES = {
	Head = "HeadEquipment",
	Torso = "TorsoEquipment",
	Legs = "LegsEquipment",
}
-- Reverse lookup: GUI instance name -> abstract slot name
local GUI_NAME_TO_SLOT = {}
for slot_name, gui_name in pairs(EQUIPMENT_SLOT_NAMES) do
	GUI_NAME_TO_SLOT[gui_name] = slot_name
end
-- Setting references to the panels for the scanning border effect
local stats_panel = inventory_gui.Inventory.Stats
local gear_panel = inventory_gui.Inventory.Equipment
local inv_panel = inventory_gui.Inventory.Backpack
-- Stats panel value labels — names match exactly what's in Studio, note
-- the inconsistent capitalization on "stat"/"Stat" between a few of them.
local stats_grid = stats_panel.StatsGrid
local armor_stat_label = stats_grid:WaitForChild("ARMOR stat")
local dex_stat_label = stats_grid:WaitForChild("DEX stat")
local end_stat_label = stats_grid:WaitForChild("END Stat")
local health_stat_label = stats_grid:WaitForChild("HEALTH Stat")
local stam_regen_stat_label = stats_grid:WaitForChild("STAM REGEN Stat")
local hunger_stat_label = stats_grid:WaitForChild("HUNGER Stat")
local str_stat_label = stats_grid:WaitForChild("STR Stat")
-- Bracket-indexed because the instance name contains "&".
local storage_weight_panel = inventory_gui.Inventory.Equipment["Storage&Weight"]
local weight_label = storage_weight_panel:WaitForChild("Weight")
-- How far the mouse has to move before a press+release counts as a drag
local CLICK_MOVE_THRESHOLD = 6
-- Setting variables for inventory item dragging
local dragged_item = nil
local dragged_clone = nil
local dragged_item_name = nil
local dragged_item_amount = nil
local drag_start_position = nil
local function Clear_Items()
	for _, child in ipairs(grid_area:GetChildren()) do
		if child:IsA("TextButton") and child ~= inventory_slot_template then
			child:Destroy()
		end
	end
end
local function Where_Is_Mouse(gui_object, mouse_position)
	local pos = gui_object.AbsolutePosition
	local size = gui_object.AbsoluteSize
	return mouse_position.X >= pos.X
		and mouse_position.X <= pos.X + size.X
		and mouse_position.Y >= pos.Y
		and mouse_position.Y <= pos.Y + size.Y
end
local function Get_Combined_Slots()
	local combined = {}
	for _, child in ipairs(grid_area:GetChildren()) do
		if child ~= inventory_slot_template then
			table.insert(combined, child)
		end
	end
	for _, child in ipairs(hot_bar:GetChildren()) do
		table.insert(combined, child)
	end
	for _, child in ipairs(equipment_grid:GetChildren()) do
		table.insert(combined, child)
	end
	return combined
end
-- Hotbar slots in number-key order.
local function Get_Sorted_Hotbar_Slots()
	local slots = {}
	for _, child in ipairs(hot_bar:GetChildren()) do
		if child:IsA("TextButton") or child:IsA("ImageButton") then
			table.insert(slots, child)
		end
	end
	table.sort(slots, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	return slots
end
-- Updates the Scan panel with the given item's icon and description.
local function Show_Item_Info(item_name)
	local data = item_data[item_name]
	if not data then
		return
	end
	scan_icon.Image = data.Icon or ""
	scan_text.Text = data.Description or ""
end
-- Shows the item name on the button and the count (if > 1) on ItemAmount.
-- Safe on slots without an ItemAmount child.
local function Set_Slot_Display(slot, item_name, amount)
	slot.Text = item_name or ""
	local amount_label = slot:FindFirstChild("ItemAmount")
	if amount_label then
		if amount and amount > 1 then
			amount_label.Text = tostring(amount)
			amount_label.Visible = true
		else
			amount_label.Text = ""
			amount_label.Visible = false
		end
	end
end
local function Create_Inventory_Slot(item_name, amount)
	local slot = inventory_slot_template:Clone()
	slot:SetAttribute("ItemName", item_name)
	slot:SetAttribute("Amount", amount)
	slot.Name = item_name
	slot.Visible = true
	Set_Slot_Display(slot, item_name, amount)
	slot.Parent = grid_area
	return slot
end
local function Add_Scanning_Border(stroke)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(90, 75, 15)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 220, 80)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(90, 75, 15)),
	})
	gradient.Parent = stroke
	local tween = tween_service:Create(
		gradient,
		TweenInfo.new(2.5, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, false),
		{Rotation = 360}
	)
	tween:Play()
end
local currently_equipped = {}
-- Display-only total Defense (counted once per item, like the server's
-- get_total_defense).
local function Compute_Total_Defense(equipped)
	local total = 0
	local counted_items = {}
	for _, entry in pairs(equipped) do
		if not counted_items[entry.ItemName] then
			counted_items[entry.ItemName] = true
			local data = item_data[entry.ItemName]
			if data and data.Defense then
				total = total + data.Defense
			end
		end
	end
	return total
end
local function Update_Equipment_Display(equipped)
	currently_equipped = {}
	for slot_name, entry in pairs(equipped) do
		currently_equipped[slot_name] = entry.ItemName
	end
	for slot_name, gui_name in pairs(EQUIPMENT_SLOT_NAMES) do
		local slot = equipment_grid:FindFirstChild(gui_name)
		if slot then
			local entry = equipped[slot_name]
			if entry then
				slot:SetAttribute("ItemName", entry.ItemName)
				slot.Text = entry.ItemName
			else
				slot:SetAttribute("ItemName", nil)
				slot.Text = slot_name:upper()
			end
		end
	end
	armor_stat_label.Text = tostring(Compute_Total_Defense(equipped))
end
equipment_updated.OnClientEvent:Connect(Update_Equipment_Display)
-- STR/DEX/END from PlayerStats, STAMINA REGEN from PlayerStamina, HEALTH from
-- the local Humanoid, HUNGER from PlayerHunger.
stats_updated.OnClientEvent:Connect(function(stats)
	str_stat_label.Text = tostring(stats.Strength)
	dex_stat_label.Text = tostring(stats.Dexterity)
	end_stat_label.Text = tostring(stats.Endurance)
end)
stamina_updated.OnClientEvent:Connect(function(current, max, regen_rate)
	stam_regen_stat_label.Text = string.format("%.1f/s", regen_rate)
end)
-- seconds_to_next is a projection at the current rate (nil at Starving), so it
-- shifts as activity changes.
hunger_updated.OnClientEvent:Connect(function(stage_name, seconds_to_next)
	if seconds_to_next then
		hunger_stat_label.Text = string.format("%s (%ds)", stage_name, math.ceil(seconds_to_next))
	else
		hunger_stat_label.Text = stage_name
	end
end)
-- Carried/max weight and tier, pushed by PlayerWeight on any change.
weight_updated.OnClientEvent:Connect(function(data)
	weight_label.Text = string.format("%.1f/%.1f (%s)", data.Carried, data.Max, data.Tier)
end)
local function Setup_Health_Display(character)
	local humanoid = character:WaitForChild("Humanoid")
	local function Update_Health_Display()
		health_stat_label.Text = string.format("%d/%d", math.floor(humanoid.Health), humanoid.MaxHealth)
	end
	humanoid.HealthChanged:Connect(Update_Health_Display)
	humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(Update_Health_Display)
	Update_Health_Display()
end
if local_player.Character then
	Setup_Health_Display(local_player.Character)
end
local_player.CharacterAdded:Connect(Setup_Health_Display)
-- Weapons, armor and backpacks don't stack: the server just keeps a count, and
-- the client shows that many separate slots. Food (which also has a
-- WeaponModel so it can be held) and other consumables stack.
local function Is_Stackable(data)
	if data.ArmorTemplate or data.BackpackModel then
		return false
	end
	if data.WeaponModel and not data.Food then
		return false
	end
	return true
end
-- Shift-click: armor equips immediately; anything else goes to the first empty
-- hotbar slot, or swaps into the last one if the hotbar is full.
local function Get_First_Empty_Hotbar_Slot()
	for _, slot in ipairs(Get_Sorted_Hotbar_Slots()) do
		if not slot:GetAttribute("ItemName") then
			return slot
		end
	end
	return nil
end
-- Existing grid slot for item_name, so stackables merge when returning from
-- the hotbar.
local function Find_Grid_Slot(item_name)
	for _, child in ipairs(grid_area:GetChildren()) do
		if child ~= inventory_slot_template and child.Name == item_name then
			return child
		end
	end
	return nil
end
local function Move_Item_To_Hotbar(source_slot, item_name, amount)
	local target_slot = Get_First_Empty_Hotbar_Slot()
	local bumped_name, bumped_amount = nil, nil
	if not target_slot then
		local sorted = Get_Sorted_Hotbar_Slots()
		target_slot = sorted[#sorted]
		if not target_slot then
			return -- no hotbar slots exist at all
		end
		bumped_name = target_slot:GetAttribute("ItemName")
		bumped_amount = target_slot:GetAttribute("Amount")
	end
	target_slot:SetAttribute("ItemName", item_name)
	target_slot:SetAttribute("Amount", amount)
	Set_Slot_Display(target_slot, item_name, amount)
	if bumped_name then
		-- Same swap behavior as dragging onto an occupied slot: the item
		-- that got bumped out takes the shift-clicked item's old spot.
		source_slot:SetAttribute("ItemName", bumped_name)
		source_slot:SetAttribute("Amount", bumped_amount)
		Set_Slot_Display(source_slot, bumped_name, bumped_amount)
	elseif source_slot.Parent == grid_area then
		source_slot:Destroy()
	else
		source_slot:SetAttribute("ItemName", nil)
		source_slot:SetAttribute("Amount", nil)
		Set_Slot_Display(source_slot, "", nil)
	end
end
-- Shift-click on equipped armor or a hotbar item sends it back to the inventory.
local function Handle_Shift_Click(slot)
	local item_name = slot:GetAttribute("ItemName")
	if not item_name then
		return
	end
	local data = item_data[item_name]
	if not data then
		return
	end
	if slot.Parent == equipment_grid then
		-- The server refunds the item and pushes updates that redraw both panels.
		local slot_name = GUI_NAME_TO_SLOT[slot.Name] or slot.Name
		unequip_request:FireServer(slot_name)
		return
	end
	if data.ArmorTemplate or data.BackpackModel then
		equip_request:FireServer(item_name)
		return
	end
	if data.StatBoost or data.MinimapUpgrade or data.Food then
		-- Consumables can be used from anywhere, including the hotbar.
		use_item_request:FireServer(item_name)
		return
	end
	if slot.Parent == hot_bar then
		-- Back to the inventory: unequip first if it's the held weapon; otherwise this
		-- is client-only, so mirror it back into the grid locally (merging if stackable).
		local amount = slot:GetAttribute("Amount") or 1
		if currently_equipped["Weapon"] == item_name then
			unequip_request:FireServer("Weapon")
		elseif Is_Stackable(data) then
			local existing = Find_Grid_Slot(item_name)
			if existing then
				local new_amount = (existing:GetAttribute("Amount") or 1) + amount
				existing:SetAttribute("Amount", new_amount)
				Set_Slot_Display(existing, item_name, new_amount)
			else
				Create_Inventory_Slot(item_name, amount)
			end
		else
			for _ = 1, amount do
				Create_Inventory_Slot(item_name, 1)
			end
		end
		slot:SetAttribute("ItemName", nil)
		slot:SetAttribute("Amount", nil)
		Set_Slot_Display(slot, "", nil)
		return
	end
	local amount = slot:GetAttribute("Amount") or 1
	Move_Item_To_Hotbar(slot, item_name, amount)
end
-- Drops exactly what's in this slot, then clears the slot locally (hotbar slots
-- are client state and need clearing by hand).
local function Drop_Slot_Contents(slot, item_name)
	local amount = slot:GetAttribute("Amount") or 1
	drop_item_request:FireServer(item_name, amount)
	if slot.Parent == grid_area then
		slot:Destroy()
	elseif slot.Parent == hot_bar then
		slot:SetAttribute("ItemName", nil)
		slot:SetAttribute("Amount", nil)
		Set_Slot_Display(slot, "", nil)
	end
end
-- Shift+right-click drops a slot's contents. Equipped items are excluded
-- (use ctrl+click).
local function Handle_Shift_Right_Click(slot)
	if slot.Parent == equipment_grid then
		return
	end
	local item_name = slot:GetAttribute("ItemName")
	if not item_name then
		return
	end
	Drop_Slot_Contents(slot, item_name)
end
-- Ctrl+click drops an item or stack, including equipped gear. Equipped items use
-- DropEquippedRequest so the unequip and drop happen in one server step.
local function Handle_Ctrl_Click(slot)
	local item_name = slot:GetAttribute("ItemName")
	if not item_name then
		return
	end
	if slot.Parent == equipment_grid then
		local slot_name = GUI_NAME_TO_SLOT[slot.Name] or slot.Name
		drop_equipped_request:FireServer(slot_name)
		return
	end
	Drop_Slot_Contents(slot, item_name)
end
user_input_service.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if not camera_lock_state.gui_open then
			return
		end
		local mouse_position = input.Position
		for _, slot in ipairs(Get_Combined_Slots()) do
			if (slot:IsA("TextButton") or slot:IsA("ImageButton")) and Where_Is_Mouse(slot, mouse_position) then
				if user_input_service:IsKeyDown(Enum.KeyCode.LeftControl) or user_input_service:IsKeyDown(Enum.KeyCode.RightControl) then
					Handle_Ctrl_Click(slot)
					break
				end
				if user_input_service:IsKeyDown(Enum.KeyCode.LeftShift) or user_input_service:IsKeyDown(Enum.KeyCode.RightShift) then
					Handle_Shift_Click(slot)
					break
				end
				local item_name = slot:GetAttribute("ItemName")
				if item_name then
					dragged_item = slot
					dragged_item_name = item_name
					dragged_item_amount = slot:GetAttribute("Amount") or 1
					drag_start_position = mouse_position
					if slot.Parent == equipment_grid then
						slot.Text = ""
					end
					dragged_clone = dragged_item:Clone()
					dragged_clone.Parent = script.Parent
					dragged_clone.Size = UDim2.fromScale(.07, .1)
					dragged_clone.ZIndex = 100
					dragged_clone.Text = item_name
					dragged_clone.Position = UDim2.fromOffset(mouse_position.X, mouse_position.Y)
					dragged_clone.Active = false
				end
				break
			end
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		-- Needs shift, so a plain right-click still blocks when the panel is closed.
		if not camera_lock_state.gui_open then
			return
		end
		if not (user_input_service:IsKeyDown(Enum.KeyCode.LeftShift) or user_input_service:IsKeyDown(Enum.KeyCode.RightShift)) then
			return
		end
		local mouse_position = input.Position
		for _, slot in ipairs(Get_Combined_Slots()) do
			if (slot:IsA("TextButton") or slot:IsA("ImageButton")) and Where_Is_Mouse(slot, mouse_position) then
				Handle_Shift_Right_Click(slot)
				break
			end
		end
	end
end)
user_input_service.InputEnded:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end
	if not dragged_clone then
		return
	end
	local mouse_position = input.Position
	local moved_distance = (mouse_position - drag_start_position).Magnitude
	if moved_distance < CLICK_MOVE_THRESHOLD then
		Show_Item_Info(dragged_item_name)
		if dragged_item and dragged_item.Parent == equipment_grid then
			dragged_item.Text = dragged_item_name
		end
		dragged_clone:Destroy()
		dragged_clone = nil
		dragged_item = nil
		dragged_item_name = nil
		dragged_item_amount = nil
		drag_start_position = nil
		return
	end
	if dragged_item and dragged_item.Parent == equipment_grid then
		local slot_name = GUI_NAME_TO_SLOT[dragged_item.Name] or dragged_item.Name
		unequip_request:FireServer(slot_name)
		dragged_item.Text = slot_name:upper()
		dragged_clone:Destroy()
		dragged_clone = nil
		dragged_item = nil
		dragged_item_name = nil
		dragged_item_amount = nil
		drag_start_position = nil
		return
	end
	local slot_matched = false
	for _, slot in ipairs(Get_Combined_Slots()) do
		if slot:IsA("TextButton") or slot:IsA("ImageButton") then
			if Where_Is_Mouse(slot, mouse_position) then
				slot_matched = true
				if slot.Parent == equipment_grid then
					equip_request:FireServer(dragged_item_name)
					break
				end
				local switched_slot_name = slot:GetAttribute("ItemName")
				local switched_slot_amount = slot:GetAttribute("Amount")
				if dragged_item then
					if switched_slot_name then
						dragged_item:SetAttribute("ItemName", switched_slot_name)
						dragged_item:SetAttribute("Amount", switched_slot_amount)
						Set_Slot_Display(dragged_item, switched_slot_name, switched_slot_amount)
					elseif dragged_item.Parent == grid_area then
						dragged_item:Destroy()
					else
						dragged_item:SetAttribute("ItemName", nil)
						dragged_item:SetAttribute("Amount", nil)
						Set_Slot_Display(dragged_item, "", nil)
					end
				end
				slot:SetAttribute("ItemName", dragged_item_name)
				slot:SetAttribute("Amount", dragged_item_amount)
				Set_Slot_Display(slot, dragged_item_name, dragged_item_amount)
				break
			end
		end
	end
	if not slot_matched and Where_Is_Mouse(grid_area, mouse_position) then
		Create_Inventory_Slot(dragged_item_name, dragged_item_amount)
		if dragged_item then
			if dragged_item.Parent == grid_area then
				dragged_item:Destroy()
			else
				dragged_item:SetAttribute("ItemName", nil)
				dragged_item:SetAttribute("Amount", nil)
				Set_Slot_Display(dragged_item, "", nil)
			end
		end
	elseif not slot_matched and not Where_Is_Mouse(inventory_gui.Inventory, mouse_position) then
		-- Released outside the inventory panel: drop just this slot's amount.
		drop_item_request:FireServer(dragged_item_name, dragged_item_amount)
		if dragged_item then
			if dragged_item.Parent == grid_area then
				dragged_item:Destroy()
			else
				dragged_item:SetAttribute("ItemName", nil)
				dragged_item:SetAttribute("Amount", nil)
				Set_Slot_Display(dragged_item, "", nil)
			end
		end
	end
	dragged_clone:Destroy()
	dragged_clone = nil
	dragged_item = nil
	dragged_item_name = nil
	dragged_item_amount = nil
	drag_start_position = nil
end)
user_input_service.InputChanged:Connect(function(input)
	if dragged_clone and input.UserInputType == Enum.UserInputType.MouseMovement then
		dragged_clone.Position = UDim2.fromOffset(input.Position.X, input.Position.Y)
	end
end)
-- Number keys 1-9 (and 0) equip the item in that hotbar slot, panel open or not.
local HOTBAR_KEYCODES = {
	Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four,
	Enum.KeyCode.Five, Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight,
	Enum.KeyCode.Nine, Enum.KeyCode.Zero,
}
user_input_service.InputBegan:Connect(function(input, game_processed)
	if game_processed then
		return
	end
	for index, keycode in ipairs(HOTBAR_KEYCODES) do
		if input.KeyCode == keycode then
			local sorted_slots = Get_Sorted_Hotbar_Slots()
			local slot = sorted_slots[index]
			local item_name = slot and slot:GetAttribute("ItemName") or nil
			if item_name then
				local data = item_data[item_name]
				local target_slot = data and data.EquipSlots and data.EquipSlots[1]
				if target_slot and currently_equipped[target_slot] == item_name then
					-- Same item already equipped from this key -> toggle off
					unequip_request:FireServer(target_slot)
				else
					equip_request:FireServer(item_name)
				end
			else
				-- Empty hotbar slot selected -> empty hand
				if currently_equipped["Weapon"] then
					unequip_request:FireServer("Weapon")
				end
			end
			break
		end
	end
end)
-- Hotbar placement is client-only (the server count doesn't change), so
-- subtract hotbar amounts before rendering the grid to avoid showing items twice.
local function Get_Hotbar_Committed_Amounts()
	local committed = {}
	for _, slot in ipairs(hot_bar:GetChildren()) do
		local item_name = slot:GetAttribute("ItemName")
		if item_name then
			local amount = slot:GetAttribute("Amount") or 1
			committed[item_name] = (committed[item_name] or 0) + amount
		end
	end
	-- The equipped weapon was already removed from the server count, but its hotbar
	-- slot still counts it, so credit 1 back to avoid hiding a second copy.
	local equipped_item = currently_equipped["Weapon"]
	if equipped_item and committed[equipped_item] then
		committed[equipped_item] = math.max(0, committed[equipped_item] - 1)
	end
	return committed
end
local function Update_Inventory(inventory)
	Clear_Items()
	local hotbar_committed = Get_Hotbar_Committed_Amounts()
	for item_name, amount in pairs(inventory) do
		local remaining = amount - (hotbar_committed[item_name] or 0)
		if remaining > 0 then
			local data = item_data[item_name]
			if data and not Is_Stackable(data) then
				-- Non-stackable: one slot per copy.
				for _ = 1, remaining do
					Create_Inventory_Slot(item_name, 1)
				end
			else
				Create_Inventory_Slot(item_name, remaining)
			end
		end
	end
end
inventory_updated.OnClientEvent:Connect(Update_Inventory)
for _, panel in ipairs({stats_panel, gear_panel, inv_panel, description_panel}) do
	local stroke = panel:FindFirstChildOfClass("UIStroke")
	if stroke then
		Add_Scanning_Border(stroke)
	end
end
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
-- [stated] ctrl+click dropping equipped gear — see Handle_Ctrl_Click below.
-- New RemoteEvent, needs manual creation in ReplicatedStorage (same as
-- InfectionUpdated before it).
local drop_equipped_request = replicated_storage:WaitForChild("DropEquippedRequest")
local stats_updated = replicated_storage:WaitForChild("StatsUpdated")
local stamina_updated = replicated_storage:WaitForChild("StaminaUpdated")
local weight_updated = replicated_storage:WaitForChild("WeightUpdated")
local hunger_updated = replicated_storage:WaitForChild("HungerUpdated")
-- Item data lookup (icons, descriptions, equip info)
local item_data = require(replicated_storage:WaitForChild("ItemData"))
-- Camera lock state — tracks whether the inventory is genuinely open, used
-- to gate drag-start so stale click coordinates can't start a drag while
-- the panel isn't actually up.
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
-- Weight display lives in a different branch of the tree than the Stats
-- panel above — Inventory.Equipment.Storage&Weight.Weight, next to the
-- gear/backpack panel rather than under Stats.StatsGrid. Bracket-indexed
-- because "Storage&Weight" has an ampersand in its instance name.
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
-- Hotbar slots are fixed GUI objects (not cloned like grid slots), sorted
-- into number-key order. Shared by shift-click placement and the number-
-- key equip handler below, so both agree on which slot is "first"/"last".
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
-- Updates a slot's display: item name on the button itself, and the count
-- (if more than 1) on its ItemAmount label — instead of appending the
-- count into the button's own text. Safe to call on slots that don't have
-- an ItemAmount child at all (equipment slots, for instance).
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
-- Sums Defense across the equipped table purely from item_data, which the
-- client already has — no extra remote needed just to display ARMOR.
-- Dedupes by ItemName (not slot key) in case a future item ever spans
-- more than one EquipSlot; mirrors PlayerEquipment.get_total_defense's
-- dedup logic server-side, which is what actually gates combat damage.
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
-- Stats panel: STR/DEX/END come from the server (PlayerStats), STAMINA
-- REGEN from PlayerStamina, HEALTH is read directly off the local
-- character's own Humanoid since that's already replicated to us and
-- doesn't need a dedicated remote. HUNGER shows hunger stage +
-- time-to-next-stage, which both explains WHY regen speed is changing and
-- is more actionable (tells you when to go eat something).
stats_updated.OnClientEvent:Connect(function(stats)
	str_stat_label.Text = tostring(stats.Strength)
	dex_stat_label.Text = tostring(stats.Dexterity)
	end_stat_label.Text = tostring(stats.Endurance)
end)
stamina_updated.OnClientEvent:Connect(function(current, max, regen_rate)
	stam_regen_stat_label.Text = string.format("%.1f/s", regen_rate)
end)
-- Hunger stage + estimated seconds until it worsens (nil at Starving —
-- nothing worse to count down to). seconds_to_next is a live projection at
-- the player's CURRENT rate, so it can jump around a bit as sprinting/
-- blocking/etc. start and stop — same caveat any "time to empty" estimate
-- carries, not a bug.
hunger_updated.OnClientEvent:Connect(function(stage_name, seconds_to_next)
	if seconds_to_next then
		hunger_stat_label.Text = string.format("%s (%ds)", stage_name, math.ceil(seconds_to_next))
	else
		hunger_stat_label.Text = stage_name
	end
end)
-- Weight panel: current/max carried weight plus the tier name (Very
-- Light/Standard/Heavy/Very Heavy/Overburdened), all computed server-side
-- by PlayerWeight and pushed here any time inventory, equipment, or a
-- Strength-boosting stat item changes.
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
-- [stated] "I do not want weapons or armor to be stackable in the player's
-- inventory, while stims and food would be stackable." The server-side
-- inventory (PlayerInventory.lua) is, and stays, just a plain
-- item_name -> count map — there's no per-copy identity to track (no
-- durability or other distinguishing state), so nothing there needs to
-- change. This only affects how the CLIENT renders that count: a
-- non-stackable item's count gets rendered as that many SEPARATE
-- amount-1 slots instead of one slot with a count label. Real weapons,
-- armor, and backpacks are non-stackable; food/drinks are explicitly
-- carved back OUT of "has a WeaponModel" (they share that field with real
-- weapons purely so they can occupy the hand slot, see PlayerEquipment/
-- ItemData) so they stay stackable; everything else (stims/StatBoost,
-- MinimapUpgrade) also stays stackable, matching how it already displayed.
local function Is_Stackable(data)
	if data.ArmorTemplate or data.BackpackModel then
		return false
	end
	if data.WeaponModel and not data.Food then
		return false
	end
	return true
end
-- Shift-click quick actions. Armor equips immediately — the server's
-- equip_item already unequips whatever currently occupies that armor's
-- EquipSlots before attaching the new piece, so this is literally the
-- same equip_request the drag-onto-equipment-slot flow already fires,
-- just skipping the drag. Everything else (per current design, that's
-- every non-armor item) drops into the first open hotbar slot, or swaps
-- into the last hotbar slot — trading places with whatever was there —
-- if the hotbar's already full.
local function Get_First_Empty_Hotbar_Slot()
	for _, slot in ipairs(Get_Sorted_Hotbar_Slots()) do
		if not slot:GetAttribute("ItemName") then
			return slot
		end
	end
	return nil
end
-- Finds an existing grid slot for item_name, if any — used when moving a
-- STACKABLE item back out of the hotbar (see Handle_Shift_Click below) so
-- it merges into an existing pile instead of creating a redundant second
-- slot for the same item.
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
-- [stated/found] shift-clicking an equipped armor piece, or an item already
-- sitting in the hotbar, used to be flat no-ops ("nothing to shift-click
-- into" / "already in the hotbar") — [stated] "shift clicking items in the
-- hotbar or equipped armor does not auto put them back in the inventory
-- and I want it to." This is also almost certainly why [stated] separately
-- saw a weapon model stay welded to the hand after "unequipping" it: if
-- shift-click was the only unequip gesture being tried and it was actually
-- a no-op, no UnequipRequest ever fired, so PlayerEquipment never got a
-- chance to destroy that weapon's attached piece server-side (the drag-off
-- and number-key-toggle unequip paths already worked correctly — this
-- fills in the missing third one).
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
		-- unequip_item already refunds 1 to inventory server-side, and the
		-- resulting equipment_updated/inventory_updated pushes redraw both
		-- panels — nothing else to do locally here.
		local slot_name = GUI_NAME_TO_SLOT[slot.Name] or slot.Name
		unequip_request:FireServer(slot_name)
		return
	end
	if data.ArmorTemplate or data.BackpackModel then
		equip_request:FireServer(item_name)
		return
	end
	if data.StatBoost or data.MinimapUpgrade or data.Food then
		-- Consumables (stat-boost crate items, minimap upgrades, and now
		-- food/drink) — usable from anywhere, including the hotbar, unlike
		-- the hotbar-move path below which is a no-op once something's
		-- already there. Food is ALSO reachable by selecting it off the
		-- hotbar (equips into the Weapon hand-slot) then left-clicking —
		-- this is the instant-eat shortcut, same as the other two.
		use_item_request:FireServer(item_name)
		return
	end
	if slot.Parent == hot_bar then
		-- Sending a hotbar item back to the inventory. If it's the item
		-- currently equipped in the Weapon slot (selected via number key),
		-- unequip it server-side first — that refunds 1 to inventory, so the
		-- next inventory_updated push naturally shows it in the grid, same
		-- as the equipment_grid branch above. Otherwise there's no server
		-- state to change (Move_Item_To_Hotbar never told the server
		-- anything either), so this just mirrors it back into the grid
		-- locally — merging into an existing pile if the item's stackable,
		-- or always adding a fresh slot if it's not (see Is_Stackable).
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
-- Fires the server drop for exactly what's sitting in THIS slot (not the
-- item's total owned amount — see DroppedItems.drop_item's own comment for
-- why that used to be wrong), then clears LOCAL state so the UI doesn't
-- keep showing an item the server just threw away. Grid slots always
-- represent exactly what's currently owned there, so they just get
-- destroyed; hotbar slots are hand-managed client state (see
-- Move_Item_To_Hotbar's own comment above) so their attributes need
-- clearing by hand, the same way an emptied hotbar slot already is
-- elsewhere in this file. [stated/found] this cleanup was missing before —
-- shift+right-clicking a hotbar item dropped it server-side but left the
-- slot showing a phantom item you could still try (and fail) to equip.
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
-- Shift+right-click drops this slot's contents to the ground — equipped
-- items are excluded the same way Handle_Shift_Click excludes them; drag
-- them off onto the world instead (see InputEnded) to shed worn gear.
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
-- [stated] "ctrl + left clicking items in a players hotbar/equipped
-- armor/inventory to drop that item/stack of items" — same drop behavior
-- as shift+right-click above, EXTENDED to also cover equipped gear (which
-- shift+right-click deliberately still excludes, per its own comment).
-- Dropping something currently equipped needs an unequip first (dropping
-- checks the player's OWN inventory, and an equipped item isn't sitting
-- there) — routed through a dedicated DropEquippedRequest so the unequip
-- and the drop happen as one atomic server step, rather than this script
-- firing UnequipRequest then DropItemRequest back to back and hoping
-- they're processed in that order.
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
		-- Gate drag-start on the inventory actually being open — this is
		-- what stops precise-but-stale coordinate clicks from starting a
		-- drag while the panel isn't genuinely visible/interactable.
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
		-- Same open-panel gate as the MouseButton1 branch above, plus
		-- requiring shift so a bare right-click still falls through to
		-- CombatInput's block bind whenever the panel is closed (that
		-- script already no-ops while gui_open is true, so there's no
		-- conflict either way).
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
		-- Released outside the whole inventory panel (not just outside a
		-- slot, and not just outside the backpack grid) -> drop just THIS
		-- slot's amount to the ground instead of snapping back to its old
		-- slot. [stated/found] this used to drop the item's entire owned
		-- amount regardless of what was actually dragged out — dragging one
		-- of two separate (now non-stackable) weapons out was taking both.
		-- dragged_item_amount was already being captured at drag-start for
		-- display purposes; it just wasn't being passed along here.
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
-- Number-key hotbar equip: pressing 1-9 (0 for a 10th slot) equips
-- whatever item currently occupies that hotbar slot, using the same
-- equip_request the drag-drop system already fires. Works regardless of
-- whether the inventory GUI is currently open.
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
-- [stated/found] items shift-clicked/dragged into the hotbar were showing
-- up a SECOND time in the backpack grid too. Root cause: Move_Item_To_Hotbar
-- is purely a client-side visual placement — it never tells the server
-- anything, since the server's inventory count for that item never actually
-- changes (the item is still owned, just displayed in a different slot).
-- Update_Inventory didn't know that, though: it blindly re-rendered a fresh
-- grid slot for the item's FULL server-side amount every time ANY inventory
-- change pushed a refresh (picking up something unrelated, consuming
-- something else, etc.), even though some of that amount was already
-- sitting in a hotbar slot. Fixed by subtracting whatever's currently
-- committed to the hotbar before deciding what (if anything) to render in
-- the grid.
local function Get_Hotbar_Committed_Amounts()
	local committed = {}
	for _, slot in ipairs(hot_bar:GetChildren()) do
		local item_name = slot:GetAttribute("ItemName")
		if item_name then
			local amount = slot:GetAttribute("Amount") or 1
			committed[item_name] = (committed[item_name] or 0) + amount
		end
	end
	-- [stated/found] "equip one of two separate Maces -> the OTHER one
	-- disappears from the inventory grid, reappears after unequipping."
	-- Root cause: equipping (or selecting food to eat) removes exactly ONE
	-- unit from the SERVER's inventory count (PlayerEquipment.equip_item's
	-- PlayerInventory.remove_item(player, item_name, 1)) — that unit is
	-- genuinely gone from the server count already, not merely "reserved"
	-- the way an unequipped hotbar item still is. But the hotbar slot's
	-- local Amount attribute above doesn't know that and keeps counting it
	-- too, so it was getting subtracted a SECOND time on top of the
	-- server's already-reduced count — hiding a second, separate,
	-- non-equipped copy of the same item that should still be showing in
	-- the grid. Fixed by crediting back exactly 1 for whichever item is
	-- currently equipped in the Weapon slot, since that's the one unit the
	-- server-side count has already accounted for.
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
				-- [stated] weapons/armor never stack -- each copy the server
				-- count says the player owns gets its own separate slot.
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
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerInventory = require(script.Parent.PlayerInventory)
local ItemData = require(ReplicatedStorage:WaitForChild("ItemData"))
local PlayerEquipment = {}
PlayerEquipment.player_equipment = {} -- player_equipment[player][slot] = {ItemName, pieces, hidden_accessories}
local ARMOR_TO_LIMB = {
	Helmet = "Head",
	Chest = "UpperTorso",
	Belt = "LowerTorso",
	LeftShoulder = "LeftUpperArm",
	RightShoulder = "RightUpperArm",
	LeftKnee = "LeftLowerLeg",
	RightKnee = "RightLowerLeg",
	-- Scavenger set. Armor piece names must differ from real R15 limb names.
	-- LowerJacket pieces are the jacket's lower flaps and attach to the thighs.
	LeftLowerSleeve = "LeftLowerArm",
	RightLowerSleeve = "RightLowerArm",
	LeftLowerJacket = "LeftUpperLeg",
	RightLowerJacket = "RightUpperLeg",
	LeftBoot = "LeftFoot",
	RightBoot = "RightFoot",
	-- Raider set. Names avoid real R15 limb names (matching names caused texture
	-- corruption). Shin pieces share LeftBoot/RightBoot (foot), which clip less.
	LeftLowerGuard = "LeftLowerArm",
	RightLowerGuard = "RightLowerArm",
	LeftUpperGreaves = "LeftUpperLeg",
	RightUpperGreaves = "RightUpperLeg",
}
-- Head-worn accessory types hidden under helmets (Face covers glasses/masks).
local HIDDEN_ACCESSORY_TYPES = {
	[Enum.AccessoryType.Hair] = true,
	[Enum.AccessoryType.Hat] = true,
	[Enum.AccessoryType.Face] = true,
	[Enum.AccessoryType.Eyebrow] = true,
	[Enum.AccessoryType.Eyelash] = true,
}
-- Starting guesses — tune per weapon by testing in-game. Position nudges
-- move the grip point; Angles rotates the weapon around that point.
local WEAPON_SCALE = {
	["Tier1MacePipe"] = 0.65,
	["Tier2MacePoliceBaton"] = 0.65,
	["Tier3MaceFlangedMace"] = 0.65,
	["Tier1AxeWoodAxe"] = 0.9,
	["Tier2AxeFireaxe"] = 0.9,
	["Tier3AxeMilitaryAxe"] = 0.9,
	["Tier1TrainingSword"] = 1,
	["Tier2HistoricalSword"] = 1.2,
	["Tier3MilitarySword"] = 1,
	-- Models are scaled with ScaleTo (whole model uniformly). Placeholders.
	["Empty Bow"] = 1,
	["Sling"] = 1,
}
local WEAPON_GRIP_OFFSET = {
	["Tier1MacePipe"] = CFrame.new(0, -0.5, -1) * CFrame.Angles(math.rad(-110), 0, 0),
	["Tier2MacePoliceBaton"] = CFrame.new(0, -0.5, -1) * CFrame.Angles(math.rad(-110), 0, 0),
	["Tier3MaceFlangedMace"] = CFrame.new(0, -0.5, -1) * CFrame.Angles(math.rad(-110), 0, 0),
	-- Hand grip offset per weapon (no entry = raw mesh origin, which looks wrong).
	["Tier1AxeWoodAxe"] = CFrame.new(0, -0.5, -1.5) * CFrame.Angles(math.rad(-95), math.rad(180), 0),
	["Tier2AxeFireaxe"] = CFrame.new(0, -0.15, -1.5) * CFrame.Angles(math.rad(-95), 0, math.rad(180)),
	["Tier3AxeMilitaryAxe"] = CFrame.new(0, -0.85, -1.8) * CFrame.Angles(math.rad(-90), math.rad(180), math.rad(0)),

	["Tier1TrainingSword"] = CFrame.new(0, -0.75, -1.75) * CFrame.Angles(math.rad(-110), 0, 0),
	["Tier2HistoricalSword"] = CFrame.new(0, -0.5, -2.5) * CFrame.Angles(math.rad(-100), math.rad(180), 0),
	["Tier3MilitarySword"] = CFrame.new(0, -0.75, -1.50) * CFrame.Angles(math.rad(-110), math.rad(180), 0),
	["Empty Bow"] = CFrame.new(0.125, 0.30, -2.75) * CFrame.Angles(math.rad(-90), math.rad(-20), math.rad(-5)),
	-- Placeholder; tune in Studio.
	["Sling"] = CFrame.new(0, -0.5, -1),
}
local function Find_Armor_Template(template_name)
	local armor_root = ServerStorage:WaitForChild("PlayerItems"):WaitForChild("Armor")
	for _, descendant in ipairs(armor_root:GetDescendants()) do
		if descendant.Name == template_name and descendant:IsA("Model") then
			return descendant
		end
	end
	return nil
end
local function Get_Reference_Limb(armor_template, limb_name)
	local reference_rig = armor_template:FindFirstChild("AlignmentRig")
	if not reference_rig then
		return nil
	end
	return reference_rig:FindFirstChild(limb_name)
end
-- Finds the real body limb, skipping same-named armor clones (they're marked
-- with the IsArmorPiece attribute).
local function Find_Real_Limb(character, limb_name)
	for _, child in ipairs(character:GetChildren()) do
		if child.Name == limb_name and child:IsA("BasePart") and not child:GetAttribute("IsArmorPiece") then
			return child
		end
	end
	return nil
end
local function Attach_Armor(character, armor_template, piece_names)
	local piece_set = {}
	for _, name in ipairs(piece_names) do
		piece_set[name] = true
	end
	local attached_pieces = {}
	for _, source_piece in ipairs(armor_template:GetChildren()) do
		if source_piece:IsA("BasePart") and piece_set[source_piece.Name] then
			local limb_name = ARMOR_TO_LIMB[source_piece.Name]
			local real_limb = limb_name and Find_Real_Limb(character, limb_name)
			local reference_limb = limb_name and Get_Reference_Limb(armor_template, limb_name)
			if real_limb and reference_limb then
				local piece = source_piece:Clone()
				local scale = Vector3.new(
					real_limb.Size.X / reference_limb.Size.X,
					real_limb.Size.Y / reference_limb.Size.Y,
					real_limb.Size.Z / reference_limb.Size.Z
				)
				local offset = reference_limb.CFrame:ToObjectSpace(source_piece.CFrame)
				local offset_rotation = offset - offset.Position
				local scaled_offset = CFrame.new(offset.Position * scale) * offset_rotation
				piece.Size = piece.Size * scale
				piece.CFrame = real_limb.CFrame * scaled_offset
				piece.Anchored = false
				piece.CanCollide = false
				-- Workaround for flipped normals on mirrored pieces (textures vanishing at
				-- some angles). Fixing the mesh normals is the real fix.
				piece.DoubleSided = true
				piece:SetAttribute("IsArmorPiece", true)
				piece.Parent = character
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = piece
				weld.Part1 = real_limb
				weld.Parent = piece
				table.insert(attached_pieces, piece)
			end
		end
	end
	return attached_pieces
end
-- Finds a hand-held item template (part or Model) anywhere under
-- ServerStorage.PlayerItems -- weapons, bows, food and drinks.
local function Find_Weapon_Template(model_name)
	local items_root = ServerStorage:WaitForChild("PlayerItems")
	for _, descendant in ipairs(items_root:GetDescendants()) do
		if descendant.Name == model_name and (descendant:IsA("BasePart") or descendant:IsA("Model")) then
			return descendant
		end
	end
	return nil
end
-- Welds a weapon to the right hand at its grip offset. A Model template (bows)
-- is cloned, scaled and pivoted as one unit, with only its PrimaryPart welded
-- (set it to "Bow" in Studio); PlayerCombat drives the string/arrow parts.
local function Attach_Weapon(character, weapon_model_name)
	local template = Find_Weapon_Template(weapon_model_name)
	if not template then
		return nil
	end
	local hand = character:FindFirstChild("RightHand")
	if not hand then
		return nil
	end
	local scale = WEAPON_SCALE[weapon_model_name] or 1
	local grip_offset = WEAPON_GRIP_OFFSET[weapon_model_name] or CFrame.new(0, 0, 0)
	if template:IsA("Model") then
		local clone = template:Clone()
		local primary = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
		if not primary then
			clone:Destroy()
			return nil
		end
		clone.PrimaryPart = primary
		for _, part in ipairs(clone:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = false
				part.CanCollide = false
			end
		end
		clone:ScaleTo(scale)
		clone:PivotTo(hand.CFrame * grip_offset)
		clone.Parent = character
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = primary
		weld.Part1 = hand
		weld.Parent = primary
		return {clone}
	end
	local weapon = template:Clone()
	weapon.Anchored = false
	weapon.CanCollide = false
	weapon.Size = weapon.Size * scale
	weapon.CFrame = hand.CFrame * grip_offset
	weapon.Parent = character
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = weapon
	weld.Part1 = hand
	weld.Parent = weapon
	return {weapon}
end
-- Backpack models live under ServerStorage.PlayerItems.Items.
local function Find_Backpack_Template(model_name)
	local items_root = ServerStorage:WaitForChild("PlayerItems"):WaitForChild("Items")
	for _, descendant in ipairs(items_root:GetDescendants()) do
		if descendant.Name == model_name and (descendant:IsA("Model") or descendant:IsA("BasePart")) then
			return descendant
		end
	end
	return nil
end
-- Placeholder offset from UpperTorso, nudge once you've seen it in-game —
-- same "starting guess" spirit as WEAPON_GRIP_OFFSET.
local BACKPACK_OFFSET = CFrame.new(0, 0, 0.6)
-- Welds the backpack to the back. Never fails the equip: the bag's effects
-- don't need a visual.
local function Attach_Backpack(character, model_name)
	local template = Find_Backpack_Template(model_name)
	local torso = character:FindFirstChild("UpperTorso")
	if not template or not torso then
		return {}
	end
	local clone = template:Clone()
	if clone:IsA("Model") then
		local primary = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
		if not primary then
			clone:Destroy()
			return {}
		end
		clone.PrimaryPart = primary
		for _, part in ipairs(clone:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = false
				part.CanCollide = false
			end
		end
		clone:PivotTo(torso.CFrame * BACKPACK_OFFSET)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = primary
		weld.Part1 = torso
		weld.Parent = primary
		clone.Parent = character
	else
		clone.Anchored = false
		clone.CanCollide = false
		clone.CFrame = torso.CFrame * BACKPACK_OFFSET
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = clone
		weld.Part1 = torso
		weld.Parent = clone
		clone.Parent = character
	end
	return {clone}
end
-- Destroys a list of attached pieces (armor, weapons and backpacks).
local function Detach_Armor(pieces)
	for _, piece in ipairs(pieces) do
		if piece and piece.Parent then
			piece:Destroy()
		end
	end
end
local function Hide_Conflicting_Accessories(character)
	local hidden = {}
	for _, accessory in ipairs(character:GetChildren()) do
		if accessory:IsA("Accessory") and HIDDEN_ACCESSORY_TYPES[accessory.AccessoryType] then
			local handle = accessory:FindFirstChild("Handle")
			if handle then
				table.insert(hidden, {handle = handle, original_transparency = handle.Transparency})
				handle.Transparency = 1
			end
		end
	end
	return hidden
end
local function Restore_Accessories(hidden)
	if not hidden then
		return
	end
	for _, entry in ipairs(hidden) do
		if entry.handle and entry.handle.Parent then
			entry.handle.Transparency = entry.original_transparency
		end
	end
end
function PlayerEquipment.new_equipment(player)
	PlayerEquipment.player_equipment[player] = {}
end
function PlayerEquipment.remove_equipment(player)
	local equipped = PlayerEquipment.player_equipment[player]
	if equipped then
		local already_removed = {}
		for _, entry in pairs(equipped) do
			if not already_removed[entry.pieces] then
				Detach_Armor(entry.pieces)
				Restore_Accessories(entry.hidden_accessories)
				already_removed[entry.pieces] = true
			end
		end
	end
	PlayerEquipment.player_equipment[player] = nil
end
function PlayerEquipment.equip_item(player, item_name)
	local data = ItemData[item_name]
	if not data or not data.Equipable or not data.EquipSlots then
		return false, "not equipable"
	end
	if not PlayerInventory.has_item(player, item_name) then
		return false, "item not owned"
	end
	local character = player.Character
	if not character then
		return false, "no character"
	end
	local equipped = PlayerEquipment.player_equipment[player]
	if not equipped then
		equipped = {}
		PlayerEquipment.player_equipment[player] = equipped
	end
	for _, slot in ipairs(data.EquipSlots) do
		if equipped[slot] then
			PlayerEquipment.unequip_item(player, slot)
		end
	end
	local pieces
	local hidden_accessories = {}
	if data.ArmorTemplate then
		local template = Find_Armor_Template(data.ArmorTemplate)
		if not template then
			return false, "template not found"
		end
		pieces = Attach_Armor(character, template, data.Pieces)
		if table.find(data.EquipSlots, "Head") then
			hidden_accessories = Hide_Conflicting_Accessories(character)
		end
	elseif data.WeaponModel then
		pieces = Attach_Weapon(character, data.WeaponModel)
		if not pieces then
			return false, "weapon template not found"
		end
	elseif data.BackpackModel then
		pieces = Attach_Backpack(character, data.BackpackModel)
	else
		return false, "no attach method defined for this item"
	end
	for _, slot in ipairs(data.EquipSlots) do
		equipped[slot] = {ItemName = item_name, pieces = pieces, hidden_accessories = hidden_accessories}
	end
	PlayerInventory.remove_item(player, item_name, 1)
	return true, equipped
end
-- Shared by unequip_item (refunds the item) and clear_slot (no refund, for
-- food eaten while held).
local function Detach_Slot(equipped, entry, slot)
	local data = ItemData[entry.ItemName]
	Detach_Armor(entry.pieces)
	Restore_Accessories(entry.hidden_accessories)
	if data and data.EquipSlots then
		for _, s in ipairs(data.EquipSlots) do
			if equipped[s] and equipped[s].ItemName == entry.ItemName then
				equipped[s] = nil
			end
		end
	else
		equipped[slot] = nil
	end
end
function PlayerEquipment.unequip_item(player, slot)
	local equipped = PlayerEquipment.player_equipment[player]
	if not equipped or not equipped[slot] then
		return false, "nothing equipped"
	end
	local entry = equipped[slot]
	Detach_Slot(equipped, entry, slot)
	PlayerInventory.add_item(player, entry.ItemName, 1)
	return true, equipped
end
-- No-refund unequip — see Detach_Slot's comment above.
function PlayerEquipment.clear_slot(player, slot)
	local equipped = PlayerEquipment.player_equipment[player]
	if not equipped or not equipped[slot] then
		return false, "nothing equipped"
	end
	local entry = equipped[slot]
	Detach_Slot(equipped, entry, slot)
	return true, equipped
end
-- Total Defense of equipped items, counted once per item even if it fills
-- several slots.
function PlayerEquipment.get_total_defense(player)
	local equipped = PlayerEquipment.player_equipment[player]
	if not equipped then
		return 0
	end
	local total = 0
	local counted_items = {}
	for _, entry in pairs(equipped) do
		if not counted_items[entry.ItemName] then
			counted_items[entry.ItemName] = true
			local data = ItemData[entry.ItemName]
			if data and data.Defense then
				total = total + data.Defense
			end
		end
	end
	return total
end
-- Attaches item visuals to any character (used for zombies).
function PlayerEquipment.attach_item_visual(character, item_name)
	local data = ItemData[item_name]
	if not data then
		return nil
	end
	if data.ArmorTemplate then
		local template = Find_Armor_Template(data.ArmorTemplate)
		if not template then
			return nil
		end
		local pieces = Attach_Armor(character, template, data.Pieces)
		if table.find(data.EquipSlots, "Head") then
			Hide_Conflicting_Accessories(character)
		end
		return pieces
	elseif data.WeaponModel then
		return Attach_Weapon(character, data.WeaponModel)
	elseif data.BackpackModel then
		return Attach_Backpack(character, data.BackpackModel)
	end
	return nil
end
-- Shared with DroppedItems for building weapon drops.
PlayerEquipment.find_weapon_template = Find_Weapon_Template
return PlayerEquipment
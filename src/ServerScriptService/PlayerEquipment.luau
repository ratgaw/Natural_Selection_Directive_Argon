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
	-- Added for the Scavenger Armor set. LeftLowerSleeve/RightLowerSleeve are
	-- the forearm guards -- [stated] renamed from LeftLowerArm/RightLowerArm
	-- to avoid sharing a name with the real rig limb they weld to (the
	-- IsArmorPiece-attribute lookup in Find_Real_Limb already made that
	-- collision harmless, but the distinct name is clearer to read in the
	-- Explorer regardless). LeftLowerJacket/RightLowerJacket are NOT arm
	-- pieces despite the naming similarity -- [stated] they're the lower
	-- flaps of the jacket garment and weld to the upper leg limbs instead
	-- (thigh coverage). LeftBoot/RightBoot -> feet is an assumption, not yet
	-- confirmed -- swap to LeftLowerLeg/RightLowerLeg instead if the boots
	-- are modeled to extend up over the shin rather than sitting at the
	-- ankle/foot.
	LeftLowerSleeve = "LeftLowerArm",
	RightLowerSleeve = "RightLowerArm",
	LeftLowerJacket = "LeftUpperLeg",
	RightLowerJacket = "RightUpperLeg",
	LeftBoot = "LeftFoot",
	RightBoot = "RightFoot",
	-- Added for the Raider Armor set. [found] originally named
	-- LeftLowerArm/RightLowerArm/LeftUpperLeg/RightUpperLeg/LeftLowerLeg/
	-- RightLowerLeg -- exact matches to the real R15 limb names, six
	-- collisions at once. That's the same pattern Scavenger's forearm
	-- pieces hit (see LeftLowerSleeve/RightLowerSleeve above) before they
	-- were renamed away from LeftLowerArm/RightLowerArm and the texture
	-- corruption on them stopped -- worse here since there are three times
	-- as many colliding names, which tracks with this set's corruption
	-- being more widespread. Renamed to LeftLowerGuard/RightLowerGuard
	-- (forearm) and LeftUpperGreaves/RightUpperGreaves (thighs), none of
	-- which match any real R15 limb name. The shin pieces were further
	-- renamed to LeftBoot/RightBoot and re-pointed at the foot instead of
	-- the lower leg -- [stated] they were clipping hard during movement,
	-- and the ankle joint moves less than the knee does, so anchoring to
	-- the foot should track better. LeftBoot/RightBoot -> foot already
	-- existed below from the Scavenger set -- same names, same target
	-- limb, no new entry needed, it's just shared now.
	LeftLowerGuard = "LeftLowerArm",
	RightLowerGuard = "RightLowerArm",
	LeftUpperGreaves = "LeftUpperLeg",
	RightUpperGreaves = "RightUpperLeg",
}
-- [stated/found] sunglasses were clipping through the Scavenger Helmet --
-- Hair/Hat alone doesn't catch everything worn on the head. Widened to
-- every head-worn AccessoryType: Face covers glasses/masks, Eyebrow/Eyelash
-- cover facial-hair-style accessories. Deliberately NOT widened to
-- Neck/Shoulder/Front/Back/Waist (torso-worn) or the clothing-layer types
-- (TShirt/Shirt/Pants/Jacket/Sweater/Shorts/LeftShoe/RightShoe/DressSkirt)
-- -- those aren't on the head and shouldn't disappear just because a
-- helmet went on.
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
	-- [stated] bow/sling weapons -- see Attach_Weapon's Model branch
	-- below. ScaleTo (not Size*scale) is what actually applies this one
	-- for a Model, so it scales the whole weapon (strings/arrow/pouch
	-- included) uniformly. Placeholders, tune once you've seen them in-hand.
	["Empty Bow"] = 1,
	["Sling"] = 1,
}
local WEAPON_GRIP_OFFSET = {
	["Tier1MacePipe"] = CFrame.new(0, -0.5, -1) * CFrame.Angles(math.rad(-110), 0, 0),
	["Tier2MacePoliceBaton"] = CFrame.new(0, -0.5, -1) * CFrame.Angles(math.rad(-110), 0, 0),
	["Tier3MaceFlangedMace"] = CFrame.new(0, -0.5, -1) * CFrame.Angles(math.rad(-110), 0, 0),
	-- [found] these were missing entirely, which is why the axe was floating
	-- near the shoulder/back instead of sitting in the hand -- with no entry
	-- here, Attach_Weapon's `WEAPON_GRIP_OFFSET[weapon_model_name] or
	-- CFrame.new(0, 0, 0)` fallback kicks in, so the weapon's raw mesh
	-- origin/orientation was being used as-is with zero offset and zero
	-- rotation. Tuned in-game since -- Tier1/Tier2 share a grip offset,
	-- Tier3 (Military Axe) needed its own distinct position AND rotation
	-- rather than just a bigger Z nudge like Tier1/2 got.
	["Tier1AxeWoodAxe"] = CFrame.new(0, -0.5, -1.5) * CFrame.Angles(math.rad(-95), math.rad(180), 0),
	["Tier2AxeFireaxe"] = CFrame.new(0, -0.15, -1.5) * CFrame.Angles(math.rad(-95), 0, math.rad(180)),
	["Tier3AxeMilitaryAxe"] = CFrame.new(0, -0.85, -1.8) * CFrame.Angles(math.rad(-90), math.rad(180), math.rad(0)),

	["Tier1TrainingSword"] = CFrame.new(0, -0.75, -1.75) * CFrame.Angles(math.rad(-110), 0, 0),
	["Tier2HistoricalSword"] = CFrame.new(0, -0.5, -2.5) * CFrame.Angles(math.rad(-100), math.rad(180), 0),
	["Tier3MilitarySword"] = CFrame.new(0, -0.75, -1.50) * CFrame.Angles(math.rad(-110), math.rad(180), 0),
	-- [stated] tuned in-game -- the bow's actual grip offset, replacing
	-- the earlier placeholder.
	["Empty Bow"] = CFrame.new(0.125, 0.30, -2.75) * CFrame.Angles(math.rad(-90), math.rad(-20), math.rad(-5)),
	-- [stated] still a placeholder -- this is where the Model gets
	-- PivotTo'd relative to the hand (see Attach_Weapon's Model branch),
	-- so tune it the same way: nudge position/rotation until the sling
	-- sits naturally in-hand once you can see it in Studio.
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
-- [stated/found] some armor pieces (e.g. LeftLowerArm/RightLowerArm on the
-- Scavenger set) are deliberately named identically to the real R15 limb
-- they weld to, since that's the limb ARMOR_TO_LIMB maps them onto. Once
-- equipped, that means `character` has two same-named siblings -- the real
-- limb and the armor clone -- and plain FindFirstChild(limb_name) has no
-- way to tell them apart if it ever resolves the wrong one (order isn't
-- guaranteed). Not confirmed to be an active bug (the debug print showed it
-- resolving correctly), but cheap to make impossible outright: every armor
-- clone gets tagged with an attribute at parent time, and this lookup skips
-- anything carrying it, so it can only ever return a genuine body limb.
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
				-- [found] safety net for the "lower arm textures break only in
				-- Play, look fine in Studio" report -- leading theory is
				-- backface culling from inverted normals on the mirrored L/R
				-- pair (DoubleSided was off), which is angle-dependent and
				-- would explain exactly that discrepancy. Forcing DoubleSided
				-- on every armor piece is cheap insurance regardless of root
				-- cause -- doesn't fix bad normals, just stops them from ever
				-- being invisible/culled. Still worth getting the mesh itself
				-- fixed (flipped normals) since DoubleSided is a workaround,
				-- not a real fix, and costs a little extra render time.
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
-- Finds a hand-held item template by name anywhere under
-- ServerStorage.PlayerItems. Widened from the Weapons subfolder specifically
-- to the whole PlayerItems tree — [stated/found] food/drink items now also
-- go through this same "single part welded to hand" mechanism (WeaponModel
-- on their ItemData entries), but those models live under separate Food/
-- Drink subfolders, not Weapons.
-- [stated/found] widened again for the bow -- its commissioned model has
-- separate string/arrow pieces (see PlayerCombat.lua's "Ranged weapons"
-- section) so it needs to be a whole Model, not the single welded
-- BasePart every weapon up to now has been. Matching by either type keeps
-- every existing single-part weapon working exactly as before.
local function Find_Weapon_Template(model_name)
	local items_root = ServerStorage:WaitForChild("PlayerItems")
	for _, descendant in ipairs(items_root:GetDescendants()) do
		if descendant.Name == model_name and (descendant:IsA("BasePart") or descendant:IsA("Model")) then
			return descendant
		end
	end
	return nil
end
-- Weapons are usually a single part welded directly to the player's hand
-- -- much simpler than armor, no multi-piece scale compensation needed.
-- [stated/found] the bow needs its separate string/arrow pieces to come
-- along too (for PlayerCombat.lua's procedural draw-stretch to find and
-- drive), so a Model template takes a second path here: the whole Model
-- gets cloned, uniformly scaled (Model:ScaleTo, not Size*scale -- that's
-- the real per-part scaling, this just applies WEAPON_SCALE's existing
-- single number to a whole Model instead of one part), and PivotTo'd into
-- the grip offset as one rigid unit, with only its PrimaryPart (set this
-- to the bow's own "Bow" part in Studio, or it falls back to any BasePart
-- it finds) actually welded to the hand -- the string/arrow parts are
-- deliberately left un-welded, since PlayerCombat's own Setup_Bow strips
-- any weld on them anyway and re-positions them itself every frame.
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
-- Finds a backpack model anywhere under ServerStorage.PlayerItems.Items —
-- separate root from Weapons/Armor since that's where the user's Backpack
-- model actually lives.
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
-- Welds the backpack model onto the character's back. Deliberately never
-- fails outright the way Attach_Weapon does (returning nil there rejects
-- the whole equip) — the Bag slot's actual gameplay effect (PlayerWeight's
-- carry-weight discount, RequestChecker's sprint stamina penalty) doesn't
-- depend on there being a visual at all, only on the slot being filled.
-- Missing model/torso just means an invisible-but-functional bag rather
-- than blocking the player from equipping it.
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
-- Destroys every piece in the given list — shared by armor, weapons, and
-- backpacks, since all three ultimately just produce a list of cloned
-- Instances (Parts or, for backpacks, possibly a whole Model).
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
-- Shared by unequip_item (refunds 1 to inventory — the normal manual-
-- unequip path) and clear_slot below (doesn't refund — for RequestChecker
-- to call when a consumable equipped into the Weapon slot gets eaten down
-- to 0, where refunding would undo the very item that was just consumed).
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
-- Sums Defense across every currently-equipped item for a player — used
-- by PlayerCombat's hit-check to reduce incoming damage. Dedupes by
-- ItemName (not by the equipped table's slot keys, and not by the
-- "pieces" table's identity) since a hypothetical future item spanning
-- multiple EquipSlots would otherwise appear once per slot and get
-- double-counted.
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
-- Attaches item_name's visuals onto an ARBITRARY character (not tied to
-- any player's own equipment state) — used for zombies reusing a dead
-- player's captured equipped-item names.
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
-- Exposed so DroppedItems.lua can reuse the same lookup when building a
-- ground representation for a dropped weapon, instead of duplicating the
-- search logic.
PlayerEquipment.find_weapon_template = Find_Weapon_Template
return PlayerEquipment
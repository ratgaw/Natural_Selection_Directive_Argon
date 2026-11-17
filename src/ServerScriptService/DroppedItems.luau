-- Handles dropping an item's entire stack out of a player's inventory onto
-- the ground, and letting it be picked back up with E. A Phase 2 companion
-- to the weight system -- without a way to shed items, an overburdened
-- player would have no way to lighten their load. Pickup is deliberately
-- free-for-all (no ownership check on who dropped it), matching how loot
-- generally works in this game.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local inventory_updated = ReplicatedStorage:WaitForChild("InventoryUpdated")
local PlayerInventory = require(ServerScriptService:WaitForChild("PlayerInventory"))
local PlayerEquipment = require(ServerScriptService:WaitForChild("PlayerEquipment"))
local PlayerWeight = require(ServerScriptService:WaitForChild("PlayerWeight"))
local PlayerStats = require(ServerScriptService:WaitForChild("PlayerStats"))
local ItemData = require(ReplicatedStorage:WaitForChild("ItemData"))
local DroppedItems = {}
-- Placeholders, tune once tested. Prompt values mirror WildLifeManager's
-- Setup_Harvest prompt (same ActionText style / MaxActivationDistance)
-- since that's the established "walk up, press E, get item" pattern
-- elsewhere in this codebase.
local DROP_DISTANCE = 3 -- studs in front of the player a dropped item lands
local PICKUP_HOLD_DURATION = 0.3
local PICKUP_MAX_DISTANCE = 8
-- [stated] "Dexterity -> interaction ... speed" -- this pickup prompt is the
-- only timed interaction that exists in the codebase right now, so it's the
-- only place this applies; "revive speed" from the same stated bullet has
-- nowhere to go yet, there's no revive/downed mechanic in this game at all.
local DEXTERITY_INTERACTION_SPEED_PER_POINT = 0.04
local MIN_INTERACTION_HOLD_FRACTION = 0.5
local LABEL_MAX_DISTANCE = 40 -- placeholder, tune once tested
-- [stated/found] "Empty Bow"/the bow family is the first weapon drop that
-- isn't a single welded BasePart -- PlayerEquipment.lua's Attach_Weapon
-- grew a Model branch for it (separate string/arrow pieces), so a dropped
-- bow's ground representation has to be Model-aware too, everywhere this
-- file used to assume `part` was always a BasePart. Get_Ground_Piece_Size/
-- Set_Ground_Piece_CFrame below are the two small duck-typed helpers that
-- make the rest of this file (Get_Lay_Flat_Rotation_And_Height,
-- spawn_ground_item_at, Add_Pickup_Prompt) work unchanged for either shape
-- -- everything else in this file reads a "size" or sets a "position",
-- never .Size/.CFrame directly any more.
local function Get_Ground_Piece_Size(piece)
	if piece:IsA("Model") then
		-- World-space bounding box of whatever orientation the piece
		-- template/clone is CURRENTLY in -- good enough for this
		-- function's own "which axis is thinnest" heuristic, same
		-- placeholder-quality fit as everything else in this file.
		return piece:GetExtentsSize()
	end
	return piece.Size
end
local function Set_Ground_Piece_CFrame(piece, target_cframe)
	if piece:IsA("Model") then
		piece:PivotTo(target_cframe)
	else
		piece.CFrame = target_cframe
	end
end
-- [stated] "loot items tend to be standing upright rather than lying on
-- their side and such, is there a way for them to get their dimensions
-- real fast and have the largest side against the ground?" -- replaces
-- the old single hand-guessed WEAPON_FLAT_ROTATION (one fixed 90° tilt
-- applied to every weapon regardless of its actual shape, left every
-- non-weapon item standing upright, and the comment on it even admitted
-- "can't verify visually from here"). This instead reads the part's own
-- Size (or, for a Model, its overall extents -- see Get_Ground_Piece_Size)
-- and tips it onto whichever face is largest: whichever axis is SMALLEST
-- (the "thickness") gets rotated to point straight up, so the other two
-- (larger) dimensions end up flat against the ground. Ties/already-
-- upright (Y already the smallest, e.g. the placeholder cube, where all
-- three are equal) fall through to no rotation at all. Returns the
-- rotation to apply AND the resulting half-height to use for the ground
-- offset, since tipping the part changes which axis is actually vertical
-- afterward.
local function Get_Lay_Flat_Rotation_And_Height(piece)
	local size = Get_Ground_Piece_Size(piece)
	if size.X < size.Y and size.X <= size.Z then
		-- X is the thinnest axis -- rotate it up to vertical (about Z).
		return CFrame.Angles(0, 0, math.rad(90)), size.X / 2
	elseif size.Z < size.X and size.Z < size.Y then
		-- Z is the thinnest axis -- rotate it up to vertical (about X).
		return CFrame.Angles(math.rad(90), 0, 0), size.Z / 2
	end
	-- Y already the thinnest (or tied) -- already resting on its largest
	-- face, no tilt needed.
	return CFrame.new(), size.Y / 2
end
-- [stated] "if I dropped items inside a building they would be dropped on
-- the roof of the building" -- this used to ALWAYS raycast from y=1000
-- straight down with no reference point at all. That's fine out in the
-- open, but a long-range top-down ray cast at a point INSIDE a building's
-- footprint hits that building's own ROOF first, long before it would ever
-- reach the floor the player is actually standing on -- there's no way to
-- tell "outdoors vs. indoors on an upper floor" from x/z alone with that
-- approach. Fixed by anchoring the search to the PLAYER's own height
-- instead: a short ray starting a little above wherever the player's feet
-- already are, reaching only a modest distance below that -- same idea
-- (and the same placeholder values) as StartMatch's
-- FLOOR_LOOT_RAY_CLEARANCE/FLOOR_LOOT_RAY_DISTANCE for building floor loot,
-- reused here for player-dropped items. A player standing on an upper
-- floor already has their own feet resting on that floor, so this reaches
-- it immediately without ever getting far enough to punch through to the
-- roof below them or the terrain far under the building. reference_y is
-- optional so any future caller that really does want the old long-range
-- "just find the terrain under this x/z" behavior still can, by leaving it
-- out.
local GROUND_RAY_CLEARANCE = 5
local GROUND_RAY_DISTANCE = 20
local function Get_Ground_Height(x, z, reference_y)
	local origin_y = (reference_y and reference_y + GROUND_RAY_CLEARANCE) or 1000
	local distance = reference_y and GROUND_RAY_DISTANCE or 2000
	local result = workspace:Raycast(Vector3.new(x, origin_y, z), Vector3.new(0, -distance, 0))
	return result and result.Position.Y or nil
end
-- Weapons already have a standalone ground-ready template (the same one
-- PlayerEquipment attaches to a character's hand), so cloning it is a
-- clean "drop the model" -- reuses PlayerEquipment's own lookup rather
-- than duplicating the ServerStorage search here.
-- [stated/found] that template used to always be a single BasePart --
-- PlayerEquipment.lua's Find_Weapon_Template now also returns a whole
-- Model for the bow (separate string/arrow pieces), so this clones either
-- shape and anchors/un-collides every real part inside it, same "set
-- PrimaryPart, touch every BasePart descendant" treatment
-- PlayerEquipment's own Attach_Weapon Model branch already uses.
local function Build_Weapon_Drop(weapon_model_name)
	local template = PlayerEquipment.find_weapon_template(weapon_model_name)
	if not template then
		return nil
	end
	local clone = template:Clone()
	if clone:IsA("Model") then
		local primary = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
		if not primary then
			clone:Destroy()
			return nil
		end
		clone.PrimaryPart = primary
		for _, descendant in ipairs(clone:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = true
			end
		end
		return clone
	end
	clone.Anchored = true
	clone.CanCollide = true
	return clone
end
-- Fallback for everything without a standalone ground-ready model --
-- currently that's armor too, not just modelless consumables: armor's
-- actual model is a shared multi-piece template whose positioning
-- (PlayerEquipment.Attach_Armor) is built around scaling to a live
-- character's limb sizes, so there's no ready "lying on the ground" pose
-- for it without a design pass. Revisit once that exists.
local function Build_Placeholder_Drop(item_name)
	local part = Instance.new("Part")
	part.Name = item_name
	part.Size = Vector3.new(1.5, 1.5, 1.5)
	part.Material = Enum.Material.WoodPlanks
	part.BrickColor = BrickColor.new("Institutional white")
	part.Anchored = true
	part.CanCollide = true
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(150, 40)
	billboard.StudsOffset = Vector3.new(0, 1.2, 0)
	-- [stated/found] labels were visible through walls from anywhere on the
	-- map -- AlwaysOnTop=true renders straight through occluding geometry
	-- (that's what it's for), and Roblox's default MaxDistance is enormous
	-- (effectively "always render"). Neither is right for a ground-item
	-- nameplate.
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = LABEL_MAX_DISTANCE
	billboard.Parent = part
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.SourceSansBold
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.5
	label.Text = item_name
	label.Parent = billboard
	return part
end
-- Adds the pickup prompt directly to the dropped piece.
-- [stated/found] this used to assume every drop was a single, unwelded
-- BasePart (no Model wrapper could ever need one, since armor -- the one
-- case that would've needed a multi-piece group -- falls back to the
-- placeholder box above). The bow drop breaks that assumption: a
-- ProximityPrompt parented to a Model tracks that Model's PrimaryPart,
-- which Build_Weapon_Drop above already guarantees is set, so parenting
-- it directly to either shape works with no further branching here.
local function Add_Pickup_Prompt(piece, item_name, amount)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Pick Up"
	prompt.ObjectText = amount > 1 and string.format("%s x%d", item_name, amount) or item_name
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = PICKUP_HOLD_DURATION
	prompt.MaxActivationDistance = PICKUP_MAX_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = piece
	-- HoldDuration is a property of the prompt instance itself, not
	-- per-player, so it has to be rewritten right as each attempt begins
	-- rather than baked in once at creation -- early enough that the
	-- engine's own hold timer for THIS attempt picks up the new value.
	prompt.PromptButtonHoldBegan:Connect(function(player)
		local fraction = math.max(MIN_INTERACTION_HOLD_FRACTION, 1 - (PlayerStats.get(player, "Dexterity") - 1) * DEXTERITY_INTERACTION_SPEED_PER_POINT)
		prompt.HoldDuration = PICKUP_HOLD_DURATION * fraction
	end)
	local picked_up = false
	prompt.Triggered:Connect(function(player)
		if picked_up then
			return
		end
		picked_up = true
		prompt.Enabled = false
		local inventory = PlayerInventory.add_item(player, item_name, amount)
		inventory_updated:FireClient(player, inventory)
		PlayerWeight.notify(player)
		task.wait(0.2)
		piece:Destroy()
	end)
end
-- Builds a pickupable ground representation of item_name/amount at an EXACT
-- world position, with no raycasting of its own -- the caller has already
-- decided what "on the ground" means here. drop_item (below) figures that
-- out with a short raycast anchored near the dropping player; StartMatch's
-- building floor-loot scatter uses a short indoor raycast off a
-- LootFloorArea marker instead, since a long-range one would just hit the
-- building's roof on an upper floor rather than that floor's actual surface.
-- Both funnel through this one function so there's a single place that
-- knows how a ground item looks and how it's picked up.
function DroppedItems.spawn_ground_item_at(item_name, amount, position)
	local data = ItemData[item_name]
	if not data then
		return false, "unknown item"
	end
	local piece = nil
	if data.WeaponModel then
		piece = Build_Weapon_Drop(data.WeaponModel)
	end
	if not piece then
		piece = Build_Placeholder_Drop(item_name)
	end
	-- Tips the piece onto its own largest face (see
	-- Get_Lay_Flat_Rotation_And_Height above) and uses the resulting
	-- half-height for the ground offset -- whichever axis ends up
	-- vertical after the tilt, not always the Y size, or a tipped item
	-- ends up floating/clipping instead of resting flush.
	local rotation, half_height = Get_Lay_Flat_Rotation_And_Height(piece)
	local target_cframe = CFrame.new(position.X, position.Y + half_height + 0.05, position.Z) * rotation
	Set_Ground_Piece_CFrame(piece, target_cframe)
	piece.Parent = workspace
	Add_Pickup_Prompt(piece, item_name, amount)
	return true, piece
end
-- Removes item_name from the player's inventory and spawns a ground-
-- pickable representation of it. requested_amount is optional -- omit it
-- (or pass nil) to drop everything owned, matching the original "entire
-- stack" behavior; pass a specific amount to drop only that many, clamped
-- to what's actually owned so a stale/adversarial client can't drop more
-- than it has. [stated/found] this used to ALWAYS drop the full owned
-- amount regardless of what the player actually clicked/dragged -- fine
-- for a single stacked slot, but wrong the moment an item is split across
-- more than one slot (a second separate non-stackable weapon sitting
-- elsewhere in the inventory, or a stackable item split between the grid
-- and the hotbar): dropping ONE of them was taking ALL of them. Returns
-- true, amount-actually-dropped on success; false, reason on failure
-- (nothing removed in that case).
function DroppedItems.drop_item(player, item_name, requested_amount)
	local data = ItemData[item_name]
	if not data then
		return false, "unknown item"
	end
	local owned = PlayerInventory.get_amount(player, item_name)
	if owned <= 0 then
		return false, "item not owned"
	end
	local amount = requested_amount and math.min(requested_amount, owned) or owned
	if amount <= 0 then
		return false, "invalid amount"
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false, "no character"
	end
	PlayerInventory.remove_item(player, item_name, amount)
	local drop_position = (root.CFrame * CFrame.new(0, 0, -DROP_DISTANCE)).Position
	local ground_y = Get_Ground_Height(drop_position.X, drop_position.Z, root.Position.Y) or root.Position.Y
	DroppedItems.spawn_ground_item_at(item_name, amount, Vector3.new(drop_position.X, ground_y, drop_position.Z))
	return true, amount
end
return DroppedItems
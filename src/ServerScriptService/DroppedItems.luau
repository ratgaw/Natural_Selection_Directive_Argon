-- Dropping items onto the ground and picking them back up with E.
-- Anyone can pick up any dropped item.
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
-- Placeholders.
local DROP_DISTANCE = 3 -- studs in front of the player a dropped item lands
local PICKUP_HOLD_DURATION = 0.3
local PICKUP_MAX_DISTANCE = 8
-- Dexterity -> faster pickup.
local DEXTERITY_INTERACTION_SPEED_PER_POINT = 0.04
local MIN_INTERACTION_HOLD_FRACTION = 0.5
local LABEL_MAX_DISTANCE = 40 -- placeholder, tune once tested
-- Drops can be a single part or a Model (bows); these helpers handle both.
local function Get_Ground_Piece_Size(piece)
	if piece:IsA("Model") then
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
-- Lays the item on its largest face: rotates so its thinnest axis points up.
-- Returns the rotation and the resulting half-height for the ground offset.
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
-- Short ray from just above the player's feet, so drops indoors land on the
-- floor instead of the roof. Without reference_y it searches from high above.
local GROUND_RAY_CLEARANCE = 5
local GROUND_RAY_DISTANCE = 20
local function Get_Ground_Height(x, z, reference_y)
	local origin_y = (reference_y and reference_y + GROUND_RAY_CLEARANCE) or 1000
	local distance = reference_y and GROUND_RAY_DISTANCE or 2000
	local result = workspace:Raycast(Vector3.new(x, origin_y, z), Vector3.new(0, -distance, 0))
	return result and result.Position.Y or nil
end
-- Clones the weapon's template (part or Model) as an anchored ground item.
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
-- Labeled box for items without a ground model (including armor).
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
	-- Don't show labels through walls or from across the map.
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
-- Prompt works on a part or a Model (it tracks the PrimaryPart).
local function Add_Pickup_Prompt(piece, item_name, amount)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Pick Up"
	prompt.ObjectText = amount > 1 and string.format("%s x%d", item_name, amount) or item_name
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = PICKUP_HOLD_DURATION
	prompt.MaxActivationDistance = PICKUP_MAX_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = piece
	-- HoldDuration is per prompt, so set it from this player's Dexterity as each
	-- hold begins.
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
-- Creates a pickupable item at an exact position (the caller handles finding
-- the ground). Used by drop_item and StartMatch's floor loot.
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
	-- Use the post-rotation half-height so tipped items sit flush.
	local rotation, half_height = Get_Lay_Flat_Rotation_And_Height(piece)
	local target_cframe = CFrame.new(position.X, position.Y + half_height + 0.05, position.Z) * rotation
	Set_Ground_Piece_CFrame(piece, target_cframe)
	piece.Parent = workspace
	Add_Pickup_Prompt(piece, item_name, amount)
	return true, piece
end
-- Removes item_name from the inventory and drops it in front of the player.
-- requested_amount is clamped to what's owned; nil drops everything.
-- Returns true, amount or false, reason (nothing removed on failure).
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
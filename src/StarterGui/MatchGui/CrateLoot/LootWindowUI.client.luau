local replicated_storage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local crate_contents_updated = replicated_storage:WaitForChild("CrateContentsUpdated")
local take_crate_item_request = replicated_storage:WaitForChild("TakeCrateItemRequest")
local take_all_crate_request = replicated_storage:WaitForChild("TakeAllCrateRequest")

local loot_window = script.Parent
local frame = loot_window:WaitForChild("Frame")
local item_template = frame:WaitForChild("ItemTemplate")
local take_all_button = frame:WaitForChild("TakeAll")
local close_button = frame:WaitForChild("MenuClose")

local local_player = Players.LocalPlayer
local player_scripts = local_player:WaitForChild("PlayerScripts")
local camera_lock_state = require(player_scripts:WaitForChild("CameraLockState"))

local current_crate = nil

local function Clear_Items()
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("TextButton") and child ~= item_template and child ~= take_all_button and child ~= close_button then
			child:Destroy()
		end
	end
end

local function Populate_Loot(crate_instance, contents)
	local opened = camera_lock_state.try_open_gui("LootWindow")
	if not opened then
		-- Another GUI (e.g. the inventory) is already open — don't show
		-- the loot window even though the server did roll real contents.
		return
	end

	current_crate = crate_instance
	Clear_Items()

	-- One row per entry, e.g. "Beans Can x3". Only the name is sent back; the server
	-- knows the amount.
	for _, entry in ipairs(contents) do
		local item_button = item_template:Clone()
		item_button.Text = entry.Amount > 1 and (entry.ItemName .. " x" .. entry.Amount) or entry.ItemName
		item_button.Visible = true
		item_button.Parent = frame
		item_button.MouseButton1Click:Connect(function()
			take_crate_item_request:FireServer(current_crate, entry.ItemName)
		end)
	end

	loot_window.Enabled = true
	frame.Visible = true
end

crate_contents_updated.OnClientEvent:Connect(Populate_Loot)

take_all_button.MouseButton1Click:Connect(function()
	if current_crate then
		take_all_crate_request:FireServer(current_crate)
	end
end)

close_button.MouseButton1Click:Connect(function()
	loot_window.Enabled = false
	frame.Visible = false
	camera_lock_state.close_gui("LootWindow")
end)
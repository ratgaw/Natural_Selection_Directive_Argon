local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local local_player = Players.LocalPlayer
local player_scripts = local_player:WaitForChild("PlayerScripts")
local gui = script.Parent
local inventory = gui:WaitForChild("Inventory")
local toggleButton = gui:WaitForChild("InventoryButton")
local camera_lock_state = require(player_scripts:WaitForChild("CameraLockState"))

local function toggleInventory()
	if inventory.Visible then
		inventory.Visible = false
		camera_lock_state.close_gui("Inventory")
	else
		local opened = camera_lock_state.try_open_gui("Inventory")
		if opened then
			inventory.Visible = true
		end
		-- If not opened, another GUI (e.g. the loot window) is already
		-- open — silently do nothing, per the single-GUI-at-a-time rule.
	end
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed == true then
		return
	end
	if input.KeyCode == Enum.KeyCode.C then
		toggleInventory()
	end
end)
toggleButton.MouseButton1Click:Connect(toggleInventory)
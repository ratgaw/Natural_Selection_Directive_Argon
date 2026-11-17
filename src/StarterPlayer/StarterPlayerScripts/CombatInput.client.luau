local user_input_service = game:GetService("UserInputService")
local replicated_storage = game:GetService("ReplicatedStorage")
local attack_request = replicated_storage:WaitForChild("AttackRequest")
local block_start_request = replicated_storage:WaitForChild("BlockStartRequest")
local block_stop_request = replicated_storage:WaitForChild("BlockStopRequest")
local dodge_request = replicated_storage:WaitForChild("DodgeRequest")
-- [stated] "Hold to charge, release to fire" bow draw -- PlayerCombat.lua
-- already has start_draw/release_draw and RequestChecker.lua already
-- wires these two remotes to them; this script is what actually fires
-- them. Needs manual creation in ReplicatedStorage, same outstanding step
-- as every other new remote this project.
local draw_start_request = replicated_storage:WaitForChild("DrawStartRequest")
local draw_release_request = replicated_storage:WaitForChild("DrawReleaseRequest")
-- [stated/found] "attempt to perform arithmetic (mul) on nil and number"
-- in PlayerCombat.attack the first time MouseButton1 fired AttackRequest
-- while a bow was equipped -- a melee swing and a ranged draw are two
-- completely different server calls (attack vs. start_draw/release_draw),
-- so this script needs to know what's currently equipped to pick the
-- right one. equipment_updated already fires this exact table
-- (RequestChecker.lua's equip_request/unequip_request handlers both do
-- `equipment_updated:FireClient(player, equipped)`) -- it was just never
-- listened to here before, since melee never needed to know.
local equipment_updated = replicated_storage:WaitForChild("EquipmentUpdated")
local ItemData = require(replicated_storage:WaitForChild("ItemData"))
local camera_lock_state = require(script.Parent:WaitForChild("CameraLockState"))
-- Updated on every EquipmentUpdated -- read once per MouseButton1 press
-- to decide attack vs. draw, same "decide off current equipped state, not
-- a stored mode flag" spirit RequestChecker's own server-side gating
-- already uses for the food-vs-weapon AttackRequest branch.
local equipped_weapon_item_name = nil
equipment_updated.OnClientEvent:Connect(function(equipped)
	local weapon_entry = equipped and equipped["Weapon"]
	equipped_weapon_item_name = weapon_entry and weapon_entry.ItemName
end)
-- Set the instant MouseButton1 goes down IF that press started a ranged
-- draw, so InputEnded knows whether its own MouseButton1 release means
-- "release_draw" -- reading equipped_weapon_item_name again at release
-- time would be wrong if the player switched weapons mid-hold.
local is_drawing = false
user_input_service.InputBegan:Connect(function(input, game_processed)
	if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
		camera_lock_state.alt_held = true
		camera_lock_state.apply()
		return
	end
	if game_processed or camera_lock_state.gui_open then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		local weapon_data = equipped_weapon_item_name and ItemData[equipped_weapon_item_name]
		if weapon_data and weapon_data.IsRanged then
			is_drawing = true
			draw_start_request:FireServer()
		else
			attack_request:FireServer()
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		camera_lock_state.right_click_held = true
		if camera_lock_state.alt_held then
			camera_lock_state.apply()
		else
			block_start_request:FireServer()
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton3 then
		dodge_request:FireServer()
	end
end)
user_input_service.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
		camera_lock_state.alt_held = false
		camera_lock_state.apply()
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if is_drawing then
			is_drawing = false
			draw_release_request:FireServer()
		end
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		local was_camera_adjusting = camera_lock_state.right_click_held and camera_lock_state.alt_held
		camera_lock_state.right_click_held = false
		camera_lock_state.apply()
		if not was_camera_adjusting and not camera_lock_state.gui_open then
			block_stop_request:FireServer()
		end
	end
end)
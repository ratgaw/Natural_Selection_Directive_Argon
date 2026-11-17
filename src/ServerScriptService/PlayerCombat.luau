-- Declaring game services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
-- Bow draw reference models live here (see the Ranged weapons section).
local ServerStorage = game:GetService("ServerStorage")
local ItemData = require(ReplicatedStorage:WaitForChild("ItemData"))
-- Tells only the attacking player's client to draw the ground swing-cone telegraph
-- (SwingConeTelegraph.client). Sends the swing track's Length so the cone lasts
-- exactly as long as the animation.
local swing_telegraph_event = ReplicatedStorage:WaitForChild("SwingTelegraph")
local server_script = game:GetService("ServerScriptService")
local PlayerStamina = require(server_script:WaitForChild("PlayerStamina"))
local PlayerEquipment = require(server_script:WaitForChild("PlayerEquipment"))
local PlayerWeight = require(server_script:WaitForChild("PlayerWeight"))
local PlayerHunger = require(server_script:WaitForChild("PlayerHunger"))
local PlayerStats = require(server_script:WaitForChild("PlayerStats"))
-- Real sprint state, used to pick the walk vs. run phase multiplier in
-- Get_Blended_Movement_Phase.
local PlayerSprint = require(server_script:WaitForChild("PlayerSprint"))
local PlayerCombat = {}
PlayerCombat.blocking_players = {}
PlayerCombat.invulnerable_until = {}
-- /dev invincibility: a standing flag (unlike the timed dodge window below),
-- checked first in is_invulnerable so every damage source respects it.
PlayerCombat.dev_invulnerable = {}
local DODGE_STAMINA_COST = 25
local DODGE_INVULN_DURATION = 0.3
-- Dodge: short invulnerability window plus a directional dash (backward if
-- standing still). Dash lasts as long as the invuln window; distance scales
-- with weight tier.
local BASE_DASH_DISTANCE = 12 -- studs, at Standard weight tier
local DASH_DURATION = 0.3
-- [player] = Heartbeat connection driving an in-flight dash, so a re-dodge or
-- leaving can cancel it cleanly.
local active_dash_connections = {}
local BLOCK_STAMINA_DRAIN_PER_SECOND = 10
local BLOCK_DAMAGE_REDUCTION = 0.5
local ATTACK_WINDUP_DELAY = 0.25 -- seconds, matches the swing animation's windup
local COMBAT_TARGET_TAG = "CombatTarget"
-- Armor reduces damage by a percentage (capped), so heavy hits still hurt
-- armored targets. Tune alongside per-item Defense in ItemData.
local DEFENSE_REDUCTION_PER_POINT = 0.02 -- 2% damage reduction per point of Defense
local MAX_DEFENSE_REDUCTION = 0.6 -- armor alone can't reduce damage by more than 60%
-- Strength -> melee damage. Uncapped; stat items are already limited.
local STRENGTH_DAMAGE_PER_POINT = 0.05
-- Endurance -> cheaper attack stamina cost (floored).
local ENDURANCE_ATTACK_COST_REDUCTION_PER_POINT = 0.05
local MIN_ATTACK_COST_FRACTION = 0.5
-- Dexterity -> faster swings (shorter cooldown, floored).
local DEXTERITY_SWING_SPEED_PER_POINT = 0.04
local MIN_SWING_COOLDOWN_FRACTION = 0.5
-- Knockback: dealt scales with attacker Strength, resisted with target
-- Endurance. A single horizontal impulse that decays naturally.
local BASE_KNOCKBACK_FORCE = 25
local STRENGTH_KNOCKBACK_DEALT_PER_POINT = 0.05
local ENDURANCE_KNOCKBACK_RESIST_PER_POINT = 0.05
local MAX_KNOCKBACK_RESIST_REDUCTION = 0.6
local last_attack_time = {}
-- Swing animation per WeaponModel. Tiers share a clip for now.
local WEAPON_SWING_ANIMATIONS = {
	["Tier1MacePipe"] = "rbxassetid://123175949781602",
	["Tier2MacePoliceBaton"] = "rbxassetid://123175949781602",
	["Tier3MaceFlangedMace"] = "rbxassetid://123175949781602",
	["Fists"] = "rbxassetid://115447738290945",
	["Tier1AxeWoodAxe"] = "rbxassetid://119725409532721",
	["Tier2AxeFireaxe"] = "rbxassetid://119725409532721",
	["Tier3AxeMilitaryAxe"] = "rbxassetid://119725409532721",
	["Tier1TrainingSword"] = "rbxassetid://121781100536173",
	["Tier2HistoricalSword"] = "rbxassetid://121781100536173",
	["Tier3MilitarySword"] = "rbxassetid://121781100536173",
}
-- Bow/sling draw animation, played from start_draw (see Get_Fire_Track).
local WEAPON_FIRE_ANIMATIONS = {
	["Empty Bow"] = "rbxassetid://107808555659870",
}
-- Continuous "weapon out" poses, authored on arm joints only so they layer over
-- the default leg walk/run. Weapons with no entry keep the default Animate poses.
-- Move is position-locked to the legs (see Start_Move_Sync); the phase multipliers
-- scale its cycle separately for walking and sprinting (default 1).
local WEAPON_HOLD_POSE_ANIMATIONS = {
	["Tier1AxeWoodAxe"] = {Idle = "rbxassetid://74728762589279", Move = "rbxassetid://132488335286650", MoveWalkPhaseMultiplier = 0.5, MoveRunPhaseMultiplier = 0.5},
	["Tier2AxeFireaxe"] = {Idle = "rbxassetid://74728762589279", Move = "rbxassetid://132488335286650", MoveWalkPhaseMultiplier = 0.5, MoveRunPhaseMultiplier = 0.5},
	["Tier3AxeMilitaryAxe"] = {Idle = "rbxassetid://74728762589279", Move = "rbxassetid://132488335286650", MoveWalkPhaseMultiplier = 0.5, MoveRunPhaseMultiplier = 0.5},
	["Tier1TrainingSword"] = {Idle = "rbxassetid://86403277677852", Move = "rbxassetid://117859017992029", MoveWalkPhaseMultiplier = 0.5, MoveRunPhaseMultiplier = 0.5},
	["Tier2HistoricalSword"] = {Idle = "rbxassetid://86403277677852", Move = "rbxassetid://117859017992029", MoveWalkPhaseMultiplier = 0.5, MoveRunPhaseMultiplier = 0.5},
	["Tier3MilitarySword"] = {Idle = "rbxassetid://86403277677852", Move = "rbxassetid://117859017992029", MoveWalkPhaseMultiplier = 0.5, MoveRunPhaseMultiplier = 0.5},
	["Empty Bow"] = {Idle = "rbxassetid://0", Move = "rbxassetid://82761838868249", MoveWalkPhaseMultiplier = 0.5, MoveRunPhaseMultiplier = 0.5},
}
local WEAPON_BLOCK_ANIMATIONS = {
	["Tier1AxeWoodAxe"] = "rbxassetid://112631031216145",
	["Tier2AxeFireaxe"] = "rbxassetid://112631031216145",
	["Tier3AxeMilitaryAxe"] = "rbxassetid://112631031216145",
}
-- Hold poses use Action priority to override the default arm swing; the swing
-- itself uses Action2 so it fully overrides the hold pose while it plays.
local HOLD_POSE_FADE_TIME = 0.15
-- A non-looping track stops itself on reaching Length. To hold the last draw
-- frame, the Setup_Bow Heartbeat clamps TimePosition to Length minus this
-- cushion and freezes playback until release.
local FIRE_TRACK_HOLD_EPSILON = 0.03
local loaded_swing_tracks = {} -- [player] = {[weapon_model_name] = AnimationTrack}
local loaded_fire_tracks = {} -- [player] = {[weapon_model_name] = AnimationTrack} -- see Get_Fire_Track/WEAPON_FIRE_ANIMATIONS
local loaded_hold_tracks = {} -- [player] = {[weapon_model_name] = {Idle=, Move=, Block=}}
local active_hold_track = {} -- [player] = the one AnimationTrack currently playing from Idle/Move/Block (or nil)
local hold_pose_connections = {} -- [player] = Humanoid.Running connection that picks Idle vs Move
local move_sync_connections = {} -- [player] = Heartbeat connection driving the Move track (see Start_Move_Sync)
-- Unarmed stats, used when the Weapon slot is empty. WeaponModel is only a key
-- into the animation tables.
local FIST_DATA = {
	Damage = 5,
	Range = 4,
	ConeAngle = 70,
	AttackStaminaCost = 0, -- always available, even at 0 stamina
	AttackCooldown = 0.4,
	WeaponModel = "Fists",
}
-- Loads and caches a swing track per weapon so swings reuse it.
local function Get_Swing_Track(player, character, weapon_model_name)
	local anim_id = WEAPON_SWING_ANIMATIONS[weapon_model_name]
	if not anim_id then
		return nil
	end
	loaded_swing_tracks[player] = loaded_swing_tracks[player] or {}
	if loaded_swing_tracks[player][weapon_model_name] then
		return loaded_swing_tracks[player][weapon_model_name]
	end
	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = anim_id
	local track = humanoid:LoadAnimation(animation)
	-- Action2: one tier above the hold poses so the swing fully overrides them.
	track.Priority = Enum.AnimationPriority.Action2
	loaded_swing_tracks[player][weapon_model_name] = track
	return track
end
-- Same load-and-cache as Get_Swing_Track, for the draw clip. Played from
-- start_draw so it starts on button-down; Action2 so it overrides hold poses.
local function Get_Fire_Track(player, character, weapon_model_name)
	local anim_id = WEAPON_FIRE_ANIMATIONS[weapon_model_name]
	if not anim_id then
		return nil
	end
	loaded_fire_tracks[player] = loaded_fire_tracks[player] or {}
	if loaded_fire_tracks[player][weapon_model_name] then
		return loaded_fire_tracks[player][weapon_model_name]
	end
	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = anim_id
	local track = humanoid:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Action2
	loaded_fire_tracks[player][weapon_model_name] = track
	return track
end
-- Returns the currently equipped weapon's data, or FIST_DATA as a fallback
-- when nothing is equipped — combat always has something to fall back on.
local function Get_Equipped_Weapon_Data(player)
	local equipped = PlayerEquipment.player_equipment[player]
	if equipped and equipped["Weapon"] then
		local data = ItemData[equipped["Weapon"].ItemName]
		if data then
			return data
		end
	end
	return FIST_DATA
end
-- Loads and caches Idle/Move/Block tracks for a weapon. Returns nil if the
-- weapon has no hold poses (callers then leave the default Animate alone).
local function Get_Hold_Tracks(player, character, weapon_model_name)
	local pose_ids = WEAPON_HOLD_POSE_ANIMATIONS[weapon_model_name]
	if not pose_ids then
		return nil
	end
	loaded_hold_tracks[player] = loaded_hold_tracks[player] or {}
	if loaded_hold_tracks[player][weapon_model_name] then
		return loaded_hold_tracks[player][weapon_model_name]
	end
	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid then
		return nil
	end
	-- Idle/Move loop. Block plays once and start_block pins its last frame, because
	-- a finished non-looping track releases the pose instead of holding it.
	local function Load(anim_id, should_loop)
		if not anim_id then
			return nil
		end
		local animation = Instance.new("Animation")
		animation.AnimationId = anim_id
		local track = humanoid:LoadAnimation(animation)
		track.Priority = Enum.AnimationPriority.Action
		track.Looped = should_loop
		return track
	end
	local tracks = {
		Idle = Load(pose_ids.Idle, true),
		Move = Load(pose_ids.Move, true),
		Block = Load(WEAPON_BLOCK_ANIMATIONS[weapon_model_name], false),
	}
	-- Move is frozen here and driven by Start_Move_Sync instead, so it never runs
	-- on its own clock and drifts from the legs.
	if tracks.Move then
		tracks.Move:AdjustSpeed(0)
	end
	loaded_hold_tracks[player][weapon_model_name] = tracks
	return tracks
end
-- ============================================================
-- Ranged weapons -- hold to charge, release to fire (bows and slings)
-- ============================================================
-- Draw fraction = time held / MaxDrawTime (max 1); damage, range, speed and
-- accuracy all scale with it (see Fire_Projectile).
-- Visuals are procedural, since animations can't resize parts:
-- - "stretch" (bow): strings span from fixed tip Attachments on the bow to a
--   draw point that slides from the nock toward the drawing hand.
-- - "spin" (sling): the pouch/cord assembly orbits the hand, speeding up with
--   the draw.
-- Tracked parts must not be welded inside the model; Strip_Rigid_Constraints
-- removes any such weld at equip time.
local function Find_Equipped_Weapon_Model(character, weapon_model_name)
	return character:FindFirstChild(weapon_model_name, true)
end
-- Searches all of ServerStorage.PlayerItems, same as Find_Weapon_Template.
local cached_reference_models = {} -- [DrawReferenceModel name] = Model, shared by everyone
local function Get_Reference_Model(reference_name)
	if cached_reference_models[reference_name] then
		return cached_reference_models[reference_name]
	end
	local player_items = ServerStorage:FindFirstChild("PlayerItems")
	if not player_items then
		warn("[PlayerCombat] couldn't find ServerStorage.PlayerItems -- check this path still matches your actual folder layout before this weapon will draw correctly")
		return nil
	end
	for _, instance in ipairs(player_items:GetDescendants()) do
		if instance.Name == reference_name and instance:IsA("Model") then
			cached_reference_models[reference_name] = instance
			return instance
		end
	end
	warn("[PlayerCombat] couldn't find draw reference model '" .. reference_name .. "' anywhere under ServerStorage.PlayerItems")
	return nil
end
-- Destroys welds whose BOTH ends are inside this model and touch a tracked part.
-- Matching by Part0/Part1 catches the weld whichever side it's parented to;
-- requiring both ends inside the model keeps the hand weld (one end is
-- RightHand) intact. (Set "Empty Bow"'s PrimaryPart to "Bow" in Studio too.)
local function Strip_Rigid_Constraints_Touching(model, parts_set)
	for _, instance in ipairs(model:GetDescendants()) do
		if instance:IsA("WeldConstraint") or instance:IsA("Weld") or instance:IsA("Motor6D") then
			local part0, part1 = instance.Part0, instance.Part1
			if (parts_set[part0] or parts_set[part1]) and part0 and part1 and part0:IsDescendantOf(model) and part1:IsDescendantOf(model) then
				instance:Destroy()
			end
		end
	end
end
-- Captures each part's CFrame/Size relative to anchor_part, so poses stay valid
-- wherever the weapon moves; the Setup_Bow loop converts back every frame.
local function Capture_Pose_Relative_To(anchor_part, parts_by_name)
	local pose = {}
	for name, part in pairs(parts_by_name) do
		if part then
			pose[name] = {CFrame = anchor_part.CFrame:ToObjectSpace(part.CFrame), Size = part.Size}
		end
	end
	return pose
end
local function Lerp_Number(min_value, max_value, fraction)
	return min_value + (max_value - min_value) * fraction
end
-- Which of a Size's axes is longest -- the axis a string is resized and
-- pointed along.
local function Get_Long_Axis(size)
	if size.X >= size.Y and size.X >= size.Z then
		return "X"
	elseif size.Y >= size.X and size.Y >= size.Z then
		return "Y"
	end
	return "Z"
end
local function Set_Long_Axis_Size(rest_size, new_length)
	local long_axis = Get_Long_Axis(rest_size)
	if long_axis == "X" then
		return Vector3.new(new_length, rest_size.Y, rest_size.Z)
	elseif long_axis == "Y" then
		return Vector3.new(rest_size.X, new_length, rest_size.Z)
	end
	return Vector3.new(rest_size.X, rest_size.Y, new_length)
end
-- CFrame spanning point_a to point_b with rest_size's longest axis along that
-- line. up_hint only keeps the string from twisting frame to frame.
local function Build_Beam_CFrame(point_a, point_b, up_hint, rest_size)
	local delta = point_b - point_a
	local length = delta.Magnitude
	local direction = length > 1e-4 and (delta / length) or Vector3.new(0, 1, 0)
	local midpoint = (point_a + point_b) / 2
	local right = direction:Cross(up_hint)
	if right.Magnitude < 1e-4 then
		right = direction:Cross(Vector3.new(1, 0, 0))
	end
	if right.Magnitude < 1e-4 then
		right = direction:Cross(Vector3.new(0, 0, 1))
	end
	right = right.Unit
	local up = right:Cross(direction).Unit
	local long_axis = Get_Long_Axis(rest_size)
	local cframe
	if long_axis == "X" then
		cframe = CFrame.fromMatrix(midpoint, direction, up, right)
	elseif long_axis == "Y" then
		cframe = CFrame.fromMatrix(midpoint, right, direction, up)
	else
		cframe = CFrame.fromMatrix(midpoint, up, right, direction)
	end
	return cframe, length
end
-- Local offset from the arrow's center to its nock end: the long axis, with the
-- sign picked by whichever end is nearer the nock Attachment. Nil if either
-- argument is missing.
local function Compute_Arrow_Local_Offset(projectile_part, nock_rest_attachment)
	if not projectile_part or not nock_rest_attachment then
		return nil
	end
	local size = projectile_part.Size
	local long_axis = Get_Long_Axis(size)
	local half_length = size[long_axis] / 2
	local function Axis_Offset(axis_name, distance)
		if axis_name == "X" then
			return Vector3.new(distance, 0, 0)
		elseif axis_name == "Y" then
			return Vector3.new(0, distance, 0)
		end
		return Vector3.new(0, 0, distance)
	end
	local nock_world_position = nock_rest_attachment.WorldPosition
	local candidate_positive = (projectile_part.CFrame * CFrame.new(Axis_Offset(long_axis, half_length))).Position
	local candidate_negative = (projectile_part.CFrame * CFrame.new(Axis_Offset(long_axis, -half_length))).Position
	if (candidate_positive - nock_world_position).Magnitude <= (candidate_negative - nock_world_position).Magnitude then
		return Axis_Offset(long_axis, half_length)
	end
	return Axis_Offset(long_axis, -half_length)
end
-- Clones a fresh arrow from the DrawReferenceModel when a draw starts (the
-- arrow isn't on the bow while equipped). Returns nil if there's nothing to clone.
local function Spawn_Draw_Arrow(bow_model, pivot_part, bow_data)
	local reference_model = bow_data.DrawReferenceModel and Get_Reference_Model(bow_data.DrawReferenceModel)
	local reference_projectile = reference_model and reference_model:FindFirstChild(bow_data.ProjectilePart)
	if not reference_projectile then
		return nil
	end
	local projectile_part = reference_projectile:Clone()
	-- Spawned outside Attach_Weapon, so anchor it and strip any welds here.
	projectile_part.Anchored = true
	projectile_part.CanCollide = false
	for _, instance in ipairs(projectile_part:GetDescendants()) do
		if instance:IsA("WeldConstraint") or instance:IsA("Weld") or instance:IsA("Motor6D") then
			instance:Destroy()
		end
	end
	projectile_part.Parent = bow_model
	-- Temporary position; the follow loop places it at the nock before the next frame.
	projectile_part.CFrame = pivot_part.CFrame
	return projectile_part
end
local active_bow_draws = {} -- [player] = per-player draw state, created by Setup_Bow
local bow_follow_connections = {} -- [player] = Heartbeat connection positioning the tracked parts while equipped
local function Teardown_Bow(player)
	if bow_follow_connections[player] then
		bow_follow_connections[player]:Disconnect()
		bow_follow_connections[player] = nil
	end
	active_bow_draws[player] = nil
end
-- Called from refresh_weapon_animations when a bow or sling is equipped.
-- Sets up the per-frame procedural draw visuals.
local function Setup_Bow(player, character, weapon_model_name, bow_data)
	Teardown_Bow(player)
	local bow_model = Find_Equipped_Weapon_Model(character, weapon_model_name)
	if not bow_model then
		warn("[PlayerCombat] equipped ranged weapon '" .. weapon_model_name .. "' not found under " .. player.Name .. "'s character -- Attach_Weapon in PlayerEquipment.lua may have failed to clone/parent it (check its own warnings) rather than this lookup being wrong")
		return
	end
	-- BowPart is optional: a sling has no rigid frame, so the hand is the pivot.
	local pivot_part
	if bow_data.BowPart then
		pivot_part = bow_model:FindFirstChild(bow_data.BowPart)
		if not pivot_part then
			warn("[PlayerCombat] weapon model '" .. weapon_model_name .. "' has no '" .. bow_data.BowPart .. "' part")
			return
		end
	else
		pivot_part = character:FindFirstChild("RightHand")
		if not pivot_part then
			warn("[PlayerCombat] no RightHand found on " .. player.Name .. "'s character -- can't position hand-anchored ranged weapon '" .. weapon_model_name .. "'")
			return
		end
	end
	local tracked_parts = {}
	for _, tracked_name in ipairs(bow_data.TrackedParts) do
		local tracked_part = bow_model:FindFirstChild(tracked_name)
		if tracked_part then
			tracked_parts[tracked_name] = tracked_part
		end
	end
	-- Nil for a bow with no arrow on its model; start_draw spawns one per draw.
	local projectile_part = bow_model:FindFirstChild(bow_data.ProjectilePart)
	if projectile_part then
		tracked_parts[bow_data.ProjectilePart] = projectile_part
	end
	-- Build the full set first so the weld sweep can check every tracked part.
	local parts_set = {}
	for _, part in pairs(tracked_parts) do
		parts_set[part] = true
	end
	Strip_Rigid_Constraints_Touching(bow_model, parts_set)
	-- If the model's PrimaryPart isn't the bow body (Attach_Weapon falls back to any
	-- BasePart), the hand weld ends up on a string and the bow body falls. Move that
	-- hand weld onto pivot_part instead.
	if bow_data.BowPart and bow_model.PrimaryPart and bow_model.PrimaryPart ~= pivot_part then
		local primary_part = bow_model.PrimaryPart
		for _, instance in ipairs(bow_model:GetDescendants()) do
			if instance:IsA("WeldConstraint") or instance:IsA("Weld") or instance:IsA("Motor6D") then
				local part0, part1 = instance.Part0, instance.Part1
				if part0 == primary_part or part1 == primary_part then
					local hand = (part0 == primary_part) and part1 or part0
					instance:Destroy()
					if hand then
						local pivot_hand_weld = Instance.new("WeldConstraint")
						pivot_hand_weld.Name = "PivotHandWeld"
						pivot_hand_weld.Part0 = pivot_part
						pivot_hand_weld.Part1 = hand
						pivot_hand_weld.Parent = pivot_part
					else
						warn("[PlayerCombat] '" .. weapon_model_name .. "' had a rigid constraint on its PrimaryPart ('" .. primary_part.Name .. "') with no other part set -- couldn't rebuild a hand-weld for pivot_part ('" .. pivot_part.Name .. "'), so it'll have nothing holding it up")
					end
				end
			end
		end
	end
	-- Attach_Weapon unanchors every part. Tracked parts lost their internal welds
	-- above, so anchor them; only this loop moves them. The pivot keeps its hand weld.
	for _, tracked_part in pairs(tracked_parts) do
		tracked_part.Anchored = true
	end
	-- rest_pose is used by "spin" weapons only.
	local rest_pose = Capture_Pose_Relative_To(pivot_part, tracked_parts)
	-- Bow geometry comes from Attachments under the Bow part, read live each frame:
	-- UpperStringTip/LowerStringTip are the fixed string ends; StringRestNock is the
	-- undrawn string/arrow point (its rotation sets the arrow's look only; aiming
	-- uses the player's facing).
	local string_tip_attachments = nil
	local nock_rest_attachment = nil
	local draw_hand = nil
	if bow_data.StringTipAttachment then
		string_tip_attachments = {}
		for tracked_name, attachment_name in pairs(bow_data.StringTipAttachment) do
			local attachment = pivot_part:FindFirstChild(attachment_name)
			if attachment then
				string_tip_attachments[tracked_name] = attachment
			else
				warn("[PlayerCombat] '" .. weapon_model_name .. "' is missing an Attachment named '" .. attachment_name .. "' under '" .. pivot_part.Name .. "' -- add it in Studio (marking where " .. tracked_name .. " should touch the bow) or it won't animate")
			end
		end
		if bow_data.NockRestAttachment then
			nock_rest_attachment = pivot_part:FindFirstChild(bow_data.NockRestAttachment)
			if not nock_rest_attachment then
				warn("[PlayerCombat] '" .. weapon_model_name .. "' is missing an Attachment named '" .. bow_data.NockRestAttachment .. "' under '" .. pivot_part.Name .. "' -- add it in Studio (marking the undrawn string/arrow rest point) or the draw won't animate")
			end
		end
		-- Assumes the bow is held in RightHand and drawn with LeftHand.
		draw_hand = character:FindFirstChild("LeftHand")
		if not draw_hand then
			warn("[PlayerCombat] no LeftHand found on " .. player.Name .. "'s character -- the draw won't have anywhere live to track for '" .. weapon_model_name .. "'")
		end
	end
	-- Each string's rest Size, captured once; only its long axis changes per frame.
	local string_rest_info = {}
	if string_tip_attachments then
		for tracked_name in pairs(string_tip_attachments) do
			local part = tracked_parts[tracked_name]
			if part then
				string_rest_info[tracked_name] = part.Size
			end
		end
	end
	-- Only set for a weapon that carries its own arrow at equip time;
	-- draw-spawned arrows compute this in start_draw.
	local arrow_local_offset = Compute_Arrow_Local_Offset(projectile_part, nock_rest_attachment)
	bow_follow_connections[player] = RunService.Heartbeat:Connect(function(dt)
		if not pivot_part.Parent then
			return
		end
		local draw_state = active_bow_draws[player]
		local fraction = 0
		if draw_state and draw_state.drawing then
			fraction = math.clamp((os.clock() - draw_state.draw_start_time) / bow_data.MaxDrawTime, 0, 1)
		end
		-- Hold the draw clip on its last frame while drawing (see FIRE_TRACK_HOLD_EPSILON).
		if draw_state and draw_state.drawing and draw_state.fire_track and not draw_state.fire_track_held then
			local track = draw_state.fire_track
			if track.Length > 0 and track.TimePosition >= track.Length - FIRE_TRACK_HOLD_EPSILON then
				track.TimePosition = track.Length - FIRE_TRACK_HOLD_EPSILON
				track:AdjustSpeed(0)
				draw_state.fire_track_held = true
			end
		end
		if bow_data.VisualStyle == "spin" then
			-- Sling wind-up: spin_angle grows each tick at a speed that ramps with the draw
			-- fraction and resets when drawing stops. Rotating the rest pose around the pivot
			-- makes the whole assembly orbit together.
			if draw_state then
				if draw_state.drawing then
					local angular_speed = Lerp_Number(bow_data.MinSpinSpeed or 0, bow_data.MaxSpinSpeed, fraction)
					draw_state.spin_angle = (draw_state.spin_angle or 0) + angular_speed * dt
				else
					draw_state.spin_angle = 0
				end
			end
			local spin_angle = (draw_state and draw_state.spin_angle) or 0
			local spin_rotation = CFrame.fromAxisAngle(bow_data.SpinAxis or Vector3.new(1, 0, 0), spin_angle)
			for name, part in pairs(tracked_parts) do
				local rest = rest_pose[name]
				if rest and part.Parent then
					part.CFrame = pivot_part.CFrame:ToWorldSpace(spin_rotation * rest.CFrame)
				end
			end
		elseif nock_rest_attachment then
			-- draw_point is shared by both strings and the arrow's nock: the nock Attachment
			-- at rest, sliding toward the drawing hand as the fraction rises.
			local draw_point = nock_rest_attachment.WorldPosition
			if draw_hand and draw_hand.Parent then
				draw_point = draw_point:Lerp(draw_hand.Position, fraction)
			end
			if string_tip_attachments then
				local up_hint = nock_rest_attachment.WorldCFrame.UpVector
				for tracked_name, tip_attachment in pairs(string_tip_attachments) do
					local part = tracked_parts[tracked_name]
					local rest_size = string_rest_info[tracked_name]
					if part and rest_size and part.Parent and tip_attachment.Parent then
						local new_cframe, length = Build_Beam_CFrame(tip_attachment.WorldPosition, draw_point, up_hint, rest_size)
						part.CFrame = new_cframe
						part.Size = Set_Long_Axis_Size(rest_size, length)
					end
				end
			end
			-- Read from draw_state each frame: a draw-spawned arrow is a new Instance each draw.
			local live_projectile_part = draw_state and draw_state.projectile_part
			local live_arrow_local_offset = draw_state and draw_state.arrow_local_offset
			if live_projectile_part and live_arrow_local_offset and live_projectile_part.Parent then
				-- Arrow keeps the nock Attachment's rotation and only slides back with the string.
				live_projectile_part.CFrame = CFrame.new(draw_point) * nock_rest_attachment.WorldCFrame.Rotation * CFrame.new(-live_arrow_local_offset)
			end
		end
	end)
	active_bow_draws[player] = {
		pivot_part = pivot_part,
		projectile_part = projectile_part,
		arrow_local_offset = arrow_local_offset,
		nock_rest_attachment = nock_rest_attachment,
		projectile_is_temporary = false, -- true only for an arrow spawned by start_draw
		bow_data = bow_data,
		drawing = false,
		spin_angle = 0,
	}
end
-- Flies a copy of the drawn projectile. Kinematic: anchored, moved a step each
-- Heartbeat with a raycast across the step so fast shots can't tunnel. Aims along
-- the player's facing plus a random accuracy cone (slings too).
local PROJECTILE_RAYCAST_PARAMS = RaycastParams.new()
PROJECTILE_RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
local function Fire_Projectile(player, character, root, bow_data, template_projectile_part, draw_fraction)
	local damage = Lerp_Number(bow_data.MinDamage, bow_data.MaxDamage, draw_fraction)
	local speed = Lerp_Number(bow_data.MinProjectileSpeed, bow_data.MaxProjectileSpeed, draw_fraction)
	local range = Lerp_Number(bow_data.MinRange, bow_data.MaxRange, draw_fraction)
	-- Lower draw = wider accuracy cone.
	local cone_angle = Lerp_Number(bow_data.MinConeAngle, bow_data.MaxConeAngle, draw_fraction)
	local half_cone_rad = math.rad(cone_angle / 2)
	local base_direction = root.CFrame.LookVector
	local spread_cframe = CFrame.Angles((math.random() - 0.5) * 2 * half_cone_rad, (math.random() - 0.5) * 2 * half_cone_rad, 0)
	local fire_direction = (CFrame.new(Vector3.new(), base_direction) * spread_cframe).LookVector
	local projectile = template_projectile_part:Clone()
	projectile.Anchored = true
	projectile.CanCollide = false
	projectile.CanTouch = false
	local start_position = root.Position + base_direction * 3
	projectile.CFrame = CFrame.new(start_position, start_position + fire_direction)
	projectile.Parent = workspace
	PROJECTILE_RAYCAST_PARAMS.FilterDescendantsInstances = {character}
	local traveled = 0
	local connection
	connection = RunService.Heartbeat:Connect(function(dt)
		if not projectile.Parent then
			connection:Disconnect()
			return
		end
		local step_distance = speed * dt
		local from_position = projectile.Position
		local to_position = from_position + fire_direction * step_distance
		local hit_result = workspace:Raycast(from_position, to_position - from_position, PROJECTILE_RAYCAST_PARAMS)
		traveled = traveled + step_distance
		if hit_result then
			connection:Disconnect()
			projectile.CFrame = CFrame.new(hit_result.Position, hit_result.Position + fire_direction)
			local hit_model = hit_result.Instance:FindFirstAncestorOfClass("Model")
			local hit_player = hit_model and game.Players:GetPlayerFromCharacter(hit_model)
			-- Only players and CombatTarget-tagged NPCs take damage.
			if hit_model and (hit_player or CollectionService:HasTag(hit_model, COMBAT_TARGET_TAG)) then
				local hit_humanoid = hit_model:FindFirstChild("Humanoid")
				-- Humanoid health for players/zombies, "Health" attribute for Humanoid-less wildlife.
				local hit_health = hit_humanoid and hit_humanoid.Health or hit_model:GetAttribute("Health")
				if hit_health and hit_health > 0 and not PlayerCombat.is_invulnerable(hit_player) then
					if hit_humanoid then
						hit_humanoid:TakeDamage(damage)
					else
						hit_model:SetAttribute("Health", math.max(0, hit_health - damage))
					end
					projectile:Destroy()
					return
				end
			end
			-- Hit scenery or an invulnerable target: leave the projectile stuck there.
			return
		end
		projectile.CFrame = CFrame.new(to_position, to_position + fire_direction)
		if traveled >= range then
			connection:Disconnect()
			projectile:Destroy()
		end
	end)
end
-- Per-weapon draw/fire tuning, keyed by WeaponModel (ItemData describes the item,
-- this describes how it plays). The Tier 3 compound bow has no entry yet
-- (no separate strings modeled).
local BOW_DATA = {
	["Empty Bow"] = {
		VisualStyle = "stretch", -- default, named explicitly for symmetry with the Sling entry below
		-- Used only as the source to clone an arrow from at draw time. Never shown.
		DrawReferenceModel = "Drawn Bow",
		BowPart = "Bow",
		TrackedParts = {"Lowerstring", "Upperstring"},
		ProjectilePart = "Arrow",
		-- Studio requirement: Attachments under "Bow" -- UpperStringTip and LowerStringTip
		-- at the limb tips, StringRestNock where the string/arrow rest undrawn.
		StringTipAttachment = {["Lowerstring"] = "LowerStringTip", ["Upperstring"] = "UpperStringTip"},
		NockRestAttachment = "StringRestNock",
		MaxDrawTime = 1.2, -- seconds held to reach a full (100%) draw. Placeholder, tune once tested.
		-- Min* = instant release, Max* = full MaxDrawTime hold. Placeholders.
		MinDamage = 10,
		MaxDamage = 35,
		MinRange = 60,
		MaxRange = 300,
		MinProjectileSpeed = 60,
		MaxProjectileSpeed = 150,
		MinConeAngle = 12, -- degrees -- wider/less accurate at a low draw
		MaxConeAngle = 2,
		AttackStaminaCost = 15, -- spent once, when the draw starts
	},
	-- "spin" style: no BowPart (hand is the pivot), no DrawReferenceModel.
	["Sling"] = {
		VisualStyle = "spin",
		TrackedParts = {"Sling Pouch", "Uppersling String", "Lowersling String"},
		ProjectilePart = "Stone",
		-- Local hand axis the sling spins around while winding up. Cosmetic only.
		SpinAxis = Vector3.new(1, 0, 0),
		MaxDrawTime = 1.0, -- seconds held to reach max wind-up. Placeholder, tune once tested.
		MinSpinSpeed = 2, -- radians/sec, lazy initial swing
		MaxSpinSpeed = 25, -- radians/sec, full windup
		-- Placeholders: quicker, shorter-ranged and weaker than the bow.
		MinDamage = 6,
		MaxDamage = 22,
		MinRange = 50,
		MaxRange = 220,
		MinProjectileSpeed = 50,
		MaxProjectileSpeed = 110,
		MinConeAngle = 16,
		MaxConeAngle = 4,
		AttackStaminaCost = 10,
	},
}
-- Hold to charge, release to fire: start_draw on button-down, release_draw on
-- button-up (wired through DrawStartRequest/DrawReleaseRequest in RequestChecker).
function PlayerCombat.start_draw(player)
	local weapon_data = Get_Equipped_Weapon_Data(player)
	local bow_data = BOW_DATA[weapon_data.WeaponModel]
	if not bow_data then
		return false, "not holding a ranged weapon"
	end
	local draw_state = active_bow_draws[player]
	if not draw_state then
		return false, "ranged weapon not set up" -- Setup_Bow hasn't run yet or failed -- see refresh_weapon_animations
	end
	if draw_state.drawing then
		return false, "already drawing"
	end
	if not PlayerStamina.spend(player, bow_data.AttackStaminaCost) then
		return false, "not enough stamina"
	end
	-- No arrow on the bow yet: spawn one for this draw and mark it temporary so
	-- release_draw removes it.
	if not draw_state.projectile_part then
		local character = player.Character
		local bow_model = character and Find_Equipped_Weapon_Model(character, weapon_data.WeaponModel)
		if bow_model then
			local spawned_arrow = Spawn_Draw_Arrow(bow_model, draw_state.pivot_part, bow_data)
			if spawned_arrow then
				draw_state.projectile_part = spawned_arrow
				draw_state.arrow_local_offset = Compute_Arrow_Local_Offset(spawned_arrow, draw_state.nock_rest_attachment)
				draw_state.projectile_is_temporary = true
			end
		end
	end
	draw_state.drawing = true
	draw_state.draw_start_time = os.clock()
	draw_state.spin_angle = 0 -- sling only
	-- Start the draw clip on button-down.
	local character = player.Character
	if character then
		local fire_track = Get_Fire_Track(player, character, weapon_data.WeaponModel)
		if fire_track then
			fire_track:Play()
			-- Read by the hold-last-frame logic in Setup_Bow; cleared in release_draw.
			draw_state.fire_track = fire_track
			draw_state.fire_track_held = false
		end
	end
	return true
end
function PlayerCombat.release_draw(player)
	local draw_state = active_bow_draws[player]
	if not draw_state or not draw_state.drawing then
		return false, "not drawing"
	end
	draw_state.drawing = false
	local bow_data = draw_state.bow_data
	local fraction = math.clamp((os.clock() - draw_state.draw_start_time) / bow_data.MaxDrawTime, 0, 1)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and draw_state.projectile_part then
		Fire_Projectile(player, character, root, bow_data, draw_state.projectile_part, fraction)
	end
	-- The fired shot is a separate clone, so remove the temporary nocked arrow now.
	if draw_state.projectile_is_temporary and draw_state.projectile_part then
		draw_state.projectile_part:Destroy()
		draw_state.projectile_part = nil
		draw_state.arrow_local_offset = nil
		draw_state.projectile_is_temporary = false
	end
	-- Unfreeze the draw clip (it may be held on its last frame) and let it finish.
	if draw_state.fire_track then
		draw_state.fire_track:AdjustSpeed(1)
		draw_state.fire_track = nil
		draw_state.fire_track_held = nil
	end
	return true, fraction
end
-- Default walk/run tracks blend continuously over a speed range, so instead of
-- picking one, this takes a weight-averaged circular mean of every playing
-- movement track's phase (circular so 0.95 and 0.05 average near 0, not 0.5).
-- The walk or run multiplier is chosen from PlayerSprint, since Roblox's blend
-- weights don't follow our weight-tier walk speeds. Roblox tags these tracks
-- Core on some builds and Movement on others, so match both.
local MOVEMENT_TRACK_PRIORITIES = {
	[Enum.AnimationPriority.Movement] = true,
	[Enum.AnimationPriority.Core] = true,
}
local function Get_Blended_Movement_Phase(player, humanoid, walk_phase_multiplier, run_phase_multiplier)
	local raw_tracks = humanoid:GetPlayingAnimationTracks()
	local active_tracks = {}
	for _, track in ipairs(raw_tracks) do
		if MOVEMENT_TRACK_PRIORITIES[track.Priority] and track.Length > 0 and track.WeightCurrent > 0 then
			table.insert(active_tracks, track)
		end
	end
	if #active_tracks == 0 then
		return nil
	end
	local is_sprinting = PlayerSprint.is_sprinting(player)
	local multiplier = (is_sprinting and (run_phase_multiplier or 1)) or (walk_phase_multiplier or 1)
	local sum_x, sum_y, total_weight = 0, 0, 0
	for _, track in ipairs(active_tracks) do
		local raw_phase = (track.TimePosition % track.Length) / track.Length
		local phase = (raw_phase * multiplier) % 1
		local angle = phase * 2 * math.pi
		sum_x = sum_x + math.cos(angle) * track.WeightCurrent
		sum_y = sum_y + math.sin(angle) * track.WeightCurrent
		total_weight = total_weight + track.WeightCurrent
	end
	if total_weight <= 0 then
		return nil
	end
	local blended_angle = math.atan2(sum_y, sum_x)
	if blended_angle < 0 then
		blended_angle = blended_angle + 2 * math.pi
	end
	local result_phase = blended_angle / (2 * math.pi)
	return result_phase
end
-- Drives the frozen Move track every frame: sets its TimePosition to the legs'
-- blended phase (as a 0..1 fraction, so clip lengths can differ). Only runs while
-- Move is the active hold pose.
local function Start_Move_Sync(player, humanoid, tracks, walk_phase_multiplier, run_phase_multiplier)
	if move_sync_connections[player] then
		move_sync_connections[player]:Disconnect()
		move_sync_connections[player] = nil
	end
	if not tracks.Move then
		return
	end
	move_sync_connections[player] = RunService.Heartbeat:Connect(function()
		if active_hold_track[player] ~= tracks.Move or not humanoid.Parent then
			return
		end
		-- Play() resets Speed to 1, undoing the freeze from Get_Hold_Tracks; re-freeze
		-- every tick so the track can't advance on its own clock.
		if tracks.Move.Speed ~= 0 then
			tracks.Move:AdjustSpeed(0)
		end
		local phase = Get_Blended_Movement_Phase(player, humanoid, walk_phase_multiplier, run_phase_multiplier)
		if phase and tracks.Move.Length > 0 then
			tracks.Move.TimePosition = phase * tracks.Move.Length
		end
	end)
end
-- Idle/Move/Block are mutually exclusive; switching crossfades from the old one.
local function Set_Active_Hold_Track(player, track)
	local current = active_hold_track[player]
	if current == track then
		return
	end
	if current then
		current:Stop(HOLD_POSE_FADE_TIME)
	end
	if track then
		track:Play(HOLD_POSE_FADE_TIME)
	end
	active_hold_track[player] = track
end
-- Call whenever the Weapon slot changes (equip, unequip, eaten, dropped) to
-- re-wire hold poses and bow visuals for whatever is now in hand.
function PlayerCombat.refresh_weapon_animations(player)
	local character = player.Character
	if not character then
		return
	end
	if hold_pose_connections[player] then
		hold_pose_connections[player]:Disconnect()
		hold_pose_connections[player] = nil
	end
	if move_sync_connections[player] then
		move_sync_connections[player]:Disconnect()
		move_sync_connections[player] = nil
	end
	local weapon_data = Get_Equipped_Weapon_Data(player)
	-- Bows have no hold-pose entry, so set them up before the early return below.
	local bow_data = BOW_DATA[weapon_data.WeaponModel]
	if bow_data then
		Setup_Bow(player, character, weapon_data.WeaponModel, bow_data)
	else
		Teardown_Bow(player)
	end
	local tracks = Get_Hold_Tracks(player, character, weapon_data.WeaponModel)
	if not tracks then
		Set_Active_Hold_Track(player, nil)
		return
	end
	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid then
		return
	end
	if PlayerCombat.is_blocking(player) then
		Set_Active_Hold_Track(player, tracks.Block)
	else
		Set_Active_Hold_Track(player, humanoid.MoveDirection.Magnitude > 0.1 and tracks.Move or tracks.Idle)
	end
	-- Switches Idle vs Move only; Start_Move_Sync keeps Move in time with the legs.
	hold_pose_connections[player] = humanoid.Running:Connect(function(speed)
		if PlayerCombat.is_blocking(player) then
			return -- block owns the pose while it's held; don't let walk/run churn interrupt it
		end
		Set_Active_Hold_Track(player, speed > 0.5 and tracks.Move or tracks.Idle)
	end)
	local pose_ids = WEAPON_HOLD_POSE_ANIMATIONS[weapon_data.WeaponModel]
	local walk_phase_multiplier = pose_ids and pose_ids.MoveWalkPhaseMultiplier
	local run_phase_multiplier = pose_ids and pose_ids.MoveRunPhaseMultiplier
	Start_Move_Sync(player, humanoid, tracks, walk_phase_multiplier, run_phase_multiplier)
end
function PlayerCombat.is_invulnerable(player)
	if PlayerCombat.dev_invulnerable[player] then
		return true
	end
	local until_time = PlayerCombat.invulnerable_until[player]
	return until_time ~= nil and os.clock() < until_time
end
function PlayerCombat.set_dev_invulnerable(player, enabled)
	PlayerCombat.dev_invulnerable[player] = enabled or nil
end
function PlayerCombat.is_blocking(player)
	return PlayerCombat.blocking_players[player] == true
end
-- Every valid target: other players plus CombatTarget-tagged NPCs.
local function Get_Combat_Targets(attacking_player)
	local targets = {}
	for _, other_player in ipairs(game.Players:GetPlayers()) do
		if other_player ~= attacking_player and other_player.Character then
			table.insert(targets, {player = other_player, character = other_player.Character})
		end
	end
	for _, tagged_model in ipairs(CollectionService:GetTagged(COMBAT_TARGET_TAG)) do
		if tagged_model:IsA("Model") then
			table.insert(targets, {player = nil, character = tagged_model})
		end
	end
	return targets
end
function PlayerCombat.attack(player)
	local weapon_data = Get_Equipped_Weapon_Data(player)
	-- Ranged weapons fire through start_draw/release_draw and have no melee stats.
	if BOW_DATA[weapon_data.WeaponModel] then
		return false, "ranged weapon -- hold to draw, release to fire, not a regular attack"
	end
	local now = os.clock()
	local last_time = last_attack_time[player] or 0
	local swing_speed_fraction = math.max(MIN_SWING_COOLDOWN_FRACTION, 1 - (PlayerStats.get(player, "Dexterity") - 1) * DEXTERITY_SWING_SPEED_PER_POINT)
	local effective_cooldown = weapon_data.AttackCooldown * swing_speed_fraction
	if now - last_time < effective_cooldown then
		return false, "attack on cooldown"
	end
	local attack_cost_fraction = math.max(MIN_ATTACK_COST_FRACTION, 1 - (PlayerStats.get(player, "Endurance") - 1) * ENDURANCE_ATTACK_COST_REDUCTION_PER_POINT)
	if not PlayerStamina.spend(player, weapon_data.AttackStaminaCost * attack_cost_fraction) then
		return false, "not enough stamina"
	end
	last_attack_time[player] = now
	-- Uses the attacker's Strength at swing start.
	local strength_damage_multiplier = 1 + (PlayerStats.get(player, "Strength") - 1) * STRENGTH_DAMAGE_PER_POINT
	local strength_knockback_multiplier = 1 + (PlayerStats.get(player, "Strength") - 1) * STRENGTH_KNOCKBACK_DEALT_PER_POINT
	-- Attacking speeds up hunger.
	PlayerHunger.pulse(player)
	local character = player.Character
	if not character then
		return false, "no character"
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false, "no root part"
	end
	-- Play the swing animation now that stamina/cooldown checks passed.
	local equipped_weapon_model = weapon_data.WeaponModel
	if equipped_weapon_model then
		local track = Get_Swing_Track(player, character, equipped_weapon_model)
		if track then
			track:Play()
			-- Swing length lets the client telegraph last as long as the animation.
			swing_telegraph_event:FireClient(player, track.Length)
		end
	end
	-- Hit-check after the windup, using the attacker's facing at that moment.
	task.delay(ATTACK_WINDUP_DELAY, function()
		local current_character = player.Character
		if current_character ~= character then
			return
		end
		if not root or not root.Parent then
			return
		end
		local attacker_pos = root.Position
		local attacker_forward = root.CFrame.LookVector
		local half_cone_rad = math.rad(weapon_data.ConeAngle / 2)
		for _, target in ipairs(Get_Combat_Targets(player)) do
			local target_root = target.character:FindFirstChild("HumanoidRootPart")
			local target_humanoid = target.character:FindFirstChild("Humanoid")
			-- Players/zombies use Humanoid health; wildlife has no Humanoid and uses a
			-- "Health" attribute (shared with WildLifeManager's health bar and death).
			local target_health = target_humanoid and target_humanoid.Health or target.character:GetAttribute("Health")
			if target_root and target_health and target_health > 0 then
				local to_target = target_root.Position - attacker_pos
				local distance = to_target.Magnitude
				if distance <= weapon_data.Range then
					local direction = to_target.Unit
					local angle = math.acos(math.clamp(attacker_forward:Dot(direction), -1, 1))
					if angle <= half_cone_rad and not PlayerCombat.is_invulnerable(target.player) then
						local damage = weapon_data.Damage * strength_damage_multiplier
						if PlayerCombat.is_blocking(target.player) then
							damage = damage * (1 - BLOCK_DAMAGE_REDUCTION)
						end
						local knockback_force = BASE_KNOCKBACK_FORCE * strength_knockback_multiplier
						if target.player then
							local defense = PlayerEquipment.get_total_defense(target.player)
							local defense_reduction = math.min(defense * DEFENSE_REDUCTION_PER_POINT, MAX_DEFENSE_REDUCTION)
							damage = damage * (1 - defense_reduction)
							local target_endurance = PlayerStats.get(target.player, "Endurance")
							local resist_reduction = math.min((target_endurance - 1) * ENDURANCE_KNOCKBACK_RESIST_PER_POINT, MAX_KNOCKBACK_RESIST_REDUCTION)
							knockback_force = knockback_force * (1 - resist_reduction)
						end
						if target_humanoid then
							target_humanoid:TakeDamage(damage)
						else
							target.character:SetAttribute("Health", math.max(0, target_health - damage))
						end
						-- One-off horizontal impulse; vertical velocity is preserved.
						local current_velocity = target_root.AssemblyLinearVelocity
						target_root.AssemblyLinearVelocity = Vector3.new(direction.X * knockback_force, current_velocity.Y, direction.Z * knockback_force)
					end
				end
			end
		end
	end)
	return true, "attack started"
end
function PlayerCombat.start_block(player)
	PlayerCombat.blocking_players[player] = true
	PlayerHunger.set_active(player, "Block", true) -- blocking speeds up hunger
	local character = player.Character
	if character then
		local weapon_data = Get_Equipped_Weapon_Data(player)
		local tracks = Get_Hold_Tracks(player, character, weapon_data.WeaponModel)
		if tracks and tracks.Block then
			local block_track = tracks.Block
			Set_Active_Hold_Track(player, block_track)
			block_track:AdjustSpeed(1) -- undo a previous block's speed=0 freeze, if this track was reused
			-- A finished non-looping track releases the pose, so re-pin the last frame.
			-- Stopped also fires on a manual Stop(), hence the still-blocking guard.
			local connection
			connection = block_track.Stopped:Connect(function()
				connection:Disconnect()
				if PlayerCombat.is_blocking(player) and active_hold_track[player] == block_track then
					block_track:Play(0)
					block_track.TimePosition = block_track.Length
					block_track:AdjustSpeed(0)
				end
			end)
		end
	end
end
function PlayerCombat.stop_block(player)
	PlayerCombat.blocking_players[player] = nil
	PlayerHunger.set_active(player, "Block", false)
	local character = player.Character
	if character then
		local weapon_data = Get_Equipped_Weapon_Data(player)
		local tracks = Get_Hold_Tracks(player, character, weapon_data.WeaponModel)
		if tracks then
			local humanoid = character:FindFirstChild("Humanoid")
			local is_moving = humanoid and humanoid.MoveDirection.Magnitude > 0.1
			Set_Active_Hold_Track(player, is_moving and tracks.Move or tracks.Idle)
		end
	end
end
function PlayerCombat.block_tick(player, dt)
	if not PlayerCombat.is_blocking(player) then
		return
	end
	local ok = PlayerStamina.drain_tick(player, BLOCK_STAMINA_DRAIN_PER_SECOND, dt)
	if not ok then
		PlayerCombat.stop_block(player)
	end
end
function PlayerCombat.dodge(player)
	if PlayerCombat.is_blocking(player) then
		return false, "cannot dodge while blocking"
	end
	local effects = PlayerWeight.get_tier_effects(player)
	local dodge_cost = DODGE_STAMINA_COST * effects.DodgeCostMultiplier
	if not PlayerStamina.spend(player, dodge_cost) then
		return false, "not enough stamina"
	end
	PlayerCombat.invulnerable_until[player] = os.clock() + DODGE_INVULN_DURATION
	PlayerHunger.pulse(player) -- dodging speeds up hunger
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChild("Humanoid")
	if root and humanoid then
		-- Dash the way the player is moving, or backward if standing still.
		local move_direction = humanoid.MoveDirection
		local dash_direction
		if move_direction.Magnitude > 0.1 then
			dash_direction = move_direction.Unit
		else
			dash_direction = -root.CFrame.LookVector
		end
		local dash_distance = BASE_DASH_DISTANCE * effects.DodgeDistanceMultiplier
		local dash_speed = dash_distance / DASH_DURATION
		if active_dash_connections[player] then
			active_dash_connections[player]:Disconnect()
			active_dash_connections[player] = nil
		end
		-- Re-assert velocity every Heartbeat (a one-time set is overridden by the
		-- Humanoid). Only X/Z; Y is preserved.
		local dash_end_time = os.clock() + DASH_DURATION
		local connection
		connection = RunService.Heartbeat:Connect(function()
			if os.clock() >= dash_end_time or not root.Parent then
				connection:Disconnect()
				active_dash_connections[player] = nil
				return
			end
			local current_velocity = root.AssemblyLinearVelocity
			root.AssemblyLinearVelocity = Vector3.new(dash_direction.X * dash_speed, current_velocity.Y, dash_direction.Z * dash_speed)
		end)
		active_dash_connections[player] = connection
	end
	return true
end
function PlayerCombat.remove_player(player)
	PlayerCombat.blocking_players[player] = nil
	PlayerCombat.invulnerable_until[player] = nil
	PlayerCombat.dev_invulnerable[player] = nil
	last_attack_time[player] = nil
	loaded_swing_tracks[player] = nil
	loaded_fire_tracks[player] = nil
	loaded_hold_tracks[player] = nil
	active_hold_track[player] = nil
	if hold_pose_connections[player] then
		hold_pose_connections[player]:Disconnect()
		hold_pose_connections[player] = nil
	end
	if move_sync_connections[player] then
		move_sync_connections[player]:Disconnect()
		move_sync_connections[player] = nil
	end
	if active_dash_connections[player] then
		active_dash_connections[player]:Disconnect()
		active_dash_connections[player] = nil
	end
	Teardown_Bow(player)
end
return PlayerCombat
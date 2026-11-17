local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local CollectionService = game:GetService("CollectionService")
local arena_manager = ServerScriptService:WaitForChild("ArenaManager")
local PlayerInventory = require(ServerScriptService:WaitForChild("PlayerInventory"))
local PlayerCombat = require(ServerScriptService:WaitForChild("PlayerCombat"))
local PlayerInfection = require(arena_manager:WaitForChild("PlayerInfection"))
local MatchFreeze = require(ServerScriptService:WaitForChild("MatchFreeze"))
local last_pause_debug = 0 -- [FreezeDebug] throttle, temporary
local inventory_updated = ReplicatedStorage:WaitForChild("InventoryUpdated")
local WildlifeManager = {}
local COMBAT_TARGET_TAG = "CombatTarget"
local PATH_REFRESH_INTERVAL = 2
local WAYPOINT_REACHED_DISTANCE = 3
local ANGER_LINGER_DURATION = 30 -- seconds a conditional-threat stays aggressive after losing aggro range
-- Every live animal, keyed by its entry table, so events like Animal Frenzy can
-- reach them all.
local active_animals = {}
-- Combat stats for species that normally never fight (Deer/Rat), so Animal
-- Frenzy can make every animal hostile. Placeholders.
local FRENZY_FALLBACK_COMBAT_STATS = {Damage = 8, AttackRange = 4, AttackCooldown = 1.5}
-- How far away from the player a fleeing animal paths to.
local FLEE_DESTINATION_DISTANCE = 40
-- Idle wandering when no player is in range (see Wander_Tick). Placeholders.
local WANDER_MIN_IDLE_TIME = 3 -- seconds standing still before picking a new wander spot
local WANDER_MAX_IDLE_TIME = 8
local WANDER_MIN_DISTANCE = 4 -- studs -- "a random SMALL amount"
local WANDER_MAX_DISTANCE = 12
local WANDER_SPEED_MULTIPLIER = 0.4 -- fraction of WalkSpeed used while wandering
-- Per-species Idle/Move/Attack clips. A species left at rbxassetid://0 simply
-- plays no animation for that slot (Move needs both Idle and Move set).
-- Only species in WILDLIFE_STATS can spawn; add both entries together.
local WILDLIFE_ANIMATIONS = {
	Bear = {Idle = "rbxassetid://80022095367839", Move = "rbxassetid://122910290685658", Attack = "rbxassetid://102672275576039"},
	Wolf = {Idle = "rbxassetid://72589098604736", Move = "rbxassetid://80209714329135", Attack = "rbxassetid://122533141737561"},
	Deer = {Idle = "rbxassetid://121184421507913", Move = "rbxassetid://78625918323996", Attack = "rbxassetid://119461979815977"},
	Rat = {Idle = "rbxassetid://136936821701378", Move = "rbxassetid://93828977601368", Attack = "rbxassetid://133568114553201"},
}
local MOVEMENT_FADE_TIME = 0.2 -- seconds, Idle/Move crossfade. Placeholder.
local MOVING_THRESHOLD = 0.5 -- studs/sec, Move vs Idle
-- IsThreat: always aggressive.
-- IsConditionalThreat: flees, turns aggressive when damaged, calms down after
-- ANGER_LINGER_DURATION with no player in AggroRange (no species uses it yet).
-- Neither flag: always flees. Placeholder numbers.
local WILDLIFE_STATS = {
	Bear = {IsThreat = true, Health = 150, WalkSpeed = 14, Damage = 20, AttackRange = 6, AttackCooldown = 1.5, AggroRange = 50, HarvestItem = "Raw Meat"},
	Wolf = {IsThreat = true, Health = 60, WalkSpeed = 20, Damage = 12, AttackRange = 5, AttackCooldown = 1, AggroRange = 60, HarvestItem = "Raw Meat"},
	Deer = {Health = 40, WalkSpeed = 12, FleeRange = 30, HarvestItem = "Raw Meat"},
	Rat = {Health = 10, WalkSpeed = 10, FleeRange = 15, HarvestItem = "Raw Meat"},
}
local function Get_Model_Template(species_name)
	return ServerStorage:WaitForChild("Wildlife"):WaitForChild(species_name)
end
-- Each animal gets its own copy so Frenzy can change one animal's stats.
local function Copy_Stats(base)
	local copy = {}
	for key, value in pairs(base) do
		copy[key] = value
	end
	return copy
end
-- Fisher-Yates, used to pick a random handful of animals to infect without
-- picking the same one twice.
local function Shuffled_Copy(list)
	local copy = {}
	for index, value in ipairs(list) do
		copy[index] = value
	end
	for index = #copy, 2, -1 do
		local swap_index = math.random(index)
		copy[index], copy[swap_index] = copy[swap_index], copy[index]
	end
	return copy
end
-- Animals have no Humanoid: health lives in "Health"/"MaxHealth" attributes
-- (PlayerCombat writes the same attribute). Infected animals look identical
-- to normal ones on purpose.
local function Setup_Health_Bar(model)
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "WildlifeHealthBar"
	billboard.Size = UDim2.new(3, 0, 0.4, 0)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.MaxDistance = 60
	billboard.AlwaysOnTop = true
	billboard.Enabled = false -- hidden until first damaged
	billboard.Parent = root
	local background = Instance.new("Frame")
	background.Name = "Background"
	background.Size = UDim2.new(1, 0, 1, 0)
	background.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	background.BorderSizePixel = 0
	background.Parent = billboard
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
	fill.BorderSizePixel = 0
	fill.Parent = background
	local function Update_Bar()
		local max_health = model:GetAttribute("MaxHealth") or 0
		local health = model:GetAttribute("Health") or 0
		local ratio = max_health > 0 and math.clamp(health / max_health, 0, 1) or 0
		fill.Size = UDim2.new(ratio, 0, 1, 0)
		if health < max_health and health > 0 then
			billboard.Enabled = true
		elseif health <= 0 then
			billboard.Enabled = false
		end
	end
	model:GetAttributeChangedSignal("Health"):Connect(Update_Bar)
	Update_Bar()
end
-- Runs once when Health reaches 0 (entry.dead guards against double hits):
-- adds the harvest prompt.
local function Handle_Death(entry)
	if entry.dead then
		return
	end
	entry.dead = true
	active_animals[entry] = nil
	task.wait(0.5)
	local model = entry.model
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Harvest"
	prompt.ObjectText = model.Name
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 1
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = root
	local harvested = false
	prompt.Triggered:Connect(function(player)
		if harvested then
			return
		end
		harvested = true
		prompt.Enabled = false
		local inventory = PlayerInventory.add_item(player, entry.stats.HarvestItem, 1)
		inventory_updated:FireClient(player, inventory)
		task.wait(0.3)
		model:Destroy()
	end)
end
-- Animals animate through an AnimationController. Warns and returns nil if
-- missing, which just means no animation.
local function Get_Animation_Owner(model)
	local controller = model:FindFirstChildOfClass("AnimationController")
	if not controller then
		warn("[WildLifeManager] " .. model:GetFullName() .. " has no AnimationController -- can't load any animation for it")
	end
	return controller
end
-- Loads this species' Idle/Move tracks. Nil if unset or a load fails (the
-- animal then moves without animation).
local function Load_Movement_Tracks(model, species_name)
	local anim_ids = WILDLIFE_ANIMATIONS[species_name]
	if not anim_ids or anim_ids.Idle == "rbxassetid://0" or anim_ids.Move == "rbxassetid://0" then
		return nil
	end
	local owner = Get_Animation_Owner(model)
	if not owner then
		return nil
	end
	local function Load(anim_id)
		local animation = Instance.new("Animation")
		animation.AnimationId = anim_id
		local ok, track_or_err = pcall(function()
			return owner:LoadAnimation(animation)
		end)
		if not ok then
			warn("[WildLifeManager] failed to load movement animation for", species_name, ":", tostring(track_or_err))
			return nil
		end
		track_or_err.Looped = true
		return track_or_err
	end
	local idle_track = Load(anim_ids.Idle)
	local move_track = Load(anim_ids.Move)
	if not idle_track or not move_track then
		return nil
	end
	return {Idle = idle_track, Move = move_track}
end
-- Loaded independently of Idle/Move. Not looped; Action priority so it plays
-- over the movement loop.
local function Load_Attack_Track(model, species_name)
	local anim_ids = WILDLIFE_ANIMATIONS[species_name]
	if not anim_ids or anim_ids.Attack == "rbxassetid://0" then
		return nil
	end
	local owner = Get_Animation_Owner(model)
	if not owner then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = anim_ids.Attack
	local ok, track_or_err = pcall(function()
		return owner:LoadAnimation(animation)
	end)
	if not ok then
		warn("[WildLifeManager] failed to load attack animation for", species_name, ":", tostring(track_or_err))
		return nil
	end
	track_or_err.Looped = false
	track_or_err.Priority = Enum.AnimationPriority.Action
	return track_or_err
end
-- Idle/Move are mutually exclusive, same crossfade-swap shape as
-- PlayerCombat's Set_Active_Hold_Track.
local function Set_Active_Movement_Track(entry, track)
	if entry.active_movement_track == track then
		return
	end
	if entry.active_movement_track then
		entry.active_movement_track:Stop(MOVEMENT_FADE_TIME)
	end
	if track then
		track:Play(MOVEMENT_FADE_TIME)
	end
	entry.active_movement_track = track
end
-- Without a Humanoid, these two drive movement: horizontal velocity (Y left to
-- physics) and facing. The root stays unanchored so gravity and collisions work.
-- The animal meshes' visible front is rotated relative to the root's -Z axis;
-- MOVEMENT_FACING_OFFSET corrects for that. No step-climb help, so very rough
-- terrain may snag animals.
local MOVEMENT_FACING_OFFSET = math.rad(-90)
-- Keeps animals upright (they used to tip over while idle). A rigid
-- AlignOrientation on the root holds the current yaw at all times; it's
-- parented to the root so it's cleaned up with it.
local UPRIGHT_ATTACHMENT_NAME = "UprightAttachment"
local UPRIGHT_STABILIZER_NAME = "UprightStabilizer"
local function Setup_Upright_Stabilizer(root)
	local attachment = Instance.new("Attachment")
	attachment.Name = UPRIGHT_ATTACHMENT_NAME
	attachment.Parent = root
	local stabilizer = Instance.new("AlignOrientation")
	stabilizer.Name = UPRIGHT_STABILIZER_NAME
	stabilizer.Mode = Enum.OrientationAlignmentMode.OneAttachment
	stabilizer.Attachment0 = attachment
	stabilizer.RigidityEnabled = true
	stabilizer.CFrame = root.CFrame -- initial target: whatever it spawned facing
	stabilizer.Parent = root
	return stabilizer
end
local function Get_Upright_Stabilizer(root)
	return root:FindFirstChild(UPRIGHT_STABILIZER_NAME)
end
local function Move_Animal(root, direction, speed)
	if direction.Magnitude <= 0.1 then
		return
	end
	local unit_direction = direction.Unit
	local current_velocity = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(unit_direction.X * speed, current_velocity.Y, unit_direction.Z * speed)
	local facing_cframe = CFrame.new(root.Position, root.Position + Vector3.new(unit_direction.X, 0, unit_direction.Z)) * CFrame.Angles(0, MOVEMENT_FACING_OFFSET, 0)
	root.CFrame = facing_cframe
	-- Keep the stabilizer's target matching the facing just set, or they'd fight.
	local stabilizer = Get_Upright_Stabilizer(root)
	if stabilizer then
		stabilizer.CFrame = facing_cframe
	end
end
local function Stop_Animal(root)
	local current_velocity = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(0, current_velocity.Y, 0)
end
-- Plays the Idle track the moment an animal spawns, before its first AI
-- tick has run, so it doesn't sit in bind pose for the first 0.1s.
local function Start_Movement_Animation(entry)
	local tracks = entry.movement_tracks
	if not tracks then
		return
	end
	Set_Active_Movement_Track(entry, tracks.Idle)
end
-- Called every AI tick with speed measured from real displacement since the last
-- tick (not the commanded velocity), so an animal blocked by a collision shows
-- its idle animation instead of walking in place.
local function Update_Movement_Animation(entry, speed)
	local tracks = entry.movement_tracks
	if not tracks then
		return
	end
	Set_Active_Movement_Track(entry, speed > MOVING_THRESHOLD and tracks.Move or tracks.Idle)
	local reference_speed = entry.stats.WalkSpeed
	if reference_speed > 0 then
		tracks.Move:AdjustSpeed(speed / reference_speed)
	end
end
-- Flee from the nearest player within FleeRange by pathfinding to a point
-- FLEE_DESTINATION_DISTANCE away. Uses its own flee_* waypoint cache so
-- switching between fleeing and chasing never reuses the other's path.
local function Flee_Tick(root, stats, ai_state)
	local closest_distance, closest_root = math.huge, nil
	for _, player in ipairs(game.Players:GetPlayers()) do
		local character = player.Character
		local target_root = character and character:FindFirstChild("HumanoidRootPart")
		if target_root then
			local distance = (target_root.Position - root.Position).Magnitude
			if distance < closest_distance then
				closest_distance = distance
				closest_root = target_root
			end
		end
	end
	if not closest_root or closest_distance > stats.FleeRange then
		ai_state.flee_waypoints = nil
		-- Not fleeing; Flee_Or_Wander handles idle wandering.
		return false
	end
	local away_direction = root.Position - closest_root.Position
	away_direction = Vector3.new(away_direction.X, 0, away_direction.Z)
	if away_direction.Magnitude < 0.1 then
		-- Standing on top of the player: pick any direction (avoids .Unit of ~0).
		away_direction = Vector3.new(1, 0, 0)
	end
	local flee_target = root.Position + away_direction.Unit * FLEE_DESTINATION_DISTANCE
	local now = os.clock()
	-- The destination depends on the player's position, so the player moving
	-- is what makes the path stale.
	local target_moved = ai_state.flee_path_target and (closest_root.Position - ai_state.flee_path_target).Magnitude > 5
	local needs_new_path = (not ai_state.flee_waypoints) or target_moved or (now - ai_state.flee_path_time >= PATH_REFRESH_INTERVAL)
	-- ComputeAsync can take tens of seconds near dense trees, so run it in the
	-- background and keep following the old path (or the fallback) meanwhile.
	if needs_new_path and not ai_state.computing_flee_path then
		ai_state.computing_flee_path = true
		ai_state.flee_path_time = now
		local request_origin = root.Position
		local request_target = flee_target
		local request_player_position = closest_root.Position
		task.spawn(function()
			local path = PathfindingService:CreatePath({
				AgentRadius = 2,
				AgentHeight = 5,
				AgentCanJump = false,
			})
			local success = pcall(function()
				path:ComputeAsync(request_origin, request_target)
			end)
			if success and path.Status == Enum.PathStatus.Success then
				ai_state.flee_waypoints = path:GetWaypoints()
				ai_state.flee_waypoint_index = 2
				ai_state.flee_path_target = request_player_position
			end
			-- On failure, keep following the last good path.
			ai_state.computing_flee_path = false
		end)
	end
	if ai_state.flee_waypoints and ai_state.flee_waypoints[ai_state.flee_waypoint_index] then
		local waypoint = ai_state.flee_waypoints[ai_state.flee_waypoint_index]
		local to_waypoint = waypoint.Position - root.Position
		local flat_direction = Vector3.new(to_waypoint.X, 0, to_waypoint.Z)
		if flat_direction.Magnitude < WAYPOINT_REACHED_DISTANCE then
			ai_state.flee_waypoint_index += 1
		else
			Move_Animal(root, flat_direction, stats.WalkSpeed)
		end
	else
		-- No usable path: run straight away instead of freezing.
		Move_Animal(root, away_direction, stats.WalkSpeed)
	end
	return true -- was actively fleeing this tick
end
-- Short straight-line hop to a random nearby spot after a random idle time.
-- Only runs on ticks with no player to react to. No pathfinding: if a hop
-- hits a tree, the next one picks a new spot.
local function Wander_Tick(root, stats, ai_state)
	if ai_state.wander_target then
		local to_target = ai_state.wander_target - root.Position
		local flat_direction = Vector3.new(to_target.X, 0, to_target.Z)
		if flat_direction.Magnitude < WAYPOINT_REACHED_DISTANCE then
			-- Arrived (or close enough) -- stand still for a fresh random
			-- idle period before picking the next spot.
			ai_state.wander_target = nil
			Stop_Animal(root)
			ai_state.next_wander_time = os.clock() + WANDER_MIN_IDLE_TIME + math.random() * (WANDER_MAX_IDLE_TIME - WANDER_MIN_IDLE_TIME)
		else
			Move_Animal(root, flat_direction, stats.WalkSpeed * WANDER_SPEED_MULTIPLIER)
		end
		return
	end
	Stop_Animal(root)
	if os.clock() >= ai_state.next_wander_time then
		local angle = math.random() * 2 * math.pi
		local distance = WANDER_MIN_DISTANCE + math.random() * (WANDER_MAX_DISTANCE - WANDER_MIN_DISTANCE)
		ai_state.wander_target = root.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * distance
	end
end
-- Chase the nearest player in AggroRange (cached, throttled pathfinding) and
-- attack in range. Returns that player, or nil.
local function Threat_Tick(model, root, stats, ai_state, infected, attack_track)
	local closest_player, closest_distance = nil, math.huge
	for _, player in ipairs(game.Players:GetPlayers()) do
		local character = player.Character
		local target_root = character and character:FindFirstChild("HumanoidRootPart")
		local target_humanoid = character and character:FindFirstChild("Humanoid")
		if target_root and target_humanoid and target_humanoid.Health > 0 then
			local distance = (target_root.Position - root.Position).Magnitude
			if distance < closest_distance then
				closest_distance = distance
				closest_player = player
			end
		end
	end
	if not closest_player or closest_distance > stats.AggroRange then
		ai_state.current_waypoints = nil
		-- Not engaged; Threat_Or_Wander handles idle wandering.
		return nil
	end
	local target_root = closest_player.Character.HumanoidRootPart
	if closest_distance <= stats.AttackRange then
		ai_state.current_waypoints = nil
		Stop_Animal(root)
		local now = os.clock()
		local cooldown_ready = now - ai_state.last_attack_time >= stats.AttackCooldown
		if cooldown_ready then
			ai_state.last_attack_time = now
			if attack_track then
				attack_track:Play()
			end
			if not PlayerCombat.is_invulnerable(closest_player) then
				local damage = stats.Damage
				if PlayerCombat.is_blocking(closest_player) then
					damage = damage * 0.5
				end
				closest_player.Character.Humanoid:TakeDamage(damage)
				if infected then
					PlayerInfection.infect(closest_player)
				end
			end
		end
		return closest_player
	end
	-- Pathfind at every distance beyond AttackRange so trees get routed around.
	-- Path recomputes can occasionally look like sidestepping; the refresh
	-- throttle below limits it.
	local now = os.clock()
	local target_moved = ai_state.last_path_target and (target_root.Position - ai_state.last_path_target).Magnitude > 5
	local needs_new_path = (not ai_state.current_waypoints) or target_moved or (now - ai_state.last_path_time >= PATH_REFRESH_INTERVAL)
	-- Compute the path in the background (it can take tens of seconds near dense
	-- trees) and keep following the old one meanwhile.
	if needs_new_path and not ai_state.computing_path then
		ai_state.computing_path = true
		ai_state.last_path_time = now
		local request_origin = root.Position
		local request_target = target_root.Position
		task.spawn(function()
			local path = PathfindingService:CreatePath({
				AgentRadius = 2,
				AgentHeight = 5,
				-- No Humanoid, so no jumping.
				AgentCanJump = false,
			})
			local success = pcall(function()
				path:ComputeAsync(request_origin, request_target)
			end)
			if success and path.Status == Enum.PathStatus.Success then
				ai_state.current_waypoints = path:GetWaypoints()
				ai_state.current_waypoint_index = 2
				ai_state.last_path_target = request_target
			end
			-- On failure, keep following the last good path.
			ai_state.computing_path = false
		end)
	end
	if ai_state.current_waypoints and ai_state.current_waypoints[ai_state.current_waypoint_index] then
		local waypoint = ai_state.current_waypoints[ai_state.current_waypoint_index]
		local to_waypoint = waypoint.Position - root.Position
		local flat_direction = Vector3.new(to_waypoint.X, 0, to_waypoint.Z)
		if flat_direction.Magnitude < WAYPOINT_REACHED_DISTANCE then
			ai_state.current_waypoint_index += 1
		else
			Move_Animal(root, flat_direction, stats.WalkSpeed)
		end
	else
		local to_target = target_root.Position - root.Position
		local flat_direction = Vector3.new(to_target.X, 0, to_target.Z)
		Move_Animal(root, flat_direction, stats.WalkSpeed)
	end
	return closest_player
end
local function New_Ai_State()
	return {
		last_attack_time = 0,
		current_waypoints = nil,
		current_waypoint_index = 1,
		last_path_target = nil,
		last_path_time = 0,
		-- Flee_Tick's own path cache (see Flee_Tick).
		flee_waypoints = nil,
		flee_waypoint_index = 1,
		flee_path_target = nil,
		flee_path_time = 0,
		-- Random initial delay so animals spawned together don't wander in sync.
		wander_target = nil,
		next_wander_time = os.clock() + WANDER_MIN_IDLE_TIME + math.random() * (WANDER_MAX_IDLE_TIME - WANDER_MIN_IDLE_TIME),
		-- True while a background path computation is running for this animal,
		-- so a second one isn't started.
		computing_path = false,
		computing_flee_path = false,
	}
end
-- Chase if a player is in range, otherwise wander. Clears any wander hop once
-- engaged so it doesn't resume later.
local function Threat_Or_Wander(model, root, stats, ai_state, infected, attack_track)
	local player_in_aggro = Threat_Tick(model, root, stats, ai_state, infected, attack_track)
	if player_in_aggro then
		ai_state.wander_target = nil
	else
		Wander_Tick(root, stats, ai_state)
	end
	return player_in_aggro
end
-- Flee if a player is in range, otherwise wander.
local function Flee_Or_Wander(root, stats, ai_state)
	local fleeing = Flee_Tick(root, stats, ai_state)
	if fleeing then
		ai_state.wander_target = nil
	else
		Wander_Tick(root, stats, ai_state)
	end
end
-- One loop per animal that re-reads species_mode / is_provoked / frenzied each
-- tick, so events can change an animal's behavior mid-match.
local function Run_Animal_AI(entry)
	local model, root = entry.model, entry.root
	task.spawn(function()
		while model.Parent and not entry.dead do
			local tick_time = os.clock()
			local tick_position = root.Position
			-- Speed from real displacement since the last tick (see Update_Movement_Animation).
			local elapsed = tick_time - entry.last_anim_tick_time
			local measured_speed = 0
			if elapsed > 0 then
				local delta = tick_position - entry.last_anim_position
				measured_speed = Vector3.new(delta.X, 0, delta.Z).Magnitude / elapsed
			end
			local ok, err = pcall(function()
				-- Event cutscene: hold still, and restart the attack cooldown so
				-- nothing hits the instant the cutscene ends.
				if MatchFreeze.mobs_paused() then
					Stop_Animal(root)
					entry.ai_state.last_attack_time = os.clock()
					Update_Movement_Animation(entry, 0)
					if os.clock() - last_pause_debug >= 1 then -- temporary, remove once confirmed
						last_pause_debug = os.clock()
						print("[FreezeDebug] wildlife AI paused for cutscene")
					end
					return
				end
				if entry.frenzied then
					local player_in_aggro = Threat_Or_Wander(model, root, entry.stats, entry.ai_state, entry.infected, entry.attack_track)
					if player_in_aggro then
						entry.last_in_aggro_time = os.clock()
					end
				elseif entry.species_mode == "threat" then
					Threat_Or_Wander(model, root, entry.stats, entry.ai_state, false, entry.attack_track)
				elseif entry.species_mode == "conditional" then
					if entry.is_provoked then
						local player_in_aggro = Threat_Or_Wander(model, root, entry.stats, entry.ai_state, false, entry.attack_track)
						if player_in_aggro then
							entry.last_in_aggro_time = os.clock()
						elseif os.clock() - entry.last_in_aggro_time >= ANGER_LINGER_DURATION then
							entry.is_provoked = false
						end
					else
						-- Shouldn't happen: infected animals are always frenzied, checked first.
						if entry.infected then
							warn("[WildLifeManager]", model.Name, "is INFECTED but fell through to Flee_Tick (conditional/not-provoked branch) — entry.frenzied =", tostring(entry.frenzied))
						end
						Flee_Or_Wander(root, entry.stats, entry.ai_state)
					end
				else
					if entry.infected then
						warn("[WildLifeManager]", model.Name, "is INFECTED but fell through to Flee_Tick (plain-flee branch) — entry.frenzied =", tostring(entry.frenzied))
					end
					Flee_Or_Wander(root, entry.stats, entry.ai_state)
				end
				Update_Movement_Animation(entry, measured_speed)
			end)
			if not ok then
				warn("Wildlife AI error for", model.Name, ":", err)
			end
			entry.last_anim_position = tick_position
			entry.last_anim_tick_time = tick_time
			task.wait(0.1)
		end
		if root.Parent then
			Stop_Animal(root)
		end
		active_animals[entry] = nil
	end)
end
function WildlifeManager.spawn_animal(species_name, x, z)
	local base_stats = WILDLIFE_STATS[species_name]
	if not base_stats then
		return
	end
	local ground_result = workspace:Raycast(Vector3.new(x, 1000, z), Vector3.new(0, -2000, 0))
	if not ground_result then
		return
	end
	local template = Get_Model_Template(species_name)
	local model = template:Clone()
	-- HumanoidRootPart is required; animals have no Humanoid.
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then
		warn("[WildLifeManager] " .. species_name .. " template has no HumanoidRootPart -- can't spawn")
		model:Destroy()
		return
	end
	root.Anchored = false -- physics (gravity, collisions, knockback) still applies
	model:SetAttribute("Health", base_stats.Health)
	model:SetAttribute("MaxHealth", base_stats.Health)
	model:PivotTo(CFrame.new(x, ground_result.Position.Y + 3, z))
	model.Parent = workspace
	CollectionService:AddTag(model, COMBAT_TARGET_TAG)
	Setup_Upright_Stabilizer(root)
	Setup_Health_Bar(model)
	local species_mode = "flee"
	if base_stats.IsThreat then
		species_mode = "threat"
	elseif base_stats.IsConditionalThreat then
		species_mode = "conditional"
	end
	local entry = {
		model = model,
		root = root,
		species_name = species_name,
		natural_stats = base_stats, -- shared species table, never mutated — the "reset to normal" target
		stats = Copy_Stats(base_stats), -- this animal's own live copy, safe for Frenzy to mutate
		ai_state = New_Ai_State(),
		species_mode = species_mode,
		is_provoked = false,
		last_in_aggro_time = 0,
		frenzied = false,
		infected = false,
		dead = false,
		-- Seed with the spawn position so the first speed reading is 0.
		last_anim_position = root.Position,
		last_anim_tick_time = os.clock(),
		movement_tracks = nil, -- set just below -- nil if this species has no real animation IDs yet
		active_movement_track = nil,
		attack_track = nil, -- set below; nil if no Attack clip
	}
	active_animals[entry] = true
	entry.movement_tracks = Load_Movement_Tracks(model, species_name)
	entry.attack_track = Load_Attack_Track(model, species_name)
	Start_Movement_Animation(entry)
	if species_mode == "conditional" then
		-- Conditional threats: any damage provokes them (see Run_Animal_AI).
		local last_health = model:GetAttribute("Health")
		model:GetAttributeChangedSignal("Health"):Connect(function()
			local new_health = model:GetAttribute("Health")
			if new_health < last_health then
				entry.is_provoked = true
				entry.last_in_aggro_time = os.clock() -- damage itself counts as "contact"
			end
			last_health = new_health
		end)
	end
	-- Death is detected from the Health attribute reaching 0.
	model:GetAttributeChangedSignal("Health"):Connect(function()
		if model:GetAttribute("Health") <= 0 then
			Handle_Death(entry)
		end
	end)
	Run_Animal_AI(entry)
end
-- Prunes dead/removed animals and returns everything still alive. The only
-- way anything outside this file can see what's currently roaming the map.
function WildlifeManager.get_active_animals()
	local alive = {}
	for entry in pairs(active_animals) do
		if entry.model.Parent and not entry.dead then
			table.insert(alive, entry)
		else
			active_animals[entry] = nil
		end
	end
	return alive
end
-- Animal Frenzy: every live animal gets infinite AggroRange for config.duration
-- (non-fighters borrow FRENZY_FALLBACK_COMBAT_STATS). config.infected_count of
-- them become infected and stay aggressive permanently. Call after spawning
-- reinforcements so they're included.
function WildlifeManager.start_frenzy(config)
	local duration = (config and config.duration) or 30
	local infected_count = (config and config.infected_count) or 0
	local alive = WildlifeManager.get_active_animals()
	for _, entry in ipairs(alive) do
		if not entry.infected then
			entry.frenzied = true
			entry.stats = Copy_Stats(entry.natural_stats)
			entry.stats.AggroRange = math.huge
			if not entry.stats.Damage then
				for key, value in pairs(FRENZY_FALLBACK_COMBAT_STATS) do
					entry.stats[key] = value
				end
			end
		end
	end
	if infected_count > 0 and #alive > 0 then
		local shuffled = Shuffled_Copy(alive)
		local to_infect = math.min(infected_count, #shuffled)
		for i = 1, to_infect do
			local entry = shuffled[i]
			entry.infected = true
			entry.frenzied = true
		end
	end
	task.delay(duration, function()
		WildlifeManager.end_frenzy()
	end)
end
-- Reverts non-infected animals. Infected ones stay aggressive.
function WildlifeManager.end_frenzy()
	for entry in pairs(active_animals) do
		if entry.frenzied and not entry.infected then
			entry.frenzied = false
			entry.stats = Copy_Stats(entry.natural_stats)
		end
	end
end
return WildlifeManager
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local PlayerEquipment = require(ServerScriptService:WaitForChild("PlayerEquipment"))
local PlayerCombat = require(ServerScriptService:WaitForChild("PlayerCombat"))
local EliminatedAppearances = require(ServerScriptService:WaitForChild("ArenaManager"):WaitForChild("EliminatedAppearances"))
local SettlementData = require(ServerScriptService:WaitForChild("ArenaManager"):WaitForChild("SettlementData"))
local MatchFreeze = require(ServerScriptService:WaitForChild("MatchFreeze"))
local last_pause_debug = 0 -- [FreezeDebug] throttle, temporary
local ZombieEvent = {}
local match_start_time = nil
local BASE_ZOMBIE_COUNT = 10
local ZOMBIES_PER_MINUTE = 0.33
local MAX_ZOMBIES = 30
local ZOMBIE_HEALTH = 80
local ZOMBIE_WALK_SPEED = 15 -- above RUN_SPEED_THRESHOLD so zombies use the run animation
local ZOMBIE_DAMAGE = 10
local ZOMBIE_ATTACK_RANGE = 5
local ZOMBIE_ATTACK_COOLDOWN = 1.2
-- Within this range, walk straight at the player instead of pathfinding, so
-- path recomputes don't look like dodging.
local ZOMBIE_DIRECT_CHASE_RANGE = 10
local ZOMBIE_AGGRO_RANGE = 110
local PATH_REFRESH_INTERVAL = 2
local WAYPOINT_REACHED_DISTANCE = 3
local COLLISION_GROUP = "Zombies"
local RUN_SPEED_THRESHOLD = 16 -- studs/sec — above this, play the run track instead of walk
local SETTLEMENT_SPAWN_CHANCE = 0.7
local COMBAT_TARGET_TAG = "CombatTarget"
-- Idle/Walk/Run fall back to a live player's default animations if left at the
-- placeholder. Attack has no fallback (no animation plays).
local ZOMBIE_ANIMATIONS = {
	Idle = "rbxassetid://115109941400360",
	Walk = "rbxassetid://139538810972180",
	Run = "rbxassetid://139538810972180",
	Attack = "rbxassetid://127255091636228",
}
pcall(function()
	PhysicsService:RegisterCollisionGroup(COLLISION_GROUP)
end)
pcall(function()
	PhysicsService:CollisionGroupSetCollidable(COLLISION_GROUP, COLLISION_GROUP, false)
end)
local function Get_Zombie_Count(elapsed_minutes)
	local count = BASE_ZOMBIE_COUNT + math.floor(elapsed_minutes * ZOMBIES_PER_MINUTE)
	return math.min(count, MAX_ZOMBIES)
end
local function Get_Spawn_Point()
	local zones = SettlementData.get_zones()
	local block_size = SettlementData.get_block_size()
	if #zones > 0 and math.random() < SETTLEMENT_SPAWN_CHANCE then
		local zone = zones[math.random(#zones)]
		local angle = math.random() * math.pi * 2
		local dist = math.random() * zone.flat_radius
		local world_x = zone.center.X * block_size + math.cos(angle) * dist * block_size
		local world_z = zone.center.Y * block_size + math.sin(angle) * dist * block_size
		return world_x, world_z
	end
	local map_radius = workspace:GetAttribute("MapRadius") or 2100
	local angle = math.random() * math.pi * 2
	local dist = math.random() * map_radius * 0.9
	return math.cos(angle) * dist, math.sin(angle) * dist
end
local function Get_Ground_Height(x, z)
	local result = workspace:Raycast(Vector3.new(x, 1000, z), Vector3.new(0, -2000, 0))
	return result and result.Position.Y or 0
end
local function Get_Zombie_Appearance()
	local pool = EliminatedAppearances.get_pool()
	if #pool > 0 then
		return pool[math.random(#pool)]
	end
	return {description = Instance.new("HumanoidDescription"), equipped_items = {}}
end
-- Borrows a live player's default Animate clip ID for a slot.
local function Get_Player_Animation_Id(folder_name)
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local animate = character and character:FindFirstChild("Animate")
		local anim_folder = animate and animate:FindFirstChild(folder_name)
		local anim = anim_folder and anim_folder:FindFirstChildOfClass("Animation")
		if anim then
			return anim.AnimationId
		end
	end
	return nil
end
local function Resolve_Animation_Id(custom_id, fallback_folder_name)
	if custom_id and custom_id ~= "rbxassetid://0" and custom_id ~= "" then
		return custom_id
	end
	return Get_Player_Animation_Id(fallback_folder_name)
end
-- Loads Idle/Walk/Run and switches between them by movement speed. Also loads
-- the one-off Attack track and returns it for Run_Zombie_AI to play on hits.
local function Setup_Zombie_Animation(zombie, humanoid)
	local idle_id = Resolve_Animation_Id(ZOMBIE_ANIMATIONS.Idle, "idle")
	local walk_id = Resolve_Animation_Id(ZOMBIE_ANIMATIONS.Walk, "walk")
	local run_id = Resolve_Animation_Id(ZOMBIE_ANIMATIONS.Run, "run")
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
	local idle_track = nil
	local walk_track = nil
	local run_track = nil
	if idle_id then
		local anim = Instance.new("Animation")
		anim.AnimationId = idle_id
		idle_track = animator:LoadAnimation(anim)
		idle_track.Looped = true
	end
	if walk_id then
		local anim = Instance.new("Animation")
		anim.AnimationId = walk_id
		walk_track = animator:LoadAnimation(anim)
		walk_track.Looped = true
		-- The custom walk only animates the upper body; Action priority lets it win
		-- there while the borrowed default walk below drives the legs.
		walk_track.Priority = Enum.AnimationPriority.Action
	end
	if run_id then
		local anim = Instance.new("Animation")
		anim.AnimationId = run_id
		run_track = animator:LoadAnimation(anim)
		run_track.Looped = true
		run_track.Priority = Enum.AnimationPriority.Action
	end
	-- Legs: a live player's default walk/run, always loaded and played alongside
	-- the custom upper-body clip (they don't share joints).
	local leg_walk_id = Get_Player_Animation_Id("walk")
	local leg_run_id = Get_Player_Animation_Id("run")
	local leg_walk_track = nil
	local leg_run_track = nil
	if leg_walk_id then
		local anim = Instance.new("Animation")
		anim.AnimationId = leg_walk_id
		leg_walk_track = animator:LoadAnimation(anim)
		leg_walk_track.Looped = true
	end
	if leg_run_id then
		local anim = Instance.new("Animation")
		anim.AnimationId = leg_run_id
		leg_run_track = animator:LoadAnimation(anim)
		leg_run_track.Looped = true
	end
	humanoid.Running:Connect(function(speed)
		local target_track = idle_track
		local leg_target_track = nil
		if speed > RUN_SPEED_THRESHOLD then
			target_track = run_track or walk_track or idle_track
			leg_target_track = leg_run_track or leg_walk_track
		elseif speed > 1 then
			target_track = walk_track or run_track or idle_track
			leg_target_track = leg_walk_track or leg_run_track
		end
		for _, track in ipairs({idle_track, walk_track, run_track}) do
			if track and track ~= target_track and track.IsPlaying then
				track:Stop()
			end
		end
		for _, track in ipairs({leg_walk_track, leg_run_track}) do
			if track and track ~= leg_target_track and track.IsPlaying then
				track:Stop()
			end
		end
		if target_track and not target_track.IsPlaying then
			target_track:Play()
		end
		if leg_target_track and not leg_target_track.IsPlaying then
			leg_target_track:Play()
		end
	end)
	local attack_track = nil
	local attack_id = ZOMBIE_ANIMATIONS.Attack
	if attack_id and attack_id ~= "rbxassetid://0" and attack_id ~= "" then
		local anim = Instance.new("Animation")
		anim.AnimationId = attack_id
		attack_track = animator:LoadAnimation(anim)
		attack_track.Looped = false
		-- Forced so it plays over walk/run.
		attack_track.Priority = Enum.AnimationPriority.Action
	end
	return attack_track
end
local function Spawn_Zombie(game_data)
	local appearance = Get_Zombie_Appearance()
	local zombie = Players:CreateHumanoidModelFromDescriptionAsync(appearance.description, Enum.HumanoidRigType.R15)
	local humanoid = zombie:FindFirstChild("Humanoid")
	if not humanoid then
		zombie:Destroy()
		return
	end
	zombie.Name = "Zombie"
	humanoid.MaxHealth = ZOMBIE_HEALTH
	humanoid.Health = ZOMBIE_HEALTH
	humanoid.WalkSpeed = ZOMBIE_WALK_SPEED
	local spawn_x, spawn_z = Get_Spawn_Point()
	local ground_y = Get_Ground_Height(spawn_x, spawn_z)
	zombie:PivotTo(CFrame.new(spawn_x, ground_y + 3, spawn_z))
	zombie.Parent = workspace
	for _, part in ipairs(zombie:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CollisionGroup = COLLISION_GROUP
		end
	end
	for _, item_name in pairs(appearance.equipped_items) do
		PlayerEquipment.attach_item_visual(zombie, item_name)
	end
	local attack_track = Setup_Zombie_Animation(zombie, humanoid)
	CollectionService:AddTag(zombie, COMBAT_TARGET_TAG)
	ZombieEvent.Run_Zombie_AI(zombie, humanoid, game_data, attack_track)
end
function ZombieEvent.Run_Zombie_AI(zombie, humanoid, game_data, attack_track)
	local root = zombie:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local last_attack_time = 0
	local current_waypoints = nil
	local current_waypoint_index = 1
	local last_path_target = nil
	local last_path_time = 0
	task.spawn(function()
		while zombie.Parent and humanoid.Health > 0 do
			local ok, err = pcall(function()
				-- Event cutscene: stand still, and restart the attack cooldown so
				-- nothing hits the instant the cutscene ends.
				if MatchFreeze.mobs_paused() then
					humanoid:Move(Vector3.new(0, 0, 0), false)
					current_waypoints = nil
					last_attack_time = os.clock()
					if os.clock() - last_pause_debug >= 1 then -- temporary, remove once confirmed
						last_pause_debug = os.clock()
						print("[FreezeDebug] zombie AI paused for cutscene")
					end
					return
				end
				local closest_player, closest_distance = nil, math.huge
				for player in pairs(game_data.participants) do
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
				if not closest_player or closest_distance > ZOMBIE_AGGRO_RANGE then
					current_waypoints = nil
					humanoid:Move(Vector3.new(0, 0, 0), false)
					return
				end
				local target_root = closest_player.Character.HumanoidRootPart
				if closest_distance <= ZOMBIE_ATTACK_RANGE then
					current_waypoints = nil
					humanoid:Move(Vector3.new(0, 0, 0), false)
					local now = os.clock()
					if now - last_attack_time >= ZOMBIE_ATTACK_COOLDOWN then
						last_attack_time = now
						if attack_track then
							attack_track:Play()
						end
						if not PlayerCombat.is_invulnerable(closest_player) then
							local damage = ZOMBIE_DAMAGE
							if PlayerCombat.is_blocking(closest_player) then
								damage = damage * 0.5
							end
							closest_player.Character.Humanoid:TakeDamage(damage)
						end
					end
					return
				end
				if closest_distance <= ZOMBIE_DIRECT_CHASE_RANGE then
					-- Close enough to skip pathfinding.
					current_waypoints = nil
					local to_target = target_root.Position - root.Position
					local flat_direction = Vector3.new(to_target.X, 0, to_target.Z)
					if flat_direction.Magnitude > 0.1 then
						humanoid:Move(flat_direction.Unit, false)
					end
					return
				end
				local now = os.clock()
				local target_moved = last_path_target and (target_root.Position - last_path_target).Magnitude > 5
				local needs_new_path = (not current_waypoints) or target_moved or (now - last_path_time >= PATH_REFRESH_INTERVAL)
				if needs_new_path then
					local path = PathfindingService:CreatePath({
						AgentRadius = 2,
						AgentHeight = 5,
						AgentCanJump = true,
					})
					local success = pcall(function()
						path:ComputeAsync(root.Position, target_root.Position)
					end)
					if success and path.Status == Enum.PathStatus.Success then
						current_waypoints = path:GetWaypoints()
						current_waypoint_index = 2
						last_path_target = target_root.Position
						last_path_time = now
					else
						current_waypoints = nil
					end
				end
				if current_waypoints and current_waypoints[current_waypoint_index] then
					local waypoint = current_waypoints[current_waypoint_index]
					local to_waypoint = waypoint.Position - root.Position
					local flat_direction = Vector3.new(to_waypoint.X, 0, to_waypoint.Z)
					if flat_direction.Magnitude < WAYPOINT_REACHED_DISTANCE then
						current_waypoint_index += 1
					elseif flat_direction.Magnitude > 0.1 then
						humanoid:Move(flat_direction.Unit, false)
					end
				else
					local to_target = target_root.Position - root.Position
					local flat_direction = Vector3.new(to_target.X, 0, to_target.Z)
					if flat_direction.Magnitude > 0.1 then
						humanoid:Move(flat_direction.Unit, false)
					end
				end
			end)
			if not ok then
				warn("Zombie AI tick error:", err)
			end
			task.wait(0.1)
		end
		humanoid:Move(Vector3.new(0, 0, 0), false)
		if zombie.Parent then
			zombie:Destroy()
		end
	end)
end
function ZombieEvent.trigger(game_data)
	if not match_start_time then
		match_start_time = os.clock()
	end
	local elapsed_minutes = (os.clock() - match_start_time) / 60
	local count = Get_Zombie_Count(elapsed_minutes)
	for i = 1, count do
		Spawn_Zombie(game_data)
		task.wait(0.2)
	end
end
return ZombieEvent
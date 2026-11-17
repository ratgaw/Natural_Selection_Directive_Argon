local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local PlayerEquipment = require(ServerScriptService:WaitForChild("PlayerEquipment"))
local PlayerCombat = require(ServerScriptService:WaitForChild("PlayerCombat"))
local EliminatedAppearances = require(ServerScriptService:WaitForChild("ArenaManager"):WaitForChild("EliminatedAppearances"))
local SettlementData = require(ServerScriptService:WaitForChild("ArenaManager"):WaitForChild("SettlementData"))
local PlayerMinimap = require(ServerScriptService:WaitForChild("ArenaManager"):WaitForChild("PlayerMinimap"))
local event_warning = ReplicatedStorage:WaitForChild("EventWarning")
local ZombieEvent = {}
local match_start_time = nil
local BASE_ZOMBIE_COUNT = 10
local ZOMBIES_PER_MINUTE = 0.33
local MAX_ZOMBIES = 30
local ZOMBIE_HEALTH = 80
local ZOMBIE_WALK_SPEED = 15 -- was 12 — above the run-animation threshold below
local ZOMBIE_DAMAGE = 10
local ZOMBIE_ATTACK_RANGE = 5
local ZOMBIE_ATTACK_COOLDOWN = 1.2
-- Inside this range (but still outside ZOMBIE_ATTACK_RANGE), skip
-- PathfindingService entirely and walk straight at the player instead.
-- Waypoint recomputation (every PATH_REFRESH_INTERVAL, or whenever the
-- target moves >5 studs) can pick a slightly different angle each time,
-- which reads as the zombie "dodging" a swing mid-windup even though
-- it's just ordinary path churn. This close, obstacle avoidance no
-- longer matters — the hard part of the chase is already done — so a
-- straight line in gives a predictable target to actually hit.
local ZOMBIE_DIRECT_CHASE_RANGE = 10
local ZOMBIE_AGGRO_RANGE = 110 -- was 60
local PATH_REFRESH_INTERVAL = 2
local WAYPOINT_REACHED_DISTANCE = 3
local COLLISION_GROUP = "Zombies"
local RUN_SPEED_THRESHOLD = 16 -- studs/sec — above this, play the run track instead of walk
local SETTLEMENT_SPAWN_CHANCE = 0.7
local COMBAT_TARGET_TAG = "CombatTarget"
-- [stated] "I've added zombie animations for their idle, attack, and
-- movement" -- Idle and Attack are new slots; Walk/Run (the "movement"
-- animations) already existed. Drop each real published asset ID in here.
-- Idle/Walk/Run still fall back to a live player's own Animate-script
-- animation if left at the placeholder (see Get_Player_Animation_Id
-- below) -- useful for filling slots in one at a time. Attack has no real
-- player equivalent to borrow (players don't have a bare-fists swing
-- animation the way a zombie does), so leaving Attack at the placeholder
-- just means no attack animation plays -- same "degrade gracefully,
-- nothing errors" shape as every other animation system in this project.
local ZOMBIE_ANIMATIONS = {
	Idle = "rbxassetid://115109941400360",
	Walk = "rbxassetid://139538810972180",
	Run = "rbxassetid://139538810972180",
	Attack = "rbxassetid://127255091636228",
}
local collision_group_ready = pcall(function()
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
-- Fallback: borrows a real player's own walk/run/idle animation ID, used
-- only when ZOMBIE_ANIMATIONS doesn't have a real custom ID set for that
-- slot. Players' default Animate script has an "idle" folder too, same as
-- "walk"/"run", so this same fallback now also covers Idle -- there's just
-- no equivalent folder for Attack, which is why that one has no fallback.
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
-- Loads Idle/Walk/Run tracks, switching between them based on actual
-- movement speed — matches how Roblox's own default character animates,
-- so a fast-moving zombie visually reads as running, not moonwalking, and
-- a standing-still one now actually idles instead of holding rest pose.
-- Attack is loaded here too (same Animator, same function, so there's only
-- one place that ever needs an animator reference) but is NOT part of the
-- Running-speed switch below -- it's a one-off action pose played directly
-- from Run_Zombie_AI when a hit actually lands, the same way
-- PlayerCombat's own swing track and WildLifeManager's attack_track work,
-- not a looping locomotion state. Returned to the caller so Spawn_Zombie
-- can hand it to Run_Zombie_AI.
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
		-- [stated] the custom Walk clip only animates the upper body and was
		-- meant to rely on "Roblox's default run animations" for the legs --
		-- but these zombies never get a default Animate script, so nothing
		-- else was ever driving the legs. Forcing this to Action priority
		-- guarantees it wins on any joint it DOES touch (upper body) once the
		-- player-sourced leg_walk_track below is layered in underneath it.
		walk_track.Priority = Enum.AnimationPriority.Action
	end
	if run_id then
		local anim = Instance.new("Animation")
		anim.AnimationId = run_id
		run_track = animator:LoadAnimation(anim)
		run_track.Looped = true
		run_track.Priority = Enum.AnimationPriority.Action
	end
	-- [stated] "basing the movement on the live player's default walk/run" --
	-- these two tracks are loaded UNCONDITIONALLY from a live player's own
	-- default Animate walk/run clips (bypassing Resolve_Animation_Id's
	-- placeholder-gate on purpose) and played in parallel with the custom
	-- walk/run tracks above. The custom clip never has leg keyframe data, so
	-- it can't conflict with these on the leg joints -- Priority only
	-- resolves conflicts between tracks that both touch the same joint, it
	-- can't animate a joint a track never keyed. Where the two WOULD overlap
	-- (upper body), the custom track's forced Action priority wins, so the
	-- net effect is: custom clip drives the upper body, borrowed
	-- player animation drives the legs, nothing fights over either.
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
		-- Forced here in script rather than relying on it having been set
		-- correctly in the Animation Editor -- guarantees the attack pose
		-- wins over the looping Walk/Run track for as long as it's
		-- playing, regardless of how the clip was authored.
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
					-- Close enough that obstacle avoidance no longer
					-- matters — walk straight at the player instead of
					-- letting path-waypoint churn cause sidestepping.
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
local function Send_Warnings(delay_seconds)
	for _, player in ipairs(Players:GetPlayers()) do
		local has_upgrade = PlayerMinimap.has_upgrade(player, "Terrain")
		local warning_time = has_upgrade and WARNING_LONG or WARNING_SHORT
		if warning_time >= delay_seconds then
			event_warning:FireClient(player, "Zombies", delay_seconds)
		end
	end
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
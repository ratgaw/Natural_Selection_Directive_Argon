local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local CollectionService = game:GetService("CollectionService")
local arena_manager = ServerScriptService:WaitForChild("ArenaManager")
local PlayerInventory = require(ServerScriptService:WaitForChild("PlayerInventory"))
local PlayerCombat = require(ServerScriptService:WaitForChild("PlayerCombat"))
local PlayerInfection = require(arena_manager:WaitForChild("PlayerInfection"))
local inventory_updated = ReplicatedStorage:WaitForChild("InventoryUpdated")
local WildlifeManager = {}
local COMBAT_TARGET_TAG = "CombatTarget"
local PATH_REFRESH_INTERVAL = 2
local WAYPOINT_REACHED_DISTANCE = 3
local ANGER_LINGER_DURATION = 30 -- seconds a conditional-threat stays aggressive after losing aggro range
-- Every spawned animal gets an entry here (keyed by the entry table itself,
-- so pruning a dead one is just active_animals[entry] = nil) — needed so
-- AnimalFrenzyEvent can reach into every currently-alive animal at once
-- (make it aggressive, pick a few to infect) instead of only ever being
-- able to spawn new ones. Nothing read this before the frenzy event existed.
local active_animals = {}
-- Placeholders, tune once tested. Fallback combat numbers for species that
-- normally never fight (Deer/Rat have no Damage/AttackRange/AttackCooldown
-- in WILDLIFE_STATS at all) — Animal Frenzy is supposed to turn EVERY
-- animal on the map hostile, so something has to fill in for the ones that
-- were never built to attack.
local FRENZY_FALLBACK_COMBAT_STATS = {Damage = 8, AttackRange = 4, AttackCooldown = 1.5}
-- [stated] "extend real pathfinding to all ranges" -- replaces the old
-- DIRECT_CHASE_RANGE_MULTIPLIER straight-line shortcut entirely (see
-- Threat_Tick's own comment on this change for the full reasoning and the
-- tradeoff it reintroduces). How far past its own current position a
-- fleeing animal paths TO when running from a player -- same shape
-- Threat_Tick already uses (path toward a concrete point, not just "a
-- direction"), just aimed away from the player instead of at them.
local FLEE_DESTINATION_DISTANCE = 40
-- [stated] "while a player is not within their threat radius they'll pick a
-- random direction to move a random small amount in after a random period
-- of time, to help simulate them as real animals rather than them just
-- standing there until a player comes close by" -- see Wander_Tick below
-- for the actual behavior; these are just its tunables. Placeholders, tune
-- once you can see this in-game.
local WANDER_MIN_IDLE_TIME = 3 -- seconds standing still before picking a new wander spot
local WANDER_MAX_IDLE_TIME = 8
local WANDER_MIN_DISTANCE = 4 -- studs -- "a random SMALL amount"
local WANDER_MAX_DISTANCE = 12
local WANDER_SPEED_MULTIPLIER = 0.4 -- fraction of the animal's real WalkSpeed -- an idle amble should read slower/calmer than an actual flee or chase, not identical to one
-- [stated] wiring in per-species walk/idle/attack animations, mirroring the
-- Idle/Move hold-pose pattern PlayerCombat.lua already uses for weapons,
-- plus a third Attack slot. Placeholders (rbxassetid://0) until each
-- species' clip is published -- Load_Movement_Tracks/Load_Attack_Track
-- below skip gracefully (no error, no animation played, animal just moves
-- and attacks exactly as it does today) for any species left at the
-- placeholder, so an unfinished entry doesn't break that animal's AI loop.
-- Fill in the real published asset ID per species as you finish each clip.
-- Bear, Wolf, and Deer are done; Rat has its Idle clip in but Move/Attack
-- are still placeholders -- Load_Movement_Tracks skips Rat's movement
-- animation entirely until Move is filled in too (it requires both Idle
-- and Move before loading either, see its own comment), so Rat keeps
-- moving with no animation at all, same as before, until that happens.
-- Attack is only reachable in play for Bear/Wolf normally -- Deer/Rat only
-- ever attack during Animal Frenzy -- but every species gets a slot so
-- Frenzy doesn't leave them silently animation-less if you do animate
-- them too.
-- [stated/found] "I've removed several of the animals from the spawn pool
-- of animals as at this time they're unneeded" -- Buffalo/Fox/Raccoon
-- entries removed here along with their WILDLIFE_STATS below, since
-- StartMatch.lua's WILDLIFE_SPAWN_TABLE no longer spawns any of the three
-- (spawn_animal is simply never called with those names any more). Add
-- both back together if any of them return to the spawn pool later.
local WILDLIFE_ANIMATIONS = {
	Bear = {Idle = "rbxassetid://80022095367839", Move = "rbxassetid://122910290685658", Attack = "rbxassetid://102672275576039"},
	Wolf = {Idle = "rbxassetid://72589098604736", Move = "rbxassetid://80209714329135", Attack = "rbxassetid://122533141737561"},
	Deer = {Idle = "rbxassetid://121184421507913", Move = "rbxassetid://78625918323996", Attack = "rbxassetid://119461979815977"},
	Rat = {Idle = "rbxassetid://136936821701378", Move = "rbxassetid://93828977601368", Attack = "rbxassetid://133568114553201"},
}
local MOVEMENT_FADE_TIME = 0.2 -- seconds, crossfade between Idle/Move -- a touch longer than the player's own hold-pose fade (0.15) since these are calmer, less snappy creature cycles. Placeholder, tune once tested.
local MOVING_THRESHOLD = 0.5 -- studs/sec -- same threshold PlayerCombat's own Running handler uses to decide Move vs Idle
-- Starting guesses — tune once you can see these in-game.
-- IsThreat: always aggressive (Bear, Wolf).
-- IsConditionalThreat: flees normally, becomes threat-AI after taking
-- damage, reverts to fleeing once no player has been in AggroRange for
-- ANGER_LINGER_DURATION seconds. [stated/found] Buffalo/Fox were the only
-- two species ever marked IsConditionalThreat, and both are currently out
-- of the spawn pool (see WILDLIFE_ANIMATIONS's own comment) -- the
-- species_mode == "conditional" branch in Run_Animal_AI, is_provoked, and
-- this whole mechanism are all still live code, just dormant until some
-- species in this table sets IsConditionalThreat = true again.
-- Plain entries (neither flag): pure flee, never fights back.
local WILDLIFE_STATS = {
	Bear = {IsThreat = true, Health = 150, WalkSpeed = 14, Damage = 20, AttackRange = 6, AttackCooldown = 1.5, AggroRange = 50, HarvestItem = "Raw Meat"},
	Wolf = {IsThreat = true, Health = 60, WalkSpeed = 20, Damage = 12, AttackRange = 5, AttackCooldown = 1, AggroRange = 60, HarvestItem = "Raw Meat"},
	Deer = {Health = 40, WalkSpeed = 12, FleeRange = 30, HarvestItem = "Raw Meat"},
	Rat = {Health = 10, WalkSpeed = 10, FleeRange = 15, HarvestItem = "Raw Meat"},
}
local function Get_Model_Template(species_name)
	return ServerStorage:WaitForChild("Wildlife"):WaitForChild(species_name)
end
-- WILDLIFE_STATS entries are shared per-species tables — fine for read-only
-- use, but Animal Frenzy needs to boost ONE animal's AggroRange without
-- affecting every other animal of that species on the map, so each spawned
-- animal gets its own shallow copy to mutate instead.
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
-- [stated] "remove the outline from the infected animals, I don't want
-- players to be able to know which animals are infected and which aren't"
-- -- removed the WHOLE Highlight (used to set both FillColor/
-- FillTransparency and OutlineColor) rather than just OutlineColor alone --
-- the translucent fill tint on its own would still have visually marked an
-- infected animal as different from a normal one, which contradicts the
-- actual goal stated here. An infected animal now looks 100% identical to
-- a normal one of its species; the only tell left is its behavior
-- (permanently hyper-aggressive) once a player gets close enough to notice.
-- [stated] "I removed the humanoid part in each animal" -- no more
-- Humanoid.MaxHealth/Health/HealthChanged to read from, so health now
-- lives as a plain "Health"/"MaxHealth" NUMBER ATTRIBUTE directly on the
-- model instead. This is also the exact interface PlayerCombat.lua's
-- attack code now writes to for any CombatTarget-tagged model that has no
-- Humanoid (see the matching change there) -- both sides agree health
-- lives here, so nothing in WildLifeManager needs its own damage API.
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
-- Replaces the old humanoid.Died:Connect split across two listeners (one for cleanup in
-- spawn_animal, one for the harvest prompt in the old Setup_Harvest) with
-- a single handler, since there's no more Humanoid.Died event to hang
-- either off of -- both now fire from the same "Health attribute crossed
-- to 0" moment instead (see spawn_animal's GetAttributeChangedSignal
-- connection). entry.dead guards this from ever running twice (an
-- attribute-changed signal firing more than once right around 0 is
-- possible -- e.g. two near-simultaneous hits -- harmless on its own, but
-- a second ProximityPrompt/second inventory grant would not be).
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
-- [stated] "I removed the humanoid part in each animal... you can assume
-- all animals have the same formatting for their models" -- confirmed via
-- the Explorer screenshot (Bear/Buffalo both: HumanoidRootPart +
-- AnimationController, no Humanoid at all anymore) -- so this no longer
-- needs a Humanoid fallback; the AnimationController is the only possible
-- owner now. Still returns nil (with a warning) rather than erroring if a
-- template is ever missing one, same "degrade gracefully" philosophy as
-- everywhere else in this animation system -- Load_Movement_Tracks/
-- Load_Attack_Track below both already treat a nil owner as "no animation
-- for this animal" rather than crashing its spawn.
local function Get_Animation_Owner(model)
	local controller = model:FindFirstChildOfClass("AnimationController")
	if not controller then
		warn("[WildLifeManager] " .. model:GetFullName() .. " has no AnimationController -- can't load any animation for it")
	end
	return controller
end
-- Loads (once per animal) this species' Idle/Move tracks -- same Idle/Move
-- shape as PlayerCombat's weapon hold poses. Returns nil if this species is
-- still at the rbxassetid://0 placeholder, or if either track fails to
-- load (bad/unpublished asset ID) -- callers treat nil as "no movement
-- animation for this animal", same as before this system existed, rather
-- than erroring out that animal's whole AI loop.
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
-- Attack is intentionally independent of Load_Movement_Tracks above -- an
-- animal with a finished walk cycle but no attack clip yet (or vice versa)
-- should still get whichever half IS ready rather than either being held
-- back by the other. Not looped (one swing, then stops, matching how
-- PlayerCombat.attack plays the player's own swing track) and Priority is
-- forced to Action here in script rather than relying on it having been set
-- correctly in the Animation Editor -- that guarantees the attack pose wins
-- over the looping Idle/Move track for as long as it's playing regardless
-- of how the clip was authored. [not yet confirmed] whether Action is high
-- enough to fully override Movement-priority Move tracks on THIS rig type --
-- it's the standard Roblox priority ordering (Action > Movement > Idle) so
-- it should, but flag it if an attack visually gets stomped by the walk
-- cycle once real clips are in.
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
-- [stated] "I removed the humanoid part in each animal" -- humanoid:Move()
-- doesn't exist without a Humanoid, so every AI function that used to call
-- it now goes through these two instead. HumanoidRootPart is left
-- unanchored (set in spawn_animal) specifically so gravity/falling/landing
-- and collision with players, props and terrain all still come from
-- ordinary Roblox physics exactly as before -- NOTHING about that changes.
-- Only the two things Humanoid used to handle for us are handled here now:
-- driving horizontal speed (via AssemblyLinearVelocity, Y left alone so
-- it never fights gravity) and turning to face the movement direction
-- (Humanoid's AutoRotate doesn't exist anymore either). [known
-- limitation] there's no more Humanoid hip-height/step-climb assistance,
-- so very rough terrain may need revisiting later -- flag it if animals
-- visibly get stuck on bumps or slopes once you can see this in-game.
-- [stated] "when moving they will move sideways, as if the side of their
-- body is thought to be the front instead" -- CFrame.new(pos, pos+direction)
-- below is the standard, correct way to point a Part's own front (its
-- local -Z axis) along a direction, and that part-level rotation IS
-- correct -- the walking animation playing at all confirms the root is
-- turning the right way. The mismatch is one level deeper: these custom
-- skinned-mesh rigs (SK-Bear2 etc.) evidently weren't modeled/welded with
-- their VISIBLE front lined up with HumanoidRootPart's own -Z axis, so the
-- part turns correctly while the mesh riding along with it still reads as
-- facing sideways. A Humanoid-driven rig never would have surfaced this --
-- Humanoid's own AutoRotate makes the exact same -Z assumption, so this
-- offset would have looked identical even before the Humanoid was removed.
-- MOVEMENT_FACING_OFFSET is a constant extra twist applied in the root's
-- OWN local space (hence multiplying on the right, after the aim-at-
-- direction CFrame) to correct for that baked-in mismatch -- same angle
-- every time, regardless of which way the animal is actually walking.
-- [stated] "those running away from the player will face the player the
-- entire time" -- Flee_Tick's own direction math is correct (away_direction
-- = root.Position - closest_root.Position, i.e. pointing FROM the player
-- TOWARD the animal -- away from the player, exactly as intended), so this
-- isn't a flee-logic bug. "Facing the player while traveling away from the
-- player" is EXACTLY what facing 180 degrees opposite of travel direction
-- looks like -- meaning the +90 guess above wasn't just a little off, it
-- was off by a further 180: the true offset is 90 + 180 = 270, i.e. -90.
-- [stated] "to 180 the rotation so that the animals point the right way" --
-- done, adjusted below rather than leaving +90 and layering a second fix
-- on top.
local MOVEMENT_FACING_OFFSET = math.rad(-90)
-- [stated] "the animals have a tendency to sometimes fall over/tip, which
-- is corrected when prompted into a different animation" -- that tell is
-- the whole diagnosis: Move_Animal below already forces root.CFrame to a
-- clean, perfectly-upright orientation every time it runs, so tipping can
-- only actually be VISIBLE during the gaps that leaves -- while an animal
-- is standing still (Stop_Animal only ever touches velocity, never
-- CFrame, so nothing re-uprights it if gravity/a collision/terrain torque
-- tips it while idle) or in the up-to-0.1s window between AI ticks while
-- moving. "Corrected when prompted into a different animation" is exactly
-- what the NEXT Move_Animal call re-snapping CFrame to upright would look
-- like. A Humanoid prevented this automatically, all the time, regardless
-- of movement state -- there's no equivalent without one unless something
-- is added back. An AlignOrientation constraint is the standard Roblox
-- answer: a continuous, physics-rate (not 0.1s-tick-rate) corrective
-- torque holding the root upright at whatever yaw it's currently facing,
-- active whether the animal is moving OR standing still. RigidityEnabled
-- is on rather than tuning MaxTorque/Responsiveness -- given "I definitely
-- don't want this to happen", a rigid, instant, zero-tolerance upright
-- lock is simpler to reason about and strictly stronger than a springy
-- one; the tradeoff is the root stays perfectly vertical even on a slope
-- (no natural forward/backward lean climbing or descending), which reads
-- as a bit stiff but was never something before this existed anyway. An
-- Attachment0-only constraint, parented to the root itself so it travels
-- and gets destroyed with it -- nothing elsewhere needs to clean it up.
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
-- [known limitation] if a template is ever missing HumanoidRootPart's
-- stabilizer for some reason (shouldn't happen -- spawn_animal always
-- creates one), this just means nothing corrects tipping for that one
-- animal, same graceful-degradation shape as everything else here rather
-- than erroring its whole AI loop.
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
	-- Keeps the continuous stabilizer's target in lockstep with whatever
	-- direction was just snapped to directly above -- if these two ever
	-- disagreed the constraint would start fighting this function's own
	-- CFrame assignment instead of just holding it steady.
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
-- [stated] "I removed the humanoid part in each animal" -- this used to be
-- event-driven off humanoid.Running (fired by Roblox whenever a Humanoid's
-- actual speed changes), which no longer exists. Called once per AI tick
-- from Run_Animal_AI instead (every 0.1s, same cadence everything else in
-- this file already runs at).
-- [stated] "one deer... became stuck in place once the event had started,
-- running their movement animation while not moving" -- this originally
-- took the animal's speed straight off root.AssemblyLinearVelocity, read
-- immediately after THIS SAME TICK's Move_Animal/Threat_Tick call had just
-- SET it -- meaning it only ever reflected what the script just commanded,
-- never whether physics actually let it happen. The reasoning at the time
-- ("Move_Animal sets velocity directly, so there's no acceleration ramp to
-- lag behind") was true but missed a different source of mismatch: a
-- collision -- with a player (exactly what triggered this report -- "ran
-- into right before the event"), another animal, or a tree with no
-- steering/avoidance beyond waypoint-following -- can zero out or redirect
-- the ACTUAL motion between ticks while this function keeps reasserting
-- the same full-speed command every 0.1s regardless, so a genuinely stuck
-- animal reads as "moving at full WalkSpeed" forever. Run_Animal_AI now
-- passes in a speed measured from REAL displacement since the previous
-- tick instead (one tick, ~0.1s, of lag, in exchange for reflecting what
-- actually happened) -- see the comment there for the full reasoning. This
-- function itself didn't need to change, just what it's called with.
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
-- One tick of flee behavior: run away from the nearest player if they're
-- within FleeRange, otherwise stand still.
-- [stated] "fix the issue of not being able to get around trees... extend
-- real pathfinding to all ranges" -- this used to just walk straight away
-- from the player (no PathfindingService at all), so a tree sitting on
-- that line stopped a fleeing animal cold with nothing to route around it.
-- Now paths toward a point FLEE_DESTINATION_DISTANCE studs out along the
-- away direction instead of a raw direction, same "path to a concrete
-- point" shape Threat_Tick already used for chasing.
-- ai_state is the SAME per-animal table Threat_Tick uses (a
-- conditional-threat animal calls into both this and Threat_Tick depending
-- on entry.is_provoked -- currently no species does, see WILDLIFE_STATS's
-- own comment), but this keeps its own flee_* waypoint-cache fields
-- separate from Threat_Tick's current_waypoints/last_path_target/
-- last_path_time -- the two compute paths toward opposite destinations
-- (away from the player vs. toward it), so sharing one cache would let a
-- mode switch reuse stale waypoints computed for the other behavior for up
-- to PATH_REFRESH_INTERVAL seconds.
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
		-- [stated/found] Stop_Animal used to be called directly here -- now
		-- left to Flee_Or_Wander (see its own comment, just above
		-- Run_Animal_AI) so a disengaged animal wanders instead of just
		-- standing still the moment nothing's within FleeRange.
		return false
	end
	local away_direction = root.Position - closest_root.Position
	away_direction = Vector3.new(away_direction.X, 0, away_direction.Z)
	if away_direction.Magnitude < 0.1 then
		-- Standing right on top of the player (shouldn't normally happen,
		-- but guards the .Unit below from dividing by ~0) -- pick an
		-- arbitrary direction rather than erroring.
		away_direction = Vector3.new(1, 0, 0)
	end
	local flee_target = root.Position + away_direction.Unit * FLEE_DESTINATION_DISTANCE
	local now = os.clock()
	-- Recompute keyed off the PLAYER's movement, same as Threat_Tick --
	-- the flee destination is derived from the player's position, so it's
	-- the player moving (not the animal) that stales out an existing path.
	local target_moved = ai_state.flee_path_target and (closest_root.Position - ai_state.flee_path_target).Magnitude > 5
	local needs_new_path = (not ai_state.flee_waypoints) or target_moved or (now - ai_state.flee_path_time >= PATH_REFRESH_INTERVAL)
	-- [stated/found] see ai_state.computing_flee_path's own comment in
	-- New_Ai_State -- ComputeAsync is launched in its own coroutine instead
	-- of inline here so a slow computation (dense trees) can't freeze this
	-- animal's whole AI loop for however long it takes to resolve. Keeps
	-- whatever flee_waypoints it already has (stale, but still usable) --
	-- or the straight-line fallback below if it has none yet -- until the
	-- background computation finishes and swaps in a fresh path.
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
			-- On failure, deliberately leave the existing flee_waypoints
			-- (if any) in place rather than nil-ing them -- an animal
			-- mid-flee keeps following its last known-good route instead
			-- of being yanked back to the straight-line fallback every
			-- time a refresh attempt comes up empty.
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
		-- Path failed (boxed in, bad navmesh gap, etc.) or ran out of
		-- waypoints before reaching the destination -- fall back to the
		-- old straight-line-away behavior rather than freezing in place,
		-- same "degrade gracefully" shape Threat_Tick uses for its own
		-- path failures.
		Move_Animal(root, away_direction, stats.WalkSpeed)
	end
	return true -- was actively fleeing this tick
end
-- [stated] "while a player is not within their threat radius they'll pick a
-- random direction to move a random small amount in after a random period
-- of time, to help simulate them as real animals rather than them just
-- standing there until a player comes close by" -- called from Run_Animal_AI
-- (via Threat_Or_Wander/Flee_Or_Wander below) only on ticks where
-- Threat_Tick/Flee_Tick found no player to react to, so it never fights
-- either of those for control of the animal -- the moment a player comes
-- back into range, Run_Animal_AI goes back to calling the real behavior
-- instead, same tick.
-- Deliberately a straight-line hop rather than the full PathfindingService
-- routing Threat_Tick/Flee_Tick use for their much longer, must-actually-
-- arrive trips -- a wander hop is short and low-stakes, so if one happens to
-- bump a tree or a rock it just stops there; the next idle cycle picks a
-- fresh random spot rather than it staying stuck (unlike a blocked flee/
-- chase, which needed the real pathfinding fix to reliably reach its
-- destination at all).
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
-- One tick of threat behavior: cached/throttled pathfinding chase +
-- attack, identical structure to ZombieEvent's proven AI. ai_state holds
-- waypoint/timing data that must persist across ticks for one animal.
-- Returns the player currently within AggroRange, or nil.
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
		-- [stated/found] Stop_Animal used to be called directly here -- now
		-- left to Threat_Or_Wander (see its own comment, just above
		-- Run_Animal_AI) so a disengaged animal wanders instead of just
		-- standing still the moment nothing's within AggroRange.
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
	-- [stated] "fix the issue of not being able to get around trees...
	-- extend real pathfinding to all ranges" -- this used to skip
	-- PathfindingService entirely inside AttackRange * DIRECT_CHASE_RANGE_
	-- MULTIPLIER and walk straight at the target, specifically to stop
	-- waypoint-recompute churn from reading as sidestepping/dodging out of
	-- a swing's cone mid-windup (same fix ZombieEvent.lua uses). Removed --
	-- every distance beyond AttackRange now goes through the same
	-- pathfinding-waypoint flow below, so a tree between the animal and the
	-- player gets routed around instead of walked into regardless of how
	-- close the animal already is.
	-- [known tradeoff, accepted going into this change] the sidestepping
	-- behavior this used to prevent can recur -- a path recompute landing
	-- while an animal is mid-approach and the player has drifted can still
	-- send it on a new, different-looking route. The existing
	-- PATH_REFRESH_INTERVAL / 5-stud-target-move throttle just below is the
	-- only thing limiting how often that can happen now. Revisit if it
	-- reads as "dodging" again once you can see it in-game.
	local now = os.clock()
	local target_moved = ai_state.last_path_target and (target_root.Position - ai_state.last_path_target).Magnitude > 5
	local needs_new_path = (not ai_state.current_waypoints) or target_moved or (now - ai_state.last_path_time >= PATH_REFRESH_INTERVAL)
	-- [stated/found] "a deer stood right next to the player and never
	-- reacted at all" -- root-caused to ComputeAsync being called INLINE
	-- here, blocking this one animal's entire Run_Animal_AI coroutine (no
	-- more ticks, no more debug prints, nothing) for as long as it takes to
	-- resolve -- on this map (~5000 trees) that turned out to be 40+
	-- seconds for at least one close-range case. See
	-- ai_state.computing_path's own comment in New_Ai_State for the full
	-- reasoning. Launched in its own coroutine instead so the main loop
	-- keeps ticking -- following whatever current_waypoints it already has
	-- (stale is fine), or the straight-line fallback below if it has none
	-- -- while a fresh path resolves in the background and gets swapped in
	-- once ready.
	if needs_new_path and not ai_state.computing_path then
		ai_state.computing_path = true
		ai_state.last_path_time = now
		local request_origin = root.Position
		local request_target = target_root.Position
		task.spawn(function()
			local path = PathfindingService:CreatePath({
				AgentRadius = 2,
				AgentHeight = 5,
				-- [stated] "I removed the humanoid part in each animal" -- no
				-- Humanoid left to actually execute a jump even if the path
				-- called for one, so no point computing paths that assume
				-- that capability exists.
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
			-- On failure, deliberately leave the existing current_waypoints
			-- (if any) in place -- same "keep following the last known-good
			-- route instead of yanking back to the fallback" reasoning as
			-- Flee_Tick's mirrored version of this.
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
		-- Separate waypoint cache for Flee_Tick -- see its own comment for
		-- why this can't share current_waypoints/last_path_target/
		-- last_path_time with Threat_Tick above.
		flee_waypoints = nil,
		flee_waypoint_index = 1,
		flee_path_target = nil,
		flee_path_time = 0,
		-- Wander_Tick's own state -- see its comment, just above
		-- Threat_Tick, for the full behavior. Seeded with a random initial
		-- delay (rather than 0) so a batch of animals spawned together
		-- don't all take their first wander step on the same tick.
		wander_target = nil,
		next_wander_time = os.clock() + WANDER_MIN_IDLE_TIME + math.random() * (WANDER_MAX_IDLE_TIME - WANDER_MIN_IDLE_TIME),
		-- [stated/found] a deer standing right next to the player went
		-- completely silent (no debug prints, no AI-error warning) for 40+
		-- seconds the instant Animal Frenzy made it start pathfinding --
		-- root-caused to PathfindingService:ComputeAsync being called
		-- INLINE in Threat_Tick/Flee_Tick, blocking that one animal's
		-- entire per-tick coroutine until it resolves. With ~5000 trees on
		-- this map, a close-range path through dense clutter can apparently
		-- take ComputeAsync tens of seconds to resolve (a far, effectively
		-- unreachable target seems to fail fast by comparison, which is why
		-- this wasn't obvious before). These two flags mark "a background
		-- path computation is already in flight for this animal" -- one per
		-- cache, same reason the waypoint caches themselves are separate --
		-- so needs_new_path can avoid launching a second overlapping one
		-- while the main AI loop keeps ticking (and moving, via whatever
		-- waypoints/fallback it already has) instead of freezing solid
		-- until the slow computation returns.
		computing_path = false,
		computing_flee_path = false,
	}
end
-- Shared by every caller below that normally runs Threat_Tick (frenzied,
-- plain "threat" species, and a provoked "conditional" one) -- same
-- fallback in all three cases: wander instead of just standing still the
-- instant no player is within AggroRange this tick. Clears wander_target
-- the moment a player IS found, so a stale in-progress wander hop from
-- before this animal got engaged doesn't resume (and potentially read as a
-- weird detour) once it disengages again later.
local function Threat_Or_Wander(model, root, stats, ai_state, infected, attack_track)
	local player_in_aggro = Threat_Tick(model, root, stats, ai_state, infected, attack_track)
	if player_in_aggro then
		ai_state.wander_target = nil
	else
		Wander_Tick(root, stats, ai_state)
	end
	return player_in_aggro
end
-- Mirrors Threat_Or_Wander above, but for the two callers that normally run
-- Flee_Tick instead (plain-flee species, and a conditional-threat one that's
-- not currently provoked).
local function Flee_Or_Wander(root, stats, ai_state)
	local fleeing = Flee_Tick(root, stats, ai_state)
	if fleeing then
		ai_state.wander_target = nil
	else
		Wander_Tick(root, stats, ai_state)
	end
end
-- Replaces the old Run_Flee_AI/Run_Threat_AI/Run_Conditional_AI trio with
-- one loop per animal that reads entry.species_mode/entry.is_provoked/
-- entry.frenzied EVERY tick instead of picking a fixed behavior once at
-- spawn — Animal Frenzy needs to be able to flip a live Deer or a fleeing
-- Fox into full threat behavior mid-match, which a function chosen once
-- up front can't do. Per-species behavior when not frenzied is unchanged
-- from before this refactor. [stated/found] the "conditional" branch below
-- is currently unreachable in practice -- Buffalo/Fox (its only two
-- IsConditionalThreat species) are both out of the spawn pool right now --
-- left in place rather than removed, since it's generic per-species_mode
-- logic that resumes working the instant any species sets
-- IsConditionalThreat = true again.
local function Run_Animal_AI(entry)
	local model, root = entry.model, entry.root
	task.spawn(function()
		while model.Parent and not entry.dead do
			local tick_time = os.clock()
			local tick_position = root.Position
			-- [stated] "one deer that a ran into right before the event
			-- became stuck in place once the event had started, running
			-- their movement animation while not moving" -- see
			-- Update_Movement_Animation's own comment for the full
			-- reasoning: this measures REAL displacement since the start
			-- of the previous tick (one tick, ~0.1s, of lag) instead of
			-- reading AssemblyLinearVelocity right after this tick's own
			-- Move_Animal/Threat_Tick call just set it, so a collision-
			-- blocked animal (a player standing in its way, another
			-- animal, a tree) now correctly reads as near-zero speed
			-- instead of "moving at full WalkSpeed" forever.
			local elapsed = tick_time - entry.last_anim_tick_time
			local measured_speed = 0
			if elapsed > 0 then
				local delta = tick_position - entry.last_anim_position
				measured_speed = Vector3.new(delta.X, 0, delta.Z).Magnitude / elapsed
			end
			local ok, err = pcall(function()
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
						-- [debug] Should be unreachable for an infected animal —
						-- entry.frenzied is permanent once entry.infected is true
						-- and is checked FIRST, above, every tick. If this ever
						-- actually prints, entry.frenzied is somehow false on an
						-- infected entry — real bug to chase from here.
						if entry.infected then
							warn("[AnimalFrenzy DEBUG]", model.Name, "is INFECTED but fell through to Flee_Tick (conditional/not-provoked branch) — entry.frenzied =", tostring(entry.frenzied))
						end
						Flee_Or_Wander(root, entry.stats, entry.ai_state)
					end
				else
					if entry.infected then
						warn("[AnimalFrenzy DEBUG]", model.Name, "is INFECTED but fell through to Flee_Tick (plain-flee branch) — entry.frenzied =", tostring(entry.frenzied))
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
	-- [stated] "I removed the humanoid part in each animal... this was
	-- preventing the models from working correctly in animating them" --
	-- confirmed root cause of nothing spawning: this guard used to require
	-- BOTH humanoid and root and destroyed the clone if either was missing,
	-- so every single spawn attempt was silently destroying itself right
	-- here. HumanoidRootPart is still required (it's the model's physical
	-- anchor, and what Move_Animal/Stop_Animal above actually drive) but
	-- Humanoid no longer is.
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then
		warn("[WildLifeManager] " .. species_name .. " template has no HumanoidRootPart -- can't spawn")
		model:Destroy()
		return
	end
	root.Anchored = false -- physics (gravity, collision, knockback) still comes from here exactly as it did with Humanoid
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
		-- [stated] "one deer... became stuck in place... running their
		-- movement animation while not moving" -- seeded with this
		-- animal's actual spawn position/time so Run_Animal_AI's very
		-- first displacement measurement is correct (0 studs/s, since it
		-- hasn't moved yet) instead of comparing against a nil position.
		last_anim_position = root.Position,
		last_anim_tick_time = os.clock(),
		movement_tracks = nil, -- set just below -- nil if this species has no real animation IDs yet
		active_movement_track = nil,
		attack_track = nil, -- set just below -- nil if this species has no real Attack animation ID yet, Threat_Tick no-ops on nil same as before this existed
	}
	active_animals[entry] = true
	entry.movement_tracks = Load_Movement_Tracks(model, species_name)
	entry.attack_track = Load_Attack_Track(model, species_name)
	Start_Movement_Animation(entry)
	if species_mode == "conditional" then
		-- Flees normally, taking any damage flips it into threat mode (see
		-- Run_Animal_AI) for as long as a player stays in AggroRange, plus
		-- ANGER_LINGER_DURATION seconds after -- unchanged from before this
		-- refactor, just reading the Health ATTRIBUTE now instead of
		-- humanoid.HealthChanged. [stated/found] no species currently sets
		-- IsConditionalThreat (see WILDLIFE_STATS's own comment), so this
		-- branch isn't reached by anything spawning today -- left as-is,
		-- ready for whichever future species uses it.
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
	-- Replaces humanoid.Died:Connect -- fires Handle_Death the moment
	-- Health crosses to 0 or below, from whatever actually did the
	-- damage (PlayerCombat.lua's attack code, for now).
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
-- Animal Frenzy event, called from AnimalFrenzyEvent.lua. Every currently
-- alive animal gets AggroRange pushed to effectively infinite for
-- config.duration seconds (species that never had attack stats to begin
-- with — Deer/Rat — borrow FRENZY_FALLBACK_COMBAT_STATS for the duration so
-- "ALL animals become aggressive" is actually true, not just the ones
-- already built to fight). config.infected_count of them are additionally
-- marked infected and stay hyper-aggressive PERMANENTLY (never revert on
-- end_frenzy) — those are the ones a player needs a cure station for. Call
-- this AFTER spawning any reinforcement animals for the event so the new
-- arrivals get swept up into the same rampage/infection roll as everything
-- already on the map.
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
-- Reverts every non-infected animal back to its normal behavior/AggroRange.
-- Infected animals are left exactly as they are — the whole point of the
-- infection is that it doesn't wear off on its own.
function WildlifeManager.end_frenzy()
	for entry in pairs(active_animals) do
		if entry.frenzied and not entry.infected then
			entry.frenzied = false
			entry.stats = Copy_Stats(entry.natural_stats)
		end
	end
end
return WildlifeManager
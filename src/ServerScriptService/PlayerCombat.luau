-- Declaring game services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
-- [stated] bow draw reference models -- see the "Ranged weapons" section
-- below for why this is needed.
local ServerStorage = game:GetService("ServerStorage")
local ItemData = require(ReplicatedStorage:WaitForChild("ItemData"))
-- [stated] "display on the ground in front of the player a 2D cone showing
-- their attack range/angle when they swing" -- fired to exactly one client
-- (FireClient below, never FireAllClients) right where the real swing
-- animation plays in PlayerCombat.attack, i.e. only after cooldown/stamina
-- checks already passed -- see SwingConeTelegraph.lua (StarterPlayerScripts)
-- for the client-side visual itself, which is what actually enforces "only
-- visible to that player": an Instance a LocalScript creates and parents to
-- Workspace is never replicated to the server or any other client, so no
-- additional filtering is needed beyond this being a per-player FireClient.
-- Needs manual creation in ReplicatedStorage, same outstanding step as
-- every other RemoteEvent added this project. Carries the real swing
-- track's Length so the client's telegraph lingers for exactly as long as
-- the actual swing animation plays, rather than a guessed fixed duration
-- that could cut off early or run long -- [stated/found] "it cuts a bit
-- early during the swing animation" with the original fixed 0.4s guess was
-- exactly this mismatch.
local swing_telegraph_event = ReplicatedStorage:WaitForChild("SwingTelegraph")
local server_script = game:GetService("ServerScriptService")
local PlayerStamina = require(server_script:WaitForChild("PlayerStamina"))
local PlayerEquipment = require(server_script:WaitForChild("PlayerEquipment"))
local PlayerWeight = require(server_script:WaitForChild("PlayerWeight"))
local PlayerHunger = require(server_script:WaitForChild("PlayerHunger"))
local PlayerStats = require(server_script:WaitForChild("PlayerStats"))
-- [stated/found] "walk animations still moving too fast while sprint is
-- fine" -- used below in Get_Blended_Movement_Phase to pick the walk vs.
-- run phase multiplier off the player's REAL sprint request instead of
-- inferring it from Roblox's own default walk/run animation blend weights
-- -- see PlayerSprint.lua's own comment for why that inference broke
-- under the weight system.
local PlayerSprint = require(server_script:WaitForChild("PlayerSprint"))
local PlayerCombat = {}
PlayerCombat.blocking_players = {}
PlayerCombat.invulnerable_until = {}
-- [stated] "/dev text command that would make my character invincible" --
-- a standing flag rather than a timed window like the dodge's own
-- invulnerable_until below, checked first in is_invulnerable so it works
-- regardless of whatever that timer is doing. Every damage source that
-- already calls is_invulnerable (the melee hit-check here, ZombieEvent,
-- ForestFireEvent) picks this up automatically with no changes of its own.
PlayerCombat.dev_invulnerable = {}
local DODGE_STAMINA_COST = 25
local DODGE_INVULN_DURATION = 0.3
-- Dash redesign — [stated] target was "invulnerability window + a short
-- directional dash (backward if standing still)". Duration matches the
-- invuln window so the dash is over right as vulnerability comes back;
-- distance is scaled per weight tier the same way cost already was.
-- Placeholders, tune once tested.
local BASE_DASH_DISTANCE = 12 -- studs, at Standard weight tier
local DASH_DURATION = 0.3
-- [player] = the Heartbeat connection currently overriding that player's
-- velocity for an in-flight dash — tracked so a re-dodge (or the player
-- leaving) can cleanly cancel a still-running one instead of leaving two
-- connections fighting over the same HumanoidRootPart.
local active_dash_connections = {}
local BLOCK_STAMINA_DRAIN_PER_SECOND = 10
local BLOCK_DAMAGE_REDUCTION = 0.5
local ATTACK_WINDUP_DELAY = 0.25 -- seconds, matches the swing animation's windup
local COMBAT_TARGET_TAG = "CombatTarget"
-- Starting guesses — armor's damage reduction is percentage-based with
-- diminishing returns rather than a flat subtraction, so a heavy weapon
-- still meaningfully hurts a well-armored target instead of potentially
-- being reduced to near-nothing. Tune alongside the per-piece Defense
-- values in ItemData.
local DEFENSE_REDUCTION_PER_POINT = 0.02 -- 2% damage reduction per point of Defense
local MAX_DEFENSE_REDUCTION = 0.6 -- armor alone can't reduce damage by more than 60%
-- [stated] "Strength -> melee damage". Uncapped — Strength itself is
-- already effectively capped by how many stat items exist in the game.
local STRENGTH_DAMAGE_PER_POINT = 0.05
-- [stated] "Endurance -> reduced weapon attack stamina cost". Floored the
-- same shape as PlayerHunger/PlayerStamina's other Endurance reductions.
local ENDURANCE_ATTACK_COST_REDUCTION_PER_POINT = 0.05
local MIN_ATTACK_COST_FRACTION = 0.5
-- [stated] "Dexterity -> weapon swing speed" — shortens AttackCooldown.
-- Floored so a weapon can never swing faster than this fraction of its
-- own base cooldown, regardless of Dexterity.
local DEXTERITY_SWING_SPEED_PER_POINT = 0.04
local MIN_SWING_COOLDOWN_FRACTION = 0.5
-- [stated] "knockback (dealt+resisted) governed purely by stats for now,
-- not per-weapon" — dealt scales with the ATTACKER's Strength (same stat
-- that governs damage), resisted scales with the TARGET's Endurance
-- (same "toughness" role Endurance already plays for fall damage/hunger).
-- This stat assignment wasn't spelled out explicitly, just inferred from
-- each stat's existing theme — flag if a different pairing was intended.
-- Only horizontal (X/Z) velocity is touched, same as the dodge dash, so it
-- doesn't interact strangely with jumping/falling. A single impulse add
-- rather than the dash's continuous reassert — knockback is meant to be a
-- one-off shove that naturally decays, not a sustained override.
local BASE_KNOCKBACK_FORCE = 25
local STRENGTH_KNOCKBACK_DEALT_PER_POINT = 0.05
local ENDURANCE_KNOCKBACK_RESIST_PER_POINT = 0.05
local MAX_KNOCKBACK_RESIST_REDUCTION = 0.6
local last_attack_time = {}
-- Starting guesses — tune per weapon once you've published real swing
-- animations for the other two tiers. Reusing the pipe's swing for all
-- three is a fine starting point.
local WEAPON_SWING_ANIMATIONS = {
	["Tier1MacePipe"] = "rbxassetid://123175949781602",
	["Tier2MacePoliceBaton"] = "rbxassetid://123175949781602",
	["Tier3MaceFlangedMace"] = "rbxassetid://123175949781602",
	["Fists"] = "rbxassetid://115447738290945",
	-- [stated] all 3 axe tiers share one published swing clip for now,
	-- same "reuse across tiers" starting point as the maces above. Replace
	-- with the real published asset ID from the Animation Editor.
	["Tier1AxeWoodAxe"] = "rbxassetid://119725409532721",
	["Tier2AxeFireaxe"] = "rbxassetid://119725409532721",
	["Tier3AxeMilitaryAxe"] = "rbxassetid://119725409532721",
	-- [stated] "I've added the attack, move, and idle animation for the 1
	-- handed sword... for the time being just place in placeholder values
	-- which I'll change in myself." All 3 sword tiers (WeaponModel keys
	-- match ServerStorage.PlayerItems.Weapons.1HandSwords -- Tier1TrainingSword/
	-- Tier2HistoricalSword/Tier3MilitarySword) share one entry for now,
	-- same "reuse across tiers, split later" pattern as the axes/maces
	-- above -- drop the real published swing clip's asset ID in here.
	["Tier1TrainingSword"] = "rbxassetid://121781100536173",
	["Tier2HistoricalSword"] = "rbxassetid://121781100536173",
	["Tier3MilitarySword"] = "rbxassetid://121781100536173",
}
-- [stated] "I've made an animation for the bow firing" -- a separate table
-- from WEAPON_SWING_ANIMATIONS above even though the loading/caching/
-- playback mechanism (Get_Fire_Track below) is nearly identical, since a
-- bow release isn't a "swing" conceptually (no windup delay, no cone
-- telegraph, triggered from release_draw instead of attack) and keeping
-- them separate means a reader never has to wonder why a bow is sitting in
-- a table named for swinging. Keyed by WeaponModel, same convention as
-- every other per-weapon table in this file. Drop the real published
-- asset ID from the Animation Editor in place of the placeholder below.
local WEAPON_FIRE_ANIMATIONS = {
	["Empty Bow"] = "rbxassetid://107808555659870",
}
-- Continuous "weapon is out" poses — NOT one-off actions like the swing.
-- Idle/Move only need to be authored on the arm/shoulder/wrist joints (see
-- the animating discussion) so they layer over Roblox's own default
-- leg/torso walk-run without fighting it; Block is a held stance for
-- however long the block button is down. Weapons with no entry here (mace,
-- fists) just keep using the default Animate idle/walk/run untouched.
-- [stated] sword's Idle/Move (no Block yet) -- same placeholder-for-now
-- treatment as WEAPON_SWING_ANIMATIONS above, same shared-across-tiers
-- starting point. Get_Hold_Tracks already handles WEAPON_BLOCK_ANIMATIONS
-- having no entry for these keys (Load(nil, false) returns nil, start_
-- block's tracks.Block check just skips it), so swords simply won't have
-- a block stance until one's added -- no code change needed for that.
-- [stated/found] "the sword movement animation is very slow compared to
-- the leg movement" -- the old fix here was a per-weapon MoveSpeedMultiplier
-- scaling the Move track's playback SPEED to try to match the legs.
-- [stated, forum-sourced] that approach can never fully lock two tracks
-- together -- both are still independent clocks accumulating their own
-- time, so any tiny per-frame mismatch compounds until they're visibly out
-- of step, then happen to realign for a moment before drifting again.
-- Replaced with real position-locking instead -- see Get_Blended_Movement_
-- Phase/Start_Move_Sync and the Move:AdjustSpeed(0) freeze in Get_Hold_
-- Tracks below.
-- [stated/found] "found a timelength which pairs well with the sprint
-- cycle, but during the normal cycle it looks too fast" -- confirms
-- Roblox's own default walk and run clips don't represent the same AMOUNT
-- of visual stride per their own Length (one's 0..1 phase spans more of a
-- full gait cycle than the other's does), so a clip tuned to match one
-- will always be off against the other -- a single flat correction can't
-- fix both at once. MoveWalkPhaseMultiplier / MoveRunPhaseMultiplier (read
-- in Get_Blended_Movement_Phase below, applied per PlayerSprint.is_sprinting
-- rather than per-track now) are SEPARATE knobs (defaults to 1, i.e. no
-- change, for either one left unset).
-- [stated/found] "upper animation is certainly still too fast" even once
-- weight/blend-inference issues were ruled out and tested at the true,
-- unmodified baseline (WalkSpeed 16/28, no tier multiplier at all) for
-- BOTH walking and sprinting -- so the original 1:1-with-run assumption
-- behind these numbers was simply wrong, not just a weight-tier artifact.
-- [stated] "I would say it's double the speed it needs to be" -- that
-- estimate was about SPRINT specifically ("I'm now seeing the sprinting
-- have too fast animation"), but got applied to both knobs: walk was
-- halved too (0.5 -> 0.25) even though walk was never reported as too
-- fast at that point.
-- [stated/found] "during the latest test I found the walking animations
-- to be almost cut off" -- that walk halving was wrong: it doubled up an
-- already-correct walk multiplier instead of just fixing sprint. Reverted
-- MoveWalkPhaseMultiplier back to 0.5 (its pre-halving value) and left
-- MoveRunPhaseMultiplier at 0.5, so the "double speed" correction only
-- ever applies while PlayerSprint.is_sprinting(player) is true, never to
-- walking. Still not a measured ratio like the axe's earlier Length-based
-- 0.78 -- flag if sprint still isn't quite right once retested, and
-- whether sword/mace (sharing these same two values today) need their own
-- separate tuning once tried.
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
-- Idle/Move/Block sit at Action priority so they cleanly override the
-- default Animate script's own baked-in arm swing on walk/run/idle (same
-- trick the legacy Tool system uses for toolnone/toolslash). The swing
-- itself is bumped to Action2 below specifically so it fully overrides
-- these continuous poses for its duration instead of permanently blending
-- 50/50 with whichever one is playing underneath — see Get_Swing_Track.
local HOLD_POSE_FADE_TIME = 0.15
-- [stated] "the animation will play completely then end, rather than
-- holding the final frame of the animation, even if the player continues
-- to hold the click ... Let's start with holding the final frame of the
-- animation until it's released" -- a non-looping AnimationTrack stops
-- itself the instant TimePosition reaches Length, which happens on its
-- own clock regardless of how long the player is still holding the draw.
-- The fix (see the Heartbeat loop in Setup_Bow) is to catch it just
-- BEFORE that happens each frame while still drawing -- clamp
-- TimePosition to Length minus this small cushion and freeze playback
-- (AdjustSpeed(0)) so it never actually reaches its own natural end and
-- never auto-stops. Needs to be small enough that the hold isn't visibly
-- a frame or two early, but bigger than a single frame's worth of normal
-- playback so the >= check reliably catches it instead of occasionally
-- stepping past Length first.
local FIRE_TRACK_HOLD_EPSILON = 0.03
local loaded_swing_tracks = {} -- [player] = {[weapon_model_name] = AnimationTrack}
local loaded_fire_tracks = {} -- [player] = {[weapon_model_name] = AnimationTrack} -- see Get_Fire_Track/WEAPON_FIRE_ANIMATIONS
local loaded_hold_tracks = {} -- [player] = {[weapon_model_name] = {Idle=, Move=, Block=}}
local active_hold_track = {} -- [player] = the one AnimationTrack currently playing from Idle/Move/Block (or nil)
local hold_pose_connections = {} -- [player] = Humanoid.Running connection, only while a hold-pose weapon is equipped -- picks Idle vs Move
local move_sync_connections = {} -- [player] = Heartbeat connection position-locking the Move track's TimePosition to the live default leg track, only while a hold-pose weapon is equipped -- see Start_Move_Sync
-- Fallback unarmed combat stats — used whenever nothing is equipped in the
-- Weapon slot. Kept standalone so a future zombie AI module can reuse
-- these same stats for melee attacks, rather than duplicating them.
-- WeaponModel is a pure lookup key into WEAPON_SWING_ANIMATIONS — no real
-- model needs to exist under that name.
local FIST_DATA = {
	Damage = 5,
	Range = 4,
	ConeAngle = 70,
	AttackStaminaCost = 0, -- always available, even at 0 stamina
	AttackCooldown = 0.4,
	WeaponModel = "Fists",
}
-- Loads (once per character) and caches an AnimationTrack for the given
-- weapon, so repeated swings reuse the same track instead of reloading it
-- every attack.
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
	-- Action2 -- one tier above the Idle/Move/Block hold-pose tracks
	-- (Action), so a swing fully overrides them for its duration instead
	-- of the two blending together at equal weight the whole time it
	-- plays. Roblox still crossfades smoothly in/out via each track's own
	-- fade time; this only changes who wins while both have weight.
	track.Priority = Enum.AnimationPriority.Action2
	loaded_swing_tracks[player][weapon_model_name] = track
	return track
end
-- Same load-once-per-character-and-cache shape as Get_Swing_Track above,
-- just reading WEAPON_FIRE_ANIMATIONS instead. [stated/found] "the bow
-- draw animation only fires after I let go of left click, when it should
-- start when the player starts the left click hold" -- this used to only
-- ever get :Play()'d from release_draw, i.e. the instant a bow/sling
-- actually fires, which is backwards for a single clip meant to show the
-- WHOLE hold-to-charge motion: now played from start_draw instead, the
-- moment the draw itself begins, not from attack(). Letting it just keep
-- running after release (nothing here stops it) means it plays out to
-- its own natural length regardless of how long the player actually
-- held -- [ASSUMPTION, flag if wrong] fine for a snap-release landing
-- partway through the clip, since that's what a cut-short real draw
-- would look like too, but if you want the clip's TIMING itself to
-- track the live draw fraction (e.g. visibly pause mid-pull on a long
-- hold, or compress to fit a quick one) that's a separate ask -- this
-- only fixes WHEN it starts. Action2 for the same reason the swing track uses it: so it fully
-- overrides whatever Idle/Move hold-pose (or, for a bow, nothing -- see
-- the "Ranged weapons" section's own animation table, WEAPON_HOLD_POSE_
-- ANIMATIONS) is currently playing, for its own duration, rather than
-- blending with it the whole time.
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
-- Loads (once per character) and caches the continuous Idle/Move/Block
-- tracks for weapon_model_name. Returns nil if this weapon has no
-- hold-pose entry at all (mace, fists) -- callers treat that as "leave
-- the default Animate idle/walk/run alone".
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
	-- Idle/Move loop forever by design (continuous resting/walking poses).
	-- Block does NOT loop -- it plays forward once (idle -> raised) and
	-- start_block below takes over from there, pinning it at its final
	-- frame once it naturally finishes. [stated/found] a non-looping
	-- AnimationTrack does NOT hold its last frame automatically -- it
	-- releases control back to whatever's underneath once it ends, so that
	-- pinning in start_block (Stopped -> replay at TimePosition=Length,
	-- Speed=0) is doing real work, not just a safety net.
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
	-- [stated, forum-sourced] position-locking, not speed-matching -- frozen
	-- here once at load time rather than ever being driven by AdjustSpeed
	-- again. Start_Move_Sync (see below) externally pins this track's
	-- TimePosition to the live default leg track every frame instead, so it
	-- never needs -- or gets -- a clock of its own to drift out of sync.
	if tracks.Move then
		tracks.Move:AdjustSpeed(0)
	end
	loaded_hold_tracks[player][weapon_model_name] = tracks
	return tracks
end
-- ============================================================
-- Ranged weapons -- charge-and-release draw (bows AND slings)
-- ============================================================
-- [stated] "I was thinking I could in the animations for the bows I could
-- have an actual drawing of the bow animation which would stretch the 2
-- string pieces while pulling the arrow back for a more realistic weapon
-- animation. Is that possible?" -- yes, but not through the normal
-- Animation/AnimationTrack system Get_Swing_Track/Get_Hold_Tracks use
-- above -- a skeletal Animation can only rotate/translate rigid Motor6D
-- joints, it can never keyframe a part's own Size to make it visibly
-- stretch. The "stretch" VisualStyle below is a procedural substitute
-- instead: every frame, while the weapon is equipped, each tracked part's
-- CFrame AND Size are Lerp'd between two READ poses, not guessed numbers
-- -- "rest" is that part's own live CFrame/Size the moment the weapon is
-- equipped, "full draw" is read ONCE from a second, never-shown reference
-- model (BOW_DATA[...].DrawReferenceModel) -- so the artist's own two
-- already-commissioned models ("Empty Bow"/"Drawn Bow") ARE the tuning
-- data, nothing here hardcodes a stretch distance.
-- [stated/found] "I do plan to do a similar hold and release mechanic for
-- the sling ... it would have a different wind up and fire animation, but
-- still hold and release for attacks" -- a sling has no rigid "frame" part
-- the way a bow does (it's just cord + pouch, see the Explorer screenshot:
-- Sling Pouch/Uppersling String/Lowersling String/Stone, no separate
-- handle), and winding one up is a continuous swing, not a pull toward one
-- fixed end pose -- a straight Lerp-to-a-target-pose doesn't fit that
-- motion at all. BOW_DATA entries now carry a VisualStyle field: "stretch"
-- (default, the bow's Lerp-to-a-read-pose system, unchanged from before)
-- or "spin" (new, for the sling) -- a continuous rotation around a pivot,
-- speeding up the longer the draw is held, with no DrawReferenceModel/
-- target pose involved at all. Both styles share the exact same
-- start_draw/release_draw/Fire_Projectile mechanics (same charge-by-
-- holding input, same damage/range/speed/accuracy-by-draw-fraction
-- formulas) -- only the per-frame VISUAL differs, same split the user's
-- own words draw between "wind up and fire animation" (different) and
-- "hold and release for attacks" (same).
-- [stated] confirmed mechanic: "Hold to charge, release to fire" -- draw
-- fraction is time-held / MaxDrawTime, clamped to 1 (see start_draw/
-- release_draw below). Damage/range/projectile speed/accuracy all scale
-- off that same fraction (see Fire_Projectile) -- a snap-release still
-- fires something, just a weak, short, inaccurate one.
-- [STUDIO REQUIREMENT, not yet confirmed] every part named in a BOW_DATA
-- entry's TrackedParts/ProjectilePart must not have a live WeldConstraint/
-- Weld/Motor6D rigidly linking it to BowPart (or, for a "spin" weapon with
-- no BowPart, to anything at all) -- Strip_Rigid_Constraints below
-- defensively destroys one if it finds it at equip time, but these parts
-- need to be free for THIS script alone to position every single frame
-- the weapon is equipped (not just while actively drawing -- see
-- Setup_Bow's Heartbeat), or they'll fight whatever else is also trying
-- to hold them in place.
-- [stated/found, confirmed against PlayerEquipment.lua] Attach_Weapon's
-- Model branch parents the whole cloned weapon (Name preserved from the
-- template, e.g. "Empty Bow"/"Sling") directly onto the character, same
-- as every single-part weapon already does -- so a plain recursive
-- FindFirstChild by that same name finds it correctly, no change needed
-- here.
local function Find_Equipped_Weapon_Model(character, weapon_model_name)
	return character:FindFirstChild(weapon_model_name, true)
end
-- [stated/found, confirmed against PlayerEquipment.lua] Find_Weapon_Template
-- there searches the WHOLE ServerStorage.PlayerItems tree (no ".Weapons"
-- subfolder requirement -- that was only ever a guess here, since fixed),
-- so the never-equipped "Drawn Bow" reference model is looked up the exact
-- same way for consistency, even though it's never actually passed through
-- Find_Weapon_Template itself.
local cached_reference_models = {} -- [DrawReferenceModel name] = Model -- found once, reused by every player/equip (same reference geometry for everyone)
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
-- [stated/found] "character started stuttering around the map, eventually
-- being flung off the map entirely" the first time a bow was equipped,
-- with the bow never even visible -- this used to only check for a
-- constraint PARENTED TO the exact part being stripped. If the "Empty
-- Bow" template was actually rigged the other way around (e.g. a
-- WeldConstraint sitting ON the Bow part, pointing OUT at a string --
-- just as valid a way to build it in Studio as the reverse), that
-- constraint was never found or destroyed at all, since it was never
-- being looked for on the right part. Every frame after that, this
-- script's own direct CFrame writes on that string fought the surviving
-- weld's enforced fixed offset -- and because Bow is itself rigidly
-- welded to the hand, that fight propagated straight through into the
-- character rig, which is exactly the kind of violent, cascading
-- correction that flings an unanchored assembly around. Sweeping the
-- WHOLE model once and matching by Part0/Part1 IDENTITY instead catches
-- a rigid link between any two tracked parts (or between a tracked part
-- and the pivot) no matter which side of it happens to be parented where.
-- [stated/found] "as soon as I equipped the bow I saw the whole model
-- fall through the floor" -- a regression from the fix above. Attach_Weapon
-- (PlayerEquipment.lua) welds the WHOLE weapon model to the player's hand
-- through exactly ONE WeldConstraint, from the model's PrimaryPart to
-- RightHand -- but if "Empty Bow" never got an explicit PrimaryPart set in
-- Studio, Attach_Weapon's own fallback (`clone.PrimaryPart or
-- clone:FindFirstChildWhichIsA("BasePart")`) can land on ANY BasePart in
-- the model, including one of the tracked parts this function is sweeping
-- for (Lowerstring/Upperstring/Arrow). When that happens, that one
-- hand-to-weapon weld touches a tracked part too, so the old version of
-- this sweep destroyed it right along with any genuine internal rig weld
-- -- severing the ONLY thing holding the entire model to the hand, not
-- just a string, which is exactly "the whole model" (unanchored,
-- non-colliding) falling straight through the floor under gravity. The
-- fix doesn't depend on knowing or fixing which part ended up as
-- PrimaryPart -- it only strips a weld whose BOTH ends sit inside this
-- same model. The hand weld always has one end OUTSIDE it (the
-- character's RightHand), so it can never match this check, while any
-- real internal string/arrow-to-Bow rig weld (both ends inside the
-- model) still gets caught exactly as before. [STUDIO RECOMMENDATION,
-- still worth doing as a second safety net, just no longer required for
-- this specific bug] explicitly set "Empty Bow"'s PrimaryPart to "Bow" in
-- Studio.
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
-- Reads every named part's CFrame/Size relative to anchor_part (NOT world
-- space) -- the weapon itself constantly moves/rotates with the player's
-- hand, so every pose captured this way stays correct regardless of where
-- the weapon currently is; the follow-loop in Setup_Bow converts back to
-- world space fresh every single frame.
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
-- [stated] "mark the ends of the string where they touch the bow as
-- attachment points, then during the bow draw animation weld the middle 2
-- strings to the player's hand so they stick to it" -- a literal
-- Weld/WeldConstraint only holds a FIXED relative offset between two
-- parts, it can't make a part longer, so welding wouldn't actually
-- produce a stretching string. The underlying idea is still exactly
-- right though: a fixed point at the bow, a point that tracks the hand,
-- the string spanning the two -- just computed fresh every frame instead
-- of a literal constraint. This replaces the old "Lerp toward a second
-- reference model's authored pose" system entirely for a "stretch"-style
-- weapon's strings and projectile -- see Setup_Bow's own comment on
-- string_tip_attachments/nock_rest_attachment for the full picture.
-- Which of a Size's 3 axes is the longest -- used both to know which
-- component to replace with a freshly-computed live length each frame,
-- and to know which local axis of the part's own CFrame that live
-- direction needs to be pointed along.
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
-- Builds a CFrame spanning point_a to point_b, with whichever local axis
-- rest_size says is longest pointed along that live direction -- works
-- regardless of whether a given string happened to be modeled running
-- along its own local X, Y, or Z. up_hint only resolves the remaining
-- rotational ambiguity (which way "up" is along the string's length) --
-- it doesn't need to be exact, just stable and roughly correct, so the
-- string doesn't visibly twist/flip frame to frame. Verified against a
-- concrete numeric example for all 3 axis cases -- each branch below is a
-- right-handed (not mirrored) basis, not an arbitrary guess.
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
-- Which local axis the Arrow's shaft runs along, and how far half its
-- length reaches from its own center, figured out from its live Size the
-- same "infer, don't hardcode" way the strings use (see Get_Long_Axis
-- above). The SIGN (whether the nock end is the positive or negative tip
-- along that axis) is picked by whichever of the two candidate offsets
-- currently lands closer to the live NockRestAttachment, so this keeps
-- working regardless of which way the arrow happened to be modeled.
-- Pulled out of Setup_Bow into its own function so a draw-spawned arrow
-- (see Spawn_Draw_Arrow/start_draw below) can compute this fresh too,
-- not just one that already existed on the model at equip time. Returns
-- nil if either argument is missing.
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
-- [stated] "for now don't add the arrow to the bow, I'd only want to add
-- it during the draw animation as I have it figured into the animation of
-- the player grabbing an arrow from their back" -- clones a fresh Arrow
-- from the DrawReferenceModel template the instant a draw actually starts
-- (see start_draw), rather than one sitting nocked on the bow the whole
-- time it's equipped. Returns nil if there's nothing to clone from (no
-- DrawReferenceModel, or that reference has no part by this name) --
-- every caller already treats a nil projectile_part as "nothing to
-- fire/animate", so this fails soft.
local function Spawn_Draw_Arrow(bow_model, pivot_part, bow_data)
	local reference_model = bow_data.DrawReferenceModel and Get_Reference_Model(bow_data.DrawReferenceModel)
	local reference_projectile = reference_model and reference_model:FindFirstChild(bow_data.ProjectilePart)
	if not reference_projectile then
		return nil
	end
	local projectile_part = reference_projectile:Clone()
	-- This clone never goes through Attach_Weapon's clone/weld pipeline
	-- (it's spawned later, straight off the inert reference model sitting
	-- in ServerStorage) -- Anchored/CanCollide need setting directly here,
	-- matching every other tracked part (see Setup_Bow's own Anchored
	-- comment), and any stray weld the reference model happened to carry
	-- gets swept the same defensive way Strip_Rigid_Constraints_Touching
	-- already does for the rest of the bow.
	projectile_part.Anchored = true
	projectile_part.CanCollide = false
	for _, instance in ipairs(projectile_part:GetDescendants()) do
		if instance:IsA("WeldConstraint") or instance:IsA("Weld") or instance:IsA("Motor6D") then
			instance:Destroy()
		end
	end
	projectile_part.Parent = bow_model
	-- Placeholder for this one instant -- the Heartbeat follow-loop
	-- repositions it for real (relative to the live nock point) before
	-- the next frame ever renders.
	projectile_part.CFrame = pivot_part.CFrame
	return projectile_part
end
local active_bow_draws = {} -- [player] = {pivot_part=, projectile_part=, arrow_local_offset=, nock_rest_attachment=, projectile_is_temporary=, drawing=, draw_start_time=, spin_angle=, bow_data=} -- drawing/draw_start_time/spin_angle/projectile_part/arrow_local_offset/projectile_is_temporary are what start_draw/release_draw/the follow-loop actually drive; pivot_part/nock_rest_attachment/bow_data are set once by Setup_Bow and never change across draws
local bow_follow_connections = {} -- [player] = Heartbeat connection continuously holding tracked parts in position relative to the pivot -- runs for as long as the weapon stays equipped, not just while actively drawing (fraction/spin just sits at rest the rest of the time), since these parts no longer have a weld doing that passively (see Strip_Rigid_Constraints)
local function Teardown_Bow(player)
	if bow_follow_connections[player] then
		bow_follow_connections[player]:Disconnect()
		bow_follow_connections[player] = nil
	end
	active_bow_draws[player] = nil
end
-- Called from refresh_weapon_animations the moment a bow/sling becomes the
-- equipped Weapon -- mirrors how Get_Hold_Tracks/Set_Active_Hold_Track get
-- (re)wired on every equip change for melee weapons, just for a
-- completely different (procedural, not AnimationTrack-based) visual
-- system.
local function Setup_Bow(player, character, weapon_model_name, bow_data)
	Teardown_Bow(player)
	local bow_model = Find_Equipped_Weapon_Model(character, weapon_model_name)
	if not bow_model then
		warn("[PlayerCombat] equipped ranged weapon '" .. weapon_model_name .. "' not found under " .. player.Name .. "'s character -- Attach_Weapon in PlayerEquipment.lua may have failed to clone/parent it (check its own warnings) rather than this lookup being wrong")
		return
	end
	-- [stated/found] a sling has no rigid "frame" part the way a bow's
	-- Bow part is (it's just cord + pouch) -- BowPart is optional for
	-- exactly that reason: when a BOW_DATA entry omits it, the player's
	-- own hand is the pivot every tracked part is positioned relative to
	-- instead of a named part on the model.
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
	-- [stated] "for now don't add the arrow to the bow, I'd only want to
	-- add it during the draw animation as I have it figured into the
	-- animation of the player grabbing an arrow from their back" -- no
	-- fallback-clone-at-equip-time any more: if "Empty Bow" (or any other
	-- "stretch"-style weapon) has no Arrow of its own already sitting on
	-- the model, projectile_part simply stays nil here until start_draw
	-- spawns one fresh (see Spawn_Draw_Arrow). The Sling's own equipped
	-- model already includes its Stone directly, so this is a no-op for
	-- it either way.
	local projectile_part = bow_model:FindFirstChild(bow_data.ProjectilePart)
	if projectile_part then
		tracked_parts[bow_data.ProjectilePart] = projectile_part
	end
	-- Build the identity-keyed lookup set BEFORE stripping anything -- the
	-- sweep needs every tracked Instance up front, not discovered and
	-- stripped one at a time as each is found.
	local parts_set = {}
	for _, part in pairs(tracked_parts) do
		parts_set[part] = true
	end
	Strip_Rigid_Constraints_Touching(bow_model, parts_set)
	-- [stated/found, confirmed via debug print] "the player falls through
	-- the ground immediately after equipping the bow" -- a [BowDebug]
	-- print on the actual failing run showed PrimaryPart='Upperstring',
	-- not 'Bow', on this exact model -- "Empty Bow" never got an explicit
	-- PrimaryPart set in Studio, so Attach_Weapon's own fallback
	-- (clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart"))
	-- landed on whichever BasePart happened to come first instead. Its
	-- ONE hand-weld (PrimaryPart->RightHand) is still exactly where that
	-- leaves it: rigidly holding Upperstring to the hand, which is a part
	-- this script already drives directly every frame and never needed a
	-- weld for -- while pivot_part ("Bow"), the one part that actually
	-- needs to follow the hand, has NOTHING holding it up at all.
	-- Unanchored and unconstrained, it free-falls under gravity from the
	-- instant Attach_Weapon parents it in (confirmed by a throttled debug
	-- print of pivot_part.Position dropping from ~2 studs to -5 to -60 in
	-- barely a second, textbook freefall acceleration) -- and since every
	-- tracked part's live CFrame is computed FROM pivot_part's own
	-- Attachments each frame (see the Heartbeat loop below), the whole
	-- visible bow falls right along with it, reading as the player
	-- falling through the map. Rather than just relying on PrimaryPart
	-- being set correctly in Studio going forward (still worth doing, but
	-- not required any more), this finds and destroys whatever rigid
	-- constraint Attach_Weapon actually attached to PrimaryPart, then
	-- recreates it fresh, in the same spot, pointed at pivot_part
	-- instead -- fixing the one part that actually needs the weld,
	-- without ever touching Attach_Weapon's own code, and sidestepping a
	-- second latent problem for free: PrimaryPart (Upperstring) is about
	-- to be Anchored by the loop just below, and an Anchored part left on
	-- one end of a live WeldConstraint to the hand is its own kind of
	-- landmine, better gone than merely untested.
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
	-- [stated/found] "the bowstring will glitch and stutter in and out
	-- constantly, often not staying with the bow" -- Attach_Weapon (in
	-- PlayerEquipment.lua) un-anchors EVERY BasePart on the weapon clone,
	-- strings and arrow included, so its PrimaryPart-to-hand
	-- WeldConstraint behaves like a normal rig attachment. That's correct
	-- for the one part actually held by that weld, but every tracked part
	-- here just had its OWN internal rigid constraint torn out by
	-- Strip_Rigid_Constraints_Touching above -- with nothing left to hold
	-- them and Anchored still false, gravity (and whatever else the
	-- physics engine integrates) fights this Heartbeat loop's CFrame
	-- write every single frame, which is exactly what reads as
	-- stuttering/drifting rather than smoothly tracking the bow.
	-- Anchoring them removes them from physics entirely, so the ONLY
	-- thing moving them from here on is this script's own writes --
	-- "Bow" itself (pivot_part) is deliberately left alone, since it's
	-- the one part that's actually supposed to keep following the hand
	-- through its own WeldConstraint.
	for _, tracked_part in pairs(tracked_parts) do
		tracked_part.Anchored = true
	end
	-- rest_pose is still exactly what a "spin"-style weapon (the sling)
	-- needs -- its whole pouch+cord assembly orbits the pivot as one
	-- rigid unit, nothing about that changes here. A "stretch"-style
	-- weapon (the bow) no longer uses rest_pose past this point -- see
	-- below.
	local rest_pose = Capture_Pose_Relative_To(pivot_part, tracked_parts)
	-- [stated/found] "the bowstring and arrow seem to be pushing on the
	-- character constantly and disconnected from the bow itself" -- the
	-- old system captured each string's position ONCE, relative to Bow,
	-- at equip time, and trusted that single snapshot forever after.
	-- Whatever exactly made that snapshot wrong (most likely: however
	-- Lowerstring/Upperstring/Arrow were originally positioned in Studio
	-- relative to Bow just doesn't read as "touching the bow" once
	-- isolated from whatever rig/pose they were modeled against), the
	-- fix isn't a better capture -- it's not reading the existing parts'
	-- own baked geometry for this at all. These Attachments, placed
	-- under Bow by hand in Studio, are the new single source of truth:
	-- UpperStringTip/LowerStringTip mark the two FIXED bow-end points
	-- (read live every frame via Attachment.WorldPosition, so they can
	-- never go stale the way a one-time capture could), and
	-- StringRestNock marks where the string+arrow sit when undrawn --
	-- its rotation also doubles as the arrow's resting orientation,
	-- purely cosmetic, since Fire_Projectile below aims off the player's
	-- own facing, never off this attachment. Only set up for a
	-- "stretch"-style entry that actually defines StringTipAttachment --
	-- the sling has no use for any of this.
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
		-- [ASSUMPTION, flag if wrong] a bow gripped in RightHand (see
		-- Attach_Weapon) is assumed drawn with the OTHER hand -- swap
		-- this if your actual draw animation pulls with a different one.
		draw_hand = character:FindFirstChild("LeftHand")
		if not draw_hand then
			warn("[PlayerCombat] no LeftHand found on " .. player.Name .. "'s character -- the draw won't have anywhere live to track for '" .. weapon_model_name .. "'")
		end
	end
	-- One-time, NOT per-frame -- each string's own Size at this exact
	-- moment (right after Attach_Weapon's clone/scale, before this
	-- script ever touches it) is the "rest" cross-section/length this
	-- system treats as ground truth; every later frame only ever
	-- replaces the long-axis component (see Build_Beam_CFrame/
	-- Set_Long_Axis_Size), never the other two.
	local string_rest_info = {}
	if string_tip_attachments then
		for tracked_name in pairs(string_tip_attachments) do
			local part = tracked_parts[tracked_name]
			if part then
				string_rest_info[tracked_name] = part.Size
			end
		end
	end
	-- Only meaningful here for a weapon that genuinely carries its own
	-- persistent Arrow at equip time -- nil for "Empty Bow" today, since
	-- projectile_part is nil at this point for it (see above). A
	-- draw-spawned arrow computes this itself, fresh, right after
	-- cloning -- see start_draw.
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
		-- [stated/found, confirmed via test] "Let's start with holding the
		-- final frame of the animation until it's released" -- see
		-- FIRE_TRACK_HOLD_EPSILON's own comment for why this has to happen
		-- just BEFORE the track's natural end rather than after. Runs
		-- every frame the weapon is equipped (not gated on VisualStyle),
		-- so it applies the same way to a "spin"-style weapon's own
		-- fire/draw track too. Confirmed holding correctly in-game
		-- (TimePosition pinned at Length-epsilon for the whole hold,
		-- resuming cleanly on release).
		if draw_state and draw_state.drawing and draw_state.fire_track and not draw_state.fire_track_held then
			local track = draw_state.fire_track
			if track.Length > 0 and track.TimePosition >= track.Length - FIRE_TRACK_HOLD_EPSILON then
				track.TimePosition = track.Length - FIRE_TRACK_HOLD_EPSILON
				track:AdjustSpeed(0)
				draw_state.fire_track_held = true
			end
		end
		if bow_data.VisualStyle == "spin" then
			-- [stated/found] "different wind up ... animation" -- winding
			-- up a sling is a continuous swing, not a pull toward one
			-- fixed pose: spin_angle accumulates every tick while
			-- drawing, at a speed that itself ramps up with the draw
			-- fraction (so it visibly speeds up the longer it's held),
			-- and resets the instant drawing stops. Rotating the REST
			-- pose (not just spinning each part in place) around the
			-- pivot's own origin is what makes the whole pouch+stone+
			-- cord assembly orbit together like a weight on a string,
			-- rather than each part just spinning on its own axis.
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
			-- [stated] "weld the middle 2 strings to the player's hand so
			-- they stick to it" -- draw_point IS that shared "middle"
			-- point: at rest it's just the live, undrawn nock Attachment
			-- position (already tracking Bow's own live movement, since
			-- Attachment positions update automatically with their
			-- parent), blending toward the drawing hand's own live
			-- position as fraction climbs. Both strings AND the arrow's
			-- nock end share this exact same point, same as a real bow.
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
			-- [stated] a draw-spawned arrow is a DIFFERENT Instance every
			-- draw now (see start_draw/release_draw), so this reads
			-- draw_state fresh every frame rather than the Setup_Bow-time
			-- projectile_part/arrow_local_offset upvalues above, which
			-- only ever reflect whatever existed at equip time (nil, for
			-- a weapon with no Arrow of its own).
			local live_projectile_part = draw_state and draw_state.projectile_part
			local live_arrow_local_offset = draw_state and draw_state.arrow_local_offset
			if live_projectile_part and live_arrow_local_offset and live_projectile_part.Parent then
				-- Rotation stays fixed at whatever NockRestAttachment was
				-- authored with (purely cosmetic, see its own comment) --
				-- only the position slides, so the arrow visibly pulls
				-- straight back with the string instead of rotating.
				live_projectile_part.CFrame = CFrame.new(draw_point) * nock_rest_attachment.WorldCFrame.Rotation * CFrame.new(-live_arrow_local_offset)
			end
		end
	end)
	active_bow_draws[player] = {
		pivot_part = pivot_part,
		projectile_part = projectile_part,
		arrow_local_offset = arrow_local_offset,
		nock_rest_attachment = nock_rest_attachment,
		projectile_is_temporary = false, -- flips true only for an arrow start_draw spawns fresh -- see Spawn_Draw_Arrow/release_draw
		bow_data = bow_data,
		drawing = false,
		spin_angle = 0,
	}
end
-- Fires a flying copy of the (visually drawn-back, or wound-up) projectile
-- -- the original projectile_part stays in the weapon for the next draw,
-- snapping back to rest the instant drawing goes false. Kinematic
-- (Anchored, hand-driven Position every step) rather than
-- physics-velocity-based, with a short raycast each step between the old
-- and new position -- avoids both tunneling through a fast-moving target
-- AND any physics weirdness (bouncing, picking up a weld, friction) a real
-- unanchored projectile could run into; same "advance a known amount,
-- raycast the gap" shape FloodEvent.lua's own terrain sampling already
-- uses elsewhere in this project, just per-frame instead of a one-off
-- grid. Launch direction is always the player's own facing (root.CFrame.
-- LookVector) plus a random accuracy-cone offset, exactly like the bow,
-- even for the sling's spin-style wind-up -- [stated] only the wind-up/
-- fire ANIMATION was asked to differ, not the actual aim/launch math, so
-- this deliberately doesn't try to compute a true tangent-of-the-swing
-- release direction off the sling's literal spin position.
local PROJECTILE_RAYCAST_PARAMS = RaycastParams.new()
PROJECTILE_RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
local function Fire_Projectile(player, character, root, bow_data, template_projectile_part, draw_fraction)
	local damage = Lerp_Number(bow_data.MinDamage, bow_data.MaxDamage, draw_fraction)
	local speed = Lerp_Number(bow_data.MinProjectileSpeed, bow_data.MaxProjectileSpeed, draw_fraction)
	local range = Lerp_Number(bow_data.MinRange, bow_data.MaxRange, draw_fraction)
	-- [stated] "draw % affecting ... accuracy" -- wider cone at a low
	-- draw, same cone-check CONCEPT PlayerCombat.attack already uses for
	-- melee, just applied as a one-time random aim offset at the moment
	-- of firing rather than a persistent hit-check region.
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
			-- Only players and CombatTarget-tagged NPCs are valid damage
			-- targets -- same gate Get_Combat_Targets uses for melee,
			-- just checked directly here since there's no cone list to
			-- build for a single raycast hit.
			if hit_model and (hit_player or CollectionService:HasTag(hit_model, COMBAT_TARGET_TAG)) then
				local hit_humanoid = hit_model:FindFirstChild("Humanoid")
				-- Same duck-typed Humanoid-vs-Health-attribute pattern
				-- PlayerCombat.attack already uses, so Humanoid-less
				-- wildlife still takes damage correctly from an arrow or
				-- a sling stone alike.
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
			-- Hit something that isn't a valid, currently-vulnerable
			-- target (scenery, terrain, an invulnerable player) -- leave
			-- the projectile stuck there rather than destroying it, same
			-- "embeds on impact" read as a real arrow or stone.
			return
		end
		projectile.CFrame = CFrame.new(to_position, to_position + fire_direction)
		if traveled >= range then
			connection:Disconnect()
			projectile:Destroy()
		end
	end)
end
-- Keyed by WeaponModel, same lookup key every other per-weapon table in
-- this file uses (WEAPON_SWING_ANIMATIONS/WEAPON_HOLD_POSE_ANIMATIONS/
-- WEAPON_BLOCK_ANIMATIONS above). Deliberately kept out of ItemData.lua's
-- "Tier N Bow" entries, same split those other per-weapon tables already
-- use -- ItemData says WHAT the item is and how it's equipped, this file
-- says how it actually plays.
-- [stated/found] Tier 3 (Compound Bow) only has a "Compound Arrow" part
-- built so far, no bow body/strings -- [stated] "the compound bow does
-- not have separate strings so I'll leave that one be for now", so no
-- entry for it below yet either.
local BOW_DATA = {
	["Empty Bow"] = {
		VisualStyle = "stretch", -- default, named explicitly for symmetry with the Sling entry below
		-- [stated/found] no longer read for a target DRAW POSE (see
		-- Setup_Bow's string_tip_attachments/nock_rest_attachment system
		-- above instead) -- this is now ONLY a fallback source to clone a
		-- resting Arrow from, for the "Empty Bow has no Arrow of its own"
		-- case Setup_Bow's projectile_part fallback handles.
		-- [ASSUMPTION] never itself shown or equipped by any player.
		DrawReferenceModel = "Drawn Bow",
		BowPart = "Bow",
		TrackedParts = {"Lowerstring", "Upperstring"},
		ProjectilePart = "Arrow",
		-- [stated] "mark the ends of the string where they touch the bow
		-- as attachment points" -- STUDIO REQUIREMENT, not yet confirmed:
		-- 3 Attachments under "Bow" -- "UpperStringTip"/"LowerStringTip"
		-- at the two limb tips (where each string piece below actually
		-- touches the bow), and "StringRestNock" marking where the
		-- string+arrow sit when undrawn (its rotation also sets the
		-- arrow's resting look -- purely cosmetic, doesn't affect aim).
		-- See Setup_Bow's own comment for why these replace the old
		-- captured-once-from-the-model's-own-geometry approach.
		StringTipAttachment = {["Lowerstring"] = "LowerStringTip", ["Upperstring"] = "UpperStringTip"},
		NockRestAttachment = "StringRestNock",
		MaxDrawTime = 1.2, -- seconds held to reach a full (100%) draw. Placeholder, tune once tested.
		-- [stated] "draw % affecting damage/range/accuracy" -- Min* is a
		-- snap-release (tapped and let go instantly); Max* is a full
		-- MaxDrawTime-second hold. Placeholders throughout, tune once tested.
		MinDamage = 10,
		MaxDamage = 35,
		MinRange = 60,
		MaxRange = 300,
		MinProjectileSpeed = 60,
		MaxProjectileSpeed = 150,
		MinConeAngle = 12, -- degrees -- wider/less accurate at a low draw
		MaxConeAngle = 2,
		AttackStaminaCost = 15, -- spent once, at draw START (committing to draw costs stamina whether or not you hold it to full) -- same "pay up front" shape PlayerCombat.attack already uses for melee
	},
	-- [stated/found] "the sling ... different wind up and fire animation,
	-- but still hold and release for attacks" -- see this section's
	-- header comment for VisualStyle="spin" generally. No BowPart (no
	-- rigid frame to anchor to -- Setup_Bow falls back to the hand) and
	-- no DrawReferenceModel (there's no separate "fully wound up"
	-- reference model the way the bow has "Drawn Bow" -- a spin doesn't
	-- need one, it just keeps rotating the live rest pose).
	["Sling"] = {
		VisualStyle = "spin",
		TrackedParts = {"Sling Pouch", "Uppersling String", "Lowersling String"},
		ProjectilePart = "Stone",
		-- [ASSUMPTION, placeholder, tune once tested] which local hand
		-- axis the whole assembly spins around while winding up -- purely
		-- a windup flourish, doesn't affect where the stone actually goes
		-- (see Fire_Projectile's own comment on why launch direction is
		-- aim-based, not tangent-of-the-swing-based).
		SpinAxis = Vector3.new(1, 0, 0),
		MaxDrawTime = 1.0, -- seconds held to reach max wind-up. Placeholder, tune once tested.
		MinSpinSpeed = 2, -- radians/sec, lazy initial swing
		MaxSpinSpeed = 25, -- radians/sec, full windup
		-- Placeholders throughout, same Min*/Max*-by-draw-fraction shape
		-- as the bow above -- a sling reads as the quicker, shorter-
		-- ranged, weaker-hitting option of the two for now; flip that if
		-- you had something else in mind for how Sling vs. Bow should
		-- feel.
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
-- [stated] confirmed mechanic: "Hold to charge, release to fire" -- call
-- start_draw on the input going down, release_draw when it comes back up.
-- Mirrors start_block/stop_block's shape; wire a new DrawStartRequest/
-- DrawReleaseRequest RemoteEvent pair in RequestChecker.lua to these two
-- (needs manual creation in ReplicatedStorage, same outstanding step as
-- every other new remote this project) -- see this response for the exact
-- snippet, mirroring block_start_request/block_stop_request there closely.
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
	-- [stated] "I'd only want to add [the arrow] during the draw
	-- animation as I have it figured into the animation of the player
	-- grabbing an arrow from their back" -- a weapon with no Arrow of its
	-- own (see Setup_Bow) has draw_state.projectile_part == nil right up
	-- until exactly this moment: clone one in fresh, flag it as
	-- temporary so release_draw below knows to clean it back up rather
	-- than leaving it nocked forever after. A weapon that DOES carry its
	-- own persistent Arrow already has draw_state.projectile_part set
	-- from Setup_Bow, so this is a no-op for it.
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
	draw_state.spin_angle = 0 -- [stated/found] sling-only state -- harmless no-op field for a "stretch"-style weapon, just reset here too for consistency
	-- [stated/found] "the bow draw animation only fires after I let go of
	-- left click, when it should start when the player starts the left
	-- click hold" -- moved here from release_draw, see Get_Fire_Track's
	-- own comment for the full reasoning. character is guaranteed here
	-- (start_draw already needed player.Character to reach this point via
	-- the Spawn_Draw_Arrow branch above, when there was no persistent
	-- projectile_part -- re-fetched plainly here so this still works even
	-- on the branch where that block never ran, e.g. a weapon with its own
	-- persistent Arrow).
	local character = player.Character
	if character then
		local fire_track = Get_Fire_Track(player, character, weapon_data.WeaponModel)
		if fire_track then
			fire_track:Play()
			-- draw_state.fire_track/fire_track_held: read by the hold-at-
			-- end-frame logic in Setup_Bow's Heartbeat loop below, and
			-- cleared again in release_draw -- see FIRE_TRACK_HOLD_EPSILON's
			-- own comment for why this is needed at all.
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
	-- [stated] "for now don't add the arrow to the bow, I'd only want to
	-- add it during the draw animation" -- the shot that was just fired
	-- is a totally separate clone Fire_Projectile already made off this
	-- one (see its own comment), so the nocked copy still sitting here
	-- is safe to remove right now rather than leaving it visibly nocked
	-- until the next draw. Only ever true for an arrow start_draw spawned
	-- fresh -- a weapon with its own persistent Arrow keeps it.
	if draw_state.projectile_is_temporary and draw_state.projectile_part then
		draw_state.projectile_part:Destroy()
		draw_state.projectile_part = nil
		draw_state.arrow_local_offset = nil
		draw_state.projectile_is_temporary = false
	end
	-- [stated/found] "the bow draw animation only fires after I let go of
	-- left click, when it should start when the player starts the left
	-- click hold" -- this used to :Play() the fire/draw track right here;
	-- moved to start_draw instead (see its own comment, and Get_Fire_
	-- Track's) so the clip's start lines up with the actual button-down
	-- moment rather than the release. Nothing plays from release_draw any
	-- more -- Fire_Projectile above is the only thing that still needs to
	-- happen at this exact instant.
	-- [stated] "Let's start with holding the final frame of the animation
	-- until it's released" -- the Heartbeat loop in Setup_Bow may have
	-- frozen this track (AdjustSpeed(0)) right at its own last frame
	-- while draw_state.drawing was true; releasing means letting it
	-- actually finish now -- resume normal speed and let it play out the
	-- last sliver to its natural end (where it stops on its own), rather
	-- than leaving it frozen forever after release.
	if draw_state.fire_track then
		draw_state.fire_track:AdjustSpeed(1)
		draw_state.fire_track = nil
		draw_state.fire_track_held = nil
	end
	return true, fraction
end
-- [stated/found] "all of the weapons will dip in and out of sync during
-- the player's normal movement, but when sprinting it'll sync" -- the
-- hysteresis margin this replaces assumed the ambiguous zone was a brief
-- CROSSING (one instant where weight passes through 50/50) -- but
-- RequestChecker.lua's Sync_Movement confirms the default Animate script
-- blends walk<->run weight continuously over a SPEED RANGE, and ordinary
-- walk speed (16) apparently sits inside that range for as long as the
-- player keeps walking, not just for an instant passing through it. "Pick
-- whichever track is winning right now" (even with hysteresis delaying the
-- switch) is the wrong model there -- there's no single correct winner to
-- hold onto while both tracks are legitimately, continuously contributing.
-- Sprinting is stable because sprint_speed (28) clears that range
-- entirely, leaving only one Movement-priority track active with real
-- weight -- consistent with what was reported.
-- Replaces "pick a winner" with a continuous circular-weighted average of
-- EVERY active Movement-priority track's phase, weighted by its own
-- WeightCurrent. Phases are cyclic (0 wraps back to 1), so this uses a
-- proper circular mean (via sin/cos, then atan2 back to an angle) rather
-- than a naive linear average, which breaks near the wrap point --
-- averaging 0.95 and 0.05 naively gives 0.5, when the honest answer is
-- close to 0.0.
-- [stated/found] "found a timelength which pairs well with the sprint
-- cycle, but during the normal cycle it looks too fast" -- originally read
-- as the default walk/run clips not representing the same AMOUNT of
-- visual stride per their own Length, needing a separate correction per
-- role (walk_phase_multiplier/run_phase_multiplier below). That correction
-- used to be applied PER TRACK, with the role ("walk" vs "run") inferred
-- from which of the two currently-blending default leg tracks was playing
-- faster -- [stated/found] "walk animations still moving too fast ... even
-- with MoveWalkPhaseMultiplier=0.5 applied" turned out to be this
-- inference breaking down, not the 0.5 value itself: tested live at the
-- Overburdened weight tier (WalkSpeed reduced to 8 -- confirmed via debug
-- log against PlayerWeight.lua's WalkSpeedMultiplier=0.5 * base 16),
-- Roblox's own walk/run blend gave the "run" track 78% of the weight while
-- the player was just walking, not sprinting -- its internal blend
-- thresholds aren't rescaled to whatever WalkSpeed the weight system
-- currently has set, so ordinary walking at a reduced WalkSpeed can still
-- read as mostly "run". Replaced entirely with PlayerSprint.is_sprinting
-- (the player's actual, server-authoritative sprint request) to choose a
-- single multiplier applied to EVERY active track uniformly, rather than
-- inferring walk-vs-run per track from Roblox's own blend weights at all.
-- [found via live test, 2026-11-02] this Roblox build tags its own
-- default walk/run tracks as Core priority, NOT Movement -- the
-- Movement filter was matching zero tracks every single frame, so
-- Get_Blended_Movement_Phase always returned nil and tracks.Move's
-- TimePosition was never being driven at all. That's the actual
-- root cause of "MoveWalkPhaseMultiplier doesn't seem to be
-- affecting the speed of the animation at all" -- the whole sync
-- was a no-op, not just the multiplier. Matching both priorities
-- here in case a given build/revision uses either one.
local MOVEMENT_TRACK_PRIORITIES = {
	[Enum.AnimationPriority.Movement] = true,
	[Enum.AnimationPriority.Core] = true,
}
-- [debug] "walk still too fast under weight" -- temporary, throttled
-- (~2/second per humanoid) print confirming the real sprint state being
-- read and the multiplier it picked, alongside each active track's raw
-- phase/weight, so a wrong PlayerSprint reading is distinguishable from
-- the multiplier value itself still being off. Remove once confirmed.
local last_phase_debug = {}
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
	-- [debug] see comment above local last_phase_debug -- remove once confirmed.
	if os.clock() - (last_phase_debug[humanoid] or 0) >= 0.5 then
		last_phase_debug[humanoid] = os.clock()
		local parts = {}
		for _, track in ipairs(active_tracks) do
			local anim_id = track.Animation and track.Animation.AnimationId
			local raw_phase = (track.TimePosition % track.Length) / track.Length
			table.insert(parts, string.format(
				"[id=%s speed=%.2f weight=%.2f raw_phase=%.2f]",
				tostring(anim_id), track.Speed, track.WeightCurrent, raw_phase
				))
		end
		print(string.format(
			"[PlayerCombat DEBUG] %s -- is_sprinting=%s multiplier=%.2f -- %d active movement track(s): %s -- blended phase: %.3f",
			humanoid.Parent and humanoid.Parent.Name or "?", tostring(is_sprinting), multiplier, #active_tracks, table.concat(parts, " "), result_phase
			))
	end
	return result_phase
end
-- [stated, forum-sourced] "setting your upper body track's speed to 0 and
-- copying the default walk track's position onto it every frame, so it
-- can't fall out of sync." tracks.Move is already frozen (AdjustSpeed(0),
-- see Get_Hold_Tracks) -- this is the per-frame driver that actually moves
-- it, phase-locked rather than time-locked (TimePosition as a 0..1
-- fraction of each track's own Length) so it lines up even when the custom
-- clip and the default leg track run different real-time durations. Gated
-- on active_hold_track so the per-frame cost is only paid while Move is
-- actually the visible pose, not e.g. while Idle or Block are showing.
-- [debug] "walk still too fast with weight on, fine at no weight, sprint
-- fine either way" -- throttled print confirming whether tracks.Move.Speed
-- is actually staying pinned at 0.00 under this specific weighted-walk
-- condition (the AdjustSpeed(0) reassertion fix above should guarantee
-- this -- if it's ever nonzero here, that fix isn't fully holding and the
-- track is drifting under its own clock between Heartbeat corrections,
-- same mechanism as before but apparently still slipping through somehow).
-- Also shows the real TimePosition/Length being written, to rule that
-- part out separately from the phase math itself. Remove once root-caused.
local last_sync_debug = {}
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
		-- [stated/found] "the legs animations of the character moving
		-- slower in accordance with the weight, but the custom animations
		-- still playing at the speed of a completely weightless player" --
		-- root cause: Set_Active_Hold_Track's track:Play(HOLD_POSE_FADE_TIME)
		-- call (whenever this Move track (re)starts, e.g. switching from
		-- Idle) resets .Speed back to its default of 1 -- AnimationTrack:
		-- Play()'s third positional argument is speed, defaulting to 1 when
		-- omitted, which silently undoes the one-time AdjustSpeed(0) freeze
		-- set back in Get_Hold_Tracks. With Speed stuck at 1 instead of 0,
		-- the track keeps advancing on its own, at the same fixed real-time
		-- rate regardless of the player's current weight tier, in between
		-- each of this Heartbeat's TimePosition corrections -- invisible at
		-- no weight (where 1x happens to be roughly the correct rate
		-- anyway), but increasingly visible the slower weight makes the
		-- real (correct) phase advance. Re-asserting the freeze every tick
		-- here, instead of only once at load time, keeps it pinned to 0 no
		-- matter how many times Play() gets called on it.
		if tracks.Move.Speed ~= 0 then
			tracks.Move:AdjustSpeed(0)
		end
		local phase = Get_Blended_Movement_Phase(player, humanoid, walk_phase_multiplier, run_phase_multiplier)
		if phase and tracks.Move.Length > 0 then
			tracks.Move.TimePosition = phase * tracks.Move.Length
		end
		-- [debug] see comment above local last_sync_debug -- remove once root-caused.
		if os.clock() - (last_sync_debug[player] or 0) >= 0.5 then
			last_sync_debug[player] = os.clock()
			print(string.format(
				"[PlayerCombat DEBUG] %s Move sync -- WalkSpeed: %.2f, is_sprinting: %s, phase: %s, Move.Speed: %.2f, Move.TimePosition: %.3f / %.3f",
				player.Name, humanoid.WalkSpeed, tostring(PlayerSprint.is_sprinting(player)), phase and string.format("%.3f", phase) or "nil", tracks.Move.Speed, tracks.Move.TimePosition, tracks.Move.Length
				))
		end
	end)
end
-- Idle/Move/Block are mutually exclusive (unlike the swing, which layers
-- independently at a higher priority) -- switching to a new one stops
-- whichever was playing, with a short crossfade rather than a hard cut.
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
-- Call this any time the player's Weapon slot changes -- equip, unequip,
-- a consumable equipped in the Weapon slot getting eaten down to 0, or
-- drop-equipped -- so the idle/move pose (and the Running hookup that
-- switches between them) stays in sync with whatever's actually in hand.
-- Weapons with no WEAPON_HOLD_POSE_ANIMATIONS entry just fall through to
-- the default Animate idle/walk/run untouched, same as before this system
-- existed.
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
	-- Bows have no WEAPON_HOLD_POSE_ANIMATIONS entry (that system is pure
	-- AnimationTrack, bows use the procedural string-stretch system
	-- instead) -- handled first, before the "no hold-pose tracks" early
	-- return just below would otherwise skip it entirely for a bow.
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
	-- Idle vs Move switching only -- no AdjustSpeed here any more, see
	-- Start_Move_Sync below for how the Move track's pose is actually kept
	-- in time with the legs now.
	hold_pose_connections[player] = humanoid.Running:Connect(function(speed)
		if PlayerCombat.is_blocking(player) then
			return -- block owns the pose while it's held; don't let walk/run churn interrupt it
		end
		Set_Active_Hold_Track(player, speed > 0.5 and tracks.Move or tracks.Idle)
	end)
	-- [stated, forum-sourced] position-locks tracks.Move to the live
	-- default leg track every frame (see Start_Move_Sync/
	-- Get_Blended_Movement_Phase above) instead of trying to match its
	-- playback speed -- replaces the old MoveSpeedMultiplier knob entirely.
	-- MoveWalkPhaseMultiplier/MoveRunPhaseMultiplier (both default to 1,
	-- i.e. no change, when a weapon doesn't set one) are the separate
	-- per-source density corrections -- see their own comment on
	-- Get_Blended_Movement_Phase for why walk and run need different ones.
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
-- [stated] "/dev text command that would make my character invincible" --
-- see PlayerCombat.dev_invulnerable's own comment above for why this is a
-- separate standing flag instead of just stretching invulnerable_until.
function PlayerCombat.set_dev_invulnerable(player, enabled)
	PlayerCombat.dev_invulnerable[player] = enabled or nil
end
function PlayerCombat.is_blocking(player)
	return PlayerCombat.blocking_players[player] == true
end
-- Every valid attack target right now: every other real player, plus
-- anything tagged CombatTarget (test dummies today, zombies later).
-- Player-only checks (blocking/invulnerability) simply never trigger for
-- untagged NPC entries, since they were never added to those tables.
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
	-- [stated/found] "attempt to perform arithmetic (mul) on nil and
	-- number" at the AttackCooldown line below, the moment a bow was
	-- equipped and the regular attack input fired -- a bow/sling's
	-- ItemData entry deliberately has no Damage/Range/ConeAngle/
	-- AttackStaminaCost/AttackCooldown fields at all (those live in
	-- BOW_DATA instead, see the "Ranged weapons" section above), so this
	-- function was always going to crash the instant it ran against one.
	-- It shouldn't run against one AT ALL -- a ranged weapon fires
	-- through start_draw/release_draw, never through attack() -- so this
	-- bails out immediately instead of trying to melee-swing a bow.
	if BOW_DATA[weapon_data.WeaponModel] then
		return false, "ranged weapon -- hold to draw, release to fire, not a regular attack"
	end
	local now = os.clock()
	local last_time = last_attack_time[player] or 0
	-- [stated] "Dexterity -> weapon swing speed"
	local swing_speed_fraction = math.max(MIN_SWING_COOLDOWN_FRACTION, 1 - (PlayerStats.get(player, "Dexterity") - 1) * DEXTERITY_SWING_SPEED_PER_POINT)
	local effective_cooldown = weapon_data.AttackCooldown * swing_speed_fraction
	if now - last_time < effective_cooldown then
		return false, "attack on cooldown"
	end
	-- [stated] "Endurance -> reduced weapon attack stamina cost"
	local attack_cost_fraction = math.max(MIN_ATTACK_COST_FRACTION, 1 - (PlayerStats.get(player, "Endurance") - 1) * ENDURANCE_ATTACK_COST_REDUCTION_PER_POINT)
	if not PlayerStamina.spend(player, weapon_data.AttackStaminaCost * attack_cost_fraction) then
		return false, "not enough stamina"
	end
	last_attack_time[player] = now
	-- [stated] "Strength -> melee damage" — computed once here (not inside
	-- the delayed hit-check below) since it's the attacker's own stat at
	-- the moment the swing started, not something that needs to stay live
	-- through the windup the way weight-tier effects do elsewhere.
	local strength_damage_multiplier = 1 + (PlayerStats.get(player, "Strength") - 1) * STRENGTH_DAMAGE_PER_POINT
	local strength_knockback_multiplier = 1 + (PlayerStats.get(player, "Strength") - 1) * STRENGTH_KNOCKBACK_DEALT_PER_POINT
	-- [stated] attacking is one of the actions that speeds up hunger —
	-- pulsed here rather than gated on the windup delay below, since the
	-- stamina cost (and the intent to attack) already happened by this point.
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
			-- Length is the real published swing clip's duration in seconds
			-- (already loaded/known by this point via Get_Swing_Track's
			-- LoadAnimation) -- passed along so the client's ground telegraph
			-- can linger for exactly as long as the actual animation plays,
			-- rather than a guessed fixed duration.
			swing_telegraph_event:FireClient(player, track.Length)
		end
	end
	-- Delay the actual hit-check to match the animation's windup, so
	-- damage lands roughly when the weapon (or fist) visually connects.
	-- NOTE: attacker_pos/attacker_forward are read from root.CFrame here,
	-- AFTER the delay — not captured back at swing start — so turning to
	-- face a target mid-swing should already be reflected in this check.
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
			-- [stated] "I removed the humanoid part in each animal" --
			-- CombatTarget-tagged NPCs can no longer be assumed to have a
			-- Humanoid (current wildlife doesn't). Duck-typed two ways now:
			-- a real Humanoid (players, and any future NPC built the normal
			-- way, e.g. zombies) still uses Humanoid.Health/TakeDamage
			-- exactly as before; anything without one is expected to carry
			-- its health as a "Health" NUMBER ATTRIBUTE on the tagged model
			-- instead -- the same attribute WildLifeManager.lua's own
			-- health bar and death handling read/write, so both sides agree
			-- on where health actually lives for a Humanoid-less target.
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
							-- [stated] "knockback resisted" — the target's
							-- Endurance, same "toughness" role it already
							-- plays elsewhere (fall damage, hunger rate).
							local target_endurance = PlayerStats.get(target.player, "Endurance")
							local resist_reduction = math.min((target_endurance - 1) * ENDURANCE_KNOCKBACK_RESIST_PER_POINT, MAX_KNOCKBACK_RESIST_REDUCTION)
							knockback_force = knockback_force * (1 - resist_reduction)
						end
						if target_humanoid then
							target_humanoid:TakeDamage(damage)
						else
							target.character:SetAttribute("Health", math.max(0, target_health - damage))
						end
						-- Single impulse, not a sustained reassert like the
						-- dodge dash — knockback is a one-off shove that
						-- should decay naturally, not fight the target's
						-- own movement input for a fixed duration. Only X/Z
						-- driven, existing Y velocity preserved, same as
						-- the dash.
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
	PlayerHunger.set_active(player, "Block", true) -- [stated] blocking speeds up hunger, same as sprint/swim it's a genuinely continuous state
	local character = player.Character
	if character then
		local weapon_data = Get_Equipped_Weapon_Data(player)
		local tracks = Get_Hold_Tracks(player, character, weapon_data.WeaponModel)
		if tracks and tracks.Block then
			local block_track = tracks.Block
			Set_Active_Hold_Track(player, block_track)
			block_track:AdjustSpeed(1) -- undo a previous block's speed=0 freeze, if this track was reused
			-- [stated/found] a non-looping AnimationTrack does NOT hold its
			-- last frame once it finishes playing -- it releases control back
			-- to whatever's underneath (the default pose, in this case),
			-- confirmed by testing. Stopped fires both when a track finishes
			-- naturally AND when :Stop() is called manually, so the guard
			-- below is needed: only re-pin the pose if we're still actually
			-- blocking with THIS track still active -- otherwise a genuine
			-- release (stop_block calling :Stop() on this same track via
			-- Set_Active_Hold_Track) would get immediately un-done by this
			-- same handler firing.
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
	PlayerHunger.pulse(player) -- [stated] dodging speeds up hunger
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChild("Humanoid")
	if root and humanoid then
		-- Direction: whichever way the player's currently moving, or
		-- straight backward relative to their facing if they're standing
		-- still — matches the [stated] redesign target exactly.
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
		-- Re-asserting velocity every Heartbeat for the dash's duration,
		-- rather than setting it once, is what actually overpowers the
		-- Humanoid's own per-frame movement calculation — a single
		-- one-time velocity set gets overwritten almost immediately
		-- otherwise. Only X/Z are driven; Y is read back and preserved
		-- each tick so gravity/jump arcs aren't touched by the dash.
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
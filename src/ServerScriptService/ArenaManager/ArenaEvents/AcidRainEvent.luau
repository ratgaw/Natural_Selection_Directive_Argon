-- Acid Rain event: a caustic storm that strips the leaves off every tree a few
-- seconds after it starts, and deals tick damage to participants who are out in
-- the open. Cover = anything solid directly overhead (a roof, a rock overhang,
-- terrain, or a tree's leaves until they dissolve). Buildings, wildlife and
-- zombies are never damaged -- only game_data.participants are checked.
-- Warnings and the camera pan are handled by ArenaEventScheduler before
-- trigger() runs. trigger() returns immediately; the storm runs in its own thread.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")
local Terrain = workspace.Terrain

local PlayerCombat = require(ServerScriptService:WaitForChild("PlayerCombat"))
local PlayerStats = require(ServerScriptService:WaitForChild("PlayerStats"))
local PlayerEquipment = require(ServerScriptService:WaitForChild("PlayerEquipment"))
local ItemData = require(ReplicatedStorage:WaitForChild("ItemData"))
local DayNightWeather = require(ServerScriptService:WaitForChild("ArenaManager"):WaitForChild("DayNightWeather"))

local acid_rain_updated = ReplicatedStorage:WaitForChild("AcidRainUpdated")

local AcidRainEvent = {}

-- Must match StartMatch's FOREST_FIRE.tag.
local LIVE_TREE_TAG = "LiveTree"

-- Placeholders, tune once tested.
local RAIN_DURATION = 90 -- TESTING value -- seconds the acid rain lasts
-- Seconds after trigger before exposure damage can start. The scheduler's
-- camera pan (5 s) runs at the same time as trigger, so this leaves a few
-- seconds of free movement to reach cover.
local DAMAGE_START_DELAY = 10

-- Leaves start dissolving at a random time in this window (seconds after
-- trigger), so trees go bare in a ripple rather than all at once.
local LEAF_BURN_START_MIN = 6
local LEAF_BURN_START_MAX = 20
-- Each tree's leaves: tint, then fade in steps, then destroyed. Stepped instead
-- of tweened because server tweens replicate every frame for every part.
local LEAF_BURN_COLOR = Color3.fromRGB(150, 160, 40) -- sickly yellow-green
local LEAF_FADE_STEPS = {0.35, 0.7} -- transparency per step
local LEAF_STEP_INTERVAL = 1.5 -- seconds between steps
-- Smoke puff while the leaves dissolve.
local LEAF_SMOKE_COLOR = Color3.fromRGB(170, 190, 90)
local LEAF_SMOKE_OPACITY = 0.25
local LEAF_SMOKE_SIZE = 6

-- Damage. Starts at BASE and climbs by RAMP each second of continuous exposure,
-- up to MAX, so a quick dash between buildings is cheap but standing out in it
-- gets dangerous fast. Stepping into cover resets the ramp.
local DAMAGE_TICK_INTERVAL = 1
local EXPOSURE_GRACE = 1.5 -- seconds exposed before the first tick lands
local DAMAGE_BASE = 3
local DAMAGE_RAMP_PER_SECOND = 0.25
local DAMAGE_MAX = 8

-- Damage reduced by Endurance, same formula as fire/fall damage.
local ENDURANCE_DAMAGE_REDUCTION_PER_POINT = 0.05
local MAX_ENDURANCE_REDUCTION = 0.6

-- Cover check: ray straight up from the head. Hits on near-invisible parts
-- (effects, invisible anchors) are skipped and the ray continues past them.
local COVER_RAY_LENGTH = 300
local COVER_MIN_OPACITY_TRANSPARENCY = 0.9 -- parts at or above this transparency don't count as cover
local COVER_MAX_PASSTHROUGHS = 6

-- Sky look handed to DayNightWeather while the rain is falling.
local ACID_SKY_LOOK = {
	fog_color = Color3.fromRGB(125, 140, 70),
	fog_start = 0,
	fog_end = 550,
	brightness_mult = 0.65,
	ambient_mult = 0.8,
	ambient_tint = Color3.fromRGB(200, 230, 140),
	hide_weather_rain = true, -- the client draws the green rain instead
}

local rain_active = false

-- [AcidRainDebug] prints are throttled per player to one every 3 s for the
-- per-tick damage line. -- temporary, remove once confirmed
local DEBUG_DAMAGE_PRINT_INTERVAL = 3
local debug_last_damage_print = {}

local function Apply_Acid_Damage(player, humanoid, base_damage)
	local endurance = PlayerStats.get(player, "Endurance")
	local endurance_reduction = math.min(math.max(endurance - 1, 0) * ENDURANCE_DAMAGE_REDUCTION_PER_POINT, MAX_ENDURANCE_REDUCTION)
	local final_damage = base_damage * (1 - endurance_reduction)
	humanoid:TakeDamage(final_damage)
	return final_damage
end

-- Optional gear protection: any equipped item can carry AcidRainProtection
-- (0-1) in ItemData. None do yet; this is the hook for a future poncho / gas
-- mask / hazmat item. Total is capped at 1 (= fully protected).
local function Get_Gear_Protection(player)
	local equipped = PlayerEquipment.player_equipment[player]
	if not equipped then
		return 0
	end
	local total = 0
	local counted_items = {}
	for _, entry in pairs(equipped) do
		if entry.ItemName and not counted_items[entry.ItemName] then
			counted_items[entry.ItemName] = true
			local data = ItemData[entry.ItemName]
			if data and data.AcidRainProtection then
				total = total + data.AcidRainProtection
			end
		end
	end
	return math.clamp(total, 0, 1)
end

-- Returns the instance providing cover, or nil if the sky is open overhead.
local function Find_Cover(character)
	local head = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
	if not head then
		return nil
	end
	local exclude = {}
	for _, other_player in ipairs(Players:GetPlayers()) do
		if other_player.Character then
			table.insert(exclude, other_player.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	local origin = head.Position
	local remaining = COVER_RAY_LENGTH
	for _ = 1, COVER_MAX_PASSTHROUGHS do
		params.FilterDescendantsInstances = exclude
		local result = workspace:Raycast(origin, Vector3.new(0, remaining, 0), params)
		if not result then
			return nil
		end
		local hit = result.Instance
		if hit == Terrain then
			return hit
		end
		if hit:IsA("BasePart") and hit.Transparency < COVER_MIN_OPACITY_TRANSPARENCY then
			return hit
		end
		-- Invisible/effect part: skip it and keep going up.
		table.insert(exclude, hit)
		remaining = remaining - (result.Position - origin).Magnitude
		origin = result.Position
		if remaining <= 0 then
			return nil
		end
	end
	return nil
end

-- Collects the BaseParts making up a tree's Leaves (a part, model or folder).
local function Get_Leaf_Parts(leaves)
	local parts = {}
	if leaves:IsA("BasePart") then
		table.insert(parts, leaves)
	end
	for _, descendant in ipairs(leaves:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

-- Tints, fades and destroys one tree's leaves over a few seconds.
-- Calls on_done(true) if leaves were removed, on_done(false) otherwise.
local function Dissolve_Leaves(tree_model, on_done)
	if not tree_model.Parent or tree_model:GetAttribute("OnFire") then
		on_done(false)
		return
	end
	local leaves = tree_model:FindFirstChild("Leaves")
	if not leaves then
		on_done(false)
		return
	end
	-- SurfaceAppearance makes a MeshPart ignore .Color, so drop it first
	-- (same approach as ForestFireEvent's Char_Parts).
	for _, descendant in ipairs(leaves:GetDescendants()) do
		if descendant:IsA("SurfaceAppearance") then
			descendant:Destroy()
		end
	end
	local parts = Get_Leaf_Parts(leaves)
	for _, part in ipairs(parts) do
		part.Color = LEAF_BURN_COLOR
	end
	local smoke_host = parts[1]
	if smoke_host then
		local smoke = Instance.new("Smoke")
		smoke.Name = "AcidLeafSmoke"
		smoke.Color = LEAF_SMOKE_COLOR
		smoke.Opacity = LEAF_SMOKE_OPACITY
		smoke.Size = LEAF_SMOKE_SIZE
		smoke.RiseVelocity = 2
		smoke.Parent = smoke_host
	end
	task.spawn(function()
		for _, transparency in ipairs(LEAF_FADE_STEPS) do
			task.wait(LEAF_STEP_INTERVAL)
			if not leaves.Parent then
				on_done(false)
				return
			end
			for _, part in ipairs(parts) do
				if part.Parent then
					part.Transparency = math.max(part.Transparency, transparency)
				end
			end
			for _, descendant in ipairs(leaves:GetDescendants()) do
				if descendant:IsA("Decal") or descendant:IsA("Texture") then
					descendant.Transparency = math.max(descendant.Transparency, transparency)
				end
			end
		end
		task.wait(LEAF_STEP_INTERVAL)
		if leaves.Parent then
			leaves:Destroy()
			tree_model:SetAttribute("AcidStripped", true)
			on_done(true)
		else
			on_done(false)
		end
	end)
end

-- Schedules every leafy LiveTree to dissolve at a random point in the window.
local function Schedule_Leaf_Burn()
	local trees = CollectionService:GetTagged(LIVE_TREE_TAG)
	local scheduled = 0
	local no_leaves = 0
	local finished_stats = {removed = 0, skipped = 0}
	for _, tree_model in ipairs(trees) do
		if tree_model:FindFirstChild("Leaves") then
			scheduled += 1
			local delay_time = LEAF_BURN_START_MIN + math.random() * (LEAF_BURN_START_MAX - LEAF_BURN_START_MIN)
			task.delay(delay_time, Dissolve_Leaves, tree_model, function(removed)
				if removed then
					finished_stats.removed += 1
				else
					finished_stats.skipped += 1
				end
			end)
		else
			no_leaves += 1
		end
	end
	print(("[AcidRainDebug] leaf burn scheduled: %d LiveTrees tagged, %d with Leaves scheduled, %d without Leaves (already burnt/stripped or different model layout)"):format(#trees, scheduled, no_leaves)) -- temporary, remove once confirmed
	-- Summary once every tree has had time to finish. -- temporary, remove once confirmed
	local total_leaf_time = LEAF_STEP_INTERVAL * (#LEAF_FADE_STEPS + 1)
	task.delay(LEAF_BURN_START_MAX + total_leaf_time + 1, function()
		print(("[AcidRainDebug] leaf burn finished: %d removed, %d skipped (on fire / destroyed mid-burn), of %d scheduled"):format(finished_stats.removed, finished_stats.skipped, scheduled)) -- temporary, remove once confirmed
	end)
end

local function Describe_Cover(cover)
	if not cover then
		return "open sky"
	end
	if cover == Terrain then
		return "Terrain"
	end
	return cover:GetFullName()
end

local function Run_Acid_Rain(game_data)
	local start_time = os.clock()
	local end_time = start_time + RAIN_DURATION
	acid_rain_updated:FireAllClients({active = true, duration = RAIN_DURATION})
	DayNightWeather.set_event_look(ACID_SKY_LOOK)
	Schedule_Leaf_Burn()

	-- player -> {exposed = bool, exposed_since = os.clock() or nil}
	local exposure = {}
	local total_damage_dealt = 0 -- temporary, remove once confirmed

	while rain_active and os.clock() < end_time and game_data.state == "matchinprogress" do
		local now = os.clock()
		local damage_enabled = now - start_time >= DAMAGE_START_DELAY
		for player in pairs(game_data.participants) do
			local character = player.Character
			local humanoid = character and character:FindFirstChild("Humanoid")
			if humanoid and humanoid.Health > 0 then
				local cover = Find_Cover(character)
				local is_exposed = cover == nil
				local entry = exposure[player]
				if not entry then
					entry = {exposed = nil, exposed_since = nil}
					exposure[player] = entry
				end
				if entry.exposed ~= is_exposed then
					entry.exposed = is_exposed
					entry.exposed_since = is_exposed and now or nil
					acid_rain_updated:FireClient(player, {active = true, exposed = is_exposed})
					print(("[AcidRainDebug] %s is now %s (overhead: %s)"):format(player.Name, is_exposed and "EXPOSED" or "SHELTERED", Describe_Cover(cover))) -- temporary, remove once confirmed
				end
				if is_exposed and damage_enabled and not PlayerCombat.is_invulnerable(player) then
					-- Exposure only counts from when damage became possible, so
					-- players caught out at the start get the same grace.
					local exposed_for = now - math.max(entry.exposed_since, start_time + DAMAGE_START_DELAY)
					if exposed_for >= EXPOSURE_GRACE then
						local gear_protection = Get_Gear_Protection(player)
						if gear_protection < 1 then
							local ramped = math.min(DAMAGE_BASE + (exposed_for - EXPOSURE_GRACE) * DAMAGE_RAMP_PER_SECOND, DAMAGE_MAX)
							local dealt = Apply_Acid_Damage(player, humanoid, ramped * (1 - gear_protection))
							total_damage_dealt += dealt
							local last_print = debug_last_damage_print[player] or 0
							if now - last_print >= DEBUG_DAMAGE_PRINT_INTERVAL then
								debug_last_damage_print[player] = now
								print(("[AcidRainDebug] %s took %.1f acid damage (exposed %.1fs, ramped base %.1f, gear protection %.2f, health now %.0f)"):format(player.Name, dealt, exposed_for, ramped, gear_protection, humanoid.Health)) -- temporary, remove once confirmed
							end
						end
					end
				end
			else
				exposure[player] = nil
			end
		end
		task.wait(DAMAGE_TICK_INTERVAL)
	end

	rain_active = false
	DayNightWeather.clear_event_look()
	acid_rain_updated:FireAllClients({active = false})
	table.clear(debug_last_damage_print)
	print(("[AcidRainDebug] rain ended after %.0fs, %.0f total damage dealt to participants"):format(os.clock() - start_time, total_damage_dealt)) -- temporary, remove once confirmed
end

function AcidRainEvent.trigger(game_data)
	if rain_active then
		warn("[AcidRainEvent] trigger: acid rain is already falling -- ignoring the second trigger")
		return
	end
	rain_active = true
	print("[AcidRainDebug] acid rain triggered") -- temporary, remove once confirmed
	task.spawn(Run_Acid_Rain, game_data)
end

-- Stops the rain early (e.g. match end). Safe to call when not active.
function AcidRainEvent.stop()
	rain_active = false
end

return AcidRainEvent

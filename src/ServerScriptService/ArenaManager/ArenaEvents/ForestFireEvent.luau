local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
-- [stated] "since I do generate the map every time that should work for
-- the voxel terrain right?" -- yes: StartMatch.lua's own generation grabs
-- this exact same `workspace.Terrain` and carves it every match via
-- terrain:FillBlock, so it's genuine voxel Terrain, not a parts-built
-- ground -- real terrain edits here work the same way.
local Terrain = workspace.Terrain

local PlayerCombat = require(ServerScriptService:WaitForChild("PlayerCombat"))
local PlayerStats = require(ServerScriptService:WaitForChild("PlayerStats"))

local ForestFireEvent = {}

-- Must match FOREST_FIRE.tag in StartMatch.lua's tree spawn loop -- that's
-- the only place any tree actually gets this tag, at the moment it's
-- cloned into workspace, so this event never needs its own tree-tracking
-- table. CollectionService:GetTagged would also work for "every live tree"
-- directly, but spread only ever needs trees NEAR an already-burning one,
-- which is what Find_Nearby_Unburnt_Trees below is for instead.
local LIVE_TREE_TAG = "LiveTree"

-- Must match LIVE_PLANT_TAG in StartMatch.lua's bush/flower/fern/water-plant
-- spawn loop -- same reasoning as LIVE_TREE_TAG above, just for the smaller
-- scattered vegetation instead of trees. Used below by Remove_Plants_In_Region
-- to find "a plant" without guessing by instance name.
local LIVE_PLANT_TAG = "LivePlant"

-- Must match LIVE_ROCK_TAG in StartMatch.lua's rock/boulder spawn loop --
-- same reasoning again, for the 5 boulder models (Big Boulder, Big Boulder
-- Pile, Dark Big Boulder, Mossy Boulder, Small Rock Pile). Used below by
-- Char_Rocks_In_Region to find rocks to char near a scorch mark, same way
-- LIVE_PLANT_TAG finds plants to remove.
local LIVE_ROCK_TAG = "LiveRock"

-- [stated] "gradual spread" -- how far (studs) a burning tree can reach to
-- catch its neighbors, and how often that check runs. Not every tree in
-- range catches the same tick (SPREAD_IGNITE_CHANCE) and only so many can
-- catch per tick (MAX_IGNITIONS_PER_TICK) -- both exist purely so the fire
-- visibly creeps outward over several ticks instead of the whole reachable
-- cluster lighting up at once the moment it's in radius.
-- [stated] "increase the burn spread speed so that the forest burns
-- faster" -- three changes together, not just one: the tick itself now
-- runs every second instead of every 3 (SPREAD_TICK_INTERVAL dropped to 1,
-- kept equal to FIRE_DAMAGE_TICK_INTERVAL on purpose -- see the
-- SPREAD_TICK_TICKS note below for why a non-whole-multiple value here is
-- actually a trap), each tick rolls a much better chance per nearby tree
-- (0.35 -> 0.65), and more trees are allowed to catch in that same tick
-- (6 -> 12). SPREAD_RADIUS also widened slightly (35 -> 40) so a burning
-- tree reaches a bit further into the surrounding canopy per roll too.
-- Together this should make a cluster visibly race outward instead of
-- creeping.
local SPREAD_RADIUS = 40
local SPREAD_TICK_INTERVAL = 1
local SPREAD_IGNITE_CHANCE = 0.75
local MAX_IGNITIONS_PER_TICK = 18

-- [stated] "persist throughout the match" -> "timed burn, then dormant" --
-- spread/damage/falling-trunk hazards only run for this long after the
-- event triggers. Every tree already Burnt by then just stays blackened
-- and leafless for the rest of the match -- no revert, no per-tree burnout
-- timer, just one shared window for the whole event.
local ACTIVE_BURN_DURATION = 180 -- TESTING value, tune once tested

-- [stated] "dealing damage to players if they're in the fire/too close to
-- it" -- a periodic tick rather than continuous, same shape as
-- PlayerHunger's own periodic damage.
local FIRE_DAMAGE_RADIUS = 12
local FIRE_DAMAGE_PER_TICK = 4
local FIRE_DAMAGE_TICK_INTERVAL = 1

-- [stated] "random tree trunks falling near the players... only from
-- burning trees" -- a tree has to have been on fire this long before it's
-- eligible to fall at all, and even then only actually tries once a
-- participant is standing within FALL_TRIGGER_RADIUS of it.
local MIN_BURN_BEFORE_FALL = 6
local FALL_CHECK_INTERVAL = 2
local FALL_TRIGGER_RADIUS = 20
local FALL_CHANCE_PER_CHECK = 0.15
local FALL_DURATION = 1.1
local FALL_DAMAGE = 35
local FALL_DAMAGE_RADIUS = 10 -- around where the trunk actually lands

-- [stated] "I'm not seeing any fire effects, do we have those plugged in?"
-- -- we didn't: Char_Tree only ever handled the permanent leaves-gone/
-- trunk-blackened damage, nothing previously spawned an actual flame while
-- a tree is OnFire. Roblox's built-in Fire instance (a legacy effect
-- object, not a ParticleEmitter) parents directly to a BasePart and
-- renders a flame + its own light at that part's position -- simplest
-- option that needs no mesh/texture assets of its own. A PointLight rides
-- along too since Fire's own light only affects nearby dynamic lighting
-- faintly; the PointLight is what actually lights up a dark trunk/nearby
-- ground at night.
local FIRE_COLOR = Color3.fromRGB(255, 142, 36)
local FIRE_SECONDARY_COLOR = Color3.fromRGB(255, 60, 0)
-- [stated] "make it bigger" -- Fire.Size is roughly the flame's height in
-- studs; bumped up from the original 12 along with the light to match.
local FIRE_SIZE = 22
local FIRE_HEAT = 15
local FIRE_LIGHT_BRIGHTNESS = 3
local FIRE_LIGHT_RANGE = 28
local FIRE_EFFECT_NAME = "ForestFireFlame"
local FIRE_LIGHT_NAME = "ForestFireGlow"

-- [stated] "is it possible to add smoky effects/sight limiting near the
-- active fires? I want the player to have little visibility when inside
-- the fire, with a lot of smoke effects coming off of it" -- a legacy
-- Smoke instance, same category of lightweight built-in effect as the
-- Fire object above (no mesh/texture asset needed), parented right
-- alongside each Fire+PointLight pair so it rides along with anything
-- that already moves/destroys that anchor (the falling-tree tween,
-- Schedule_Fire_Extinguish, Remove_Fire_Effect, the ground-fire cleanup
-- loop) with no extra code anywhere. Sized bigger than the flame itself
-- per fire type, since "a lot of smoke" should read as billowing out past
-- the fire's own visual edges, not matching them exactly. The actual
-- player-visibility reduction is handled client-side instead (see
-- ForestFireVisibility.lua, StarterPlayerScripts) -- Lighting.FogEnd only
-- affects the single client that sets it when changed from a LocalScript,
-- so it can't be done here on the server without blinding every player at
-- once regardless of where they are.
local SMOKE_COLOR = Color3.fromRGB(70, 66, 62)
local SMOKE_OPACITY = 0.55
local SMOKE_RISE_VELOCITY = 5
local SMOKE_NAME = "ForestFireSmoke"
local SMOKE_SECOND_NAME = "ForestFireSecondSmoke"
local SMOKE_GROUND_NAME = "ForestFireGroundSmoke"
-- How much bigger than the paired Fire's own Size the Smoke's Size is --
-- applied per call site below rather than one flat constant, since base/
-- second/ground fires already roll very different size ranges.
local SMOKE_SIZE_MULTIPLIER = 1.6

-- Shared tag so the client-side visibility script (ForestFireVisibility.lua,
-- StarterPlayerScripts) can find every CURRENTLY ACTIVE fire anchor with one
-- CollectionService:GetTagged call, rather than re-deriving "is this tree on
-- fire" from attributes on every live tree every frame. Tagging the ANCHOR
-- itself (not the tree Model) means the tag's lifetime already exactly
-- matches "this fire is actually burning right now" for free -- it
-- disappears the instant Destroy() runs, same way GROUND_FIRE_TAG already
-- works for ground-fire cleanup, no separate untagging code needed anywhere.
local FIRE_SOURCE_TAG = "ForestFireActiveSource"

-- [stated] "randomly add a second fire on the trees, a randomly smaller
-- size and a random distance up or down the tree" -- a second, independent
-- Fire+PointLight pair per tree, rolled once per ignition, smaller than the
-- base fire and sitting somewhere else along the trunk instead of always
-- at the very base. Not every tree gets one (TREE_SECOND_FIRE_CHANCE) --
-- that's what makes a burning cluster look varied instead of every tree
-- having an identical pair of flames.
local TREE_SECOND_FIRE_CHANCE = 0.5
local TREE_SECOND_FIRE_MIN_SIZE = 8
local TREE_SECOND_FIRE_MAX_SIZE = 16
-- [stated] "a random distance up or down the tree" -- the hit point the
-- raycast below finds is treated as the "up" end (roughly where the tree's
-- own geometry starts, looking straight down from above), and this is how
-- far DOWN from that point the second fire can land -- 0 means right at
-- the hit point itself (the "up" end of the random range), the max is how
-- far down the trunk it can wander from there.
local TREE_SECOND_FIRE_MIN_DROP = 0
local TREE_SECOND_FIRE_MAX_DROP = 18
local SECOND_FIRE_ANCHOR_NAME = "ForestFireSecondAnchor"
local SECOND_FIRE_EFFECT_NAME = "ForestFireSecondFlame"
local SECOND_FIRE_LIGHT_NAME = "ForestFireSecondGlow"
local SECOND_FIRE_LIGHT_BRIGHTNESS = 1.5
local SECOND_FIRE_LIGHT_RANGE = 16

-- [stated] "at random when a piece of terrain is replaced have a fire
-- spawn on top of it of random size" -- a standalone Fire+PointLight that
-- belongs to the SCORCHED GROUND itself, not to any tree, so it has no
-- Model to parent into (unlike the tree fires above) and no attribute to
-- key cleanup off of either -- CollectionService tags it instead, purely
-- so the burn loop's end-of-event cleanup (see trigger(), below) can find
-- and remove every one of these at once without having to track them in a
-- table threaded through Add_Scorch_Mark's caller.
local GROUND_FIRE_TAG = "ForestFireGroundFire"
local GROUND_FIRE_SPAWN_CHANCE = 0.4
local GROUND_FIRE_MIN_SIZE = 6
local GROUND_FIRE_MAX_SIZE = 16
local GROUND_FIRE_LIGHT_BRIGHTNESS = 2
local GROUND_FIRE_LIGHT_RANGE = 20

-- [stated] "would it add too much strain to the game to have each fire
-- given a random timer within 1 minute at which they'll extinguish?" --
-- the opposite, actually: a task.delay timer per fire is practically free
-- (the same lightweight scheduler every task.wait/task.delay call in this
-- project already uses), while the real rendering cost of a forest fire is
-- the Fire+PointLight pair itself -- PointLight in particular is a dynamic
-- light, the single most expensive thing per-instance in this whole
-- feature. Capping each individual fire's own lifetime means far fewer of
-- them are ever alive at once -- this is a net REDUCTION in strain, not an
-- addition. Used by Schedule_Fire_Extinguish below for the purely
-- decorative fires (second tree fire, ground fire); the BASE tree fire
-- rolls this same range too, but through trigger()'s own Ignite/
-- Extinguish_Tree instead, since -- [stated] "have damage/spread also stop
-- once the fire goes out" -- that one additionally has to flip OnFire off,
-- mark the tree Burnt, and drop it out of burning_trees so Damage_Tick/
-- Spread_Tick/Fall_Check stop touching it, not just despawn a visual
-- effect.
-- [stated] "increase the burn time to a random 90-120 seconds" -- widened
-- from the original 15-60s range.
local FIRE_EXTINGUISH_MIN_TIME = 90
local FIRE_EXTINGUISH_MAX_TIME = 120

-- Both tick cadences above expressed as multiples of the base damage tick,
-- so one shared task.wait loop in trigger() can drive all three instead of
-- juggling separate real-time deadlines.
local SPREAD_TICK_TICKS = SPREAD_TICK_INTERVAL / FIRE_DAMAGE_TICK_INTERVAL
local FALL_CHECK_TICKS = FALL_CHECK_INTERVAL / FIRE_DAMAGE_TICK_INTERVAL

-- [stated/inferred] every other environmental damage source in this
-- project (fall damage, knockback resist) already reduces off the
-- target's Endurance -- applied the same way here for consistency. If
-- fire/trunk damage was meant to hit flat instead, delete this block (and
-- the PlayerStats require) and have Apply_Environmental_Damage just call
-- humanoid:TakeDamage(base_damage) directly.
local ENDURANCE_DAMAGE_REDUCTION_PER_POINT = 0.05
local MAX_DAMAGE_REDUCTION = 0.6
local function Apply_Environmental_Damage(player, humanoid, base_damage)
	local endurance = PlayerStats.get(player, "Endurance")
	local reduction = math.min(math.max(endurance - 1, 0) * ENDURANCE_DAMAGE_REDUCTION_PER_POINT, MAX_DAMAGE_REDUCTION)
	humanoid:TakeDamage(base_damage * (1 - reduction))
end

local function Flat_Distance(a, b)
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

-- Walks up from a hit part to whichever ancestor actually carries the tag
-- -- NOT just the nearest ancestor Model, since a tree's Trunk/Leaves could
-- themselves be Models (groups) sitting a level or two below the actual
-- tagged tree instance (the clone StartMatch.lua tags directly).
local function Find_Tagged_Ancestor(instance, tag)
	local current = instance
	while current and current ~= workspace do
		if CollectionService:HasTag(current, tag) then
			return current
		end
		current = current.Parent
	end
	return nil
end

-- Shared by all three fire anchors (base tree fire, second tree fire,
-- ground fire) -- rolls a random lifetime under a minute and destroys the
-- anchor (taking its Fire+PointLight+Smoke with it) once that time is up.
-- Guards with anchor.Parent in case something else (Remove_Fire_Effect, a
-- falling tree, the tree itself getting destroyed) already removed it --
-- Destroy() on an already-destroyed Instance is harmless on its own, but
-- checking first keeps this consistent with how the rest of the file
-- guards Parent before acting.
local function Schedule_Fire_Extinguish(anchor)
	local lifetime = math.random(FIRE_EXTINGUISH_MIN_TIME, FIRE_EXTINGUISH_MAX_TIME)
	task.delay(lifetime, function()
		if anchor.Parent then
			anchor:Destroy()
		end
	end)
end

-- Strips leaves and recolors the trunk toward char-black. Handles both a
-- single-MeshPart Trunk and one with its own sub-parts, same dual-branch
-- Anchor_Model already uses in StartMatch.lua for "is this a bare BasePart
-- or a Model".
local CHAR_COLOR = Color3.fromRGB(18, 16, 15)

-- [stated] "it looks like everything is firing fine from the scripts, but
-- it isn't translating to the visuals" -- a MeshPart with a SurfaceAppearance
-- child (PBR ColorMap/NormalMap/RoughnessMap) renders entirely off that PBR
-- texture set and SILENTLY IGNORES the part's own .Color property -- same
-- PBR-asset quirk this project's Deer rig materials hit earlier. Marketplace
-- tree packs with realistic bark textures are built exactly this way, which
-- would explain Char_Tree running with zero errors every time yet never
-- visibly blackening anything. Destroying the SurfaceAppearance lets the
-- flat Color actually show. Decal/Texture objects are a separate legacy
-- case (they have their own Color3 that tints their image) -- handled too,
-- just in case any trunk uses one of those instead of/alongside PBR.
local function Char_Parts(root, color)
	local surface_appearances_removed = 0
	local base_parts_colored = 0
	local decals_tinted = 0
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("SurfaceAppearance") then
			descendant:Destroy()
			surface_appearances_removed += 1
		elseif descendant:IsA("BasePart") then
			descendant.Color = color
			base_parts_colored += 1
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Color3 = color
			decals_tinted += 1
		end
	end
	if root:IsA("BasePart") then
		root.Color = color
		base_parts_colored += 1
	end
	return surface_appearances_removed, base_parts_colored, decals_tinted
end

local function Char_Tree(tree_model)
	local leaves = tree_model:FindFirstChild("Leaves")
	if leaves then
		leaves:Destroy()
	else
		warn("[ForestFireDebug] Char_Tree: no 'Leaves' child found on " .. tree_model:GetFullName() .. " -- nothing to delete, tree won't visibly lose its leaves")
	end
	local trunk = tree_model:FindFirstChild("Trunk")
	if trunk then
		print("[ForestFireDebug] Char_Tree: trunk on " .. tree_model:GetFullName() .. " is a " .. trunk.ClassName)
		-- [stated] "some of the trees aren't blackening and my best guess is
		-- the alpine tree models which are different in that their trunks
		-- don't have a surface appearance which may be how changing their
		-- color is silently failing" -- worth checking directly rather than
		-- assuming: a MeshPart WITHOUT a SurfaceAppearance should still
		-- darken from .Color (SurfaceAppearance is specifically what makes
		-- Color get ignored -- no SurfaceAppearance means Color should
		-- apply normally), so "no SurfaceAppearance" shouldn't actually
		-- explain a blackening failure by itself. Logging Size/Material/
		-- Transparency/Reflectance (and MeshId/TextureID if it's a
		-- MeshPart) here so the next test's Output log can show what's
		-- actually different about the trees that don't visibly char,
		-- rather than guessing further.
		if trunk:IsA("BasePart") then
			local mesh_info = ""
			if trunk:IsA("MeshPart") then
				mesh_info = (", MeshId=%s, TextureID=%s"):format(tostring(trunk.MeshId), tostring(trunk.TextureID))
			end
			print(("[ForestFireDebug] Char_Tree: trunk details -- Size=%s, Material=%s, Transparency=%s, Reflectance=%s%s"):format(tostring(trunk.Size), tostring(trunk.Material), tostring(trunk.Transparency), tostring(trunk.Reflectance), mesh_info))
		end
		local surface_appearances_removed, base_parts_colored, decals_tinted = Char_Parts(trunk, CHAR_COLOR)
		print(("[ForestFireDebug] Char_Tree: trunk recolor -- %d SurfaceAppearance removed, %d BasePart(s) colored, %d Decal/Texture tinted"):format(surface_appearances_removed, base_parts_colored, decals_tinted))
		if surface_appearances_removed > 0 then
			print("[ForestFireDebug] Char_Tree: this tree HAD a SurfaceAppearance (PBR material) that would have silently ignored .Color -- removing it is what should finally make the trunk visibly blacken")
		end
	else
		warn("[ForestFireDebug] Char_Tree: no 'Trunk' child found on " .. tree_model:GetFullName() .. " -- nothing to blacken, tree won't visibly char")
	end
end

-- [stated] "some of the fires aren't paired to a tree at all? rather
-- they're just floating in the air" -- the pivot fix (below, now replaced)
-- was right for the tree it was tested against, but trusting the Model's
-- own pivot turned out to be the SAME mistake as trusting GetBoundingBox
-- before it, just milder: it assumes every tree asset was authored with
-- its pivot at the same place relative to its own visual base, and
-- different tree packs merged into this project's Nature folder evidently
-- don't agree on that convention (StartMatch.lua's spawn code plants every
-- tree at the same height+23 formula regardless of type, which only lines
-- the VISUAL base up with the ground if a given asset's pivot-to-base
-- offset happens to match whatever that 23 was tuned against -- one that
-- disagrees ends up with its pivot, and therefore this anchor, sitting at
-- the wrong height).
--
-- The actual fix: stop trusting ANY tree-model-specific convention
-- (pivot OR bounding box) and instead ask the terrain itself where the
-- ground really is, the same proven technique Add_Scorch_Mark already
-- uses. The tree's pivot is still used for X/Z (StartMatch.lua always
-- plants that correctly), but Y comes from a raycast straight down from
-- well above any terrain height on this map -- high enough that even a
-- wildly wrong pivot Y (we've seen errors upward of 70 studs between
-- different tree assets' own conventions) still starts safely above
-- ground, so this is robust across every tree type without needing to
-- know or guess each asset's own quirks.
-- [stated] "most of the fires on top of the trees, I'm assuming that the
-- fire's raycast hits the top of the tree and leaves it there, can we
-- filter out everything apart from terrain for the raycast?" -- exactly
-- right: excluding just tree_model itself still leaves every OTHER tree's
-- leaves/trunk, rock, building, prop etc. in the ray's path, and in a
-- dense forest a ray from 300 studs up is very likely to clip a
-- NEIGHBORING tree's canopy before it ever reaches the ground. Switched
-- from an Exclude-one-thing filter to an Include-only-Terrain filter --
-- same pattern StartMatch.lua's own terrain_raycast_params already uses
-- for its ground placement -- so this can ONLY ever hit the actual
-- terrain, never any instance sitting above it, tree_model included or
-- not.
local GROUND_RAYCAST_START_HEIGHT = 300 -- studs -- comfortably above anything this map's terrain generates
local GROUND_RAYCAST_DISTANCE = 600
local terrain_raycast_params = RaycastParams.new()
terrain_raycast_params.FilterType = Enum.RaycastFilterType.Include
terrain_raycast_params.FilterDescendantsInstances = {Terrain}

local function Compute_Base_Position(tree_model)
	local pivot_position = tree_model:GetPivot().Position
	local origin = Vector3.new(pivot_position.X, GROUND_RAYCAST_START_HEIGHT, pivot_position.Z)
	local result = workspace:Raycast(origin, Vector3.new(0, -GROUND_RAYCAST_DISTANCE, 0), terrain_raycast_params)
	if result then
		return result.Position
	end
	warn("[ForestFireDebug] Compute_Base_Position: ground raycast MISSED above " .. tree_model:GetFullName() .. " at X=" .. tostring(pivot_position.X) .. " Z=" .. tostring(pivot_position.Z) .. " -- falling back to the model's own pivot position, which may be unreliable for this tree type")
	return pivot_position
end

local FIRE_ANCHOR_NAME = "ForestFireAnchor"

-- [stated] "the terrain placements will sometimes spawn halfway up the
-- tree / sticking out of the ground... on mountains specifically the
-- spawning will stick out of the ground a lot" -- a flat FillBlock slab
-- assumes flat ground: it's flush at the exact point the raycast sampled,
-- but on a slope the rest of the 20x20 footprint tilts away from that one
-- sample, so part of it ends up poking out above the real surface (steeper
-- on a mountain, worse the farther from the sample point you get) while
-- another part gets buried with nothing visible at all.
--
-- [stated] "would a better way... be to raycast down to the terrain from
-- the tree's position and replace the chunk found there?" -- even better
-- than finding one chunk at one point: read the EXISTING solid/air
-- pattern across the whole footprint with ReadVoxels and only recolor
-- cells that are already solid, leaving every air cell alone. That means
-- this can never add matter above the real surface (no more poking out)
-- and never leaves a gap below it (no more getting buried) -- whatever
-- shape the terrain actually has within the footprint, flat or a 45-degree
-- mountain face, comes through unchanged, just recolored where it's
-- solid. The initial raycast still matters -- it's what decides roughly
-- WHERE (vertically) to center the read/write region -- but it no longer
-- has to be exactly right the way a single-sample FillBlock needed it to
-- be, since SCORCH_VERTICAL_MARGIN just has to be generous enough that
-- the real surface anywhere in the footprint falls inside the region,
-- not land on it precisely.
-- [stated] "increase the number of replaced terrain from each instance to
-- every terrain block surrounding that instant as well" -- widened from
-- 10 to 18 (so a 36x36 footprint instead of 20x20). At typical spread
-- spacing this now overlaps with neighboring burning trees' own scorch
-- regions, so a cluster of burning trees ends up with one continuous
-- scorched floor instead of separate small patches.
local SCORCH_RADIUS = 18 -- half-width/depth of the footprint, studs
local SCORCH_VERTICAL_MARGIN = 16 -- studs above/below the raycast hit the read/write region reaches -- generous on purpose so a slope's real surface still falls inside it even though the single raycast sample won't match every corner
local VOXEL_RESOLUTION = 4 -- legacy Terrain's fixed voxel size -- ReadVoxels/WriteVoxels require exactly this

-- [stated] "just have slate placed instead of lava" -- back to one fixed
-- material, no more alternating/weighting (that whole idea is dropped,
-- not just reweighted to rarely pick CrackedLava).
local SCORCH_MATERIAL = Enum.Material.Slate

-- [stated] "is it possible to remove all plants that's touching the
-- replaced terrain?" -- yes, same tagged-ancestor lookup Find_Tagged_Ancestor
-- already does for trees, just pointed at LIVE_PLANT_TAG instead and run
-- across every part physically overlapping the same box the terrain edit
-- just touched, rather than one specific tree. GetPartBoundsInBox only
-- returns parts, so each hit still has to walk up to find the actual
-- plant Model (or bare Part, for ones with no wrapper) that's tagged.
local function Remove_Plants_In_Region(center, size)
	local overlap_params = OverlapParams.new()
	overlap_params.FilterType = Enum.RaycastFilterType.Exclude
	overlap_params.FilterDescendantsInstances = {}
	local removed_plants = {}
	local removed_count = 0
	for _, part in ipairs(workspace:GetPartBoundsInBox(CFrame.new(center), size, overlap_params)) do
		local plant = Find_Tagged_Ancestor(part, LIVE_PLANT_TAG)
		if plant and not removed_plants[plant] then
			removed_plants[plant] = true
			removed_count += 1
			plant:Destroy()
		end
	end
	return removed_count
end

-- [stated] "add these boulders to the models that get changed when near
-- the flames... tagging them when terrain is replaced to turn them
-- varying shades of gray to black... similar to the trees of removing
-- their texture before changing it" -- reuses Char_Parts exactly like
-- Char_Tree does (strips any SurfaceAppearance/PBR texture first, same
-- fix that made tree trunks visibly blacken), just with a random
-- gray-to-black color rolled fresh per rock instead of the trees' single
-- fixed CHAR_COLOR, so a whole scorched area doesn't end up with every
-- boulder in it looking identical.
-- [stated] "can the scorched boulder colors not include such a dark
-- black, lighten the darkest color that is" -- raised the floor, not the
-- ceiling, so the lightest rocks stay the same and only the darkest end
-- of the range backs off from near-black.
local ROCK_CHAR_MIN_BRIGHTNESS = 45 -- darkest shade now allowed -- was 15 (near-black)
local ROCK_CHAR_MAX_BRIGHTNESS = 70 -- lighter gray ceiling, unchanged
local function Random_Rock_Char_Color()
	local brightness = math.random(ROCK_CHAR_MIN_BRIGHTNESS, ROCK_CHAR_MAX_BRIGHTNESS)
	return Color3.fromRGB(brightness, brightness, brightness)
end

local function Char_Rock(rock_model)
	local color = Random_Rock_Char_Color()
	local surface_appearances_removed, base_parts_colored, decals_tinted = Char_Parts(rock_model, color)
	print(("[ForestFireDebug] Char_Rock: %s recolored to %s -- %d SurfaceAppearance removed, %d BasePart(s) colored, %d Decal/Texture tinted"):format(rock_model:GetFullName(), tostring(color), surface_appearances_removed, base_parts_colored, decals_tinted))
end

-- Same find-everything-overlapping-the-box approach as
-- Remove_Plants_In_Region, but chars rocks instead of destroying them, and
-- guards with a "Scorched" attribute so a rock sitting inside overlapping
-- scorch regions from several nearby trees (likely now that SCORCH_RADIUS
-- is wide enough for neighboring trees' regions to overlap) only gets
-- charred -- and only rerolls its random color -- once, not on every
-- single tree's scorch mark that happens to reach it.
local function Char_Rocks_In_Region(center, size)
	local overlap_params = OverlapParams.new()
	overlap_params.FilterType = Enum.RaycastFilterType.Exclude
	overlap_params.FilterDescendantsInstances = {}
	local charred_count = 0
	local seen_rocks = {}
	for _, part in ipairs(workspace:GetPartBoundsInBox(CFrame.new(center), size, overlap_params)) do
		local rock = Find_Tagged_Ancestor(part, LIVE_ROCK_TAG)
		if rock and not seen_rocks[rock] then
			seen_rocks[rock] = true
			if not rock:GetAttribute("Scorched") then
				rock:SetAttribute("Scorched", true)
				Char_Rock(rock)
				charred_count += 1
			end
		end
	end
	return charred_count
end

-- [stated] "at random when a piece of terrain is replaced have a fire
-- spawn on top of it of random size" -- picks a random point within the
-- scorch footprint (not always dead center on ground_position, so a wide
-- scorched patch doesn't always get its ground fire in exactly the same
-- spot) and raycasts down fresh at THAT X/Z using the same terrain-only
-- filter everything else here uses, since ground_position's own Y was only
-- ever verified at the tree's own X/Z -- the rest of a SCORCH_RADIUS-wide
-- footprint can sit at a meaningfully different height on sloped terrain.
local function Add_Random_Ground_Fire(ground_position)
	if math.random() > GROUND_FIRE_SPAWN_CHANCE then
		return
	end
	local offset_x = math.random(-SCORCH_RADIUS, SCORCH_RADIUS)
	local offset_z = math.random(-SCORCH_RADIUS, SCORCH_RADIUS)
	local probe_origin = Vector3.new(ground_position.X + offset_x, GROUND_RAYCAST_START_HEIGHT, ground_position.Z + offset_z)
	local result = workspace:Raycast(probe_origin, Vector3.new(0, -GROUND_RAYCAST_DISTANCE, 0), terrain_raycast_params)
	local spawn_position = result and result.Position or ground_position
	if not result then
		warn("[ForestFireDebug] Add_Random_Ground_Fire: ground raycast MISSED near " .. tostring(ground_position) .. " -- falling back to the scorch mark's own center position")
	end
	local anchor = Instance.new("Part")
	anchor.Name = "ForestFireGroundAnchor"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Anchored = true
	anchor.CFrame = CFrame.new(spawn_position)
	anchor.Parent = workspace
	CollectionService:AddTag(anchor, GROUND_FIRE_TAG)
	CollectionService:AddTag(anchor, FIRE_SOURCE_TAG)
	local fire_size = math.random(GROUND_FIRE_MIN_SIZE, GROUND_FIRE_MAX_SIZE)
	local fire = Instance.new("Fire")
	fire.Name = FIRE_EFFECT_NAME
	fire.Color = FIRE_COLOR
	fire.SecondaryColor = FIRE_SECONDARY_COLOR
	fire.Size = fire_size
	fire.Heat = FIRE_HEAT
	fire.Parent = anchor
	local light = Instance.new("PointLight")
	light.Name = FIRE_LIGHT_NAME
	light.Color = FIRE_COLOR
	light.Brightness = GROUND_FIRE_LIGHT_BRIGHTNESS
	light.Range = GROUND_FIRE_LIGHT_RANGE
	light.Parent = anchor
	local smoke = Instance.new("Smoke")
	smoke.Name = SMOKE_GROUND_NAME
	smoke.Color = SMOKE_COLOR
	smoke.Opacity = SMOKE_OPACITY
	smoke.RiseVelocity = SMOKE_RISE_VELOCITY
	smoke.Size = fire_size * SMOKE_SIZE_MULTIPLIER
	smoke.Parent = anchor
	Schedule_Fire_Extinguish(anchor)
	print(("[ForestFireDebug] Add_Random_Ground_Fire: spawned standalone Fire(Size=%d)+Smoke at %s, will self-extinguish in %d-%ds"):format(fire_size, tostring(spawn_position), FIRE_EXTINGUISH_MIN_TIME, FIRE_EXTINGUISH_MAX_TIME))
end

-- ground_position is now ALREADY a verified ground-raycast hit (Compute_Base_Position
-- does that raycast once, up front, for both this and Add_Fire_Effect to
-- share) -- no need for this to do its own separate raycast off of it
-- anymore, which also means one less independent raycast that could fail.
local function Add_Scorch_Mark(tree_model, ground_position)
	local region = Region3.new(
		Vector3.new(ground_position.X - SCORCH_RADIUS, ground_position.Y - SCORCH_VERTICAL_MARGIN, ground_position.Z - SCORCH_RADIUS),
		Vector3.new(ground_position.X + SCORCH_RADIUS, ground_position.Y + SCORCH_VERTICAL_MARGIN, ground_position.Z + SCORCH_RADIUS)
	):ExpandToGrid(VOXEL_RESOLUTION)
	local materials, occupancies = Terrain:ReadVoxels(region, VOXEL_RESOLUTION)
	local recolored = 0
	for x = 1, materials.Size.X do
		for y = 1, materials.Size.Y do
			for z = 1, materials.Size.Z do
				-- Only touch cells that are already solid ground -- an
				-- occupancy of 0 is air, and leaving those alone is what
				-- keeps this from ever adding a bulge above the surface.
				if occupancies[x][y][z] > 0 then
					materials[x][y][z] = SCORCH_MATERIAL
					recolored += 1
				end
			end
		end
	end
	Terrain:WriteVoxels(region, VOXEL_RESOLUTION, materials, occupancies)
	local region_size = Vector3.new(SCORCH_RADIUS * 2, SCORCH_VERTICAL_MARGIN * 2, SCORCH_RADIUS * 2)
	local removed_plant_count = Remove_Plants_In_Region(ground_position, region_size)
	local charred_rock_count = Char_Rocks_In_Region(ground_position, region_size)
	print(("[ForestFireDebug] Add_Scorch_Mark: recolored %d solid voxel cell(s) to %s within a %dx%dx%d region centered near %s, removed %d plant(s), charred %d rock(s)"):format(recolored, tostring(SCORCH_MATERIAL), SCORCH_RADIUS * 2, SCORCH_VERTICAL_MARGIN * 2, SCORCH_RADIUS * 2, tostring(ground_position), removed_plant_count, charred_rock_count))
	Add_Random_Ground_Fire(ground_position)
end

-- [stated] "I'm not seeing any fire effects, do we have those plugged in?"
-- then "make it bigger" -- a dedicated invisible anchor Part at the tree's
-- base (rather than reusing Trunk, which could be centered anywhere) is
-- what both the Fire/PointLight attach to and what makes removal trivial
-- later (destroy the one anchor instead of hunting for Fire/PointLight by
-- name on a part we don't otherwise want to touch). Parented INTO
-- tree_model so Model:PivotTo (the falling-trunk tween) carries it along
-- automatically like every other descendant part.
-- [stated] "randomly add a second fire on the trees, a randomly smaller
-- size and a random distance up or down the tree, I suspect the best way
-- to do this is raycast from high straight down until hitting the tree,
-- then move a random amount further down and place the fire" -- exactly
-- that, using the tree's OWN geometry as the Include filter target this
-- time (unlike Compute_Base_Position's terrain_raycast_params, which is
-- deliberately filtered to ONLY ever hit Terrain) -- so this ray is
-- guaranteed to stop at wherever tree_model's own canopy/trunk first
-- blocks it, not the ground underneath.
local function Add_Second_Fire_Effect(tree_model)
	if math.random() > TREE_SECOND_FIRE_CHANCE then
		return
	end
	local pivot_position = tree_model:GetPivot().Position
	local tree_only_params = RaycastParams.new()
	tree_only_params.FilterType = Enum.RaycastFilterType.Include
	tree_only_params.FilterDescendantsInstances = {tree_model}
	local origin = Vector3.new(pivot_position.X, GROUND_RAYCAST_START_HEIGHT, pivot_position.Z)
	local result = workspace:Raycast(origin, Vector3.new(0, -GROUND_RAYCAST_DISTANCE, 0), tree_only_params)
	if not result then
		warn("[ForestFireDebug] Add_Second_Fire_Effect: raycast never hit " .. tree_model:GetFullName() .. "'s own geometry from above -- skipping the second fire for this tree")
		return
	end
	local drop = math.random(TREE_SECOND_FIRE_MIN_DROP, TREE_SECOND_FIRE_MAX_DROP)
	local fire_position = result.Position - Vector3.new(0, drop, 0)
	local anchor = Instance.new("Part")
	anchor.Name = SECOND_FIRE_ANCHOR_NAME
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Anchored = true
	anchor.CFrame = CFrame.new(fire_position)
	anchor.Parent = tree_model
	CollectionService:AddTag(anchor, FIRE_SOURCE_TAG)
	local fire_size = math.random(TREE_SECOND_FIRE_MIN_SIZE, TREE_SECOND_FIRE_MAX_SIZE)
	local fire = Instance.new("Fire")
	fire.Name = SECOND_FIRE_EFFECT_NAME
	fire.Color = FIRE_COLOR
	fire.SecondaryColor = FIRE_SECONDARY_COLOR
	fire.Size = fire_size
	fire.Heat = FIRE_HEAT
	fire.Parent = anchor
	local light = Instance.new("PointLight")
	light.Name = SECOND_FIRE_LIGHT_NAME
	light.Color = FIRE_COLOR
	light.Brightness = SECOND_FIRE_LIGHT_BRIGHTNESS
	light.Range = SECOND_FIRE_LIGHT_RANGE
	light.Parent = anchor
	local smoke = Instance.new("Smoke")
	smoke.Name = SMOKE_SECOND_NAME
	smoke.Color = SMOKE_COLOR
	smoke.Opacity = SMOKE_OPACITY
	smoke.RiseVelocity = SMOKE_RISE_VELOCITY
	smoke.Size = fire_size * SMOKE_SIZE_MULTIPLIER
	smoke.Parent = anchor
	Schedule_Fire_Extinguish(anchor)
	print(("[ForestFireDebug] Add_Second_Fire_Effect: attached second Fire(Size=%d)+Smoke %d studs below the tree-hit raycast at %s on %s, will self-extinguish in %d-%ds"):format(fire_size, drop, tostring(fire_position), tree_model:GetFullName(), FIRE_EXTINGUISH_MIN_TIME, FIRE_EXTINGUISH_MAX_TIME))
end

local function Add_Fire_Effect(tree_model)
	local base_position = Compute_Base_Position(tree_model)
	local anchor = Instance.new("Part")
	anchor.Name = FIRE_ANCHOR_NAME
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Anchored = true
	anchor.CFrame = CFrame.new(base_position)
	anchor.Parent = tree_model
	CollectionService:AddTag(anchor, FIRE_SOURCE_TAG)
	local fire = Instance.new("Fire")
	fire.Name = FIRE_EFFECT_NAME
	fire.Color = FIRE_COLOR
	fire.SecondaryColor = FIRE_SECONDARY_COLOR
	fire.Size = FIRE_SIZE
	fire.Heat = FIRE_HEAT
	fire.Parent = anchor
	local light = Instance.new("PointLight")
	light.Name = FIRE_LIGHT_NAME
	light.Color = FIRE_COLOR
	light.Brightness = FIRE_LIGHT_BRIGHTNESS
	light.Range = FIRE_LIGHT_RANGE
	light.Parent = anchor
	local smoke = Instance.new("Smoke")
	smoke.Name = SMOKE_NAME
	smoke.Color = SMOKE_COLOR
	smoke.Opacity = SMOKE_OPACITY
	smoke.RiseVelocity = SMOKE_RISE_VELOCITY
	smoke.Size = FIRE_SIZE * SMOKE_SIZE_MULTIPLIER
	smoke.Parent = anchor
	-- No Schedule_Fire_Extinguish call here on purpose -- unlike the second
	-- tree fire and the ground fire (both purely decorative), the BASE fire
	-- is what trigger()'s Ignite/Extinguish_Tree uses to decide when this
	-- tree's OnFire/burning_trees/damage/spread state ends, so its timer is
	-- rolled and scheduled there instead, where burning_trees is actually
	-- in scope.
	print(("[ForestFireDebug] Add_Fire_Effect: attached Fire(Size=%d)+PointLight+Smoke to base anchor at %s on %s"):format(FIRE_SIZE, tostring(base_position), tree_model:GetFullName()))
	Add_Scorch_Mark(tree_model, base_position)
	Add_Second_Fire_Effect(tree_model)
end

-- Called once the burn window ends and a tree goes permanently Burnt --
-- [stated] "timed burn, then dormant" means the flame itself should stop
-- once the tree stops actively being OnFire, even though the charring
-- (Char_Tree's work) and the scorched ground stay forever. Destroying the
-- one dedicated anchor takes the Fire+PointLight+Smoke (and the
-- FIRE_SOURCE_TAG tag) with it.
local function Remove_Fire_Effect(tree_model)
	local anchor = tree_model:FindFirstChild(FIRE_ANCHOR_NAME)
	if anchor then
		anchor:Destroy()
	end
	-- Second fire (not every tree got one -- TREE_SECOND_FIRE_CHANCE) is its
	-- own separate anchor, so it needs its own separate find-and-destroy
	-- rather than assuming it's there.
	local second_anchor = tree_model:FindFirstChild(SECOND_FIRE_ANCHOR_NAME)
	if second_anchor then
		second_anchor:Destroy()
	end
end

-- Finds live, not-yet-burning trees within SPREAD_RADIUS of a position.
-- No folder to scope the query to (trees spawn loose into workspace
-- alongside everything else) -- every part in range comes back and gets
-- filtered down to actual tagged, still-eligible trees afterward instead.
local function Find_Nearby_Unburnt_Trees(position)
	local overlap_params = OverlapParams.new()
	overlap_params.FilterType = Enum.RaycastFilterType.Exclude
	overlap_params.FilterDescendantsInstances = {}
	local candidates = {}
	local seen = {}
	for _, part in ipairs(workspace:GetPartBoundsInRadius(position, SPREAD_RADIUS, overlap_params)) do
		local tree_model = Find_Tagged_Ancestor(part, LIVE_TREE_TAG)
		if tree_model and not seen[tree_model] then
			seen[tree_model] = true
			if not tree_model:GetAttribute("OnFire") and not tree_model:GetAttribute("Burnt") then
				table.insert(candidates, tree_model)
			end
		end
	end
	return candidates
end

-- Rotates ~85 degrees around the horizontal axis perpendicular to
-- fall_direction, so the tree visibly tips toward wherever the player
-- actually is rather than spinning on its own vertical axis. Rotates
-- around the tree Model's own pivot (same convention the spawn loop's own
-- tilt_x/tilt_z already uses for the small random lean on planting) -- not
-- a ground-anchored hinge at the trunk's base. If that reads as rotating
-- around the tree's middle instead of its base once you see a real tree's
-- pivot point in Studio, that's the thing to adjust first.
local function Compute_Fallen_Cframe(current_cframe, fall_direction)
	local local_fall_direction = current_cframe:VectorToObjectSpace(fall_direction)
	local tilt_x = math.rad(85) * local_fall_direction.Z
	local tilt_z = -math.rad(85) * local_fall_direction.X
	return current_cframe * CFrame.Angles(tilt_x, 0, tilt_z)
end

-- Tweens tree_model from standing to fallen via a CFrameValue, same
-- tween-a-value-then-PivotTo-on-Changed pattern CrateHingeInventory.lua
-- already uses for the crate lid. Damage is checked once, when the fall
-- finishes, against wherever the trunk actually ended up landing.
local function Fall_Tree_Toward(tree_model, fall_direction, game_data)
	local current_cframe = tree_model:GetPivot()
	local fallen_cframe = Compute_Fallen_Cframe(current_cframe, fall_direction)
	local cframe_value = Instance.new("CFrameValue")
	cframe_value.Value = current_cframe
	cframe_value.Changed:Connect(function(new_cframe)
		tree_model:PivotTo(new_cframe)
	end)
	local tween = TweenService:Create(
		cframe_value,
		TweenInfo.new(FALL_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{Value = fallen_cframe}
	)
	tween.Completed:Connect(function()
		cframe_value:Destroy()
		local landed_position = tree_model:GetPivot().Position
		for player in pairs(game_data.participants) do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChild("Humanoid")
			if root and humanoid and humanoid.Health > 0 and not PlayerCombat.is_invulnerable(player) then
				if Flat_Distance(root.Position, landed_position) <= FALL_DAMAGE_RADIUS then
					Apply_Environmental_Damage(player, humanoid, FALL_DAMAGE)
				end
			end
		end
	end)
	tween:Play()
end

-- Only tries to fall if a participant is actually close enough for it to
-- matter -- [stated] "falling near the players", not just anywhere in the
-- burning cluster.
local function Try_Fall_Tree(tree_model, game_data)
	if not tree_model.Parent or tree_model:GetAttribute("Falling") then
		return
	end
	local tree_position = tree_model:GetPivot().Position
	local nearby_player = nil
	for player in pairs(game_data.participants) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and Flat_Distance(root.Position, tree_position) <= FALL_TRIGGER_RADIUS then
			nearby_player = player
			break
		end
	end
	if not nearby_player or math.random() > FALL_CHANCE_PER_CHECK then
		return
	end
	tree_model:SetAttribute("Falling", true)
	local root = nearby_player.Character.HumanoidRootPart
	local to_player = root.Position - tree_position
	local flat_direction = Vector3.new(to_player.X, 0, to_player.Z)
	local fall_direction = flat_direction.Magnitude > 0.1 and flat_direction.Unit or Vector3.new(1, 0, 0)
	Fall_Tree_Toward(tree_model, fall_direction, game_data)
end

-- [stated] "random zone each match" -- answered by StartMatch.lua's own
-- reservoir sampling during tree spawning rather than any zone computation
-- here: game_data.forest_fire_origin_trees is just whichever 3 trees that
-- picked, uniformly at random across however many trees ended up spawning.
-- [stated] "rather than 1 point of origin make it 3 points... fire will
-- start on all 3 locations" -- every valid entry gets ignited up front,
-- below; everything after that (spread/damage/falling trunks) already
-- operates on the shared burning_trees set regardless of how many fires
-- it started from, so nothing past this point needed to change for that.
function ForestFireEvent.trigger(game_data)
	print("[ForestFireDebug] ForestFireEvent.trigger called")
	local origin_trees = game_data.forest_fire_origin_trees
	if not origin_trees or #origin_trees == 0 then
		warn("[ForestFireEvent] no forest_fire_origin_trees on game_data -- StartMatch never picked any trees to start the fire from this match, skipping")
		return
	end
	print(("[ForestFireDebug] trigger: %d origin tree(s) on game_data"):format(#origin_trees))

	local burning_trees = {} -- tree_model = true, while OnFire this match

	-- [stated] "have damage/spread also stop once the fire goes out" -- the
	-- early-burnout counterpart to the loop's own end-of-window cleanup
	-- below (same three things: OnFire false, Burnt true, Remove_Fire_Effect),
	-- just triggered per-tree by that tree's own random timer instead of
	-- only once at the very end of ACTIVE_BURN_DURATION. Removing the tree
	-- from burning_trees here is what actually stops Damage_Tick/
	-- Spread_Tick/Fall_Check from touching it -- all three only ever
	-- operate by iterating burning_trees, so once a tree's key is gone none
	-- of them see it again.
	-- Guarded on OnFire still being true so this can't double-handle a tree
	-- that already went Burnt some other way first (the window simply
	-- ending while this tree's own timer hadn't fired yet, or it burning
	-- out some other way in the future) -- without the guard this would
	-- just redundantly destroy already-nil anchors and reset already-set
	-- attributes, harmless but noisy.
	local function Extinguish_Tree(tree_model)
		if not tree_model:GetAttribute("OnFire") then
			return
		end
		tree_model:SetAttribute("OnFire", false)
		tree_model:SetAttribute("Burnt", true)
		Remove_Fire_Effect(tree_model)
		burning_trees[tree_model] = nil
		print(("[ForestFireDebug] Extinguish_Tree: %s's fire burned out -- marked Burnt, damage/spread from this tree stop now"):format(tree_model:GetFullName()))
	end

	local function Ignite(tree_model)
		if not tree_model.Parent then
			warn("[ForestFireDebug] Ignite: tree_model has no Parent (already destroyed/unparented), skipping ignition")
			return
		end
		tree_model:SetAttribute("OnFire", true)
		tree_model:SetAttribute("OnFireSince", os.clock())
		Char_Tree(tree_model)
		Add_Fire_Effect(tree_model)
		burning_trees[tree_model] = true
		local burn_time = math.random(FIRE_EXTINGUISH_MIN_TIME, FIRE_EXTINGUISH_MAX_TIME)
		task.delay(burn_time, Extinguish_Tree, tree_model)
		print(("[ForestFireDebug] Ignited %s at %s, will burn for %ds"):format(tree_model:GetFullName(), tostring(tree_model:GetPivot().Position), burn_time))
	end

	for i, origin_tree in ipairs(origin_trees) do
		if origin_tree and origin_tree.Parent then
			Ignite(origin_tree)
		else
			warn(("[ForestFireDebug] origin tree #%d invalid at trigger time (nil or no Parent)"):format(i))
		end
	end
	if not next(burning_trees) then
		warn("[ForestFireEvent] none of this match's forest_fire_origin_trees were still valid at trigger time, skipping")
		return
	end

	local function Spread_Tick()
		local newly_ignited = {}
		local seen_this_tick = {}
		local ignited_this_tick = 0
		local burning_count = 0
		local candidates_seen = 0
		for tree_model in pairs(burning_trees) do
			burning_count += 1
			if ignited_this_tick >= MAX_IGNITIONS_PER_TICK then
				continue
			end
			local position = tree_model:GetPivot().Position
			local nearby = Find_Nearby_Unburnt_Trees(position)
			candidates_seen += #nearby
			for _, candidate in ipairs(nearby) do
				if ignited_this_tick >= MAX_IGNITIONS_PER_TICK then
					break
				end
				if not seen_this_tick[candidate] and math.random() < SPREAD_IGNITE_CHANCE then
					seen_this_tick[candidate] = true
					table.insert(newly_ignited, candidate)
					ignited_this_tick += 1
				end
			end
		end
		print(("[ForestFireDebug] Spread_Tick: %d burning tree(s), %d nearby unburnt candidate(s) found (within %d studs), %d newly ignited this tick"):format(burning_count, candidates_seen, SPREAD_RADIUS, #newly_ignited))
		-- Staged and applied only after the burning_trees scan above
		-- finishes -- inserting new keys into burning_trees mid-pairs()-
		-- iteration is undefined behavior in Lua.
		for _, tree_model in ipairs(newly_ignited) do
			Ignite(tree_model)
		end
	end

	local function Damage_Tick()
		for player in pairs(game_data.participants) do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChild("Humanoid")
			if root and humanoid and humanoid.Health > 0 and not PlayerCombat.is_invulnerable(player) then
				for tree_model in pairs(burning_trees) do
					if tree_model.Parent and Flat_Distance(root.Position, tree_model:GetPivot().Position) <= FIRE_DAMAGE_RADIUS then
						Apply_Environmental_Damage(player, humanoid, FIRE_DAMAGE_PER_TICK)
						break -- one tick of damage per player regardless of how many nearby trees are burning
					end
				end
			end
		end
	end

	local function Fall_Check()
		for tree_model in pairs(burning_trees) do
			local burning_since = tree_model:GetAttribute("OnFireSince") or os.clock()
			if os.clock() - burning_since >= MIN_BURN_BEFORE_FALL then
				Try_Fall_Tree(tree_model, game_data)
			end
		end
	end

	task.spawn(function()
		print(("[ForestFireDebug] burn loop starting, game_data.state=%s, will run up to %d seconds"):format(tostring(game_data.state), ACTIVE_BURN_DURATION))
		local burn_until = os.clock() + ACTIVE_BURN_DURATION
		local tick_count = 0
		while os.clock() < burn_until and game_data.state == "matchinprogress" do
			tick_count += 1
			Damage_Tick()
			if tick_count % SPREAD_TICK_TICKS == 0 then
				Spread_Tick()
			end
			if tick_count % FALL_CHECK_TICKS == 0 then
				Fall_Check()
			end
			task.wait(FIRE_DAMAGE_TICK_INTERVAL)
		end
		-- [stated] "timed burn, then dormant" -- every tree still OnFire
		-- when the window ends just becomes permanently Burnt. Purely a
		-- clean attribute state (the loop above has already stopped
		-- calling Damage_Tick/Spread_Tick/Fall_Check on anything by this
		-- point) rather than something required to actually stop the fire.
		-- Most trees will already be gone from burning_trees by now --
		-- Extinguish_Tree (above, scheduled per-tree by Ignite) removes
		-- them as their own individual FIRE_EXTINGUISH_MIN_TIME-MAX_TIME
		-- timer fires -- this only ever mops up whichever trees ignited
		-- late enough that their timer hadn't gone off yet when the match
		-- itself ended or the window closed.
		for tree_model in pairs(burning_trees) do
			if tree_model.Parent then
				tree_model:SetAttribute("OnFire", false)
				tree_model:SetAttribute("Burnt", true)
				Remove_Fire_Effect(tree_model)
			end
		end
		-- Ground fires (Add_Random_Ground_Fire) belong to the scorched
		-- terrain, not to any tree Model, so they were never in
		-- burning_trees to begin with -- CollectionService's tag is what
		-- lets this find and clean up every one of them in one pass instead
		-- of threading a tracking table through Add_Scorch_Mark's caller.
		local ground_fires_removed = 0
		for _, ground_fire_anchor in ipairs(CollectionService:GetTagged(GROUND_FIRE_TAG)) do
			ground_fire_anchor:Destroy()
			ground_fires_removed += 1
		end
		print(("[ForestFireDebug] burn loop ended, all remaining OnFire trees marked Burnt and had their flame effect(s) removed, %d standalone ground fire(s) removed"):format(ground_fires_removed))
	end)
end

return ForestFireEvent
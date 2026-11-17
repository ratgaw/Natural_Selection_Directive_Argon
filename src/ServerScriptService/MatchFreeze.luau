-- Freezes players for the match countdown and event cutscenes.
--
-- Two kinds of freeze:
--   "countdown": the given players can't move, jump or use combat.
--   "cutscene":  same, plus those players can't take damage, their characters
--                are anchored (so wind, knockback and stumbles can't move them),
--                and every mob (wildlife and zombies) stops moving and attacking.
--
-- Each freeze() returns a token; release(token) ends that freeze. Freezes can
-- overlap (e.g. a /test event during a scheduled one) -- a player stays frozen
-- until every freeze that includes them has been released.
--
-- RequestChecker's Sync_Movement calls apply() every frame for frozen players,
-- since it's the only place WalkSpeed is set during play. That also covers a
-- player who respawns mid-freeze.
local MatchFreeze = {}

local active_freezes = {} -- [token] = {players = {[player] = true}, cutscene = bool}
local next_token = 0
local saved_jump_heights = {} -- [humanoid] = JumpHeight before the freeze
local anchored_roots = {} -- [root] = true for roots this module anchored

function MatchFreeze.freeze(players_set, kind)
	next_token += 1
	local players = {}
	local count = 0
	for player in pairs(players_set) do
		players[player] = true
		count += 1
	end
	active_freezes[next_token] = {players = players, cutscene = kind == "cutscene"}
	print(("[FreezeDebug] freeze #%d started: kind=%s, %d player(s)"):format(next_token, tostring(kind), count)) -- temporary, remove once confirmed
	return next_token
end

function MatchFreeze.is_frozen(player)
	for _, freeze in pairs(active_freezes) do
		if freeze.players[player] then
			return true
		end
	end
	return false
end

-- Frozen in a cutscene: can't take damage and is anchored in place.
function MatchFreeze.is_protected(player)
	for _, freeze in pairs(active_freezes) do
		if freeze.cutscene and freeze.players[player] then
			return true
		end
	end
	return false
end

-- True while any cutscene freeze is active: mobs hold still.
function MatchFreeze.mobs_paused()
	for _, freeze in pairs(active_freezes) do
		if freeze.cutscene then
			return true
		end
	end
	return false
end

-- Called every frame for a frozen player (from RequestChecker's Sync_Movement).
function MatchFreeze.apply(player, humanoid, root)
	humanoid.WalkSpeed = 0
	if saved_jump_heights[humanoid] == nil then
		saved_jump_heights[humanoid] = humanoid.JumpHeight
	end
	humanoid.JumpHeight = 0
	if root and MatchFreeze.is_protected(player) and not root.Anchored then
		root.Anchored = true
		anchored_roots[root] = true
		print(("[FreezeDebug] %s: root anchored for cutscene"):format(player.Name)) -- temporary, remove once confirmed
	end
end

-- Undoes apply() for anything no longer covered by an active freeze.
local function Restore_Unfrozen()
	for humanoid, jump_height in pairs(saved_jump_heights) do
		local character = humanoid.Parent
		local player = character and game.Players:GetPlayerFromCharacter(character)
		if not humanoid.Parent or not player or not MatchFreeze.is_frozen(player) then
			if humanoid.Parent then
				humanoid.JumpHeight = jump_height
			end
			saved_jump_heights[humanoid] = nil
		end
	end
	for root in pairs(anchored_roots) do
		local character = root.Parent
		local player = character and game.Players:GetPlayerFromCharacter(character)
		if not root.Parent or not player or not MatchFreeze.is_protected(player) then
			if root.Parent then
				root.Anchored = false
			end
			anchored_roots[root] = nil
		end
	end
end

function MatchFreeze.release(token)
	if not active_freezes[token] then
		return
	end
	active_freezes[token] = nil
	Restore_Unfrozen()
	print(("[FreezeDebug] freeze #%d released; mobs_paused=%s"):format(token, tostring(MatchFreeze.mobs_paused()))) -- temporary, remove once confirmed
	-- WalkSpeed comes back on its own: Sync_Movement sets it normally next frame.
end

return MatchFreeze

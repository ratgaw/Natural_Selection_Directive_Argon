-- [stated/found] "is this player sprinting right now" used to live only as
-- a private local table inside RequestChecker.lua's own SprintRequest
-- handler. Pulled out into its own tiny module so OTHER systems can read
-- the same real sprint intent directly -- specifically PlayerCombat.lua's
-- upper-body Move animation sync, which previously tried to infer "is this
-- the run cycle or the walk cycle" from which of Roblox's own default
-- walk/run leg animations currently carried more blend weight.
--
-- [stated/found] "walk animations still moving too fast while sprint is
-- fine" -- that blend-weight inference turned out to be unreliable: tested
-- live at the Overburdened weight tier (WalkSpeed reduced to 8, confirmed
-- via debug log against PlayerWeight.lua's WalkSpeedMultiplier=0.5 * base
-- 16), Roblox's own walk/run blend gave 78% of its weight to the "run"
-- track even though the player was only walking, not sprinting -- its
-- internal walk/run blend thresholds aren't rescaled to match whatever
-- WalkSpeed the weight system currently has set, so a sufficiently reduced
-- WalkSpeed can read as "mostly run" purely from ordinary walking. Reading
-- the player's actual, server-authoritative sprint request here sidesteps
-- that entirely -- no inference needed.
--
-- Deliberately as small/stateless-shaped as PlayerCombat's own per-player
-- tables (a plain player-keyed table, no cleanup beyond remove_player) --
-- this is the single source of truth RequestChecker.lua now also reads
-- from and writes to, rather than keeping its own separate copy.
local PlayerSprint = {}
local sprinting_players = {}
-- Called from RequestChecker.lua's SprintRequest handler (the raw client
-- request) and from its own Sync_Movement (to force-cancel sprint once
-- stamina runs out) -- those are the only two places this should ever be
-- set from.
function PlayerSprint.set_sprinting(player, is_sprinting)
	sprinting_players[player] = is_sprinting or nil
end
function PlayerSprint.is_sprinting(player)
	return sprinting_players[player] == true
end
function PlayerSprint.remove_player(player)
	sprinting_players[player] = nil
end
return PlayerSprint

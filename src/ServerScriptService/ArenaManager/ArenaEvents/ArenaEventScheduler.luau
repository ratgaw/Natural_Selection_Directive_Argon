local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ArenaManager = game:GetService("ServerScriptService"):WaitForChild("ArenaManager")
local PlayerMinimap = require(ArenaManager:WaitForChild("PlayerMinimap"))

local PAN_DURATION = 5 -- seconds — shared with clients via the announce event
local event_announce = ReplicatedStorage:WaitForChild("EventAnnounce")
local event_warning = ReplicatedStorage:WaitForChild("EventWarning")

local ArenaEventScheduler = {}

-- Shared timing across every pooled event. Fixed schedule for now, but
-- this is the one place that'd change for eventual player-triggered
-- activation later.
local EVENT_INTERVAL = 120 -- TESTING value
local WARNING_LONG = 15
local WARNING_SHORT = 5

local event_pool = {} -- {name = string, run = function(game_data)}

-- Registers a new event type into the pool. Call once per event module.
function ArenaEventScheduler.register_event(name, run_function)
	table.insert(event_pool, {name = name, run = run_function})
end

-- [stated] "the forest fire event cannot trigger as the next event after
-- the flood event" -- Flood's own run (the storm + terrain rise) keeps
-- doing real work in the background (via its own task.spawn inside
-- Run_Event, below) well past the point Run_Event itself returns and the
-- scheduler moves on to its next EVENT_INTERVAL roll, so letting Forest
-- Fire (itself a heavy, thousands-of-trees operation) land right after is
-- what caused "considerable pressure" on a recent test -- the two ended up
-- doing their expensive work at the same time. Tracked as "the last event
-- the scheduler STARTED", not "the last event that finished", since
-- Flood's background work has no way to report back to this module when
-- it's actually done -- Run_Event sets this the moment an event is
-- chosen, not when it returns.
local last_event_name = nil

-- Name -> set of names that must NOT be picked as the very next event
-- after this one fires. A table (not a single hardcoded `if`) so a future
-- second pairing doesn't mean rewriting the selection logic again.
local EVENT_FOLLOW_BANS = {
	["Flood"] = {["Forest Fire"] = true},
}

-- Builds the actual candidate list for one random pick -- everything in
-- event_pool EXCEPT whatever EVENT_FOLLOW_BANS says can't follow
-- last_event_name. Only used by start()'s own random roll -- force_trigger
-- is an explicit, by-name manual override (see its own comment below), not
-- a random pick, so it deliberately does NOT run its target through this
-- filter.
local function Get_Allowed_Candidates()
	local banned = last_event_name and EVENT_FOLLOW_BANS[last_event_name]
	if not banned then
		return event_pool
	end
	local candidates = {}
	for _, entry in ipairs(event_pool) do
		if not banned[entry.name] then
			table.insert(candidates, entry)
		end
	end
	-- If the ban would empty the pool entirely (e.g. only the banned event
	-- is registered right now), fall back to the full pool rather than
	-- stalling the scheduler forever on an empty candidate list.
	if #candidates == 0 then
		return event_pool
	end
	return candidates
end

local function Send_Warnings(event_name, delay_seconds)
	for _, player in ipairs(Players:GetPlayers()) do
		local has_upgrade = PlayerMinimap.has_upgrade(player, "Terrain")
		local warning_time = has_upgrade and WARNING_LONG or WARNING_SHORT
		if warning_time >= delay_seconds then
			event_warning:FireClient(player, event_name, delay_seconds)
		end
	end
end

-- Sets or clears movement freeze for every participant, used to hold
-- players still during the cinematic pan.
local function Freeze_Players(game_data, frozen)
	for player in pairs(game_data.participants) do
		local character = player.Character
		local humanoid = character and character:FindFirstChild("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = frozen and 0 or 16
			humanoid.JumpHeight = frozen and 0 or 7.2
		end
	end
end

-- The actual warning/freeze/pan/run sequence for one chosen event --
-- pulled out of start()'s own loop body (below) so force_trigger (also
-- below) can run the exact same sequence on demand instead of duplicating
-- it. Takes a pool entry ({name=, run=}), not just a name, since both
-- callers already have one in hand by the time this runs.
local function Run_Event(chosen, game_data)
	-- Recorded immediately, before the warnings even go out -- see
	-- last_event_name's own comment above for why this can't wait for
	-- chosen.run to actually finish.
	last_event_name = chosen.name
	Send_Warnings(chosen.name, WARNING_LONG)
	task.wait(WARNING_LONG - WARNING_SHORT)
	Send_Warnings(chosen.name, WARNING_SHORT)
	task.wait(WARNING_SHORT)

	if game_data.state ~= "matchinprogress" then
		warn("[ArenaEventScheduler] Run_Event: '" .. chosen.name .. "' aborted after warnings -- game_data.state is '" .. tostring(game_data.state) .. "', not 'matchinprogress', so chosen.run was never called")
		return
	end

	-- Freeze players and play the cinematic pan on every client while the
	-- event's own setup work runs concurrently.
	event_announce:FireAllClients(chosen.name, PAN_DURATION)
	Freeze_Players(game_data, true)

	task.spawn(function()
		local ok, err = pcall(chosen.run, game_data)
		if not ok then
			warn("Event '" .. chosen.name .. "' failed to run:", err)
		end
	end)

	task.wait(PAN_DURATION)
	Freeze_Players(game_data, false)
end

function ArenaEventScheduler.start(game_data)
	task.spawn(function()
		while game_data.state == "matchinprogress" do
			task.wait(EVENT_INTERVAL - WARNING_LONG)
			if game_data.state ~= "matchinprogress" then
				break
			end
			if #event_pool == 0 then
				task.wait(WARNING_LONG)
				continue
			end

			local candidates = Get_Allowed_Candidates()
			local chosen = candidates[math.random(#candidates)]
			Run_Event(chosen, game_data)
		end
	end)
end

-- [stated] "a command to manually launch the forest fire event so I can
-- test it faster than waiting for it to naturally occur" -- looks the
-- event up by the same name register_event was called with, then runs it
-- through the identical warning/freeze/pan/run sequence start()'s own
-- loop uses, just kicked off immediately instead of waiting for the next
-- EVENT_INTERVAL roll. Doesn't touch or reset start()'s own timer -- this
-- is a fully separate, one-off run, safe to call while that loop is also
-- live. Returns true/false so a caller (a chat command, the Studio
-- Command Bar, etc.) can tell whether the name actually matched anything.
-- Deliberately bypasses EVENT_FOLLOW_BANS/Get_Allowed_Candidates -- this
-- is an explicit, by-name override for testing, not a random roll, so a
-- developer asking for Forest Fire by name still gets Forest Fire even
-- right after a Flood. It still updates last_event_name (via Run_Event),
-- so whatever the NEXT automatic roll does still respects the ban.
function ArenaEventScheduler.force_trigger(name, game_data)
	for _, entry in ipairs(event_pool) do
		if entry.name == name then
			task.spawn(function()
				Run_Event(entry, game_data)
			end)
			return true
		end
	end
	warn("[ArenaEventScheduler] force_trigger: no registered event named '" .. tostring(name) .. "'")
	return false
end

return ArenaEventScheduler
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ArenaManager = game:GetService("ServerScriptService"):WaitForChild("ArenaManager")
local PlayerMinimap = require(ArenaManager:WaitForChild("PlayerMinimap"))
local MatchFreeze = require(game:GetService("ServerScriptService"):WaitForChild("MatchFreeze"))

local PAN_DURATION = 5 -- seconds — shared with clients via the announce event
local event_announce = ReplicatedStorage:WaitForChild("EventAnnounce")
local event_warning = ReplicatedStorage:WaitForChild("EventWarning")

local ArenaEventScheduler = {}

-- Time between events.
local EVENT_INTERVAL = 120 -- TESTING value
local WARNING_LONG = 15
local WARNING_SHORT = 5

local event_pool = {} -- {name = string, run = function(game_data)}

-- Registers a new event type into the pool. Call once per event module.
function ArenaEventScheduler.register_event(name, run_function)
	table.insert(event_pool, {name = name, run = run_function})
end

-- Last event the scheduler started (set at start, since events like Flood keep
-- working in the background after Run_Event returns).
local last_event_name = nil

-- Event name -> events that may not come right after it (Forest Fire right
-- after Flood overloaded the server).
local EVENT_FOLLOW_BANS = {
	["Flood"] = {["Forest Fire"] = true},
}

-- Event pool minus anything banned after last_event_name. Not used by
-- force_trigger.
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
	-- If the ban empties the pool, use the full pool.
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

-- Warnings, freeze, camera pan, then the event's run function. Shared by the
-- scheduler loop and force_trigger.
local function Run_Event(chosen, game_data)
	last_event_name = chosen.name
	Send_Warnings(chosen.name, WARNING_LONG)
	task.wait(WARNING_LONG - WARNING_SHORT)
	Send_Warnings(chosen.name, WARNING_SHORT)
	task.wait(WARNING_SHORT)

	if game_data.state ~= "matchinprogress" then
		warn("[ArenaEventScheduler] Run_Event: '" .. chosen.name .. "' aborted after warnings -- game_data.state is '" .. tostring(game_data.state) .. "', not 'matchinprogress', so chosen.run was never called")
		return
	end

	-- Cutscene freeze for the camera pan: participants can't move or take damage,
	-- and mobs hold still. The event's own setup runs during the pan.
	event_announce:FireAllClients(chosen.name, PAN_DURATION)
	local freeze_token = MatchFreeze.freeze(game_data.participants, "cutscene")

	task.spawn(function()
		local ok, err = pcall(chosen.run, game_data)
		if not ok then
			warn("Event '" .. chosen.name .. "' failed to run:", err)
		end
	end)

	task.wait(PAN_DURATION)
	MatchFreeze.release(freeze_token)
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

-- Runs a named event now through the same sequence (for testing). Ignores
-- follow-bans and doesn't reset the loop's timer. Returns false if no event has
-- that name.
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
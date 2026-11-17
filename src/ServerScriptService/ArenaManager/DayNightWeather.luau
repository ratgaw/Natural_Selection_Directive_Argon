-- [stated] "implement a day/night cycle, along with a randomized weather
-- cycle" -- a self-contained, match-lifecycle-bound environmental system.
-- Scope as clarified: day/night is visual only for now (ClockTime plus
-- an Ambient/OutdoorAmbient/Brightness sweep so night actually reads as
-- dark -- Lighting.ClockTime alone doesn't dim those, they're authored
-- values, not something the engine derives from the sun position).
-- Weather cycles between Clear/Rain/Fog on its own independent timer, NOT
-- tied to time of day. The only gameplay effect asked for is reduced
-- visibility in Rain/Fog -- done the correct in-engine way, by tightening
-- Lighting.FogEnd, rather than anything touching combat/movement. Rain
-- also gets a lightweight per-player rain particle effect so "it's
-- raining" is actually visible, not just foggier -- built from Roblox's
-- default particle sprite (Texture left unset) rather than inventing an
-- asset id, since a bad asset id is exactly the kind of Studio error you
-- asked about earlier. Swap in a real raindrop decal's AssetId on the
-- ParticleEmitter later if you have one.
--
-- One Heartbeat connection drives both systems together so they can't
-- stomp each other's writes to the same Lighting properties: Ambient/
-- OutdoorAmbient/Brightness get a day-vs-night BASE value every tick that
-- weather then dims further on top of (ambient_mult/brightness_mult);
-- FogColor/FogStart/FogEnd are weather's alone, day/night never touches
-- them.
--
-- start()/stop() are both idempotent. Generate() calls stop() then
-- start() at the top of every match -- Lighting and Players are single
-- shared services, not per-match, so without this a second match on the
-- same server would stack a second competing Heartbeat connection (and a
-- second set of rain followers) on top of the first match's leftover one
-- instead of replacing it.
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local DayNightWeather = {}
local function Smooth_Step(t)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end
local function Lerp_Color(a, b, t)
	return Color3.new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end
-- Placeholder magnitudes throughout this file, same as every other
-- numeric pass in this project -- tune to taste once you've seen it live.
local DAY_NIGHT = {
	-- [stated] "fixed real-time day length" -- one full 24-hour sweep
	-- takes this many real seconds, looping forever for the match.
	day_length_seconds = 600,
	-- Matches Configure_Lighting's existing ClockTime = 14 starting point
	-- in StartMatch.lua, so the very first frame of the cycle looks
	-- exactly like what Configure_Lighting already set up.
	start_clock_time = 14,
	day_ambient = Color3.fromRGB(90, 90, 90),
	day_outdoor_ambient = Color3.fromRGB(120, 120, 120),
	day_brightness = 2,
	night_ambient = Color3.fromRGB(25, 25, 35),
	night_outdoor_ambient = Color3.fromRGB(35, 35, 50),
	night_brightness = 0.6,
	-- Dawn/dusk aren't instant -- night_factor ramps smoothly across these
	-- windows (24-hour clock) instead of snapping at a fixed hour.
	dawn_start = 5,
	dawn_end = 7,
	dusk_start = 17,
	dusk_end = 19,
}
-- 0 = full day, 1 = full night, smoothly blended across dawn/dusk via
-- Smooth_Step rather than a hard cutoff.
local function Night_Factor(clock_time)
	if clock_time >= DAY_NIGHT.dusk_end or clock_time < DAY_NIGHT.dawn_start then
		return 1
	elseif clock_time < DAY_NIGHT.dawn_end then
		return 1 - Smooth_Step((clock_time - DAY_NIGHT.dawn_start) / (DAY_NIGHT.dawn_end - DAY_NIGHT.dawn_start))
	elseif clock_time < DAY_NIGHT.dusk_start then
		return 0
	else
		return Smooth_Step((clock_time - DAY_NIGHT.dusk_start) / (DAY_NIGHT.dusk_end - DAY_NIGHT.dusk_start))
	end
end
-- [stated] weather types: "Clear, Rain, Fog" -- each state's own look.
-- fog_end is where the real visibility reduction comes from: Clear's is
-- effectively unlimited, Rain/Fog pull it in hard.
local WEATHER_LOOK = {
	Clear = {fog_color = Color3.fromRGB(192, 192, 192), fog_start = 0, fog_end = 100000, brightness_mult = 1, ambient_mult = 1},
	Rain = {fog_color = Color3.fromRGB(120, 120, 130), fog_start = 0, fog_end = 700, brightness_mult = 0.7, ambient_mult = 0.85},
	Fog = {fog_color = Color3.fromRGB(170, 170, 175), fog_start = 0, fog_end = 450, brightness_mult = 0.85, ambient_mult = 0.9},
}
local WEATHER = {
	-- [stated] "roll completely independently" of time of day -- Clear
	-- weighted heaviest so the map isn't rained/fogged on constantly.
	weights = {Clear = 0.5, Rain = 0.25, Fog = 0.25},
	min_duration = 120,
	max_duration = 240,
	-- How long a change fades in, rather than snapping Lighting straight
	-- to the new state's numbers.
	transition_seconds = 15,
}
-- Picks a new weather name, weighted, excluding whatever's currently
-- active -- a plain weighted roll could otherwise re-pick the same state
-- and look like nothing changed, which defeats "randomized... cycle".
local function Roll_Weather(exclude)
	local total = 0
	for name, weight in pairs(WEATHER.weights) do
		if name ~= exclude then
			total = total + weight
		end
	end
	local roll = math.random() * total
	for name, weight in pairs(WEATHER.weights) do
		if name ~= exclude then
			if roll < weight then
				return name
			end
			roll = roll - weight
		end
	end
	return exclude or "Clear"
end
-- Mutable state, fully rebuilt on every start() -- see the leaked-
-- connection comment up top for why this can't just persist between
-- matches untouched.
local state = nil
local heartbeat_connection = nil
local player_removing_connection = nil
local rain_followers = {}
-- How far above a player's head the rain-follower part (and its
-- ParticleEmitter) sits.
local RAIN_OFFSET = Vector3.new(0, 6, 0)
local function Remove_Rain_Follower(player)
	local follower = rain_followers[player]
	if follower then
		follower.part:Destroy()
		rain_followers[player] = nil
	end
end
local function Make_Rain_Follower()
	local part = Instance.new("Part")
	part.Name = "RainFollower"
	-- A flat box, not a point -- Shape = Box below spreads raindrops
	-- across this whole footprint above the player instead of straight
	-- down a single line.
	part.Size = Vector3.new(6, 1, 6)
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.Anchored = true
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Rain"
	emitter.Texture = "" -- Roblox's default particle sprite -- see the file header note on asset ids.
	emitter.Color = ColorSequence.new(Color3.fromRGB(200, 210, 230))
	emitter.Size = NumberSequence.new(0.15)
	emitter.Transparency = NumberSequence.new(0.4)
	emitter.Lifetime = NumberRange.new(0.6, 0.8)
	emitter.Speed = NumberRange.new(40, 45)
	emitter.Rate = 120
	emitter.SpreadAngle = Vector2.new(2, 2)
	emitter.Acceleration = Vector3.new(0, -60, 0)
	emitter.Rotation = NumberRange.new(-5, 5)
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
	emitter.Enabled = true
	emitter.Parent = part
	part.Parent = workspace
	return {part = part, emitter = emitter}
end
local function Update_Rain_Followers()
	local is_raining = state.current_weather == "Rain"
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if is_raining and root then
			local follower = rain_followers[player]
			if not follower then
				follower = Make_Rain_Follower()
				rain_followers[player] = follower
			end
			follower.emitter.Enabled = true
			follower.part.Position = root.Position + RAIN_OFFSET
		elseif rain_followers[player] then
			rain_followers[player].emitter.Enabled = false
		end
	end
end
function DayNightWeather.stop()
	if heartbeat_connection then
		heartbeat_connection:Disconnect()
		heartbeat_connection = nil
	end
	if player_removing_connection then
		player_removing_connection:Disconnect()
		player_removing_connection = nil
	end
	for player in pairs(rain_followers) do
		Remove_Rain_Follower(player)
	end
	state = nil
end
function DayNightWeather.start()
	DayNightWeather.stop()
	state = {
		elapsed = 0,
		current_weather = Roll_Weather(nil),
		previous_weather = nil,
		weather_timer = WEATHER.min_duration + math.random() * (WEATHER.max_duration - WEATHER.min_duration),
		-- Starts already "fully transitioned" so the very first frame
		-- uses current_weather's look outright, not a blend from nothing.
		transition_elapsed = WEATHER.transition_seconds,
	}
	player_removing_connection = Players.PlayerRemoving:Connect(Remove_Rain_Follower)
	heartbeat_connection = RunService.Heartbeat:Connect(function(dt)
		state.elapsed = state.elapsed + dt
		local clock_time = (DAY_NIGHT.start_clock_time + (state.elapsed / DAY_NIGHT.day_length_seconds) * 24) % 24
		local night_factor = Night_Factor(clock_time)
		state.weather_timer = state.weather_timer - dt
		if state.weather_timer <= 0 then
			state.previous_weather = state.current_weather
			state.current_weather = Roll_Weather(state.current_weather)
			state.weather_timer = WEATHER.min_duration + math.random() * (WEATHER.max_duration - WEATHER.min_duration)
			state.transition_elapsed = 0
		end
		state.transition_elapsed = math.min(state.transition_elapsed + dt, WEATHER.transition_seconds)
		local blend = state.previous_weather and Smooth_Step(state.transition_elapsed / WEATHER.transition_seconds) or 1
		local from_look = WEATHER_LOOK[state.previous_weather or state.current_weather]
		local to_look = WEATHER_LOOK[state.current_weather]
		local fog_color = Lerp_Color(from_look.fog_color, to_look.fog_color, blend)
		local fog_start = from_look.fog_start + (to_look.fog_start - from_look.fog_start) * blend
		local fog_end = from_look.fog_end + (to_look.fog_end - from_look.fog_end) * blend
		local brightness_mult = from_look.brightness_mult + (to_look.brightness_mult - from_look.brightness_mult) * blend
		local ambient_mult = from_look.ambient_mult + (to_look.ambient_mult - from_look.ambient_mult) * blend
		local base_ambient = Lerp_Color(DAY_NIGHT.day_ambient, DAY_NIGHT.night_ambient, night_factor)
		local base_outdoor_ambient = Lerp_Color(DAY_NIGHT.day_outdoor_ambient, DAY_NIGHT.night_outdoor_ambient, night_factor)
		local base_brightness = DAY_NIGHT.day_brightness + (DAY_NIGHT.night_brightness - DAY_NIGHT.day_brightness) * night_factor
		Lighting.ClockTime = clock_time
		Lighting.Ambient = Color3.new(base_ambient.R * ambient_mult, base_ambient.G * ambient_mult, base_ambient.B * ambient_mult)
		Lighting.OutdoorAmbient = Color3.new(base_outdoor_ambient.R * ambient_mult, base_outdoor_ambient.G * ambient_mult, base_outdoor_ambient.B * ambient_mult)
		Lighting.Brightness = base_brightness * brightness_mult
		Lighting.FogColor = fog_color
		Lighting.FogStart = fog_start
		Lighting.FogEnd = fog_end
		Update_Rain_Followers()
	end)
end
return DayNightWeather
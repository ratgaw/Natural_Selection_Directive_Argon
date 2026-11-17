-- LocalScript, parented directly under the TextLabel (script.Parent = that label)
local tween_service = game:GetService("TweenService")

local crawl_text = script.Parent
local crawl_container = crawl_text.Parent -- whatever Frame is holding this label

local speed = 100 -- pixels per second; higher = faster scroll

crawl_container.ClipsDescendants = true

crawl_text.AutomaticSize = Enum.AutomaticSize.X
crawl_text.Size = UDim2.new(0, 0, 1, 0)
crawl_text.Text = "This is a test script, this is a test script. Hopefully this works well then I can do more with it. //"

local function Start_Crawl()
	local container_width = crawl_container.AbsoluteSize.X
	local text_width = crawl_text.AbsoluteSize.X

	crawl_text.Position = UDim2.new(0, container_width, 0.95, 0)
	local target_x = -text_width
	local distance = container_width + text_width
	local duration = distance / speed

	local tween = tween_service:Create(
		crawl_text,
		TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1, false, 0),
		{Position = UDim2.new(0, target_x, 0.95, 0)}
	)
	tween:Play()
end

task.defer(Start_Crawl)
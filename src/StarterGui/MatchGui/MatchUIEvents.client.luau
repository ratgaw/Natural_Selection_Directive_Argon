local RS= game:GetService("ReplicatedStorage")
local match_UI_event = RS:WaitForChild("MatchUIEvent")

local gui = script.Parent
local start_match = gui:WaitForChild("StartMatch")
local end_match = gui:WaitForChild("EndMatch")

local start_text = start_match:WaitForChild("MatchStartText")
local end_text = end_match:WaitForChild("PrintWinner")

-- Listens for UI signal and responds depending on value given
match_UI_event.OnClientEvent:Connect(function(action, value)
	if action == "Start Match" then
		start_text.Visible = true
		end_text.Visible = false

		for i = value, 1, -1 do
			start_text.Text = "Match starts in " .. i
			task.wait(1)
		end

	elseif action == "End" then
		start_text.Visible = false
		end_text.Visible = true
		end_text.Text = value .. " wins!"

	elseif action == "Match Started" then
		start_text.Visible = false
		end_text.Visible = false
	end
end)
-- Setting ease of use variables
local RS = game:GetService("ReplicatedStorage")

-- Grabbing parent UI button as variable
local button = script.Parent

-- Grabbing signals as variables
local generate_arena = RS:WaitForChild("GenerateArena")

-- Detects mouse click on UI button to send arena generation signal before turning UI button invisible
button.MouseButton1Click:Connect(function() 
	generate_arena:FireServer()
	button.Visible = false
end)
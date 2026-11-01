local Players = game:GetService("Players")
local TextService = game:GetService("TextService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local wrapped = setmetatable({}, { __mode = "k" })

local function stripPostOpenSbiStats(text)
	text = tostring(text or "")
	local marker = text:find("OpenSBI fw_dynamic", 1, true)
		or text:find("NEXT-STAGE OK", 1, true)
	if not marker then return text end

	local head = text:sub(1, marker - 1)
	local tail = text:sub(marker)
	local out = {}
	local i = 1

	while i <= #tail do
		local j = tail:find("\n", i, true)
		local line = j and tail:sub(i, j) or tail:sub(i)
		local body = line:gsub("[\r\n]+$", "")
		if not body:match("^%[STAT%s*%]") then
			out[#out + 1] = line
		end
		if not j then break end
		i = j + 1
	end

	return head .. table.concat(out)
end

local function findTerminalLabel()
	for _, gui in ipairs(playerGui:GetChildren()) do
		if gui:IsA("ScreenGui") then
			local label = gui:FindFirstChild("OutputLabel", true)
			if label and label:IsA("TextLabel") then
				return label
			end
		end
	end

	for _, obj in ipairs(playerGui:GetDescendants()) do
		if obj:IsA("TextLabel") and obj.Text:find("%[RoEmu%]", 1) then
			return obj
		end
	end
	return nil
end

local function wrapLabel(label)
	if wrapped[label] or not label.Parent then return end
	wrapped[label] = true

	local parent = label.Parent
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "AutoScrollViewport"
	scroll.AnchorPoint = label.AnchorPoint
	scroll.Position = label.Position
	scroll.Size = label.Size
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ClipsDescendants = true
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = label.TextColor3
	scroll.CanvasSize = UDim2.fromOffset(0, 0)
	scroll.CanvasPosition = Vector2.zero
	pcall(function()
		scroll.AutomaticCanvasSize = Enum.AutomaticSize.None
	end)
	scroll.Parent = parent

	label.Parent = scroll
	label.AnchorPoint = Vector2.zero
	label.Position = UDim2.fromOffset(0, 0)
	label.Size = UDim2.new(1, -10, 0, scroll.AbsoluteWindowSize.Y)
	label.AutomaticSize = Enum.AutomaticSize.None
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true

	local pending = false
	local filtering = false
	local function relayout()
		pending = false
		if not label.Parent or not scroll.Parent then return end

		if not filtering then
			local filtered = stripPostOpenSbiStats(label.Text)
			if filtered ~= label.Text then
				filtering = true
				label.Text = filtered
				filtering = false
			end
		end

		local width = math.max(32, scroll.AbsoluteWindowSize.X - 10)
		local measured = TextService:GetTextSize(
			label.Text,
			label.TextSize,
			label.Font,
			Vector2.new(width, 1000000)
		)
		local height = math.max(scroll.AbsoluteWindowSize.Y, measured.Y + 8)

		label.Size = UDim2.new(1, -10, 0, height)
		scroll.CanvasSize = UDim2.fromOffset(0, height)

		local bottom = math.max(0, height - scroll.AbsoluteWindowSize.Y)
		scroll.CanvasPosition = Vector2.new(0, bottom)
	end

	local function schedule()
		if pending then return end
		pending = true
		task.defer(relayout)
	end

	label:GetPropertyChangedSignal("Text"):Connect(schedule)
	scroll:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(schedule)
	schedule()

	print("[termScroll] auto-scroll conectado")
end

task.spawn(function()
	while true do
		local label = findTerminalLabel()
		if label then
			wrapLabel(label)
		end
		task.wait(0.5)
	end
end)

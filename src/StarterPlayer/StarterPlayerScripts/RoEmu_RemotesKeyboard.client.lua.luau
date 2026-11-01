-- StarterPlayer/StarterPlayerScripts/RoEmu_RemotesKeyboard.client.lua
-- Teclado fisico y teclado virtual adaptable para la UART de RoEMU.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local VRService = game:GetService("VRService")

local REMOTES_FOLDER_NAME = "RoEmu_Remotes"
local DELETE_BYTE = string.char(127)
local CAPTURE_ACTION = "RoEmuCaptureCameraLetters"

local remotes = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 15)
if not remotes then
	warn("[RoEmu_RemotesKeyboard] No aparecio ReplicatedStorage." .. REMOTES_FOLDER_NAME)
	return
end

local In = remotes:WaitForChild("In", 15)
if not In or not In:IsA("RemoteEvent") then
	warn("[RoEmu_RemotesKeyboard] No aparecio RemoteEvent In")
	return
end

local enabled = true
local capsLock = false

local letterMap = {
	[Enum.KeyCode.A] = "a", [Enum.KeyCode.B] = "b", [Enum.KeyCode.C] = "c",
	[Enum.KeyCode.D] = "d", [Enum.KeyCode.E] = "e", [Enum.KeyCode.F] = "f",
	[Enum.KeyCode.G] = "g", [Enum.KeyCode.H] = "h", [Enum.KeyCode.I] = "i",
	[Enum.KeyCode.J] = "j", [Enum.KeyCode.K] = "k", [Enum.KeyCode.L] = "l",
	[Enum.KeyCode.M] = "m", [Enum.KeyCode.N] = "n", [Enum.KeyCode.O] = "o",
	[Enum.KeyCode.P] = "p", [Enum.KeyCode.Q] = "q", [Enum.KeyCode.R] = "r",
	[Enum.KeyCode.S] = "s", [Enum.KeyCode.T] = "t", [Enum.KeyCode.U] = "u",
	[Enum.KeyCode.V] = "v", [Enum.KeyCode.W] = "w", [Enum.KeyCode.X] = "x",
	[Enum.KeyCode.Y] = "y", [Enum.KeyCode.Z] = "z",
}

local digitMap = {
	[Enum.KeyCode.One] = "1", [Enum.KeyCode.Two] = "2",
	[Enum.KeyCode.Three] = "3", [Enum.KeyCode.Four] = "4",
	[Enum.KeyCode.Five] = "5", [Enum.KeyCode.Six] = "6",
	[Enum.KeyCode.Seven] = "7", [Enum.KeyCode.Eight] = "8",
	[Enum.KeyCode.Nine] = "9", [Enum.KeyCode.Zero] = "0",
}

local shiftDigitMap = {
	[Enum.KeyCode.One] = "!", [Enum.KeyCode.Two] = "@",
	[Enum.KeyCode.Three] = "#", [Enum.KeyCode.Four] = "$",
	[Enum.KeyCode.Five] = "%", [Enum.KeyCode.Six] = "^",
	[Enum.KeyCode.Seven] = "&", [Enum.KeyCode.Eight] = "*",
	[Enum.KeyCode.Nine] = "(", [Enum.KeyCode.Zero] = ")",
}

local normalMap = {
	[Enum.KeyCode.Space] = " ",
	[Enum.KeyCode.Return] = "\n",
	[Enum.KeyCode.KeypadEnter] = "\n",
	[Enum.KeyCode.Tab] = "\t",
	[Enum.KeyCode.Escape] = string.char(27),
	[Enum.KeyCode.Backspace] = DELETE_BYTE,
	[Enum.KeyCode.Delete] = DELETE_BYTE,
	[Enum.KeyCode.Minus] = "-", [Enum.KeyCode.Equals] = "=",
	[Enum.KeyCode.LeftBracket] = "[", [Enum.KeyCode.RightBracket] = "]",
	[Enum.KeyCode.BackSlash] = "\\", [Enum.KeyCode.Semicolon] = ";",
	[Enum.KeyCode.Quote] = "'", [Enum.KeyCode.Comma] = ",",
	[Enum.KeyCode.Period] = ".", [Enum.KeyCode.Slash] = "/",
	[Enum.KeyCode.Backquote] = "`",
}

local shiftMap = {
	[Enum.KeyCode.Minus] = "_", [Enum.KeyCode.Equals] = "+",
	[Enum.KeyCode.LeftBracket] = "{", [Enum.KeyCode.RightBracket] = "}",
	[Enum.KeyCode.BackSlash] = "|", [Enum.KeyCode.Semicolon] = ":",
	[Enum.KeyCode.Quote] = "\"", [Enum.KeyCode.Comma] = "<",
	[Enum.KeyCode.Period] = ">", [Enum.KeyCode.Slash] = "?",
	[Enum.KeyCode.Backquote] = "~",
}

local function isShiftDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

local function isCtrlDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
end

local function inputIsBlocked(): boolean
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if playerGui and playerGui:GetAttribute("RoEmuBootMenuOpen") then return true end
	if GuiService.MenuIsOpen then
		return true
	end
	return UserInputService:GetFocusedTextBox() ~= nil
end

local function sendBytes(value: string)
	if enabled and typeof(value) == "string" and value ~= "" then
		In:FireServer("bytes", value)
	end
end

local function keyCodeToChar(keyCode: Enum.KeyCode): string?
	local letter = letterMap[keyCode]
	if letter then
		if isCtrlDown() then
			return string.char(string.byte(letter) - string.byte("a") + 1)
		end
		if isShiftDown() ~= capsLock then
			return string.upper(letter)
		end
		return letter
	end

	local shifted = isShiftDown()
	if digitMap[keyCode] then
		return shifted and shiftDigitMap[keyCode] or digitMap[keyCode]
	end
	if shifted and shiftMap[keyCode] then
		return shiftMap[keyCode]
	end
	return normalMap[keyCode]
end

-- I y O son controles de zoom de la camara de Roblox. Se capturan con
-- prioridad alta, pero solo mientras no haya un TextBox o menu activo.
local function captureCameraLetters(
	_actionName: string,
	inputState: Enum.UserInputState,
	inputObject: InputObject
): Enum.ContextActionResult
	if not enabled or inputIsBlocked() then
		return Enum.ContextActionResult.Pass
	end
	if inputState == Enum.UserInputState.Begin then
		local value = keyCodeToChar(inputObject.KeyCode)
		if value then
			sendBytes(value)
		end
	end
	return Enum.ContextActionResult.Sink
end

ContextActionService:BindActionAtPriority(
	CAPTURE_ACTION,
	captureCameraLetters,
	false,
	10000,
	Enum.KeyCode.I,
	Enum.KeyCode.O
)

UserInputService.InputBegan:Connect(function(input: InputObject, _gameProcessedEvent: boolean)
	if not enabled or inputIsBlocked() then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	local keyCode = input.KeyCode
	if keyCode == Enum.KeyCode.I or keyCode == Enum.KeyCode.O then
		return -- ya lo maneja ContextActionService
	end
	if keyCode == Enum.KeyCode.CapsLock then
		capsLock = not capsLock
		return
	end

	local value = keyCodeToChar(keyCode)
	if value then
		sendBytes(value)
	end
end)

do
	-- El bloque virtual queda aislado para no chocar con el teclado fisico.
	local Workspace = game:GetService("Workspace")

	local GUI_NAME = "RoEmuVirtualKeyboard"
	local BRIDGE_NAME = "RoEmuVirtualKeyInput"
	local MAX_PENDING_BYTES = 1024
	local DELETE_REPEAT_DELAY = 0.42
	local DELETE_REPEAT_INTERVAL = 0.065

	local BACKSPACE_DEL = string.char(0x7F)
	local CTRL_C = string.char(0x03)
	local ESCAPE = string.char(0x1B)
	local TAB_BYTE = string.char(0x09)
	local ENTER_BYTE = string.char(0x0A)

	local COLOR_PANEL = Color3.fromRGB(10, 12, 18)
	local COLOR_HEADER = Color3.fromRGB(18, 21, 30)
	local COLOR_KEY = Color3.fromRGB(33, 38, 50)
	local COLOR_KEY_ACTIVE = Color3.fromRGB(63, 118, 179)
	local COLOR_KEY_SPECIAL = Color3.fromRGB(48, 54, 68)
	local COLOR_TEXT = Color3.fromRGB(242, 245, 255)
	local COLOR_MUTED_TEXT = Color3.fromRGB(197, 207, 225)
	local COLOR_STROKE = Color3.fromRGB(185, 203, 229)

	local player = Players.LocalPlayer
	if not player then
		warn("[RoEmu_RemotesKeyboard] LocalPlayer no disponible para teclado virtual")
		return
	end

	local playerGui = player:WaitForChild("PlayerGui", 15)
	if not playerGui then
		warn("[RoEmu_RemotesKeyboard] PlayerGui no disponible para teclado virtual")
		return
	end

	local previous = playerGui:FindFirstChild(GUI_NAME)
	if previous then
		previous:Destroy()
	end

	local keyboardGui = Instance.new("ScreenGui")
	keyboardGui.Name = GUI_NAME
	keyboardGui.ResetOnSpawn = false
	keyboardGui.DisplayOrder = 2500
	keyboardGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	keyboardGui.IgnoreGuiInset = false
	keyboardGui.Enabled = false

	local hasDeviceSafeInsets = pcall(function()
		keyboardGui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
		keyboardGui.ClipToDeviceSafeArea = true
	end)

	keyboardGui.Parent = playerGui

	-- Puente estable para pruebas y para conectar otra interfaz en el futuro.
	local bridge = Instance.new("BindableEvent")
	bridge.Name = BRIDGE_NAME
	bridge.Parent = keyboardGui

	local root = Instance.new("Frame")
	root.Name = "KeyboardPanel"
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.BackgroundColor3 = COLOR_PANEL
	root.BackgroundTransparency = 0.34
	root.BorderSizePixel = 0
	root.ClipsDescendants = true
	root.Position = UDim2.new(0.5, 0, 1, -8)
	root.Size = UDim2.fromOffset(760, 300)
	root.ZIndex = 2500
	root.Parent = keyboardGui

	local rootCorner = Instance.new("UICorner")
	rootCorner.CornerRadius = UDim.new(0, 10)
	rootCorner.Parent = root

	local rootStroke = Instance.new("UIStroke")
	rootStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	rootStroke.Color = COLOR_STROKE
	rootStroke.Thickness = 1
	rootStroke.Transparency = 0.68
	rootStroke.Parent = root

	local rootPadding = Instance.new("UIPadding")
	rootPadding.PaddingBottom = UDim.new(0, 7)
	rootPadding.PaddingLeft = UDim.new(0, 7)
	rootPadding.PaddingRight = UDim.new(0, 7)
	rootPadding.PaddingTop = UDim.new(0, 7)
	rootPadding.Parent = root

	local rootLayout = Instance.new("UIListLayout")
	rootLayout.FillDirection = Enum.FillDirection.Vertical
	rootLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rootLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rootLayout.Padding = UDim.new(0, 6)
	rootLayout.Parent = root

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundColor3 = COLOR_HEADER
	header.BackgroundTransparency = 0.4
	header.BorderSizePixel = 0
	header.LayoutOrder = 1
	header.Size = UDim2.new(1, 0, 0, 28)
	header.ZIndex = 2501
	header.Parent = root

	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, 7)
	headerCorner.Parent = header

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.Code
	title.Position = UDim2.fromOffset(10, 0)
	title.Size = UDim2.new(1, -82, 1, 0)
	title.Text = "RoEMU keyboard"
	title.TextColor3 = COLOR_MUTED_TEXT
	title.TextSize = 15
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 2502
	title.Parent = header

	local minimizeButton = Instance.new("TextButton")
	minimizeButton.Name = "Minimize"
	minimizeButton.AnchorPoint = Vector2.new(1, 0.5)
	minimizeButton.AutoButtonColor = true
	minimizeButton.BackgroundColor3 = COLOR_KEY_SPECIAL
	minimizeButton.BackgroundTransparency = 0.28
	minimizeButton.BorderSizePixel = 0
	minimizeButton.Font = Enum.Font.Code
	minimizeButton.Position = UDim2.new(1, -4, 0.5, 0)
	minimizeButton.Selectable = true
	minimizeButton.Size = UDim2.fromOffset(66, 22)
	minimizeButton.Text = "HIDE"
	minimizeButton.TextColor3 = COLOR_TEXT
	minimizeButton.TextSize = 13
	minimizeButton.ZIndex = 2503
	minimizeButton.Parent = header

	local minimizeCorner = Instance.new("UICorner")
	minimizeCorner.CornerRadius = UDim.new(0, 6)
	minimizeCorner.Parent = minimizeButton

	local pages = Instance.new("Frame")
	pages.Name = "Pages"
	pages.BackgroundTransparency = 1
	pages.LayoutOrder = 2
	pages.Size = UDim2.new(1, 0, 1, -34)
	pages.ZIndex = 2501
	pages.Parent = root

	local alphaPage = Instance.new("Frame")
	alphaPage.Name = "Letters"
	alphaPage.BackgroundTransparency = 1
	alphaPage.Size = UDim2.fromScale(1, 1)
	alphaPage.ZIndex = 2501
	alphaPage.Parent = pages

	local symbolPage = Instance.new("Frame")
	symbolPage.Name = "Symbols"
	symbolPage.BackgroundTransparency = 1
	symbolPage.Size = UDim2.fromScale(1, 1)
	symbolPage.Visible = false
	symbolPage.ZIndex = 2501
	symbolPage.Parent = pages

	local restoreButton = Instance.new("TextButton")
	restoreButton.Name = "Restore"
	restoreButton.AnchorPoint = Vector2.new(1, 1)
	restoreButton.AutoButtonColor = true
	restoreButton.BackgroundColor3 = COLOR_PANEL
	restoreButton.BackgroundTransparency = 0.3
	restoreButton.BorderSizePixel = 0
	restoreButton.Font = Enum.Font.Code
	restoreButton.Position = UDim2.new(1, -10, 1, -8)
	restoreButton.Selectable = true
	restoreButton.Size = UDim2.fromOffset(92, 42)
	restoreButton.Text = "KEYS"
	restoreButton.TextColor3 = COLOR_TEXT
	restoreButton.TextSize = 16
	restoreButton.Visible = false
	restoreButton.ZIndex = 2600
	restoreButton.Parent = keyboardGui

	local restoreCorner = Instance.new("UICorner")
	restoreCorner.CornerRadius = UDim.new(0, 9)
	restoreCorner.Parent = restoreButton

	local restoreStroke = Instance.new("UIStroke")
	restoreStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	restoreStroke.Color = COLOR_STROKE
	restoreStroke.Thickness = 1
	restoreStroke.Transparency = 0.55
	restoreStroke.Parent = restoreButton

	local virtualShift = false
	local virtualCaps = false
	local minimized = false
	local repeatGeneration = 0

	local printableButtons = {}
	local shiftButtons = {}
	local capsButtons = {}

	local refreshKeyboardState = function() end
	local setPage = function(_symbols: boolean) end
	local ensureAttached = function() end

	local attachRunning = false
	local channelReady = false
	local pendingBytes = ""

	local function flushPending()
		if not channelReady or pendingBytes == "" then
			return
		end
		local bytes = pendingBytes
		pendingBytes = ""
		sendBytes(bytes)
	end

	ensureAttached = function()
		if attachRunning or channelReady then
			return
		end
		attachRunning = true

		task.spawn(function()
			local rpc = remotes:FindFirstChild("Rpc")
			if not rpc then
				rpc = remotes:WaitForChild("Rpc", 5)
			end

			local confirmed = false
			if rpc and rpc:IsA("RemoteFunction") then
				for _attempt = 1, 3 do
					local ok, accepted = pcall(function()
						local success = rpc:InvokeServer("attach", {
							client = "RoEmuVirtualKeyboard",
							version = 1,
						})
						return success
					end)
					if ok and accepted == true then
						confirmed = true
						break
					end
					task.wait(0.4)
				end
			end

			if not confirmed then
				warn("[RoEmu_RemotesKeyboard] Attach virtual no confirmado; se conserva el attach de la consola")
			end

			-- El RPC es idempotente. Si otro cliente local ya adjunto al jugador,
			-- InputGate aceptara estos mismos bytes.
			channelReady = true
			attachRunning = false
			flushPending()
		end)
	end

	local function sendVirtualBytes(value: string)
		if typeof(value) ~= "string" or value == "" then
			return
		end
		if not keyboardGui.Enabled or GuiService.MenuIsOpen then
			return
		end

		if channelReady then
			sendBytes(value)
			return
		end

		local free = MAX_PENDING_BYTES - #pendingBytes
		if free > 0 then
			pendingBytes ..= string.sub(value, 1, free)
		end
		ensureAttached()
	end

	local function setMinimized(value: boolean)
		minimized = value
		root.Visible = not minimized
		restoreButton.Visible = minimized
		repeatGeneration += 1
	end

	setPage = function(symbols: boolean)
		alphaPage.Visible = not symbols
		symbolPage.Visible = symbols
		if virtualShift then
			virtualShift = false
			refreshKeyboardState()
		end
	end

	local virtualShiftSymbols = {
		["1"] = "!", ["2"] = "@", ["3"] = "#", ["4"] = "$", ["5"] = "%",
		["6"] = "^", ["7"] = "&", ["8"] = "*", ["9"] = "(", ["0"] = ")",
		["-"] = "_", ["="] = "+", ["["] = "{", ["]"] = "}",
		[string.char(92)] = "|", [";"] = ":", ["'"] = "\"",
		[","] = "<", ["."] = ">", ["/"] = "?", [string.char(96)] = "~",
	}

	local function emitLiteral(token: string)
		local value = token
		if token:match("%a") then
			local lower = string.lower(token)
			value = (virtualShift ~= virtualCaps) and string.upper(lower) or lower
		elseif virtualShift and virtualShiftSymbols[token] then
			value = virtualShiftSymbols[token]
		end

		sendVirtualBytes(value)
		if virtualShift then
			virtualShift = false
			refreshKeyboardState()
		end
	end

	local function dispatchVirtual(token: any)
		if typeof(token) ~= "string" or token == "" then
			return
		end

		if token == "backspace" or token == "delete" then
			sendVirtualBytes(BACKSPACE_DEL)
		elseif token == "enter" then
			sendVirtualBytes(ENTER_BYTE)
		elseif token == "tab" then
			sendVirtualBytes(TAB_BYTE)
		elseif token == "escape" then
			sendVirtualBytes(ESCAPE)
		elseif token == "ctrl-c" then
			sendVirtualBytes(CTRL_C)
		elseif token == "space" then
			sendVirtualBytes(" ")
		elseif token == "shift" then
			virtualShift = not virtualShift
			refreshKeyboardState()
		elseif token == "caps" then
			virtualCaps = not virtualCaps
			refreshKeyboardState()
		elseif token == "symbols" then
			setPage(true)
		elseif token == "abc" then
			setPage(false)
		elseif token == "hide" then
			setMinimized(true)
		elseif token == "show" then
			setMinimized(false)
		elseif #token == 1 then
			emitLiteral(token)
		end
	end

	bridge.Event:Connect(dispatchVirtual)

	local function createStyledButton(parent: Instance, label: string, weight: number): TextButton
		local button = Instance.new("TextButton")
		button.AutoButtonColor = true
		button.BackgroundColor3 = COLOR_KEY
		button.BackgroundTransparency = 0.24
		button.BorderSizePixel = 0
		button.Font = Enum.Font.Code
		button.Selectable = true
		button.Size = UDim2.new(weight, 0, 1, 0)
		button.Text = label
		button.TextColor3 = COLOR_TEXT
		button.TextScaled = true
		button.TextWrapped = true
		button.ZIndex = 2503
		button.Parent = parent

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = button

		local stroke = Instance.new("UIStroke")
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Color = COLOR_STROKE
		stroke.Thickness = 1
		stroke.Transparency = 0.73
		stroke.Parent = button

		local textConstraint = Instance.new("UITextSizeConstraint")
		textConstraint.MinTextSize = 9
		textConstraint.MaxTextSize = 21
		textConstraint.Parent = button

		return button
	end

	local function bindRepeat(button: TextButton, token: string)
		local activeInput: InputObject? = nil
		local lastPointerFire = -math.huge

		button.InputBegan:Connect(function(input: InputObject)
			local inputType = input.UserInputType
			if inputType ~= Enum.UserInputType.Touch
				and inputType ~= Enum.UserInputType.MouseButton1 then
				return
			end

			activeInput = input
			lastPointerFire = os.clock()
			bridge:Fire(token)
			repeatGeneration += 1
			local generation = repeatGeneration

			task.delay(DELETE_REPEAT_DELAY, function()
				while activeInput == input
					and repeatGeneration == generation
					and keyboardGui.Enabled
					and root.Visible do
					bridge:Fire(token)
					task.wait(DELETE_REPEAT_INTERVAL)
				end
			end)
		end)

		button.InputEnded:Connect(function(input: InputObject)
			if activeInput == input then
				activeInput = nil
				lastPointerFire = os.clock()
				repeatGeneration += 1
			end
		end)

		-- Activated cubre controladores VR/gamepad sin duplicar touch o mouse.
		button.Activated:Connect(function()
			if os.clock() - lastPointerFire > 0.2 then
				bridge:Fire(token)
			end
		end)
	end

	local function createKey(parent: Frame, spec): TextButton
		local weight = spec.weight or 1
		local button = createStyledButton(parent, spec.label, weight)

		if spec.role == "shift" then
			shiftButtons[#shiftButtons + 1] = button
		elseif spec.role == "caps" then
			capsButtons[#capsButtons + 1] = button
		end

		if spec.alpha then
			printableButtons[button] = {
				normal = spec.token,
				shifted = string.upper(spec.token),
				alpha = true,
			}
		end

		if spec.repeatable then
			bindRepeat(button, spec.token)
		else
			button.Activated:Connect(function()
				bridge:Fire(spec.token)
			end)
		end

		return button
	end

	local function createRows(page: Frame, rows)
		local rowGap = 5
		local pageLayout = Instance.new("UIListLayout")
		pageLayout.FillDirection = Enum.FillDirection.Vertical
		pageLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		pageLayout.SortOrder = Enum.SortOrder.LayoutOrder
		pageLayout.Padding = UDim.new(0, rowGap)
		pageLayout.Parent = page

		for rowIndex, specs in ipairs(rows) do
			local row = Instance.new("Frame")
			row.Name = "Row" .. rowIndex
			row.BackgroundTransparency = 1
			row.LayoutOrder = rowIndex
			row.Size = UDim2.new(
				1,
				0,
				1 / #rows,
				-(rowGap * (#rows - 1)) / #rows
			)
			row.ZIndex = 2502
			row.Parent = page

			local keyGap = 4
			local rowLayout = Instance.new("UIListLayout")
			rowLayout.FillDirection = Enum.FillDirection.Horizontal
			rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
			rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
			rowLayout.Padding = UDim.new(0, keyGap)
			rowLayout.Parent = row

			local totalWeight = 0
			for _, spec in ipairs(specs) do
				totalWeight += spec.weight or 1
			end

			local totalGap = keyGap * math.max(0, #specs - 1)
			for keyIndex, spec in ipairs(specs) do
				local button = createKey(row, spec)
				button.LayoutOrder = keyIndex
				local weight = spec.weight or 1
				local ratio = weight / totalWeight
				button.Size = UDim2.new(ratio, -totalGap * ratio, 1, 0)
			end
		end
	end

	local function key(label: string, token: string, weight: number?, repeatable: boolean?, role: string?, alpha: boolean?)
		return {
			label = label,
			token = token,
			weight = weight,
			repeatable = repeatable,
			role = role,
			alpha = alpha,
		}
	end

	local function letter(ch: string)
		return key(ch, ch, nil, nil, nil, true)
	end

	local alphaRows = {
		{
			key("1\n!", "1"), key("2\n@", "2"), key("3\n#", "3"),
			key("4\n$", "4"), key("5\n%", "5"), key("6\n^", "6"),
			key("7\n&", "7"), key("8\n*", "8"), key("9\n(", "9"),
			key("0\n)", "0"),
		},
		{
			letter("q"), letter("w"), letter("e"), letter("r"), letter("t"),
			letter("y"), letter("u"), letter("i"), letter("o"), letter("p"),
		},
		{
			key("Caps", "caps", 1.45, false, "caps"),
			letter("a"), letter("s"), letter("d"), letter("f"), letter("g"),
			letter("h"), letter("j"), letter("k"), letter("l"),
			key("Enter", "enter", 1.65),
		},
		{
			key("Shift", "shift", 1.55, false, "shift"),
			letter("z"), letter("x"), letter("c"), letter("v"),
			letter("b"), letter("n"), letter("m"),
			key(",\n<", ","), key(".\n>", "."), key("/\n?", "/"),
			key("Backspace", "backspace", 1.9, true),
		},
		{
			key("#+=", "symbols", 1.35),
			key("Esc", "escape", 1.05),
			key("Tab", "tab", 1.05),
			key("Ctrl-C", "ctrl-c", 1.45),
			key("Space", "space", 5.1),
		},
	}

	local slashCharacter = string.char(92)
	local graveCharacter = string.char(96)
	local symbolRows = {
		{
			key("!", "!"), key("@", "@"), key("#", "#"), key("$", "$"),
			key("%", "%"), key("^", "^"), key("&", "&"), key("*", "*"),
			key("(", "("), key(")", ")"),
		},
		{
			key("-", "-"), key("_", "_"), key("=", "="), key("+", "+"),
			key("[", "["), key("]", "]"), key("{", "{"), key("}", "}"),
			key(slashCharacter, slashCharacter), key("|", "|"),
		},
		{
			key(graveCharacter, graveCharacter), key("~", "~"), key(";", ";"),
			key(":", ":"), key("'", "'"), key("\"", "\""), key(",", ","),
			key(".", "."), key("<", "<"), key(">", ">"),
		},
		{
			key("/", "/"), key("?", "?"), key("Esc", "escape", 1.25),
			key("Tab", "tab", 1.25), key("Ctrl-C", "ctrl-c", 1.65),
			key("Backspace", "backspace", 2.1, true),
			key("Enter", "enter", 1.65),
		},
		{
			key("ABC", "abc", 1.5),
			key("Space", "space", 6),
		},
	}

	createRows(alphaPage, alphaRows)
	createRows(symbolPage, symbolRows)

	refreshKeyboardState = function()
		local uppercase = virtualCaps ~= virtualShift
		for button, info in pairs(printableButtons) do
			button.Text = uppercase and info.shifted or info.normal
		end

		for _, button in ipairs(shiftButtons) do
			button.BackgroundColor3 = virtualShift and COLOR_KEY_ACTIVE or COLOR_KEY_SPECIAL
			button.BackgroundTransparency = virtualShift and 0.1 or 0.24
		end
		for _, button in ipairs(capsButtons) do
			button.BackgroundColor3 = virtualCaps and COLOR_KEY_ACTIVE or COLOR_KEY_SPECIAL
			button.BackgroundTransparency = virtualCaps and 0.1 or 0.24
		end
	end

	minimizeButton.Activated:Connect(function()
		bridge:Fire("hide")
	end)
	restoreButton.Activated:Connect(function()
		bridge:Fire("show")
	end)

	local function applyResponsiveLayout()
		local camera = Workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
		if viewport.X < 100 or viewport.Y < 100 then
			viewport = Vector2.new(1280, 720)
		end

		local isVR = VRService.VREnabled
		local portrait = viewport.Y > viewport.X
		local sideMargin = isVR and 40 or (portrait and 6 or 12)
		local maxWidth = isVR and 1080 or 980
		local width = math.max(240, math.min(maxWidth, viewport.X - sideMargin * 2))

		local heightRatio
		local minHeight
		local maxHeight
		if isVR then
			heightRatio = 0.5
			minHeight = 245
			maxHeight = 430
		elseif portrait then
			heightRatio = 0.38
			minHeight = 245
			maxHeight = 380
		else
			heightRatio = 0.54
			minHeight = 200
			maxHeight = 340
		end

		local height = math.clamp(viewport.Y * heightRatio, minHeight, maxHeight)
		height = math.min(height, math.max(160, viewport.Y - 18))

		local fallbackBottomInset = 0
		if not hasDeviceSafeInsets then
			local ok, _, bottomRightInset = pcall(function()
				return GuiService:GetGuiInset()
			end)
			if ok and typeof(bottomRightInset) == "Vector2" then
				fallbackBottomInset = bottomRightInset.Y
			end
		end

		local bottomMargin = 8 + fallbackBottomInset
		root.Position = UDim2.new(0.5, 0, 1, -bottomMargin)
		root.Size = UDim2.fromOffset(math.floor(width), math.floor(height))
		restoreButton.Position = UDim2.new(1, -10, 1, -bottomMargin)
		restoreButton.Size = UDim2.fromOffset(isVR and 118 or 92, isVR and 50 or 42)
	end

	local viewportConnection: RBXScriptConnection? = nil
	local function connectCamera()
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
		local camera = Workspace.CurrentCamera
		if camera then
			viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyResponsiveLayout)
		end
		applyResponsiveLayout()
	end

	local function forceVirtualKeyboard(): boolean
		return RunService:IsStudio()
			and script:GetAttribute("RoEmuForceVirtualKeyboard") == true
	end

	local function needsVirtualKeyboard(): boolean
		return forceVirtualKeyboard()
			or ((UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled)
				or VRService.VREnabled)
	end

	local function refreshDeviceVisibility()
		local visible = needsVirtualKeyboard()
		keyboardGui.Enabled = visible
		if visible then
			ensureAttached()
		else
			repeatGeneration += 1
			pendingBytes = ""
		end
		applyResponsiveLayout()
	end

	UserInputService:GetPropertyChangedSignal("TouchEnabled"):Connect(refreshDeviceVisibility)
	UserInputService:GetPropertyChangedSignal("KeyboardEnabled"):Connect(refreshDeviceVisibility)
	VRService:GetPropertyChangedSignal("VREnabled"):Connect(refreshDeviceVisibility)
	script:GetAttributeChangedSignal("RoEmuForceVirtualKeyboard"):Connect(refreshDeviceVisibility)
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(connectCamera)

	connectCamera()
	refreshKeyboardState()
	refreshDeviceVisibility()
end
print("[RoEmu_RemotesKeyboard] listo")

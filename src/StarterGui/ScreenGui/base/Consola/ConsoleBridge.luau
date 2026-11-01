-- StarterGui/ScreenGui/base/Consola/ConsoleBridge  (SAFE)  (B completo v3 ORDENADO)
-- UI requerida:
--   Consola
--     OutputScroll (ScrollingFrame)
--       Output (TextLabel)
--
-- Cambios clave:
--  - Fase CATCH-UP: cola lo que llegue por Out hasta imprimir el backlog, luego flush en orden.
--  - READY: RoEmu_Ready:FireServer("ui-ready") si existe.
--  - Backlog SIEMPRE (1 pull) para no perder logs si la UI carga tarde.
--  - Auto-scroll SIEMPRE al fondo; barra oculta; scroll manual deshabilitado.
--  - Logo FULLWIDTH para IBM Plex Sans JP.

local RS         = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")

local root = script.Parent

-- ===== UI obligatoria =====
local scroll = root:WaitForChild("OutputScroll")
assert(scroll:IsA("ScrollingFrame"), "ConsoleBridge: 'OutputScroll' debe ser ScrollingFrame")

local label = scroll:WaitForChild("Output")
assert(label:IsA("TextLabel"), "ConsoleBridge: 'Output' debe ser TextLabel dentro de OutputScroll")

-- ===== límites TextLabel =====
local TEXT_HARD_MAX = 200000
local TEXT_SOFT_MAX = 195000

-- =========================
-- Helpers
-- =========================
local function ensureNL(s: string): string
	if s == nil or #s == 0 then return "\n" end
	return (s:sub(-1) == "\n") and s or (s .. "\n")
end

local function toFullwidthGrid(s: string): string
	local FW_HASH  = "＃"        -- U+FF03
	local FW_SPACE = "\u{3000}"  -- ideographic space
	s = s:gsub("#", FW_HASH)
	s = s:gsub(" ", FW_SPACE)
	return s
end

local function buildPrefix(): string
	local banner = [[
######   #####  ####### ##   ## ##   ##
##   ## ##   ## ##      ### ### ##   ##
##   ## ##   ## ##      ####### ##   ##
######  ##   ## #####   ## # ## ##   ##
## ##   ##   ## ##      ##   ## ##   ##
##  ##  ##   ## ##      ##   ## ##   ##
##   ##  #####  ####### ##   ##  ##### 

]]
	return toFullwidthGrid(banner) .. "[Consola] Click aquí, escribe y Enter para enviar...\n"
end

local PREFIX = buildPrefix()

local function trimKeepPrefix(fullText: string): string
	if #fullText <= TEXT_SOFT_MAX then return fullText end
	if fullText:sub(1, #PREFIX) ~= PREFIX then
		return fullText:sub(#fullText - TEXT_SOFT_MAX + 1)
	end
	local maxLog = TEXT_SOFT_MAX - #PREFIX
	if maxLog <= 0 then return fullText:sub(1, TEXT_SOFT_MAX) end
	local logPart = fullText:sub(#PREFIX + 1)
	if #logPart > maxLog then
		logPart = logPart:sub(#logPart - maxLog + 1)
	end
	return PREFIX .. logPart
end

-- =========================
-- Auto-scroll SIEMPRE al fondo (robusto)
-- =========================
local PADDING_Y = 8

local function forceScrollToBottom()
	task.defer(function()
		RunService.RenderStepped:Wait()
		local contentH = math.ceil(label.TextBounds.Y) + PADDING_Y
		scroll.CanvasSize = UDim2.fromOffset(0, contentH)
		label.Size = UDim2.new(1, -(scroll.ScrollBarThickness + 6), 0, contentH)
		local maxY = math.max(0, contentH - scroll.AbsoluteSize.Y)
		scroll.CanvasPosition = Vector2.new(0, maxY)
	end)
end

-- =========================
-- Append seguro + buffer
-- =========================
local function appendDirect(s: string)
	if not s or #s == 0 then return end

	local cur = label.Text or ""
	if cur == "" then cur = PREFIX end
	if cur:sub(1, #PREFIX) ~= PREFIX then
		cur = PREFIX .. cur
	end

	local logPart = cur:sub(#PREFIX + 1)
	local maxLog = math.max(0, TEXT_SOFT_MAX - #PREFIX)

	if #s >= maxLog then
		local tail = s
		if #tail > maxLog then
			tail = tail:sub(#tail - maxLog + 1)
		end
		label.Text = PREFIX .. tail
		forceScrollToBottom()
		return
	end

	local newLog = logPart .. s
	if #newLog > maxLog then
		newLog = newLog:sub(#newLog - maxLog + 1)
	end

	local newText = PREFIX .. newLog
	if #newText >= TEXT_HARD_MAX then
		newText = trimKeepPrefix(newText)
	end

	label.Text = newText
	forceScrollToBottom()
end

local pending = ""
local lastFlush = 0
local FLUSH_INTERVAL = 0.05
local FLUSH_CHUNK_MAX = 8192

local function bufferAppend(s: string)
	if not s or #s == 0 then return end
	pending ..= s
	if #pending >= FLUSH_CHUNK_MAX then
		appendDirect(pending)
		pending = ""
		lastFlush = os.clock()
	end
end

RunService.Heartbeat:Connect(function()
	if #pending == 0 then return end
	local now = os.clock()
	if (now - lastFlush) >= FLUSH_INTERVAL then
		appendDirect(pending)
		pending = ""
		lastFlush = now
	end
end)

-- =========================
-- UI init: ocultar barra + bloquear scroll manual
-- =========================
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ClipsDescendants = true
scroll.ScrollingDirection = Enum.ScrollingDirection.Y
scroll.AutomaticCanvasSize = Enum.AutomaticSize.None
scroll.CanvasSize = UDim2.fromOffset(0, 0)

scroll.ScrollBarThickness = 0
scroll.ScrollBarImageTransparency = 1
scroll.ScrollingEnabled = false

label.BackgroundTransparency = 1
label.RichText = false
label.TextWrapped = false
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextYAlignment = Enum.TextYAlignment.Top
pcall(function() label.TextTruncate = Enum.TextTruncate.None end)
pcall(function() label.MaxVisibleGraphemes = -1 end)

label.Text = PREFIX
forceScrollToBottom()

-- =========================
-- Entrada opcional (RoEmu_Input)
-- =========================
local InRE = RS:FindFirstChild("RoEmu_Input")

local hidden = root:FindFirstChild("HiddenInput")
if not (hidden and hidden:IsA("TextBox")) then
	hidden = Instance.new("TextBox")
	hidden.Name = "HiddenInput"
	hidden.Parent = root
	hidden.ClearTextOnFocus = false
	hidden.MultiLine = false
	hidden.Visible = false
	hidden.Size = UDim2.fromOffset(0,0)
	hidden.Position = UDim2.fromOffset(0,0)
	hidden.BackgroundTransparency = 1
	hidden.TextTransparency = 1
end

label.Active = true
label.Selectable = true
label.InputBegan:Connect(function(inputObj)
	if inputObj.UserInputType == Enum.UserInputType.MouseButton1 then
		hidden:CaptureFocus()
	end
end)

hidden.InputBegan:Connect(function(inputObj)
	if inputObj.UserInputType == Enum.UserInputType.Keyboard then
		if inputObj.KeyCode == Enum.KeyCode.L
			and (UIS:IsKeyDown(Enum.KeyCode.LeftControl) or UIS:IsKeyDown(Enum.KeyCode.RightControl)) then
			label.Text = PREFIX
			pending = ""
			forceScrollToBottom()
		end
	end
end)

hidden.FocusLost:Connect(function(enterPressed)
	if not enterPressed then return end
	local line = hidden.Text or ""
	hidden.Text = ""

	bufferAppend("> " .. line .. "\n")

	if InRE and InRE:IsA("RemoteEvent") then
		InRE:FireServer(line .. "\n")
	end

	task.defer(function()
		hidden:CaptureFocus()
	end)
end)

-- =========================
-- DEDUPE por líneas (para que backlog + push no duplique)
-- =========================
local RECENT_MAX = 800
local recentQ = {}
local recentSet = {}

local function remember(line: string)
	if recentSet[line] then return end
	recentSet[line] = true
	table.insert(recentQ, line)
	if #recentQ > RECENT_MAX then
		local old = table.remove(recentQ, 1)
		recentSet[old] = nil
	end
end

local function pushLine(line: string)
	line = line:gsub("\r\n", "\n"):gsub("\r", "")
	if line == "" then return end
	if recentSet[line] then return end
	remember(line)
	bufferAppend(line .. "\n")
end

local function ingestTextBlock(text: string)
	text = tostring(text or "")
	text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
	for line in text:gmatch("([^\n]*)\n?") do
		if line ~= "" then
			pushLine(line)
		end
	end
end

-- =========================
-- ORDEN: fase CATCH-UP (cola lo que llegue en vivo hasta imprimir backlog)
-- =========================
local catchingUp = true
local queuedMsgs = {} -- strings en orden de llegada

local function extractMsg(payload): string?
	if typeof(payload) == "string" then
		return payload
	elseif typeof(payload) == "table" then
		local msg = payload.msg or payload.text or payload[1]
		if typeof(msg) == "string" then return msg end
	end
	return nil
end

-- Conectarse a Out lo antes posible
local Out = RS:WaitForChild("RoEmu_Out")
assert(Out:IsA("RemoteEvent"), "RoEmu_Out debe ser RemoteEvent")

Out.OnClientEvent:Connect(function(payload)
	local msg = extractMsg(payload)
	if not msg or #msg == 0 then return end

	if catchingUp then
		table.insert(queuedMsgs, msg)
	else
		ingestTextBlock(msg)
	end
end)

-- READY (si existe)
local Ready = RS:FindFirstChild("RoEmu_Ready")
if Ready and Ready:IsA("RemoteEvent") then
	Ready:FireServer("ui-ready")
end

-- Backlog SIEMPRE: imprimir primero, luego flush de la cola (ordenado)
local function pullBacklogOnce()
	local OutGet = RS:FindFirstChild("RoEmu_OutGet")
	if not (OutGet and OutGet:IsA("RemoteFunction")) then return nil end

	local ok, hist = pcall(function()
		return OutGet:InvokeServer()
	end)
	if ok and typeof(hist) == "string" and #hist > 0 then
		return hist
	end
	return nil
end

task.defer(function()
	-- 1) backlog primero
	local hist = pullBacklogOnce()
	if hist then
		ingestTextBlock(hist)
	end

	-- 2) ahora sí, lo que llegó mientras tanto, en el orden en que llegó
	catchingUp = false
	for _, msg in ipairs(queuedMsgs) do
		ingestTextBlock(msg)
	end
	queuedMsgs = {}
end)

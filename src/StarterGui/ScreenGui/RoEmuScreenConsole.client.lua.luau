-- RoEmuScreenConsole.client.lua
-- Terminal de RoEMU sobre el ScreenGui existente, sin panel ni fondo propio.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

task.spawn(function()
	require(ReplicatedStorage:WaitForChild("RoEmu_BootSelectorClient")).Mount()
end)

local screenGui = script.Parent
assert(screenGui:IsA("ScreenGui"), "RoEmuScreenConsole debe estar dentro de un ScreenGui")

local viewport = screenGui:WaitForChild("RoEmuViewport")
local fontFolder = ReplicatedStorage:WaitForChild("PerfectDOSVGA437")
local FontData = require(fontFolder:WaitForChild("FontData"))
local PixelText = require(fontFolder:WaitForChild("PixelText"))

local SCALE = tonumber(screenGui:GetAttribute("RoEmuFontScale")) or 2
SCALE = math.max(1, math.floor(SCALE + 0.5))

local MAX_BUFFER_BYTES = 120000
local FLUSH_INTERVAL = 0.05
local CELL_WIDTH = FontData.Advance * SCALE
local CELL_HEIGHT = FontData.LineHeight * SCALE

--[[ ROEMU_STARTUP_LOGO_PATCH_BEGIN ]]
local startupLogoModule = ReplicatedStorage:WaitForChild("RoEMUPoweredLogo")
local terminalText = ""

do
	local showLogo = screenGui:GetAttribute("RoEmuShowStartupLogo")
	if showLogo == nil then
		showLogo = true
	end

	if showLogo then
		-- Esperar únicamente hasta que RoEmuViewport tenga dimensiones reales.
		-- Todavía no se conectan Out/Log, así que el logo conserva el primer lugar.
		if viewport.AbsoluteSize.X <= 0 or viewport.AbsoluteSize.Y <= 0 then
			RunService.RenderStepped:Wait()
		end

		local columns = math.max(
			1,
			math.floor(viewport.AbsoluteSize.X / CELL_WIDTH)
		)

		local logoOnly =
			screenGui:GetAttribute("RoEmuStartupLogoOnly") == true

		local ok, logoOrError = pcall(require, startupLogoModule)
		if ok
			and typeof(logoOrError) == "table"
			and typeof(logoOrError.Get) == "function"
		then
			terminalText =
				logoOrError.Get(columns, logoOnly)
				.. "\n\n"
		else
			terminalText =
				"[RoEmu] No se pudo cargar RoEMUPoweredLogo: "
				.. tostring(logoOrError)
				.. "\n"
		end
	end
end
--[[ ROEMU_STARTUP_LOGO_PATCH_END ]]

local pendingText = ""
local lastFlush = 0
local renderQueued = false
local connectedLegacyOut = nil

local renderer = PixelText.new(viewport, {
	Name = "RoEmuPixelOutput",
	Position = UDim2.fromOffset(0, 0),
	Size = UDim2.fromScale(1, 1),
	Text = "",
	Scale = SCALE,
	Color = Color3.fromRGB(225, 230, 225),
	Transparency = 0,
	TextWrapped = false,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	ClipsDescendants = true,
	ZIndex = 101,
})

local function validUtf8OrAsciiFallback(value)
	value = tostring(value or "")
	local ok = pcall(function()
		return utf8.len(value)
	end)
	if ok then
		return value
	end

	local out = table.create(#value)
	for i = 1, #value do
		local byte = string.byte(value, i)
		if byte >= 32 and byte <= 126 then
			out[#out + 1] = string.char(byte)
		elseif byte == 9 or byte == 10 or byte == 13 or byte == 8 then
			out[#out + 1] = string.char(byte)
		else
			out[#out + 1] = "?"
		end
	end
	return table.concat(out)
end

local function stripAnsi(value)
	value = validUtf8OrAsciiFallback(value)
	-- CSI: ESC [ ... command
	value = value:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
	-- OSC simple: ESC ] ... BEL
	value = value:gsub("\27%][^\7]*\7", "")
	return value
end

local function removeLastTerminalCharacter()
	if terminalText == "" or terminalText:sub(-1) == "\n" then
		return
	end
	local ok, startIndex = pcall(utf8.offset, terminalText, -1)
	if ok and startIndex then
		terminalText = terminalText:sub(1, startIndex - 1)
	else
		terminalText = terminalText:sub(1, -2)
	end
end

local function applyTerminalChunk(value)
	value = stripAnsi(value)
	value = value:gsub("\r\n", "\n")
	-- Se conserva el comportamiento anterior de la consola: un CR aislado
	-- avanza de línea. El cambio importante es que BS ahora opera sobre el
	-- estado acumulado, aunque la secuencia "\b \b" llegue en otro paquete.
	value = value:gsub("\r", "\n")

	local pending = {}
	local function flushPending()
		if #pending > 0 then
			terminalText ..= table.concat(pending)
			pending = {}
		end
	end

	for _, codepoint in utf8.codes(value) do
		if codepoint == 8 then
			flushPending()
			removeLastTerminalCharacter()
		else
			pending[#pending + 1] = utf8.char(codepoint)
		end
	end
	flushPending()
end

local function trimBuffer()
	if #terminalText <= MAX_BUFFER_BYTES then
		return
	end
	terminalText = terminalText:sub(#terminalText - MAX_BUFFER_BYTES + 1)
	local firstNewline = terminalText:find("\n", 1, true)
	if firstNewline then
		terminalText = terminalText:sub(firstNewline + 1)
	end
end

local function appendNow(value)
	value = tostring(value or "")
	if value == "" then
		return
	end
	applyTerminalChunk(value)
	trimBuffer()
end

local function append(value)
	value = tostring(value or "")
	if value ~= "" then
		pendingText ..= value
	end
end

local function pushWrappedLine(line, columns, output)
	if line == "" then
		output[#output + 1] = ""
		return
	end

	local current = table.create(columns)
	local count = 0

	for _, codepoint in utf8.codes(line) do
		if codepoint == 9 then
			local spaces = 4 - (count % 4)
			for _ = 1, spaces do
				current[#current + 1] = " "
				count += 1
				if count >= columns then
					output[#output + 1] = table.concat(current)
					current = table.create(columns)
					count = 0
				end
			end
		else
			current[#current + 1] = utf8.char(codepoint)
			count += 1
			if count >= columns then
				output[#output + 1] = table.concat(current)
				current = table.create(columns)
				count = 0
			end
		end
	end

	if count > 0 then
		output[#output + 1] = table.concat(current)
	end
end

local function buildVisibleText()
	local size = viewport.AbsoluteSize
	local columns = math.max(1, math.floor(size.X / CELL_WIDTH))
	local rows = math.max(1, math.floor(size.Y / CELL_HEIGHT))

	local wrapped = {}
	local normalized = validUtf8OrAsciiFallback(terminalText)

	for line in (normalized .. "\n"):gmatch("(.-)\n") do
		pushWrappedLine(line, columns, wrapped)
	end

	local first = math.max(1, #wrapped - rows + 1)
	local visible = table.create(math.min(rows, #wrapped))
	for i = first, #wrapped do
		visible[#visible + 1] = wrapped[i]
	end

	return table.concat(visible, "\n")
end

local function render()
	renderQueued = false
	renderer:SetText(buildVisibleText())
end

local function queueRender()
	if renderQueued then
		return
	end
	renderQueued = true
	task.defer(render)
end

viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueRender)
screenGui:GetAttributeChangedSignal("RoEmuFontScale"):Connect(function()
	warn("[RoEMU ScreenGui] RoEmuFontScale cambió. Detén y vuelve a iniciar Play para aplicarlo.")
end)

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	if pendingText ~= "" and (now - lastFlush) >= FLUSH_INTERVAL then
		local chunk = pendingText
		pendingText = ""
		lastFlush = now
		appendNow(chunk)
		queueRender()
	end
end)

local function extractPayload(payload)
	if typeof(payload) == "string" then
		return payload
	elseif typeof(payload) == "table" then
		local value = payload.msg or payload.text or payload[1]
		if typeof(value) == "string" then
			return value
		end
	end
	return tostring(payload or "")
end

local function connectLegacyOut(remote)
	if connectedLegacyOut == remote or not remote:IsA("RemoteEvent") then
		return
	end
	connectedLegacyOut = remote
	remote.OnClientEvent:Connect(function(payload)
		append(extractPayload(payload))
	end)
end

local function connectLegacyCompatibility()
	local legacyOut = ReplicatedStorage:FindFirstChild("RoEmu_Out")
	if legacyOut and legacyOut:IsA("RemoteEvent") then
		connectLegacyOut(legacyOut)
	end

	local legacyGet = ReplicatedStorage:FindFirstChild("RoEmu_OutGet")
	if legacyGet and legacyGet:IsA("RemoteFunction") then
		task.spawn(function()
			local ok, history = pcall(function()
				return legacyGet:InvokeServer()
			end)
			if ok and typeof(history) == "string" and history ~= "" then
				append(history)
			end
		end)
	end
end

ReplicatedStorage.ChildAdded:Connect(function(child)
	if child.Name == "RoEmu_Out" and child:IsA("RemoteEvent") then
		connectLegacyOut(child)
	end
end)

connectLegacyCompatibility()

-- Arquitectura nueva: ReplicatedStorage.RoEmu_Remotes/{Out,Log,In,Rpc}
task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("RoEmu_Remotes", 20)
	if not remotes or not remotes:IsA("Folder") then
		append("[RoEmu] RoEmu_Remotes no apareció. Se mantiene compatibilidad legacy.\n")
		return
	end

	local outRemote = remotes:WaitForChild("Out", 10)
	local logRemote = remotes:WaitForChild("Log", 10)
	local rpc = remotes:WaitForChild("Rpc", 10)

	if outRemote and outRemote:IsA("RemoteEvent") then
		outRemote.OnClientEvent:Connect(function(payload)
			append(extractPayload(payload))
		end)
	end

	if logRemote and logRemote:IsA("RemoteEvent") then
		logRemote.OnClientEvent:Connect(function(level, message)
			append(string.format("[%-5s] %s\n", tostring(level or "INFO"), tostring(message or "")))
		end)
	end

	if rpc and rpc:IsA("RemoteFunction") then
		local ok, success, message = pcall(function()
			return rpc:InvokeServer("attach", {
				client = "RoEmuScreenConsole",
				version = 1,
			})
		end)

		if ok and success == true then
			append("[RoEmu] Terminal adjunta al ScreenGui.\n")
		else
			append("[RoEmu] Attach falló: " .. tostring(message or success) .. "\n")
		end
	end
end)

queueRender()

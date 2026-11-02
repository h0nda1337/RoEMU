--!optimize 2
-- Local, asset-free startup overlay. The existing terminal stays underneath.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Selector = {}

function Selector.Mount()
	task.spawn(function() require(ReplicatedStorage:WaitForChild("RoEmu_PC_VideoClient")).Mount() end)
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	if playerGui:FindFirstChild("RoEmuBootSelector") then return end
	local screen = Instance.new("ScreenGui")
	screen.Name = "RoEmuBootSelector"
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 3000
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = playerGui
	playerGui:SetAttribute("RoEmuBootMenuOpen", true)
	local palette = {
		bg = Color3.fromRGB(10, 13, 22), panel = Color3.fromRGB(19, 24, 38),
		card = Color3.fromRGB(25, 31, 48), text = Color3.fromRGB(239, 244, 255),
		muted = Color3.fromRGB(148, 160, 183), cyan = Color3.fromRGB(106, 226, 213),
		blue = Color3.fromRGB(147, 170, 255), line = Color3.fromRGB(48, 59, 79),
		purple = Color3.fromRGB(205, 170, 255),
	}
	local function make(className, parent, properties)
		local object = Instance.new(className)
		for key, value in pairs(properties or {}) do object[key] = value end
		object.Parent = parent
		return object
	end
	local function round(parent, radius)
		make("UICorner", parent, { CornerRadius = UDim.new(0, radius) })
	end
	local function text(parent, name, value, x, y, width, height, size, color, font)
		return make("TextLabel", parent, {
			Name = name, Text = value, Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(width, height),
			BackgroundTransparency = 1, TextSize = size, TextColor3 = color or palette.text,
			Font = font or Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Center, TextWrapped = true,
		})
	end
	local backdrop = make("Frame", screen, {
		Name = "Backdrop", Size = UDim2.fromScale(1, 1), BackgroundColor3 = palette.bg,
		BorderSizePixel = 0, Active = true,
	})
	make("UIGradient", backdrop, {
		Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.fromRGB(13, 22, 39)),
			ColorSequenceKeypoint.new(1, palette.bg) }), Rotation = 35,
	})
	local panel = make("Frame", backdrop, {
		Name = "Panel", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(720, 510), BackgroundColor3 = palette.panel, BorderSizePixel = 0,
	})
	round(panel, 22)
	make("UIStroke", panel, { Color = palette.line, Thickness = 1 })
	local scale = make("UIScale", panel, { Scale = 1 })
	local function resize()
		local size = backdrop.AbsoluteSize
		scale.Scale = math.min(1, math.max(0.25, math.min((size.X - 24) / 720, (size.Y - 36) / 510)))
	end
	backdrop:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize)
	resize()
	local mark = make("Frame", panel, {
		Name = "Mark", Position = UDim2.fromOffset(32, 28), Size = UDim2.fromOffset(34, 34),
		BackgroundColor3 = palette.cyan, BorderSizePixel = 0,
	})
	round(mark, 9)
	text(mark, "Symbol", ">_", 5, 0, 28, 34, 17, palette.bg, Enum.Font.Code)
	text(panel, "Brand", "RoEMU", 78, 28, 180, 34, 24, palette.text, Enum.Font.GothamBold)
	text(panel, "Edition", "LOCAL BUILD", 540, 32, 148, 24, 11, palette.muted, Enum.Font.GothamMedium)
	text(panel, "Title", "Elige tu arquitectura", 32, 91, 656, 44, 32, palette.text, Enum.Font.GothamBold)
	text(panel, "Subtitle", "Elige una plataforma para explorar.", 32, 140, 656, 26, 15, palette.muted)
	local selected = "rv32"
	local busy = false
	local cards = {}
	local choices={
		rv32={start="Arrancar RV32   →",retry="Arrancar RV32   →",hint="OpenSBI, CaribeBootX y la consola de CaribeOS."},
		i386={start="Intentar Windows 95   →",retry="Reintentar Windows 95   →",hint="Se ejecutara el cargador del disco en el procesador emulado."},
		powerpc={start="Ver estado de PowerPC / PS3   →",retry="Ver estado de PowerPC / PS3   →",hint="Base PowerPC64 en desarrollo. CellOS/GameOS todavia no arranca."},
	}
	local function card(id, x, heading, title, description, badge, accent)
		local button = make("TextButton", panel, {
			Name = ({rv32="RV32Card",i386="I386Card",powerpc="PowerPCCard"})[id], Text = "", AutoButtonColor = false,
			Position = UDim2.fromOffset(x, 192), Size = UDim2.fromOffset(208, 168),
			BackgroundColor3 = palette.card, BorderSizePixel = 0, Selectable = true,
		})
		round(button, 14)
		local stroke = make("UIStroke", button, { Color = palette.line, Thickness = 1 })
		text(button, "Architecture", heading, 18, 15, 155, 31, 26, accent, Enum.Font.GothamBold)
		text(button, "Guest", title, 18, 54, 172, 24, 17, palette.text, Enum.Font.GothamMedium)
		text(button, "Description", description, 18, 84, 172, 36, 12, palette.muted)
		text(button, "Badge", badge, 18, 130, 172, 20, 11, accent, Enum.Font.GothamMedium)
		local dot = make("Frame", button, {
			Name = "Selected", Position = UDim2.fromOffset(178, 22), Size = UDim2.fromOffset(12, 12),
			BorderSizePixel = 0, BackgroundColor3 = accent, Visible = false,
		})
		round(dot, 6)
		cards[id] = { button = button, stroke = stroke, dot = dot, accent = accent }
		return button
	end
	local rv = card("rv32", 32, "RV32", "CaribeOS", "OpenSBI  /  XNU RV32  /  GNU Bash", "LISTO PARA ARRANCAR", palette.cyan)
	local x86 = card("i386", 256, "i386", "Windows 95", "Intel x86  /  Disco de prueba local", "ARRANQUE EXPERIMENTAL", palette.blue)
	local ppc = card("powerpc", 480, "PowerPC", "CellOS / GameOS", "PS3  /  Cell PPE + SPE  /  RSX", "EN DESARROLLO", palette.purple)
	local status = text(panel, "Status", "El arranque comienza cuando tu lo decides.", 32, 374, 656, 53, 12, palette.muted)
	status.TextYAlignment = Enum.TextYAlignment.Top
	local start = make("TextButton", panel, {
		Name = "StartButton", Position = UDim2.fromOffset(32, 439), Size = UDim2.fromOffset(656, 43),
		BackgroundColor3 = palette.cyan, TextColor3 = palette.bg, Text = "Arrancar RV32   →",
		TextSize = 15, Font = Enum.Font.GothamBold, BorderSizePixel = 0, AutoButtonColor = false,
	})
	round(start, 11)
	local function select(id)
		if busy then return end
		selected = id
		for key, item in pairs(cards) do
			item.dot.Visible = key == id
			TweenService:Create(item.stroke, TweenInfo.new(0.15), {
				Color = key == id and item.accent or palette.line,
				Thickness = key == id and 2 or 1,
			}):Play()
		end
		start.Text = choices[id].start
		start.BackgroundColor3 = cards[id].accent
		status.Text = choices[id].hint
		status.TextColor3 = palette.muted
	end
	rv.Activated:Connect(function() select("rv32") end)
	x86.Activated:Connect(function() select("i386") end)
	ppc.Activated:Connect(function() select("powerpc") end)
	select("rv32")
	local bootFolder
	local rpc
	local closed = false
	local attributeConnection
	local function close()
		if closed then return end
		closed = true
		if attributeConnection then attributeConnection:Disconnect() end
		playerGui:SetAttribute("RoEmuBootMenuOpen", false)
		if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(screen) then
			GuiService.SelectedObject = nil
		end
		screen:Destroy()
	end
	start.Activated:Connect(function()
		if busy or closed then return end
		if not rpc then status.Text = "Conectando con el emulador local..." return end
		busy = true
		start.Text = "Preparando..."
		local ok, accepted, reply = pcall(function() return rpc:InvokeServer("choose", selected) end)
		if closed then return end
		if ok and accepted then close() return end
		busy = false
		start.Text = choices[selected].retry
		status.TextColor3 = Color3.fromRGB(255, 200, 142)
		if ok and type(reply)=="table" and reply.code=="powerpc-platform-incomplete" then
			status.TextColor3=palette.purple
			status.Text=tostring(reply.message)
		elseif ok and type(reply) == "table" and reply.code == "pc-platform-incomplete" then
			status.Text = "Windows 95 aun no arranca: faltan modo real, paginacion, BIOS y dispositivos PC. Puedes iniciar RV32."
		else
			status.Text = ok and type(reply) == "table" and tostring(reply.message or reply.code)
				or "No se pudo conectar. Vuelve a intentarlo."
		end
	end)
	task.spawn(function()
		bootFolder = ReplicatedStorage:WaitForChild("RoEmu_Boot", 30)
		if closed then return end
		if not bootFolder then status.Text = "El servidor de arranque no respondio." return end
		rpc = bootFolder:WaitForChild("Rpc", 10)
		if not rpc then status.Text = "No se encontro el control de arranque." return end
		attributeConnection = bootFolder:GetAttributeChangedSignal("Started"):Connect(function()
			if bootFolder:GetAttribute("Started") then close() end
		end)
		if bootFolder:GetAttribute("Started") then close() end
	end)
	if UserInputService.GamepadEnabled then GuiService.SelectedObject = rv end
	return screen
end

return Selector

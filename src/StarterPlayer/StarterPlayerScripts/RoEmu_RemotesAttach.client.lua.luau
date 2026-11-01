-- StarterPlayer/StarterPlayerScripts/RoEmu_RemotesAttach.client.lua
-- LocalScript
-- Cliente para la arquitectura NUEVA:
--   ReplicatedStorage.RoEmu_Remotes/{Log,Out,In,Rpc}
-- Hace attach por Rpc y pinta Out en un monitor.
-- Si no existe GUI/OutputLabel, la crea automaticamente.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local REMOTES_FOLDER_NAME = "RoEmu_Remotes"
local ATTACH_RETRY_SECONDS = 2
local MAX_TEXT = 120000

local remotes = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 15)
if not remotes then
	warn("[RoEmu_RemotesAttach] No aparecio ReplicatedStorage." .. REMOTES_FOLDER_NAME)
	return
end

local Rpc = remotes:WaitForChild("Rpc", 15)
local Out = remotes:WaitForChild("Out", 15)
local Log = remotes:WaitForChild("Log", 15)

if not Rpc or not Out or not Log then
	warn("[RoEmu_RemotesAttach] Faltan remotos Rpc/Out/Log")
	return
end

local outputLabel: TextLabel? = nil

local function ensureMonitorGui(): TextLabel?
	local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 15)
	if not playerGui then
		return nil
	end

	local gui = playerGui:FindFirstChild("RoEmu_MonitorGui")
	if not gui then
		gui = Instance.new("ScreenGui")
		gui.Name = "RoEmu_MonitorGui"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = 1000
		gui.Parent = playerGui
	end

	local label = gui:FindFirstChild("OutputLabel")
	if not label or not label:IsA("TextLabel") then
		if label then
			label:Destroy()
		end

		label = Instance.new("TextLabel")
		label.Name = "OutputLabel"
		label.BackgroundTransparency = 0
		label.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		label.BorderSizePixel = 0
		label.TextColor3 = Color3.fromRGB(0, 255, 0)
		label.TextStrokeTransparency = 1
		label.Text = ""
		label.TextWrapped = false
		label.RichText = false
		label.TextScaled = false
		label.Font = Enum.Font.Code
		label.TextSize = 18
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.ClipsDescendants = true
		label.Size = UDim2.new(1, 0, 1, 0)
		label.Position = UDim2.new(0, 0, 0, 0)
		label.Parent = gui
	end

	return label
end

local function getOutputLabel(): TextLabel?
	if outputLabel and outputLabel.Parent then
		return outputLabel
	end

	outputLabel = ensureMonitorGui()
	return outputLabel
end

local function appendText(s: string)
	local lbl = getOutputLabel()
	if not lbl then
		warn("[RoEmu_RemotesAttach] No pude crear/encontrar OutputLabel")
		return
	end

	s = tostring(s or "")
	lbl.Text = (lbl.Text or "") .. s

	if #lbl.Text > MAX_TEXT then
		lbl.Text = string.sub(lbl.Text, #lbl.Text - MAX_TEXT + 1)
	end
end

local function clearText()
	local lbl = getOutputLabel()
	if lbl then
		lbl.Text = ""
	end
end

local attached = false

local function tryAttach()
	local ok, a, b = pcall(function()
		return Rpc:InvokeServer("attach", {
			client = "RoEmu_RemotesAttach",
			version = 2,
		})
	end)

	if not ok then
		warn("[RoEmu_RemotesAttach] attach fallo: " .. tostring(a))
		return false
	end

	local success = (a == true)
	local msg = tostring(b)

	if success then
		attached = true
		print("[RoEmu_RemotesAttach] attach OK: " .. msg)
		return true
	end

	warn("[RoEmu_RemotesAttach] attach respondio false: " .. msg)
	return false
end

Out.OnClientEvent:Connect(function(payload)
	if typeof(payload) == "string" then
		appendText(payload)
	else
		appendText(tostring(payload))
	end
end)

Log.OnClientEvent:Connect(function(level, msg)
	level = tostring(level or "INFO")
	msg = tostring(msg or "")
	appendText(string.format("[%-5s] %s\n", level, msg))
end)

player.CharacterAdded:Connect(function()
	task.delay(0.25, function()
		getOutputLabel()
	end)
end)

task.delay(0.1, function()
	getOutputLabel()
	clearText()
	appendText("[RoEmu] Cliente listo. Esperando salida...\n")
end)

task.spawn(function()
	while not attached do
		if tryAttach() then
			break
		end
		task.wait(ATTACH_RETRY_SECONDS)
	end
end)
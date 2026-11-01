-- StarterPlayerScripts/RoEmu_ClientAttach.client.lua
-- Soporta:
--  - Paquetes {t="log"/"reset", gen, seq, msg} (Channel)
--  - Strings crudos (legacy)

local RS      = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local OutRE  = RS:WaitForChild("RoEmu_Out")
local OutGet = RS:WaitForChild("RoEmu_OutGet")

local outputLabel

local function findOutputLabel()
	local pg = player:WaitForChild("PlayerGui")
	local gui = pg:FindFirstChild("RoEmu_MonitorGui") or pg:FindFirstChildOfClass("ScreenGui")
	if not gui then return nil end

	local label = gui:FindFirstChild("OutputLabel", true)
	if label and label:IsA("TextLabel") then return label end

	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("TextLabel") then return d end
	end
	return nil
end

local function ensureLabel()
	if outputLabel and outputLabel.Parent then return outputLabel end
	outputLabel = findOutputLabel()
	if not outputLabel then
		warn("[RoEmu_ClientAttach] No se encontró TextLabel (OutputLabel).")
	end
	return outputLabel
end

local function appendRaw(s: string)
	local lbl = ensureLabel()
	if not lbl then return end
	s = tostring(s or "")
	lbl.Text = (lbl.Text or "") .. s
end

local function clear()
	local lbl = ensureLabel()
	if lbl then lbl.Text = "" end
end

-- Estado para backlog delta
local gen = 0
local lastSeq = 0

local function applyPacket(p)
	if type(p) == "string" then
		appendRaw(p)
		return
	end
	if type(p) ~= "table" then return end

	if p.t == "reset" then
		gen = tonumber(p.gen) or gen
		lastSeq = 0
		clear()
		return
	end

	if p.t == "log" then
		gen = tonumber(p.gen) or gen
		lastSeq = tonumber(p.seq) or lastSeq
		appendRaw(p.msg or "")
	end
end

-- Backlog inicial (y re-sync periódico)
local function pullDelta()
	local ok, res = pcall(function()
		return OutGet:InvokeServer(gen, lastSeq)
	end)
	if not ok then return end
	if type(res) ~= "table" or type(res.items) ~= "table" then return end

	-- Si cambió gen, resetea pantalla
	if tonumber(res.gen) ~= gen then
		gen = tonumber(res.gen) or gen
		lastSeq = 0
		clear()
	end

	for _, it in ipairs(res.items) do
		applyPacket({ t="log", gen=gen, seq=it.seq, msg=it.msg })
	end

	lastSeq = tonumber(res.lastSeq) or lastSeq
end

task.spawn(function()
	pullDelta()
end)

OutRE.OnClientEvent:Connect(applyPacket)

task.spawn(function()
	while task.wait(1.5) do
		pullDelta()
	end
end)

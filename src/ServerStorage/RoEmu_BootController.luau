--!optimize 2
-- One shared machine per server. The first successful boot choice owns it.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Platform = require(script.Parent:WaitForChild("RoEmu_i386_Platform"))
local Disk = require(script.Parent:WaitForChild("RoEmu_Win95DiskMetadata"))
local PC = require(script.Parent:WaitForChild("RoEmu_PC_Runtime"))
local PowerPC = require(script.Parent:WaitForChild("RoEmu_PowerPC_Platform"))

local Controller = {}
local initialized = false
local state = {
	phase = "choosing", architecture = "", guest = "", started = false,
	windowsBootObserved = false, attemptCount = 0,
}
local lastRequest = {}
local folder

local function blockers()
	local capabilities = Platform.CAPABILITIES
	local cpu = capabilities.cpu or {}
	local devices = capabilities.devices or {}
	local missing = {}
	if not cpu.realMode then missing[#missing + 1] = "modo real x86 de 16 bits" end
	if not cpu.paging then missing[#missing + 1] = "paginacion x86" end
	if cpu.segmentation ~= "full" then missing[#missing + 1] = "segmentacion y modo virtual 8086" end
	for _, feature in ipairs({ "bios", "pic", "pit", "ide", "vga", "ps2" }) do
		if devices[feature] ~= true then missing[#missing + 1] = feature:upper() end
	end
	return missing
end

local function publish()
	if not folder then return end
	folder:SetAttribute("Phase", state.phase)
	folder:SetAttribute("Architecture", state.architecture)
	folder:SetAttribute("Guest", state.guest)
	folder:SetAttribute("Started", state.started)
end

function Controller.Status()
	local result = table.clone(state)
	result.powerpc = PowerPC.Status()
	local runtime = rawget(_G, "RoEmu")
	local pc = runtime and runtime.PCStatus
	if pc then result.pc = { phase = pc.phase, instructions = pc.instructions, reads = pc.reads,
		windowsStartingObserved = pc.windowsStartingObserved, windowsDesktopObserved = false,
		cs = pc.cs, eip = pc.eip, error = pc.error } end
	result.windows95 = {
		imageDownloadedLocally = true,
		fullDiskEmbedded = true,
		diskBytes = Disk.diskBytes,
		sha256 = Disk.sha256,
		backend = "RoEmu_PC_Machine", experimental = true,
		bootAttemptSupported = true,
		windowsBootObserved = false,
	}
	return result
end

function Controller.Choose(architecture, player)
	if architecture == "ppc64" then architecture = "powerpc" end
	if architecture ~= "rv32" and architecture ~= "i386" and architecture ~= "powerpc" then
		return false, { code = "bad-architecture", message = "Elige RV32, i386 o PowerPC." }
	end
	if state.started then
		if (architecture == "rv32" and state.architecture == "riscv32") or (architecture == "i386" and state.architecture == "i386") then
			return true, Controller.Status()
		end
		return false, { code = "already-started", message = "La maquina ya esta iniciada. Reinicia la prueba para cambiar de arquitectura." }
	end
	if architecture == "powerpc" then return PowerPC.AttemptBoot() end
	if architecture == "i386" then
        local runtime = rawget(_G, "RoEmu")
        if runtime and type(runtime.InputQueue) == "table" then table.clear(runtime.InputQueue) end
        local called, accepted, detail = pcall(PC.Start)
        if not called or not accepted then
            return false, { code = "pc-start-failed", message = tostring(called and detail or accepted) }
        end
        state.started = true
        state.architecture = "i386"
        state.guest = "Windows 95"
        state.phase = "executing"
        state.ownerUserId = player and player.UserId or nil
        publish()
        return true, Controller.Status()
    end
	local runtime = rawget(_G, "RoEmu")
	local api = runtime and runtime.BackendAPI
	if type(api) ~= "table" or type(api.SelectArchitecture) ~= "function" then
		return false, { code = "backend-not-ready", message = "Preparando el emulador. Intenta de nuevo en un momento." }
	end
	local ok, result = api:SelectArchitecture("riscv32")
	if not ok then return false, { code = "backend-error", message = tostring(result) } end
	-- Menu navigation keys must never arrive as shell commands after boot.
	if type(runtime.InputQueue) == "table" then table.clear(runtime.InputQueue) end
	state.started = true
	state.architecture = "riscv32"
	state.guest = "CaribeOS"
	state.phase = "booting"
	state.ownerUserId = player and player.UserId or nil
	publish()
	return true, Controller.Status()
end

function Controller.Init()
	if initialized then return Controller end
	initialized = true
	folder = ReplicatedStorage:FindFirstChild("RoEmu_Boot")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "RoEmu_Boot"
		folder.Parent = ReplicatedStorage
	end
	local rpc = Instance.new("RemoteFunction")
	rpc.Name = "Rpc"
	rpc.Parent = folder
	rpc.OnServerInvoke = function(player, operation, architecture)
		if operation == "status" then return true, Controller.Status() end
		if operation ~= "choose" then return false, { code = "bad-operation" } end
		local now = os.clock()
		if now - (lastRequest[player] or -math.huge) < 0.5 then
			return false, { code = "busy", message = "Espera un momento antes de volver a intentar." }
		end
		lastRequest[player] = now
		return Controller.Choose(architecture, player)
	end
	Players.PlayerRemoving:Connect(function(player) lastRequest[player] = nil end)
	_G.RoEmu = _G.RoEmu or {}
	_G.RoEmu.BootController = Controller
	publish()
	return Controller
end

function Controller.WaitForRV32()
	Controller.Init()
	while not state.started do task.wait(0.1) end
	return state.architecture == "riscv32"
end

return Controller

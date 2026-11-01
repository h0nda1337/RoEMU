--!native
--!optimize 2
-- Conservamos el nombre de la instancia para no alterar la topologia del RBXL.
-- CaribeOS ya se carga sincronicamente en RunOpenSBI_Direct; este script solo
-- publica un estado estable y serializable para el backend/API futuros.

print("[caribeStatus] monitor RV32 activo")

local function copyTable(source, seen)
	if type(source) ~= "table" then return source end
	seen = seen or {}
	if seen[source] then return seen[source] end
	local result = {}
	seen[source] = result
	for key, value in pairs(source) do
		result[copyTable(key, seen)] = copyTable(value, seen)
	end
	return result
end

_G.RoEmu = _G.RoEmu or {}
local Runtime = _G.RoEmu

local function baseStatus()
	return {
		schema = 1,
		guest = "caribeos-rv32",
		architecture = "rv32imacsu",
		bootChain = "OpenSBI -> CaribeBootX -> XNU-CaribeOS -> GNU Bash",
		phase = "waiting-core",
		running = false,
		failed = false,
		bootComplete = false,
		opensbiObserved = false,
		caribeBootXObserved = false,
		virtioBlkObserved = false,
		xnuObserved = false,
		userspaceObserved = false,
		bashObserved = false,
		interactiveInitObserved = false,
		interactivePromptObserved = false,
		bootProfile = "process-gate-11",
		prompt = "bash-5.3$ ",
		xnuBased = true,
		darwinLineage = true,
		macOS = false,
		macOSCompatible = false,
		compatibilityNote = "XNU/Darwin RV32 experimental; no ejecuta binarios ni interfaces de macOS",
	}
end

local phaseRank = {
	["waiting-core"] = 0,
	["platform-ready"] = 1,
	["opensbi"] = 2,
	["caribebootx"] = 3,
	["storage-ready"] = 4,
	["xnu-kernel"] = 5,
	["userspace"] = 6,
	["interactive-init"] = 7,
	["ready"] = 8,
	["faulted"] = 99,
}

local function ensureStatus()
	local status = Runtime.CaribeOSStatus
	if type(status) ~= "table" then
		status = baseStatus()
		Runtime.CaribeOSStatus = status
	else
		local defaults = baseStatus()
		for key, value in pairs(defaults) do
			if status[key] == nil then status[key] = value end
		end
	end
	return status
end

local function advance(status, phase)
	if status.failed then return end
	local oldRank = phaseRank[status.phase] or -1
	local newRank = phaseRank[phase] or -1
	if newRank > oldRank then
		status.phase = phase
		print(("[caribeStatus] fase=%s"):format(phase))
	end
end

Runtime.GetCaribeOSStatus = function()
	return copyTable(ensureStatus())
end

task.spawn(function()
	local currentCore = nil
	while task.wait(0.2) do
		local status = ensureStatus()
		local core = rawget(_G, "RoEmuCore")
		if type(core) == "table" then
			if currentCore ~= core then
				currentCore = core
				status.running = core.cpu ~= nil and core.cpu.halted ~= true
				advance(status, "platform-ready")
			end

			local transcript = tostring(core.__uart_transcript or "")
			if transcript:find("OpenSBI", 1, true) then
				status.opensbiObserved = true
				advance(status, "opensbi")
			end
			if transcript:find("CaribeBootX", 1, true) then
				status.caribeBootXObserved = true
				advance(status, "caribebootx")
			end
			if transcript:find("[virtio] blk OK", 1, true) then
				status.virtioBlkObserved = true
				advance(status, "storage-ready")
			end
			if transcript:find("[XNU-CaribeOS]", 1, true) then
				status.xnuObserved = true
				advance(status, "xnu-kernel")
			end
			if transcript:find("[stage1-caribed] system ready", 1, true) then
				status.userspaceObserved = true
				advance(status, "userspace")
			end
			if transcript:find("[stage1-init] exec /sbin/interactive-init", 1, true)
				or transcript:find("[process-gate-11] PID 1 interactive init started", 1, true) then
				status.userspaceObserved = true
				status.interactiveInitObserved = true
				advance(status, "interactive-init")
			end
			if transcript:find("bash-5.3$ ", 1, true) then
				status.bashObserved = true
				status.interactivePromptObserved = true
				status.bootComplete = true
				advance(status, "ready")
			elseif transcript:find("[gnu-bash] PASS", 1, true) then
				-- Compatibilidad con el perfil de autoprueba anterior.
				status.bashObserved = true
			end

			if transcript:lower():find("kernel panic", 1, true)
				or transcript:find("[RoEmu] ERROR:", 1, true) then
				status.phase = "faulted"
				status.failed = true
				status.running = false
			end

			local cpu = core.cpu
			status.running = not status.failed and cpu ~= nil and cpu.halted ~= true
			status.halted = cpu ~= nil and cpu.halted == true
			status.pc = cpu and cpu.pc or nil
			status.instructions = cpu and cpu.instret or nil
			if core.__virtio_blk and type(core.__virtio_blk.getStatus) == "function" then
				status.virtioBlk = core.__virtio_blk:getStatus()
			end
		end
	end
end)

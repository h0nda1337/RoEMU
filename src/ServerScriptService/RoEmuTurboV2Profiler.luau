--!optimize 2
local ServerScriptService = game:GetService("ServerScriptService")

local bornAt = os.clock()
local lastCore
local lastInstret = 0
local lastTime = os.clock()
local lastPrint = 0
local sameTrapSamples = 0
local lastTrapPc = nil

local function hx(n)
	return ("0x%08X"):format(bit32.band(tonumber(n) or 0, 0xFFFFFFFF))
end

local function stageFor(pc)
	if pc >= 0xC0000000 then return "CARIBEOS_VIRTUAL" end
	if pc >= 0x80400000 then return "XNU_CARIBEOS" end
	if pc >= 0x80200000 then return "CARIBEBOOTX" end
	if pc >= 0x80000000 then return "OPENSBI" end
	return "RESET"
end

while task.wait(1) do
	local core = rawget(_G, "RoEmuCore")
	local now = os.clock()

	if type(core) ~= "table" or type(core.cpu) ~= "table" then
		ServerScriptService:SetAttribute("RoEmuTurboV2IPS", 0)
		continue
	end

	local cpu = core.cpu
	local instret = tonumber(cpu.instret) or 0
	local pc = bit32.band(tonumber(cpu.pc) or 0, 0xFFFFFFFF)

	if core ~= lastCore or instret < lastInstret then
		lastCore = core
		lastInstret = instret
		lastTime = now
		lastTrapPc = nil
		sameTrapSamples = 0
		print(("[RoEmuTurboV2] core detectado pc=%s"):format(hx(pc)))
		continue
	end

	local dt = math.max(now - lastTime, 0.001)
	local ips = math.max(0, math.floor((instret - lastInstret) / dt + 0.5))
	lastInstret = instret
	lastTime = now

	local stage = stageFor(pc)
	local mcause = 0
	if type(cpu.csr) == "table" then
		mcause = bit32.band(tonumber(cpu.csr[0x342]) or 0, 0xFFFFFFFF)
	end

	ServerScriptService:SetAttribute("RoEmuTurboV2IPS", ips)
	ServerScriptService:SetAttribute("RoEmuTurboV2PC", pc)
	ServerScriptService:SetAttribute("RoEmuTurboV2Stage", stage)
	ServerScriptService:SetAttribute("RoEmuTurboV2Elapsed", now - bornAt)

	if mcause == 2 and pc == lastTrapPc then
		sameTrapSamples += 1
	else
		sameTrapSamples = 0
	end
	lastTrapPc = pc

	if sameTrapSamples == 3 then
		warn(("[RoEmuTurboV2] posible bucle de instruccion ilegal pc=%s mcause=%s")
			:format(hx(pc), hx(mcause)))
	end

	if now - lastPrint >= 5 then
		lastPrint = now
		print(("[RoEmuTurboV2] IPS=%d stage=%s pc=%s instret=%d elapsed=%.1fs")
			:format(ips, stage, hx(pc), instret, now - bornAt))
	end
end

-- ServerScriptService/RunOpenSBI_Payload.server.lua
-- Prueba alternativa: usar un fw_payload.elf / Firmware_OpenSBI
-- en vez del FW_DYNAMIC_BIN que se queda colgado en WFI.
--
-- Busca en ReplicatedStorage.RiscV.firmware, en este orden:
--   1) Firmware_OpenSBI
--   2) Firmware
--
-- También inyecta DTB en RAM y pasa:
--   a0 = hartid
--   a1 = dtb ptr
--
-- Salida por UART -> RoEmu.Channel.Out

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local RV = ReplicatedStorage:WaitForChild("RiscV")
local FirmwareFolder = RV:WaitForChild("firmware")
local DevicesFolder = RV:WaitForChild("devices")

local CoreMod = require(RV:WaitForChild("core"))
local ELF32 = require(RV:WaitForChild("elf32"))
local ClintMod = require(RV:WaitForChild("clint"))
local Uart16550Mod = require(DevicesFolder:WaitForChild("uart16550"))

local okPlic, PlicMod = pcall(function()
	return require(RV:WaitForChild("plic"))
end)

_G.RoEmu = _G.RoEmu or {}
local RoEmu = _G.RoEmu
local Channel = RoEmu.Channel

local TAG = "[RunOpenSBI_Payload]"

local RAM_BASE = 0x80000000
local RAM_SIZE = 16 * 1024 * 1024
local DTB_ADDR = 0x80F00000

local WAIT_ATTACH_SECONDS = 15
local STEPS_PER_HEARTBEAT = 20000
local STATUS_EVERY_INSTRET = 250000
local INPUT_CHUNK_BYTES = 256
local STUCK_PC_THRESHOLD = 6

local function logLine(level, msg)
	local line = string.format("%s [%s] %s", TAG, tostring(level), tostring(msg))
	print(line)
	if Channel and Channel.FireLogAll then
		Channel:FireLogAll(level, tostring(msg))
	end
end

local function outText(s)
	if Channel and Channel.FireOutAll then
		Channel:FireOutAll(tostring(s))
	end
end

local function hasAnyAttachedClient()
	if type(RoEmu.Attached) ~= "table" then
		return false
	end
	for _, v in pairs(RoEmu.Attached) do
		if v == true then
			return true
		end
	end
	return false
end

local function waitForAttach(timeoutSeconds)
	local deadline = os.clock() + (timeoutSeconds or 0)
	while os.clock() < deadline do
		if hasAnyAttachedClient() then
			return true
		end
		task.wait(0.1)
	end
	return hasAnyAttachedClient()
end

local function findFirmwareNode(...)
	local names = { ... }
	for _, wantedName in ipairs(names) do
		local node = FirmwareFolder:FindFirstChild(wantedName)
		if node then
			return node
		end
	end
	return nil
end

local function bytesToString(t)
	local out = table.create(#t)
	for i, b in ipairs(t) do
		local n = tonumber(b) or 0
		n = n % 256
		out[i] = string.char(n)
	end
	return table.concat(out)
end

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64lookup = {}
for i = 1, #b64chars do
	b64lookup[string.sub(b64chars, i, i)] = i - 1
end

local function base64DecodePure(data)
	data = tostring(data or "")
	local clean = {}

	for i = 1, #data do
		local c = string.sub(data, i, i)
		if b64lookup[c] ~= nil or c == "=" then
			clean[#clean + 1] = c
		end
	end

	local s = table.concat(clean)
	local out = {}
	local i = 1

	while i <= #s do
		local c1 = string.sub(s, i, i); i = i + 1
		local c2 = string.sub(s, i, i); i = i + 1
		local c3 = string.sub(s, i, i); i = i + 1
		local c4 = string.sub(s, i, i); i = i + 1

		if c1 == "" or c2 == "" then
			break
		end

		local v1 = b64lookup[c1]
		local v2 = b64lookup[c2]
		if v1 == nil or v2 == nil then
			error("Base64 invalido en bloque")
		end

		local v3 = (c3 == "=" or c3 == "") and nil or b64lookup[c3]
		local v4 = (c4 == "=" or c4 == "") and nil or b64lookup[c4]

		local b1 = bit32.bor(bit32.lshift(v1, 2), bit32.rshift(v2, 4))
		out[#out + 1] = string.char(bit32.band(b1, 0xFF))

		if v3 ~= nil then
			local b2 = bit32.bor(bit32.lshift(bit32.band(v2, 0x0F), 4), bit32.rshift(v3, 2))
			out[#out + 1] = string.char(bit32.band(b2, 0xFF))

			if v4 ~= nil then
				local b3 = bit32.bor(bit32.lshift(bit32.band(v3, 0x03), 6), v4)
				out[#out + 1] = string.char(bit32.band(b3, 0xFF))
			end
		end
	end

	return table.concat(out)
end

local function base64Decode(data)
	local ok, decoded = pcall(function()
		return HttpService:Base64Decode(data)
	end)

	if ok and type(decoded) == "string" then
		return decoded
	end

	return base64DecodePure(data)
end

local function moduleToBlob(modValue)
	if type(modValue) == "string" then
		return modValue
	end

	if type(modValue) ~= "table" then
		error("Formato de firmware no soportado: " .. type(modValue))
	end

	if type(modValue.bytes) == "string" then
		return modValue.bytes
	end

	if type(modValue.bytes) == "table" then
		if type(modValue.bytes[1]) == "number" then
			return bytesToString(modValue.bytes)
		end
		if type(modValue.bytes[1]) == "string" then
			return table.concat(modValue.bytes)
		end
	end

	-- compat con módulos empaquetados en b64
	local chunks = modValue.chunks_b64 or modValue.b64_chunks or modValue.chunks
	if type(chunks) == "table" then
		local parts = table.create(#chunks)
		for i, chunk in ipairs(chunks) do
			parts[i] = base64Decode(tostring(chunk))
		end
		return table.concat(parts)
	end

	-- compat con tabla "plana" {1,2,3,...}
	if type(modValue[1]) == "number" then
		return bytesToString(modValue)
	end

	error("No pude convertir el módulo de firmware a blob binario")
end

local function writeBlobToRam(ram, addr, blob)
	local idx = (addr - ram.lo) + 1
	assert(idx >= 1, string.format("blob fuera de RAM @ 0x%08X", addr))
	assert((idx + #blob - 1) <= #ram.bytes, string.format("blob fuera de RAM @ 0x%08X len=%d", addr, #blob))

	for i = 1, #blob do
		ram.bytes[idx + i - 1] = string.byte(blob, i)
	end
end

local function csr(cpu, addr)
	if not cpu or not cpu.csr then
		return 0
	end
	return tonumber(cpu.csr[addr]) or 0
end

local function ramRead8(ram, addr)
	local idx = (addr - ram.lo) + 1
	if idx < 1 or idx > #ram.bytes then
		return nil
	end
	return ram.bytes[idx] or 0
end

local function ramRead32LE(ram, addr)
	local b0 = ramRead8(ram, addr + 0) or 0
	local b1 = ramRead8(ram, addr + 1) or 0
	local b2 = ramRead8(ram, addr + 2) or 0
	local b3 = ramRead8(ram, addr + 3) or 0
	return bit32.bor(
		b0,
		bit32.lshift(b1, 8),
		bit32.lshift(b2, 16),
		bit32.lshift(b3, 24)
	)
end

local function dumpAroundPc(ram, pc)
	logLine("DUMP", string.format("dump alrededor de PC=0x%08X", pc))

	local startAddr = pc - 0x20
	local endAddr = pc + 0x20

	for addr = startAddr, endAddr, 0x10 do
		local bytes = {}
		for i = 0, 0x0F do
			local b = ramRead8(ram, addr + i)
			if b == nil then
				bytes[#bytes + 1] = "??"
			else
				bytes[#bytes + 1] = string.format("%02X", b)
			end
		end
		logLine("DUMP", string.format("0x%08X: %s", addr, table.concat(bytes, " ")))
	end

	for addr = pc - 0x10, pc + 0x10, 4 do
		logLine("DUMP", string.format("word[0x%08X] = 0x%08X", addr, ramRead32LE(ram, addr)))
	end
end

local function hexHead(blob, n)
	n = math.min(#blob, n or 16)
	local t = table.create(n)
	for i = 1, n do
		t[i] = string.format("%02X", string.byte(blob, i))
	end
	return table.concat(t, " ")
end

local function isElf(blob)
	return #blob >= 4 and blob:sub(1, 4) == "\127ELF"
end

local function pumpKeyboardIntoUart(uart)
	local q = RoEmu.InputQueue
	if type(q) ~= "table" or #q == 0 then
		return
	end

	local chars = {}
	local count = 0

	while #q > 0 and count < INPUT_CHUNK_BYTES do
		local b = table.remove(q, 1)
		chars[#chars + 1] = string.char((tonumber(b) or 0) % 256)
		count = count + 1
	end

	if count > 0 then
		uart:rx_line(table.concat(chars))
	end
end

local function main()
	logLine("INFO", "esperando cliente attached...")
	local attached = waitForAttach(WAIT_ATTACH_SECONDS)

	if attached then
		logLine("INFO", "cliente attached confirmado; arrancando")
	else
		logLine("WARN", "timeout esperando attach; continuo de todos modos")
	end

	local fwNode = findFirmwareNode("Firmware_OpenSBI", "Firmware")
	local dtbNode = findFirmwareNode("Return_QEMUvirt_DTB")

	if not fwNode then
		error("No encontre Firmware_OpenSBI ni Firmware")
	end
	if not dtbNode then
		error("No encontre Return_QEMUvirt_DTB")
	end

	local fwBlob = moduleToBlob(require(fwNode))
	local dtbBlob = moduleToBlob(require(dtbNode))

	logLine("INFO", string.format("firmware=%s bytes=%d", fwNode.Name, #fwBlob))
	logLine("INFO", string.format("dtb=%s bytes=%d", dtbNode.Name, #dtbBlob))
	logLine("INFO", "fw head: " .. hexHead(fwBlob, 16))
	logLine("INFO", "dtb head: " .. hexHead(dtbBlob, 16))

	if not isElf(fwBlob) then
		error("El firmware de payload no parece ELF")
	end

	local core = CoreMod.new()
	_G.RoEmuCore = core

	_G.shared = _G.shared or {}
	_G.shared.RoEmuCore = core
	if _G.shared.RoEmu_CoreAPI then
		_G.shared.RoEmu_CoreAPI.core = core
	end

	core:reset(RAM_BASE)
	local ram = core:map_ram(RAM_BASE, RAM_SIZE)

	local uartTx = 0
	local uart = Uart16550Mod.new({
		writeChar = function(byte)
			uartTx = uartTx + 1
			outText(string.char(bit32.band(byte, 0xFF)))
		end,
	})
	core:map_mmio(0x10000000, 0x100, uart)

	local clint = ClintMod.new()
	core:map_mmio(0x02000000, 0x10000, clint)
	if clint.bind_core then
		clint:bind_core(core)
	end

	if okPlic and type(PlicMod) == "table" and type(PlicMod.new) == "function" then
		local plic = PlicMod.new(32)
		core:map_mmio(0x0C000000, 0x400000, plic)

		if type(plic.set_source_level) ~= "function" then
			function plic:set_source_level(_irq, level)
				if core.set_meip then
					core:set_meip(level and true or false)
				end
			end
		end

		if uart.setIrqSink and plic.set_source_level then
			uart:setIrqSink(function(level)
				plic:set_source_level(10, level and true or false)
			end)
		end
	end

	writeBlobToRam(ram, DTB_ADDR, dtbBlob)

	local entry = ELF32.load(fwBlob, ram)

	logLine("INFO", string.format("Payload entry=0x%08X", entry))
	logLine("INFO", string.format("dtb@0x%08X", DTB_ADDR))

	core.cpu.regs[10] = 0        -- a0 = hartid
	core.cpu.regs[11] = DTB_ADDR -- a1 = dtb ptr
	core.cpu.pc = entry

	local trapCount = 0
	core.on_trap = function(mcause, mtval, _innerCore, cpu)
		trapCount = trapCount + 1
		if trapCount <= 32 then
			logLine(
				"WARN",
				string.format(
					"trap#%d mcause=0x%08X mtval=0x%08X pc=0x%08X mepc=0x%08X mtvec=0x%08X",
					trapCount,
					tonumber(mcause) or 0,
					tonumber(mtval) or 0,
					(cpu and cpu.pc) or 0,
					csr(cpu, 0x341),
					csr(cpu, 0x305)
				)
			)
		end
	end

	outText("[RoEmu] Lanzando OpenSBI payload...\n")
	logLine("INFO", "runner activo")

	local lastStatusInstret = 0
	local lastPc = core.cpu.pc
	local samePcStatusCount = 0
	local running = true
	local hbConn

	hbConn = RunService.Heartbeat:Connect(function()
		if not running then
			if hbConn then
				hbConn:Disconnect()
				hbConn = nil
			end
			return
		end

		pumpKeyboardIntoUart(uart)

		local ok, err = pcall(function()
			for _ = 1, STEPS_PER_HEARTBEAT do
				core:step()
				if core.cpu.halted then
					running = false
					break
				end
			end
		end)

		if not ok then
			logLine("ERROR", "fallo en step: " .. tostring(err))
			running = false
			return
		end

		local cpu = core.cpu
		local instret = tonumber(cpu.instret) or 0

		if (instret - lastStatusInstret) >= STATUS_EVERY_INSTRET then
			lastStatusInstret = instret

			if cpu.pc == lastPc then
				samePcStatusCount = samePcStatusCount + 1
			else
				samePcStatusCount = 0
			end
			lastPc = cpu.pc

			logLine(
				"STAT",
				string.format(
					"pc=0x%08X instret=%d mstatus=0x%08X mie=0x%08X mip=0x%08X mtvec=0x%08X mepc=0x%08X mcause=0x%08X samePC=%d uartTX=%d",
					tonumber(cpu.pc) or 0,
					instret,
					csr(cpu, 0x300),
					csr(cpu, 0x304),
					csr(cpu, 0x344),
					csr(cpu, 0x305),
					csr(cpu, 0x341),
					csr(cpu, 0x342),
					samePcStatusCount,
					uartTx
				)
			)

			if samePcStatusCount >= STUCK_PC_THRESHOLD then
				logLine("WARN", "PC estancado; hago dump y me detengo")
				dumpAroundPc(ram, cpu.pc)
				running = false
				return
			end
		end
	end)
end

local ok, err = pcall(main)
if not ok then
	logLine("ERROR", tostring(err))
	outText("\n[RoEmu] ERROR: " .. tostring(err) .. "\n")
end
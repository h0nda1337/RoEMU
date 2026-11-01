--!optimize 2
-- ServerScriptService/RunOpenSBI_Direct.server.lua
-- Runner OpenSBI FW_DYNAMIC para CaribeOS RV32.
-- Prefiere ELF directo si existe:
--   Return_OpenSBI_FW_DYNAMIC_ELF
-- y si no, cae a:
--   Return_OpenSBI_FW_DYNAMIC_BIN / Return_OpenSBI_FW_DYNAMIC
--
-- Incluye parche de prueba:
--   FORCE platform.hart_count = 1
-- para comprobar si OpenSBI cae a _start_hang por hart_count=0.

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
local VirtioBlkSparseMod = require(DevicesFolder:WaitForChild("virtio_blk_sparse"))

local okPlic, PlicMod = pcall(function()
	return require(RV:WaitForChild("plic"))
end)

_G.RoEmu = _G.RoEmu or {}
local RoEmu = _G.RoEmu
local Runtime = RoEmu
local Channel = RoEmu.Channel

local TAG = "[RunOpenSBI_Direct]"

local RAM_BASE = 0x80000000
local RAM_SIZE = 128 * 1024 * 1024

-- CaribeBootX ocupa 0x80200000; DTB y fw_dynamic se mantienen arriba para
-- que ni OpenSBI, ni CaribeBootX, ni los buffers XNU puedan pisarlos.
local DTB_ADDR = 0x87E00000
local FWINFO_ADDR = 0x87DFF000
local VIRTIO_BLK_ADDR = 0x10008000
local VIRTIO_BLK_IRQ = 8

local CARIBE_DISK_CHUNK_FOLDER = "Return_Linux_RV32_Min_Initramfs_Image_chunks"
local CARIBE_DISK_CHUNKS = 59
local CARIBE_DISK_PACK_BYTES = 5001023

-- Variables globales de la plataforma OpenSBI qemu-virt incluida en RoEMU.
-- Se escriben despues de cargar el ELF para que el zero-fill no las revierta.
local ROOT_NEXT_ARG1 = 0x80040ADC
local ROOT_NEXT_ADDR = 0x80040AE0
local ROOT_NEXT_MODE = 0x80040AE4

local FW_DYNAMIC_INFO_MAGIC = 0x4942534F -- 'OSBI'
local FW_DYNAMIC_INFO_VERSION = 0x2
local FW_DYNAMIC_INFO_NEXT_MODE_S = 0x1

local WAIT_ATTACH_SECONDS = 0.5
local STEP_BATCH = 4096
local MAX_STEPS_PER_HEARTBEAT = 600000
local BOOST_SLICE_SECONDS = 0.028
local CRUISE_SLICE_SECONDS = 0.012
local BOOST_SECONDS = 180
local INPUT_CHUNK_BYTES = 256
local STATUS_EVERY_INSTRET = 2000000
local STUCK_PC_THRESHOLD = 999999

-- CaribeBootX zeroes the large XNU BSS byte by byte.  On real hardware this
-- is cheap, but interpreting roughly 30 MiB of `sb` instructions dominates
-- the Roblox boot.  This guarded host fast path performs the exact same
-- zero-fill only while the PC is inside that known CaribeBootX loop.
local CARIBE_BSS_ZERO_LOOP_START = 0x80203AC8
local CARIBE_BSS_ZERO_LOOP_END = 0x80203ACE
local CARIBE_BSS_ZERO_LOOP_EXIT = 0x80203AD2
local CARIBE_BSS_ZERO_MAX_BYTES = 32 * 1024 * 1024

-- ROEMU_V211_CONSTANT_VALIDATION
assert(type(MAX_STEPS_PER_HEARTBEAT) == "number")
assert(type(BOOST_SLICE_SECONDS) == "number")
assert(type(CRUISE_SLICE_SECONDS) == "number")
assert(type(BOOST_SECONDS) == "number")

-- Parche de prueba para verificar la hipotesis de hart_count
local FORCE_PLATFORM_HART_COUNT = true
local PLATFORM_SYMBOL_ADDR = 0x80040510
local SBI_PLATFORM_HART_COUNT_OFFSET = 0x50

local function logLine(level, msg)
	local line = string.format("%s [%s] %s", TAG, tostring(level), tostring(msg))
	-- Los diagnósticos del emulador pertenecen al Output de Studio. La
	-- terminal visible queda reservada exclusivamente para la UART huésped,
	-- para no intercalar STAT/WARN dentro del prompt de Linux.
	print(line)
end

-- Keep the complete guest UART in core.__uart_transcript, while presenting a
-- clean interactive shell after Bash becomes ready. CaribeOS' bring-up traces
-- share ttyS0 with Bash; without this display-only filter they split the prompt
-- and typed command across dozens of diagnostic lines. OpenSBI and the entire
-- pre-login boot log remain byte-for-byte visible.
local DISPLAY_PROMPT = "bash-5.3$ "
local DISPLAY_HIDDEN_PREFIXES = {
	"[pmap]",
	"[vm-bootstrap]",
	"[linux-",
	"[linux]",
	"[process-gate-",
}
local displayInteractive = false
local displayActivationRecent = ""
local displaySuppressible = true
local displayCandidate = ""
local displayDroppingLine = false
local displayRecent = ""

local function hiddenPrefixState(candidate)
	for _, prefix in ipairs(DISPLAY_HIDDEN_PREFIXES) do
		if candidate == prefix then
			return "matched"
		end
		if prefix:sub(1, #candidate) == candidate then
			return "possible"
		end
	end
	return "none"
end

local function filterInteractiveBytes(value)
	local output = table.create(#value)
	local function emit(ch)
		output[#output + 1] = ch
		if ch == "\n" then
			displaySuppressible = true
			displayRecent = ""
		else
			displaySuppressible = false
			displayRecent = (displayRecent .. ch):sub(-#DISPLAY_PROMPT)
			if displayRecent == DISPLAY_PROMPT then
				displaySuppressible = true
			end
		end
	end

	for index = 1, #value do
		local ch = value:sub(index, index)
		if displayDroppingLine then
			if ch == "\n" then
				displayDroppingLine = false
				displaySuppressible = true
			end
		elseif displayCandidate ~= "" then
			displayCandidate ..= ch
			local state = hiddenPrefixState(displayCandidate)
			if state == "matched" then
				displayCandidate = ""
				displayDroppingLine = true
			elseif state == "none" then
				local literal = displayCandidate
				displayCandidate = ""
				for literalIndex = 1, #literal do
					emit(literal:sub(literalIndex, literalIndex))
				end
			end
		elseif displaySuppressible and ch == "[" then
			displayCandidate = ch
		else
			emit(ch)
		end
	end
	return table.concat(output)
end

local function filterGuestDisplay(value)
	value = tostring(value or "")
	if displayInteractive then
		return filterInteractiveBytes(value)
	end

	local output = table.create(#value)
	for index = 1, #value do
		local ch = value:sub(index, index)
		output[#output + 1] = ch
		displayActivationRecent =
			(displayActivationRecent .. ch):sub(-#DISPLAY_PROMPT)
		if displayActivationRecent == DISPLAY_PROMPT then
			displayInteractive = true
			displaySuppressible = true
			displayRecent = DISPLAY_PROMPT
			local remainder = value:sub(index + 1)
			if remainder ~= "" then
				output[#output + 1] = filterInteractiveBytes(remainder)
			end
			break
		end
	end
	return table.concat(output)
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

		if string.sub(wantedName, 1, 7) == "Return_" then
			local alt = string.sub(wantedName, 8)
			node = FirmwareFolder:FindFirstChild(alt)
			if node then
				return node
			end
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

	local chunks = modValue.chunks_b64 or modValue.b64_chunks or modValue.chunks
	if type(chunks) == "table" then
		local parts = table.create(#chunks)
		for i, chunk in ipairs(chunks) do
			parts[i] = base64Decode(tostring(chunk))
		end
		return table.concat(parts)
	end

	error("No pude convertir el modulo de firmware a blob binario")
end

local function writeU32ToRam(ram, addr, value)
	local off = addr - ram.lo
	assert(off >= 0 and off + 3 < ram.size, string.format("writeU32 fuera de RAM @ 0x%08X", addr))
	if ram.buffer then
		buffer.writeu32(ram.buffer, off, value)
		return
	end
	local idx = off + 1
	ram.bytes[idx + 0] = bit32.band(value, 0xFF)
	ram.bytes[idx + 1] = bit32.band(bit32.rshift(value, 8), 0xFF)
	ram.bytes[idx + 2] = bit32.band(bit32.rshift(value, 16), 0xFF)
	ram.bytes[idx + 3] = bit32.band(bit32.rshift(value, 24), 0xFF)
end

local function writeBlobToRam(ram, addr, blob)
	local off = addr - ram.lo
	assert(off >= 0 and off + #blob <= ram.size, string.format("blob fuera de RAM @ 0x%08X len=%d", addr, #blob))
	if ram.buffer then
		buffer.writestring(ram.buffer, off, blob)
		return
	end
	local idx = off + 1
	for i = 1, #blob do
		ram.bytes[idx + i - 1] = string.byte(blob, i)
	end
end

local function fastForwardCaribeBssZero(core, ram)
	local cpu = core and core.cpu
	if not cpu or cpu.pc < CARIBE_BSS_ZERO_LOOP_START or cpu.pc > CARIBE_BSS_ZERO_LOOP_END then
		return false
	end

	local cursor = bit32.band(cpu.regs[15] or 0, 0xFFFFFFFF) -- a5
	local finish = bit32.band(cpu.regs[10] or 0, 0xFFFFFFFF) -- a0
	local count = finish - cursor
	local offset = cursor - ram.lo
	if count <= 0 or count > CARIBE_BSS_ZERO_MAX_BYTES or offset < 0 or offset + count > ram.size then
		return false
	end

	if ram.buffer then
		buffer.fill(ram.buffer, offset, 0, count)
	else
		local first = offset + 1
		for i = 0, count - 1 do
			ram.bytes[first + i] = 0
		end
	end

	cpu.regs[15] = finish
	cpu.pc = CARIBE_BSS_ZERO_LOOP_EXIT
	Runtime.CaribeOSStatus.caribeBssFastPathBytes =
		(Runtime.CaribeOSStatus.caribeBssFastPathBytes or 0) + count
	return true
end

local function installFwDynamicInfo(ram, nextStageAddress)
	writeU32ToRam(ram, FWINFO_ADDR + 0x00, FW_DYNAMIC_INFO_MAGIC)
	writeU32ToRam(ram, FWINFO_ADDR + 0x04, FW_DYNAMIC_INFO_VERSION)
	writeU32ToRam(ram, FWINFO_ADDR + 0x08, nextStageAddress)
	writeU32ToRam(ram, FWINFO_ADDR + 0x0C, FW_DYNAMIC_INFO_NEXT_MODE_S)
	writeU32ToRam(ram, FWINFO_ADDR + 0x10, 0)
	writeU32ToRam(ram, FWINFO_ADDR + 0x14, 0)

	writeU32ToRam(ram, ROOT_NEXT_ARG1, DTB_ADDR)
	writeU32ToRam(ram, ROOT_NEXT_ADDR, nextStageAddress)
	writeU32ToRam(ram, ROOT_NEXT_MODE, FW_DYNAMIC_INFO_NEXT_MODE_S)
end

local function decodeCaribeDiskPack()
	local folder = FirmwareFolder:WaitForChild(CARIBE_DISK_CHUNK_FOLDER, 30)
	assert(folder, "No encontre el contenedor de disco CaribeOS")
	local decoded = table.create(CARIBE_DISK_CHUNKS)
	for index = 1, CARIBE_DISK_CHUNKS do
		local name = string.format("chunk%03d", index)
		local node = folder:WaitForChild(name, 30)
		assert(node and node:IsA("ModuleScript"), "Falta " .. name .. " del disco CaribeOS")
		local ok, encoded = pcall(require, node)
		assert(ok and type(encoded) == "string", "No pude cargar " .. name .. ": " .. tostring(encoded))
		decoded[index] = base64Decode(encoded)
		if index % 8 == 0 then task.wait() end
	end
	local pack = table.concat(decoded)
	assert(#pack == CARIBE_DISK_PACK_BYTES, string.format(
		"CBSP CaribeOS mide %d bytes; esperaba %d", #pack, CARIBE_DISK_PACK_BYTES
	))
	assert(pack:sub(1, 4) == "CBSP", "El disco CaribeOS no tiene magic CBSP")
	return pack
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

local function csr(cpu, addr)
	if not cpu or not cpu.csr then
		return 0
	end
	return tonumber(cpu.csr[addr]) or 0
end

local function ramRead8(ram, addr)
	local off = addr - ram.lo
	if off < 0 or off >= ram.size then return nil end
	if ram.buffer then return buffer.readu8(ram.buffer, off) end
	return ram.bytes[off + 1] or 0
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

	local start = pc - 0x20
	local finish = pc + 0x20

	for addr = start, finish, 0x10 do
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
		local w = ramRead32LE(ram, addr)
		logLine("DUMP", string.format("word[0x%08X] = 0x%08X", addr, w))
	end
end

local function findAsciiMarkers(blob, patterns)
	local found = {}
	for _, pat in ipairs(patterns) do
		local pos = string.find(blob, pat, 1, true)
		if pos then
			found[#found + 1] = string.format("%s@0x%X", pat, pos - 1)
		end
	end
	return found
end

local function main()
	logLine("INFO", "esperando cliente attached...")
	local attached = waitForAttach(WAIT_ATTACH_SECONDS)

	if attached then
		logLine("INFO", "cliente attached confirmado; arrancando")
		outText("\n[RoEmu] attach confirmado. Arrancando OpenSBI...\n")
	else
		logLine("WARN", "timeout esperando attach; continuo de todos modos")
		outText("\n[RoEmu] timeout esperando attach. Arrancando OpenSBI...\n")
	end

	local fwNode = findFirmwareNode(
		"Return_OpenSBI_FW_DYNAMIC_ELF",
		"Return_OpenSBI_FW_DYNAMIC_BIN",
		"Return_OpenSBI_FW_DYNAMIC"
	)

	local dtbNode = findFirmwareNode("Return_QEMUvirt_DTB")
	local caribeNode = findFirmwareNode("Return_Caribe_ELF")
	local manifestNode = findFirmwareNode("CaribeOS_RV32_Manifest")

	if not fwNode then
		error("No encontre Return_OpenSBI_FW_DYNAMIC_ELF/BIN")
	end
	if not dtbNode then
		error("No encontre Return_QEMUvirt_DTB")
	end
	if not caribeNode then
		error("No encontre Return_Caribe_ELF")
	end

	Runtime.CaribeOSStatus = {
		schema = 1,
		phase = "loading-assets",
		running = false,
		failed = false,
		bootChain = "OpenSBI -> CaribeBootX -> XNU-CaribeOS",
		macOS = false,
		macOSCompatible = false,
		xnuBased = true,
	}
	local fwBlob = moduleToBlob(require(fwNode))
	local dtbBlob = moduleToBlob(require(dtbNode))
	local caribeBlob = moduleToBlob(require(caribeNode))
	local diskPack = decodeCaribeDiskPack()
	local manifest = nil
	if manifestNode then
		local okManifest, value = pcall(require, manifestNode)
		if okManifest and type(value) == "table" then manifest = value end
	end

	logLine("INFO", string.format("firmware=%s bytes=%d", fwNode.Name, #fwBlob))
	logLine("INFO", string.format("dtb=%s bytes=%d", dtbNode.Name, #dtbBlob))
	logLine("INFO", string.format("CaribeBootX=%s bytes=%d", caribeNode.Name, #caribeBlob))
	logLine("INFO", string.format("CaribeOS HFS+ sparse pack=%d bytes", #diskPack))
	logLine("INFO", "fw head: " .. hexHead(fwBlob, 16))
	logLine("INFO", "dtb head: " .. hexHead(dtbBlob, 16))

	local dtbMarkers = findAsciiMarkers(dtbBlob, {
		"riscv,isa",
		"rv32",
		"rv64",
		"sv32",
		"sv39",
		"ns16550a",
		"opensbi",
	})
	if #dtbMarkers > 0 then
		logLine("INFO", "DTB markers: " .. table.concat(dtbMarkers, ", "))
	end

	_G.shared = _G.shared or {}
	_G.shared.RoEmu_Firmware = _G.shared.RoEmu_Firmware or {}
	_G.shared.RoEmu_Firmware.OpenSBI_FW_DYNAMIC = fwBlob
	_G.shared.RoEmu_Firmware.VirtDTB = dtbBlob
	_G.shared.RoEmu_Firmware.CaribeBootX = caribeBlob
	_G.shared.RoEmu_Firmware.CaribeOSDiskPack = diskPack
	_G.shared.RoEmu_Firmware.CaribeOSManifest = manifest

	local core = CoreMod.new()
	_G.RoEmuCore = core
	_G.shared.RoEmuCore = core
	if _G.shared.RoEmu_CoreAPI then
		_G.shared.RoEmu_CoreAPI.core = core
	end

	core:reset(RAM_BASE)
	local ram = core:map_ram(RAM_BASE, RAM_SIZE)
	core.__caribeos_manifest = manifest
	Runtime.CaribeOSStatus.phase = "platform-ready"

	-- ROEMU_V22_RAM_MAP_VALIDATION
	assert(
		type(ram) == "table"
			and tonumber(ram.size) == RAM_SIZE,
		"RoEMU V2.2: el mapa RAM no coincide con RAM_SIZE"
	)

	logLine(
		"INFO",
		string.format(
			"RAM física=%d MiB rango=0x%08X..0x%08X",
			math.floor(RAM_SIZE / 1048576),
			RAM_BASE,
			RAM_BASE + RAM_SIZE - 1
		)
	)

	local uartTx = 0
	local uartOutParts = table.create(2048)
	local uartOutCount = 0
	local uartOutBytes = 0
	local uartTranscript = ""
	local UART_TRANSCRIPT_LIMIT = 131072

	local function flushUartOutput()
		if uartOutCount == 0 then return end
		local text = table.concat(uartOutParts, "", 1, uartOutCount)
		local displayText = filterGuestDisplay(text)
		if displayText ~= "" then
			outText(displayText)
		end
		uartTranscript ..= text
		if #uartTranscript > UART_TRANSCRIPT_LIMIT then
			uartTranscript = uartTranscript:sub(#uartTranscript - UART_TRANSCRIPT_LIMIT + 1)
		end
		core.__uart_transcript = uartTranscript
		table.clear(uartOutParts)
		uartOutCount = 0
		uartOutBytes = 0
	end

	local uart = Uart16550Mod.new({
		writeChar = function(byte)
			local n = bit32.band(byte, 0xFF)
			uartTx += 1
			uartOutCount += 1
			uartOutBytes += 1
			uartOutParts[uartOutCount] = string.char(n)
			if uartOutBytes >= 4096 then flushUartOutput() end
		end,
	})
	core:map_mmio(0x10000000, 0x100, uart)

	local virtioBlk = VirtioBlkSparseMod.new(core, diskPack)
	core:map_mmio(VIRTIO_BLK_ADDR, 0x1000, virtioBlk)
	core.__virtio_blk = virtioBlk

	local clint = ClintMod.new()
	core:map_mmio(0x02000000, 0x10000, clint)
	core.__clint = clint
	if clint.bind_core then
		clint:bind_core(core)
	end

	-- Fast SBI transport used only after OpenSBI has entered guest S-mode.
	-- It preserves the SBI ABI while avoiding a second trip through the
	-- firmware's linked-list dispatcher for every timer/console call.
	local SBI_EXT_BASE = 0x10
	local SBI_EXT_TIME = 0x54494D45
	local SBI_EXT_IPI = 0x00735049
	local SBI_EXT_RFENCE = 0x52464E43
	local SBI_EXT_HSM = 0x0048534D
	local SBI_EXT_SRST = 0x53525354
	local SBI_EXT_DBCN = 0x4442434E
	local supportedSbiExtensions = {
		[SBI_EXT_BASE] = true,
		[SBI_EXT_TIME] = true,
		[SBI_EXT_IPI] = true,
		[SBI_EXT_RFENCE] = true,
		[SBI_EXT_HSM] = true,
		[SBI_EXT_SRST] = true,
		[SBI_EXT_DBCN] = true,
	}
	local timerProgramCount = 0
	local timerPastProgramCount = 0
	local MAX_EXACT_TIMER = 9007199254740991 -- 2^53-1, horizonte practicamente infinito

	local function sbiResult(cpu, err, value)
		cpu.regs[10] = bit32.band(err or 0, 0xFFFFFFFF)
		cpu.regs[11] = bit32.band(value or 0, 0xFFFFFFFF)
		return true
	end

	local function programSupervisorTimer(innerCore, cpu)
		local lo = bit32.band(cpu.regs[10] or 0, 0xFFFFFFFF)
		local hi = bit32.band(cpu.regs[11] or 0, 0xFFFFFFFF)
		local now = clint:get_mtime()
		-- Luau usa doubles: UINT64_MAX se redondea a 2^64 y, al dividirlo de
		-- nuevo en palabras, se convertia en 0.  Los deadlines fuera del rango
		-- entero exacto se saturan a 2^53-1; sigue siendo un futuro inalcanzable
		-- para el guest y conserva el uso de UINT64_MAX como "timer apagado".
		local targetClamped = hi >= 0x00200000
		local target = targetClamped and MAX_EXACT_TIMER or (hi * 0x100000000 + lo)
		timerProgramCount += 1
		if target <= now then timerPastProgramCount += 1 end
		Runtime.CaribeOSStatus.sbiTimer = {
			programCount = timerProgramCount,
			pastProgramCount = timerPastProgramCount,
			now = now,
			targetLo = lo,
			targetHi = hi,
			targetClamped = targetClamped,
			delta = target - now,
		}
		innerCore.__direct_sbi_timer = true
		clint:set_mtimecmp_abs(target)
	end

	core.cpu.on_sbi = function(extension, _legacyA0, innerCore, cpu)
		extension = bit32.band(extension or 0, 0xFFFFFFFF)
		local fid = bit32.band(cpu.regs[16] or 0, 0xFFFFFFFF)
		local arg0 = bit32.band(cpu.regs[10] or 0, 0xFFFFFFFF)

		-- SBI v0.1 legacy calls.
		if extension == 0 then
			programSupervisorTimer(innerCore, cpu)
			cpu.regs[10] = 0
			return true
		elseif extension == 1 then
			uart:write8(0, arg0)
			cpu.regs[10] = 0
			return true
		elseif extension == 2 then
			cpu.regs[10] = 0xFFFFFFFF
			return true
		elseif extension == 3 then
			if innerCore.set_ssip then innerCore:set_ssip(false) end
			cpu.regs[10] = 0
			return true
		elseif extension >= 4 and extension <= 7 then
			cpu.regs[10] = 0
			return true
		elseif extension == 8 then
			cpu.regs[10] = 0
			cpu.halted = true
			return true
		end

		if extension == SBI_EXT_BASE then
			if fid == 0 then return sbiResult(cpu, 0, 0x00000002) end -- SBI 0.2
			if fid == 1 then return sbiResult(cpu, 0, 0) end -- OpenSBI implementation
			if fid == 2 then return sbiResult(cpu, 0, 0x00010005) end
			if fid == 3 then
				return sbiResult(cpu, 0, supportedSbiExtensions[arg0] and 1 or 0)
			end
			if fid >= 4 and fid <= 6 then return sbiResult(cpu, 0, 0) end
			return sbiResult(cpu, -2, 0)
		elseif extension == SBI_EXT_TIME then
			if fid ~= 0 then return sbiResult(cpu, -2, 0) end
			programSupervisorTimer(innerCore, cpu)
			return sbiResult(cpu, 0, 0)
		elseif extension == SBI_EXT_IPI or extension == SBI_EXT_RFENCE then
			return sbiResult(cpu, 0, 0) -- single hart
		elseif extension == SBI_EXT_HSM then
			if fid == 2 then return sbiResult(cpu, 0, 0) end -- hart started
			return sbiResult(cpu, -2, 0)
		elseif extension == SBI_EXT_SRST then
			cpu.halted = true
			return sbiResult(cpu, 0, 0)
		elseif extension == SBI_EXT_DBCN and fid == 2 then
			uart:write8(0, arg0)
			return sbiResult(cpu, 0, 0)
		end

		return sbiResult(cpu, -2, 0)
	end

	if okPlic and type(PlicMod) == "table" and type(PlicMod.new) == "function" then
		local plic = PlicMod.new(95)
		core:map_mmio(0x0C000000, 0x400000, plic)
		if type(plic.bind_core) == "function" then
			plic:bind_core(core)
		end

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
		if virtioBlk.setIrqSink and plic.set_source_level then
			virtioBlk:setIrqSink(function(level)
				plic:set_source_level(VIRTIO_BLK_IRQ, level and true or false)
			end)
		end
	end

	-- Cargar primero CaribeBootX y luego OpenSBI. Los parches de fw_dynamic se
	-- aplican al final porque el ELF de OpenSBI incluye BSS sobre sus globals.
	writeBlobToRam(ram, DTB_ADDR, dtbBlob)
	local caribeEntry = ELF32.load(caribeBlob, ram)
	assert(caribeEntry == 0x80200000, string.format(
		"entry CaribeBootX inesperado: 0x%08X", caribeEntry
	))

	local entry
	if isElf(fwBlob) then
		logLine("INFO", "firmware detectado como ELF; usando ELF32.load")
		entry = ELF32.load(fwBlob, ram)
	else
		logLine("INFO", "firmware detectado como BIN crudo; copiando a 0x80000000")
		writeBlobToRam(ram, RAM_BASE, fwBlob)
		entry = RAM_BASE
	end

	if FORCE_PLATFORM_HART_COUNT then
		local hartCountAddr = PLATFORM_SYMBOL_ADDR + SBI_PLATFORM_HART_COUNT_OFFSET
		writeU32ToRam(ram, hartCountAddr, 1)
		logLine("INFO", string.format(
			"FORCE patch: platform.hart_count <- 1 @ 0x%08X", hartCountAddr
			))
	end
	installFwDynamicInfo(ram, caribeEntry)

	logLine("INFO", string.format("OpenSBI entry=0x%08X", entry))
	logLine("INFO", string.format(
		"dtb@0x%08X fwinfo@0x%08X next(CaribeBootX)@0x%08X virtio-blk@0x%08X irq=%d",
		DTB_ADDR, FWINFO_ADDR, caribeEntry, VIRTIO_BLK_ADDR, VIRTIO_BLK_IRQ
	))

	core.cpu.regs[10] = 0
	core.cpu.regs[11] = DTB_ADDR
	core.cpu.regs[12] = FWINFO_ADDR
	core.cpu.pc = entry
	Runtime.CaribeOSStatus.phase = "opensbi"
	Runtime.CaribeOSStatus.running = true

	local trapCount = 0
	local repeatedBreakMepc = nil
	local repeatedBreakCount = 0
	local MAX_REPEATED_BREAKS = 128

	core.on_trap = function(mcause, mtval, _innerCore, cpu)
		trapCount = trapCount + 1

		local cause = bit32.band(tonumber(mcause) or 0, 0xFFFFFFFF)
		local epc = (cpu and cpu.priv == 1) and csr(cpu, 0x141) or csr(cpu, 0x341)

		if cause == 3 then
			if repeatedBreakMepc == epc then
				repeatedBreakCount += 1
			else
				repeatedBreakMepc = epc
				repeatedBreakCount = 1
			end

			if repeatedBreakCount == MAX_REPEATED_BREAKS then
				local msg = string.format(
					"EBREAK repetido %d veces en mepc=0x%08X; detengo el core para evitar livelock",
					repeatedBreakCount,
					epc
				)

				logLine("ERROR", msg)
				outText("\n[RoEmu] " .. msg .. "\n")
				if cpu then cpu.halted = true end
			end
		else
			repeatedBreakMepc = nil
			repeatedBreakCount = 0
		end
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

	local lastStatusInstret = 0
	local lastPc = core.cpu.pc
	local samePcStatusCount = 0
	local running = true
	local hbConn
	local turboStartedAt = os.clock()

	outText("[RoEmu] Lanzando OpenSBI -> CaribeBootX -> XNU-CaribeOS...\n")
	logLine("INFO", "runner activo")

	hbConn = RunService.Heartbeat:Connect(function()
		if not running then
			if hbConn then
				hbConn:Disconnect()
				hbConn = nil
			end
			return
		end

		-- El selector de backends puede pausar RISC-V sin destruir su estado.
		-- nil se interpreta como riscv32 para conservar exactamente el arranque
		-- anterior cuando el registro opcional todavia no se ha publicado.
		if RoEmu.ActiveArchitecture ~= nil and RoEmu.ActiveArchitecture ~= "riscv32" then
			return
		end

		pumpKeyboardIntoUart(uart)

		local ok, err = pcall(function()
			local elapsedBoot = os.clock() - turboStartedAt
			local sliceSeconds = (elapsedBoot < BOOST_SECONDS) and BOOST_SLICE_SECONDS or CRUISE_SLICE_SECONDS
			local deadline = os.clock() + sliceSeconds
			local executed = 0

			repeat
				local batch = math.min(STEP_BATCH, MAX_STEPS_PER_HEARTBEAT - executed)
				for _ = 1, batch do
					if not fastForwardCaribeBssZero(core, ram) then
						core:step()
					end
					if core.cpu.halted then
						running = false
						break
					end
				end
				executed += batch
			until not running or executed >= MAX_STEPS_PER_HEARTBEAT or os.clock() >= deadline
		end)

		flushUartOutput()

		if not ok then
			logLine("ERROR", "fallo en step: " .. tostring(err))
			Runtime.CaribeOSStatus.phase = "faulted"
			Runtime.CaribeOSStatus.running = false
			Runtime.CaribeOSStatus.failed = true
			Runtime.CaribeOSStatus.error = tostring(err)
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

local ok, err = pcall(function()
	local controller = require(game:GetService("ServerStorage"):WaitForChild("RoEmu_BootController"))
	if controller.WaitForRV32() then main() end
end)
if not ok then
	logLine("ERROR", tostring(err))
	Runtime.CaribeOSStatus = Runtime.CaribeOSStatus or { schema = 1 }
	Runtime.CaribeOSStatus.phase = "faulted"
	Runtime.CaribeOSStatus.running = false
	Runtime.CaribeOSStatus.failed = true
	Runtime.CaribeOSStatus.error = tostring(err)
	outText("\n[RoEmu] ERROR: " .. tostring(err) .. "\n")
end

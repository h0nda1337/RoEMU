--!optimize 2
-- RoEMU i386 headless platform.
-- No conoce ninguna GUI: expone consola/entrada mediante metodos y callbacks.

local CPU = require(script.Parent:WaitForChild("RoEmu_i386_CPU"))
local Memory = require(script.Parent:WaitForChild("RoEmu_i386_Memory"))

local bit = bit32
local band, bor, bnot = bit.band, bit.bor, bit.bnot
local lshift, rshift = bit.lshift, bit.rshift

local Platform = {}
Platform.VERSION = "0.2.0"
Platform.ARCH = "i386"
Platform.CAPABILITIES = {
	schema = 1,
	architecture = "i386",
	maturity = "experimental",
	headless = true,
	cpu = {
		minimum = "80386",
		protected32 = true,
		realMode = false,
		paging = false,
		segmentation = "flat-selectors-only",
	},
	loaders = {
		flat = true,
		elf32 = true,
		linuxBzImageDirect32 = {
			available = true,
			executionComplete = false,
			detail = "boot_params and direct 32-bit handoff are prepared; paging and the full PC device set are not implemented",
		},
	},
	devices = {
		com1 = true,
		debugPortE9 = true,
		exitPortF4 = true,
		bios = false,
		pic = false,
		pit = false,
		apic = false,
	},
	validation = {
		bringupSelfTest = true,
		extendedDiagnostic = true,
	},
}

local Machine = {}
Machine.__index = Machine

local COM1_BASE = 0x3F8
local DEBUG_PORT = 0xE9
local EXIT_PORT = 0xF4
local MULTIBOOT_MAGIC = 0x2BADB002
local BRINGUP_LOAD = 0x00100000

-- Fixture compilado desde work/x86_guest. Solo se usa para SelfTest/bring-up.
local BRINGUP_HEX = "fa8d25f040100083e4f031ed5350e80900000083c408f4ebfdcccccc5589e58b4d0831c066baf903eeb08066bafb03eeb00366baf803ee31c066baf903eeb00366bafb03eeb0c766bafa03eeb00b66bafc03ee81f902b0ad2bb9cc0010007405b9b0001000e807000000b010e6f4f4ebfd8a2184e4742b5589e5564188e0e6e9be0001000066bafd03eca82075054e7409ebf288e066baf803ee8a2184e475db5e5dc30002b0ad1b03000000fb4f52e4524f454d555f5838365f47554553545f4f4b204449524543540d0a00524f454d555f5838365f47554553545f4f4b0d0a00"

-- Diagnostico compilado desde work/x86_guest/diagnostic.S. Cubre ALU/Jcc,
-- SIB, pila, CALL/RET, COM1 RX/TX, puerto E9, salida F4 y HLT.
local DIAGNOSTIC_HEX = "fa8d25e041100083e4f031ede85b000000e8aa00000085c07521e8e400000085c07518e81201000085c0750fe87100000083f85a7421b80400000089c38d35b4011000e82a01000089d805e000000066baf400eef4ebfe8d35a0011000e810010000b02166baf400eef4ebfe505266baf90330c0ee66bafb03b080ee66baf803b003ee66baf90330c0ee66bafb03b003ee66bafa03b001ee66bafc03b00bee5a58c3b9ffffff7f66bafd03eca8017508e2f9b8ffffffffc366baf80331c0ecc3b84030201005040302013d44332211752c35440022002d001100013d00220010751bb8ffffff7f83c0017111790fb8ffffffff83c0017305750331c0c3b801000000c38d1dd0011000b902000000b8df9b571389048b8b148b39c275178d7c8b04c707e0ac6824817c8b04e0ac6824750331c0c3b802000000c35389e368443322116804030201e81b00000083c4083d48362412750839dc75045b31c0c389dc5bb803000000c35589e58b450803450c5dc38a0684c0740846e803000000ebf2c3505266bae900ee66baf803ee5a58c302b0ad1b03000000fb4f52e400000000524f454d555f5838365f444941475f4f4b0d0a00524f454d555f5838365f444941475f4641494c0d0a0000000000000000000000000000000000000000000000"

local function u32(value)
	return band(tonumber(value) or 0, 0xFFFFFFFF)
end

local function dataLength(data)
	if type(data) == "string" then
		return #data
	end
	if typeof(data) == "buffer" then
		return buffer.len(data)
	end
	if type(data) == "table" then
		return #data
	end
	error("x86 image must be a string, buffer, or byte array", 3)
end

local function dataByte(data, offset)
	if offset < 0 or offset >= dataLength(data) then
		return nil
	end
	if type(data) == "string" then
		return string.byte(data, offset + 1)
	end
	if typeof(data) == "buffer" then
		return buffer.readu8(data, offset)
	end
	return tonumber(data[offset + 1]) or 0
end

local function dataU16(data, offset)
	local a, b = dataByte(data, offset), dataByte(data, offset + 1)
	if a == nil or b == nil then return nil end
	return a + b * 0x100
end

local function dataU32(data, offset)
	local a = dataByte(data, offset)
	local b = dataByte(data, offset + 1)
	local c = dataByte(data, offset + 2)
	local d = dataByte(data, offset + 3)
	if a == nil or b == nil or c == nil or d == nil then return nil end
	return u32(a + b * 0x100 + c * 0x10000 + d * 0x1000000)
end

local function dataSlice(data, offset, size)
	assert(offset >= 0 and size >= 0 and offset + size <= dataLength(data), "image slice out of range")
	if type(data) == "string" then
		return string.sub(data, offset + 1, offset + size)
	end
	local result = table.create(size)
	for index = 0, size - 1 do
		result[index + 1] = dataByte(data, offset + index)
	end
	return result
end

local function hexBytes(hex)
	local result = table.create(#hex / 2)
	for index = 1, #hex, 2 do
		result[#result + 1] = tonumber(string.sub(hex, index, index + 1), 16)
	end
	return result
end

local function alignDown(value, alignment)
	return math.floor(value / alignment) * alignment
end

local function shallowCopy(source)
	local result = {}
	for key, value in pairs(source or {}) do
		result[key] = value
	end
	return result
end

function Platform.new(options)
	options = options or {}
	local self = setmetatable({}, Machine)
	self.ramSize = math.floor(tonumber(options.ramSize) or (64 * 1024 * 1024))
	assert(self.ramSize >= 2 * 1024 * 1024, "i386 RAM must be at least 2 MiB")
	self.ram = Memory.RAM.new(0, self.ramSize)
	self.bus = Memory.Bus.new()
	self.bus:mapRAM(self.ram, "x86-ram")

	self.running = false
	self.exitCode = nil
	self.lastRun = nil
	self.lastLoader = nil
	self.rx = {}
	self.rxHead = 1
	self.rxTail = 0
	self.transcriptLimit = math.max(4096, math.floor(tonumber(options.transcriptLimit) or 1024 * 1024))
	self.transcript = { serial = {}, debug = {} }
	self.transcriptBytes = { serial = 0, debug = 0 }
	self.pending = { serial = {}, debug = {} }
	self.onOutput = options.onOutput
	self.inputProvider = options.inputProvider

	self.com1 = {
		dll = 1,
		dlm = 0,
		ier = 0,
		fcr = 0,
		lcr = 0,
		mcr = 0,
		msr = 0xB0,
		scratch = 0,
	}

	local memoryCallbacks = self.bus:callbacks()
	local cpuOptions = shallowCopy(options.cpu)
	cpuOptions.eip = cpuOptions.eip or 0
	cpuOptions.cr0 = cpuOptions.cr0 or 1
	cpuOptions.eflags = cpuOptions.eflags or 2
	self.cpu = CPU.new({
		read8 = memoryCallbacks.read8,
		write8 = memoryCallbacks.write8,
		ioRead = function(port, width)
			return self:readPort(port, width)
		end,
		ioWrite = function(port, width, value)
			self:writePort(port, width, value)
		end,
		onException = function(exception)
			self.running = false
			if type(options.onException) == "function" then
				return options.onException(exception, self)
			end
			return nil
		end,
	}, cpuOptions)
	return self
end

function Machine:_emit(channel, value)
	value = band(value or 0, 0xFF)
	local character = string.char(value)
	local used = self.transcriptBytes[channel]
	if used < self.transcriptLimit then
		self.transcript[channel][#self.transcript[channel] + 1] = character
		self.transcriptBytes[channel] = used + 1
	end
	self.pending[channel][#self.pending[channel] + 1] = character
	if type(self.onOutput) == "function" then
		self.onOutput(character, channel, self)
	end
end

function Machine:getTranscript(channel)
	channel = channel or "serial"
	assert(self.transcript[channel] ~= nil, "unknown x86 output channel")
	return table.concat(self.transcript[channel])
end

function Machine:clearTranscript(channel)
	if channel == nil then
		for _, name in ipairs({ "serial", "debug" }) do
			self.transcript[name] = {}
			self.transcriptBytes[name] = 0
			self.pending[name] = {}
		end
		return
	end
	assert(self.transcript[channel] ~= nil, "unknown x86 output channel")
	self.transcript[channel] = {}
	self.transcriptBytes[channel] = 0
	self.pending[channel] = {}
end

function Machine:drainOutput(channel)
	channel = channel or "serial"
	assert(self.pending[channel] ~= nil, "unknown x86 output channel")
	local text = table.concat(self.pending[channel])
	self.pending[channel] = {}
	return text
end

function Machine:_pushInput(value)
	self.rxTail += 1
	self.rx[self.rxTail] = band(tonumber(value) or 0, 0xFF)
end

function Machine:feedInput(data)
	if data == nil then return 0 end
	local added = 0
	if type(data) == "number" then
		self:_pushInput(data)
		return 1
	end
	if type(data) == "string" then
		for index = 1, #data do
			self:_pushInput(string.byte(data, index))
			added += 1
		end
		return added
	end
	if typeof(data) == "buffer" then
		for index = 0, buffer.len(data) - 1 do
			self:_pushInput(buffer.readu8(data, index))
			added += 1
		end
		return added
	end
	assert(type(data) == "table", "x86 input must be a byte, string, buffer, or byte array")
	for _, value in ipairs(data) do
		self:_pushInput(value)
		added += 1
	end
	return added
end

function Machine:_popInput()
	if self.rxHead > self.rxTail then return nil end
	local value = self.rx[self.rxHead]
	self.rx[self.rxHead] = nil
	self.rxHead += 1
	if self.rxHead > self.rxTail then
		self.rx = {}
		self.rxHead = 1
		self.rxTail = 0
	elseif self.rxHead > 4096 and self.rxHead > self.rxTail / 2 then
		local compact = {}
		for index = self.rxHead, self.rxTail do
			compact[#compact + 1] = self.rx[index]
		end
		self.rx = compact
		self.rxHead = 1
		self.rxTail = #compact
	end
	return value
end

function Machine:clearInput()
	local removed = math.max(0, self.rxTail - self.rxHead + 1)
	self.rx = {}
	self.rxHead = 1
	self.rxTail = 0
	return removed
end

function Machine:_readPort8(port)
	port = band(port, 0xFFFF)
	if port >= COM1_BASE and port <= COM1_BASE + 7 then
		local offset = port - COM1_BASE
		local dlab = band(self.com1.lcr, 0x80) ~= 0
		if offset == 0 then
			if dlab then return self.com1.dll end
			return self:_popInput() or 0
		elseif offset == 1 then
			return dlab and self.com1.dlm or self.com1.ier
		elseif offset == 2 then
			return 0x01 -- no interrupt pending
		elseif offset == 3 then
			return self.com1.lcr
		elseif offset == 4 then
			return self.com1.mcr
		elseif offset == 5 then
			local ready = self.rxHead <= self.rxTail and 1 or 0
			return bor(0x60, ready) -- THRE | TEMT | optional DR
		elseif offset == 6 then
			return self.com1.msr
		else
			return self.com1.scratch
		end
	end
	return 0xFF
end

function Machine:_writePort8(port, value)
	port = band(port, 0xFFFF)
	value = band(value or 0, 0xFF)
	if port == DEBUG_PORT then
		self:_emit("debug", value)
		return
	end
	if port == EXIT_PORT then
		self.exitCode = value
		return
	end
	if port < COM1_BASE or port > COM1_BASE + 7 then
		return
	end
	local offset = port - COM1_BASE
	local dlab = band(self.com1.lcr, 0x80) ~= 0
	if offset == 0 then
		if dlab then self.com1.dll = value else self:_emit("serial", value) end
	elseif offset == 1 then
		if dlab then self.com1.dlm = value else self.com1.ier = band(value, 0x0F) end
	elseif offset == 2 then
		self.com1.fcr = value
		if band(value, 0x02) ~= 0 then
			self:clearInput()
		end
	elseif offset == 3 then
		self.com1.lcr = value
	elseif offset == 4 then
		self.com1.mcr = value
	elseif offset == 7 then
		self.com1.scratch = value
	end
end

function Machine:readPort(port, width)
	width = width or 8
	if width == 8 then return self:_readPort8(port) end
	local value = 0
	for byteIndex = 0, width / 8 - 1 do
		value = value + self:_readPort8(port + byteIndex) * 2 ^ (byteIndex * 8)
	end
	return u32(value)
end

function Machine:writePort(port, width, value)
	width = width or 8
	for byteIndex = 0, width / 8 - 1 do
		self:_writePort8(port + byteIndex, rshift(value, byteIndex * 8))
	end
end

function Machine:_write8(address, value)
	local ok, reason = self.ram:write8(address, value)
	assert(ok, string.format("x86 memory write failed at 0x%08X: %s", u32(address), tostring(reason)))
end

function Machine:_write16(address, value)
	self:_write8(address, value)
	self:_write8(address + 1, rshift(value, 8))
end

function Machine:_write32(address, value)
	value = u32(value)
	for index = 0, 3 do
		self:_write8(address + index, rshift(value, index * 8))
	end
end

function Machine:_write64(address, low, high)
	self:_write32(address, low)
	self:_write32(address + 4, high or 0)
end

function Machine:_load(address, data)
	local ok, reason
	if type(data) == "string" or type(data) == "table" then
		ok, reason = self.ram:load(address, data)
	else
		ok = true
		for index = 0, dataLength(data) - 1 do
			local wrote, why = self.ram:write8(address + index, dataByte(data, index))
			if not wrote then ok, reason = false, why break end
		end
	end
	assert(ok, string.format("x86 image does not fit at 0x%08X: %s", u32(address), tostring(reason)))
end

function Machine:loadFlat(image, address, entry)
	address = u32(address or BRINGUP_LOAD)
	entry = u32(entry or address)
	self:_load(address, image)
	self.cpu.eip = entry
	self.cpu.halted = false
	self.exitCode = nil
	self.lastLoader = {
		format = "flat",
		phase = "prepared",
		guestKind = "flat32",
		executionComplete = true,
		bootObserved = false,
		loadAddress = address,
		entry = entry,
		imageBytes = dataLength(image),
	}
	return self.lastLoader
end

function Machine:loadELF32(image)
	assert(dataLength(image) >= 52, "truncated ELF32 image")
	assert(dataByte(image, 0) == 0x7F and dataByte(image, 1) == 0x45
		and dataByte(image, 2) == 0x4C and dataByte(image, 3) == 0x46, "bad ELF magic")
	assert(dataByte(image, 4) == 1, "ELF is not 32-bit")
	assert(dataByte(image, 5) == 1, "ELF is not little-endian")
	assert(dataU16(image, 18) == 3, "ELF e_machine is not EM_386")
	local entry = dataU32(image, 24)
	local phoff = dataU32(image, 28)
	local phentsize = dataU16(image, 42)
	local phnum = dataU16(image, 44)
	assert(entry and phoff and phentsize and phnum and phentsize >= 32, "invalid ELF32 header")
	local segments = {}
	for index = 0, phnum - 1 do
		local offset = phoff + index * phentsize
		assert(offset + 32 <= dataLength(image), "truncated ELF32 program header")
		if dataU32(image, offset) == 1 then -- PT_LOAD
			local fileOffset = dataU32(image, offset + 4)
			local virtualAddress = dataU32(image, offset + 8)
			local physicalAddress = dataU32(image, offset + 12)
			local fileSize = dataU32(image, offset + 16)
			local memorySize = dataU32(image, offset + 20)
			assert(fileOffset + fileSize <= dataLength(image), "ELF32 segment exceeds file")
			assert(memorySize >= fileSize, "ELF32 p_memsz is smaller than p_filesz")
			local loadAddress = physicalAddress ~= 0 and physicalAddress or virtualAddress
			self:_load(loadAddress, dataSlice(image, fileOffset, fileSize))
			for byteIndex = fileSize, memorySize - 1 do
				self:_write8(loadAddress + byteIndex, 0)
			end
			segments[#segments + 1] = {
				address = loadAddress,
				fileBytes = fileSize,
				memoryBytes = memorySize,
			}
		end
	end
	assert(#segments > 0, "ELF32 has no PT_LOAD segments")
	self.cpu.eip = entry
	self.cpu.halted = false
	self.exitCode = nil
	self.lastLoader = {
		format = "elf32-i386",
		phase = "prepared",
		guestKind = "elf32-i386",
		executionComplete = true,
		bootObserved = false,
		entry = entry,
		segments = segments,
	}
	return self.lastLoader
end

function Machine:loadBringupGuest(useMultibootMagic)
	self:clearTranscript()
	local info = self:loadFlat(hexBytes(BRINGUP_HEX), BRINGUP_LOAD, BRINGUP_LOAD)
	self.cpu:setReg32(CPU.REG.EAX, useMultibootMagic == false and 0 or MULTIBOOT_MAGIC)
	self.cpu:setReg32(CPU.REG.EBX, 0)
	return info
end

function Machine:prepareLinuxBzImage(image, options)
	options = options or {}
	assert(dataLength(image) >= 0x260, "truncated Linux bzImage")
	local setupSects = dataByte(image, 0x1F1)
	if setupSects == 0 then setupSects = 4 end
	assert(dataByte(image, 0x202) == 0x48 and dataByte(image, 0x203) == 0x64
		and dataByte(image, 0x204) == 0x72 and dataByte(image, 0x205) == 0x53,
		"Linux image has no HdrS signature")
	local protocol = dataU16(image, 0x206)
	local loadFlags = dataByte(image, 0x211)
	assert(protocol and protocol >= 0x0200, "Linux boot protocol is too old for direct 32-bit handoff")
	assert(band(loadFlags, 0x01) ~= 0, "Linux image is not a bzImage/LOADED_HIGH kernel")

	local payloadOffset = (setupSects + 1) * 512
	assert(payloadOffset < dataLength(image), "Linux bzImage has no protected-mode payload")
	local advertisedCode32 = dataU32(image, 0x214) or BRINGUP_LOAD
	local loadAddress = u32(options.loadAddress or advertisedCode32)
	if loadAddress < BRINGUP_LOAD then loadAddress = BRINGUP_LOAD end
	local payloadBytes = dataLength(image) - payloadOffset
	assert(loadAddress + payloadBytes <= self.ramSize, "Linux protected-mode payload exceeds x86 RAM")
	self:_load(loadAddress, dataSlice(image, payloadOffset, payloadBytes))

	local bootParams = u32(options.bootParamsAddress or 0x00090000)
	assert(bootParams + 4096 <= self.ramSize, "boot_params exceeds x86 RAM")
	for index = 0, 4095 do self:_write8(bootParams + index, 0) end
	local headerEnd = math.min(payloadOffset, 0x290)
	for offset = 0x1F1, headerEnd - 1 do
		self:_write8(bootParams + offset, dataByte(image, offset))
	end
	self:_write8(bootParams + 0x210, 0xFF) -- type_of_loader

	local commandLine = tostring(options.commandLine
		or "console=ttyS0,115200 earlycon=uart8250,io,0x3f8,115200 rdinit=/init")
	local commandAddress = u32(options.commandLineAddress or 0x00020000)
	assert(commandAddress + #commandLine + 1 <= self.ramSize, "Linux command line exceeds x86 RAM")
	self:_load(commandAddress, commandLine .. "\0")
	self:_write32(bootParams + 0x228, commandAddress)

	local e820 = {
		{ baseLow = 0, baseHigh = 0, sizeLow = math.min(self.ramSize, 0x0009FC00), sizeHigh = 0, kind = 1 },
	}
	if self.ramSize > 0x0009FC00 then
		e820[#e820 + 1] = { baseLow = 0x0009FC00, baseHigh = 0, sizeLow = 0x00060400, sizeHigh = 0, kind = 2 }
	end
	if self.ramSize > 0x00100000 then
		e820[#e820 + 1] = {
			baseLow = 0x00100000,
			baseHigh = 0,
			sizeLow = self.ramSize - 0x00100000,
			sizeHigh = 0,
			kind = 1,
		}
	end
	self:_write8(bootParams + 0x1E8, #e820)
	for index, entry in ipairs(e820) do
		local address = bootParams + 0x2D0 + (index - 1) * 20
		self:_write64(address, entry.baseLow, entry.baseHigh)
		self:_write64(address + 8, entry.sizeLow, entry.sizeHigh)
		self:_write32(address + 16, entry.kind)
	end

	local initrdAddress, initrdBytes = nil, 0
	if options.initrd ~= nil then
		initrdBytes = dataLength(options.initrd)
		local initrdMax = dataU32(image, 0x22C) or 0x37FFFFFF
		local highest = math.min(self.ramSize, initrdMax + 1)
		initrdAddress = u32(options.initrdAddress or alignDown(highest - initrdBytes - 0x10000, 4096))
		assert(initrdAddress >= loadAddress + payloadBytes, "initrd overlaps Linux kernel")
		self:_load(initrdAddress, options.initrd)
		self:_write32(bootParams + 0x218, initrdAddress)
		self:_write32(bootParams + 0x21C, initrdBytes)
	end

	self.cpu.cr0 = band(bor(self.cpu.cr0, 1), 0x7FFFFFFF) -- PE=1, PG=0
	self.cpu.eflags = band(bor(self.cpu.eflags, 2), bnot(bor(CPU.FLAG.IF, CPU.FLAG.DF)))
	self.cpu.segments.cs = 0x10
	self.cpu.segments.ds = 0x18
	self.cpu.segments.es = 0x18
	self.cpu.segments.ss = 0x18
	self.cpu.segments.fs = 0x18
	self.cpu.segments.gs = 0x18
	self.cpu:setReg32(CPU.REG.EAX, 0)
	self.cpu:setReg32(CPU.REG.EBX, 0)
	self.cpu:setReg32(CPU.REG.EBP, 0)
	self.cpu:setReg32(CPU.REG.ESI, bootParams)
	self.cpu:setReg32(CPU.REG.EDI, 0)
	self.cpu:setReg32(CPU.REG.ESP, u32(options.stackAddress or (bootParams - 0x1000)))
	self.cpu.eip = loadAddress
	self.cpu.halted = false
	self.exitCode = nil
	self.lastLoader = {
		format = "linux-bzimage-i386-direct32",
		phase = "prepared",
		guestKind = "linux-bzimage-direct32",
		executionComplete = false,
		bootObserved = false,
		userspaceObserved = false,
		limitation = "loader-ready; paging and the complete Linux PC platform are not implemented",
		protocol = protocol,
		setupSectors = setupSects,
		payloadOffset = payloadOffset,
		payloadBytes = payloadBytes,
		loadAddress = loadAddress,
		entry = loadAddress,
		bootParamsAddress = bootParams,
		commandLineAddress = commandAddress,
		commandLine = commandLine,
		initrdAddress = initrdAddress,
		initrdBytes = initrdBytes,
		e820Entries = #e820,
	}
	return self.lastLoader
end

function Machine:_pumpInputProvider()
	if type(self.inputProvider) ~= "function" then return end
	local value = self.inputProvider(self)
	if value ~= nil then self:feedInput(value) end
end

function Machine:step()
	self:_pumpInputProvider()
	local result = self.cpu:step()
	if result.kind ~= "ok" then self.running = false end
	return result
end

function Machine:runSlice(maxInstructions, maxSeconds)
	maxInstructions = math.max(1, math.floor(tonumber(maxInstructions) or 100000))
	maxSeconds = math.max(0, tonumber(maxSeconds) or 0.01)
	local deadline = os.clock() + maxSeconds
	local executed = 0
	local last = nil
	self.running = true
	self:_pumpInputProvider()
	while self.running and executed < maxInstructions and os.clock() <= deadline do
		last = self.cpu:step()
		if last.kind == "ok" then
			executed += 1
		elseif last.kind == "halted" then
			if self.cpu.halted then executed += 1 end
			self.running = false
			break
		else
			self.running = false
			break
		end
	end
	local kind
	if last and last.kind ~= "ok" then kind = last.kind
	elseif executed >= maxInstructions then kind = "limit"
	elseif os.clock() > deadline then kind = "timeslice"
	else kind = "stopped" end
	self.lastRun = { kind = kind, executed = executed, eip = self.cpu.eip, last = last }
	return self.lastRun
end

function Machine:stop()
	self.running = false
	return self:getStatus()
end

function Machine:resume()
	self.cpu:resume()
	self.running = true
	return self:getStatus()
end

function Machine:resetCPU(options)
	self.running = false
	self.exitCode = nil
	self.lastRun = nil
	self.cpu:reset(options or { eip = 0, cr0 = 1, eflags = 2 })
	return self:getStatus()
end

function Machine:getStatus()
	local exception = self.cpu.lastException
	return {
		architecture = Platform.ARCH,
		version = Platform.VERSION,
		running = self.running,
		halted = self.cpu.halted,
		eip = u32(self.cpu.eip),
		eflags = u32(self.cpu.eflags),
		instructions = tonumber(self.cpu.instructionCount) or 0,
		cycles = tonumber(self.cpu.cycleCount) or 0,
		ramBytes = self.ramSize,
		rxPending = math.max(0, self.rxTail - self.rxHead + 1),
		exitCode = self.exitCode,
		loader = self.lastLoader,
		lastRun = self.lastRun,
		lastException = exception and {
			vector = exception.vector,
			name = exception.name,
			errorCode = exception.errorCode,
			detail = exception.detail,
			eip = exception.eip,
		} or nil,
	}
end

function Machine:selfTest()
	self:clearInput()
	self:feedInput({ 0x41, 0x42 })
	local readyBefore = band(self:readPort(COM1_BASE + 5, 8), 1) == 1
	local first = self:readPort(COM1_BASE, 8)
	local second = self:readPort(COM1_BASE, 8)
	local emptyAfter = band(self:readPort(COM1_BASE + 5, 8), 1) == 0
	-- Regression: feeding again after fully draining used to append behind rxHead.
	self:feedInput("Z")
	local readyAgain = band(self:readPort(COM1_BASE + 5, 8), 1) == 1
	local third = self:readPort(COM1_BASE, 8)
	local queueOk = readyBefore and first == 0x41 and second == 0x42
		and emptyAfter and readyAgain and third == 0x5A
		and band(self:readPort(COM1_BASE + 5, 8), 1) == 0
	self:clearInput()

	self:resetCPU({ eip = BRINGUP_LOAD, cr0 = 1, eflags = 2 })
	self:loadBringupGuest(true)
	local result = self:runSlice(20000, 1.0)
	local expected = "ROEMU_X86_GUEST_OK\r\n"
	local serial = self:getTranscript("serial")
	local debug = self:getTranscript("debug")
	local ok = queueOk and result.kind == "halted" and serial == expected and debug == expected
		and self.exitCode == 0x10 and self.cpu.lastException == nil
	return ok, {
		scope = "bringup-flat32-uart-debug-exit-and-rx-queue",
		uartRx = {
			ok = queueOk,
			first = first,
			second = second,
			third = third,
		},
		result = result,
		serial = serial,
		debug = debug,
		exitCode = self.exitCode,
		status = self:getStatus(),
	}
end

function Machine:runDiagnostic()
	self:clearInput()
	self:clearTranscript()
	self:resetCPU({ eip = BRINGUP_LOAD, cr0 = 1, eflags = 2 })
	self:loadFlat(hexBytes(DIAGNOSTIC_HEX), BRINGUP_LOAD, BRINGUP_LOAD)
	self:feedInput("Z")
	local result = self:runSlice(20000, 1.0)
	local expected = "ROEMU_X86_DIAG_OK\r\n"
	local serial = self:getTranscript("serial")
	local debug = self:getTranscript("debug")
	local ok = result.kind == "halted" and serial == expected and debug == expected
		and self.exitCode == 0x21 and self.cpu.lastException == nil
	return ok, {
		scope = "alu-jcc-sib-stack-call-ret-com1-rx-tx-debug-exit",
		result = result,
		serial = serial,
		debug = debug,
		exitCode = self.exitCode,
		status = self:getStatus(),
	}
end

Platform.Machine = Machine
Platform.constants = {
	COM1_BASE = COM1_BASE,
	DEBUG_PORT = DEBUG_PORT,
	EXIT_PORT = EXIT_PORT,
	MULTIBOOT_MAGIC = MULTIBOOT_MAGIC,
	BRINGUP_LOAD = BRINGUP_LOAD,
}

return Platform

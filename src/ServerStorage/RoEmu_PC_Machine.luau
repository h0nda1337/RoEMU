--!native
--!optimize 2
-- Interpreted PC guest: actual guest instructions, host BIOS services, local disk.
local CPU = script and require(script.Parent.RoEmu_i386_CPU) or require("./i386_CPU")
local Memory = script and require(script.Parent.RoEmu_i386_Memory) or require("./i386_Memory")
local VGA = script and require(script.Parent.RoEmu_PC_VGA) or require("./VGA")
local PIC = script and require(script.Parent.RoEmu_PC_PIC) or require("./PIC")
local ATA = script and require(script.Parent.RoEmu_PC_ATA) or require("./ATA")
local PCI = script and require(script.Parent.RoEmu_PC_PCI) or require("./PCI")
local bit = bit32
local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift
local PC = {}
PC.__index = PC

function PC.new(disk, options)
	options = options or {}
	local self = setmetatable({}, PC)
	self.disk = disk
	self.firmware = options.systemFirmware ~= nil
	self.highROMBase = self.firmware and 0x100000000-#options.systemFirmware or nil
	self.firmwareROM = self.firmware and buffer.fromstring(options.systemFirmware) or nil
	self.diagnostics = options.diagnostics == true
	self.ram = Memory.RAM.new(0, options.ramSize or 64 * 1024 * 1024)
	self.vga = VGA.new()
	self.pci = PCI.new(self.vga,options.videoFirmware)
	self.onOutput = options.onOutput
	self.transcript = ""
	self.reads = 0
	self.writes = {}
	self.lastBIOS = {}
	self.biosCounts = {}
	self.trace = {}
	self.a20Trace = {}
	self.exceptions = {}
	self.exceptionCounts = {}
	self.userFaults = {}
	self.userFaultSites={}
	self.onUserFault=options.onUserFault
	self.onFault=options.onFault
	self.irqCounts = {}
	self.biosATAStarted, self.biosATACompleted, self.biosATAErrors = 0, 0, 0
	self.watchWrites = {}
	self.targetTrace = {}
	self.traceIndex = 0
	self.stepCalls = 0
	self.keyboard = {}
	self.kbcOutput = {}
	self.deviceInput,self.keyHeldTicks,self.nextInputTick={},{},0
	-- VMware's documented absolute pointer port is used by the VBMOUSE driver
	-- already installed on this disk. PS/2 still supplies its IRQ12 notification.
	self.pointerQueue, self.pointerEnabled, self.pointerAbsolute = {}, false, false
	self.kbcConfig = 0x45
	self.keyboardScanSet = 2
	self.videoMode = 3
	self.columns = 80
	self.rows = 25
	self.cursorX, self.cursorY = 0, 0
	self.portState = {}
	self.palette = buffer.create(768)
	self.dacWrite, self.dacRead = 0, 0
	self.ticks = 0
	-- About 9.5 million retired instructions per virtual second, appropriate
	-- for the emulated 386. Keep timer IRQ work proportional to that clock.
	self.pitTicksPerInstruction = options.pitTicksPerInstruction or 0.125
	self.realtimeClock = options.realtimeClock == true
	self.hostClock = options.hostClock or os.clock
	self.pitClockTicks = 0
	self.pitLastHostTime = self.hostClock()
	self.pitIdleTicks = 0
	self.pitChannels = {}
	for index = 0, 2 do
		self.pitChannels[index] = { reload = 65536, mode = 3, access = 3, loaded = 0,
			readHigh = false, writeHigh = false, gate = index ~= 2, irqCycle = 0 }
	end
	self.a20 = true
	self.portsRead = {}
	self.portsWritten = {}
	self.cmos = { [0x0A] = 0x26, [0x0B] = 2, [0x0C] = 0, [0x0D] = 0x80 }
	self.pic = PIC.new()
	self.ata = ATA.new(disk, self.writes, function() self.pic:raise(14) end)
	self.cpu = CPU.new({
		ramSpan = function(address,length,writing)
			-- Only ordinary RAM: no VGA aperture, expansion ROM, high firmware,
			-- A20 aliasing or diagnostic write hooks may be bypassed.
			if self.a20 and not self.diagnostics and address>=0 and address+length<=self.ram.size
				and (address+length<=0xA0000 or address>=0x100000)
				and not (self.pci.romEnabled and address<self.pci.romBase+self.pci.romSize and address+length>self.pci.romBase) then return self.ram.buffer,address end
		end,
		canBatchCode = function(address, count)
			return address + count <= self.ram.size and (address + count <= 0xA0000 or address >= 0xC0000)
		end,
		spinBudget = function(cpu)
			local budget = 4096
			if cpu:getFlag(CPU.FLAG.IF) then
				if self.pic:hasPending() then return 1 end
				local timer = self.pitChannels[0]
				budget = math.min(budget, math.ceil((timer.reload - (self:pitNow() - timer.loaded) % timer.reload) / self.pitTicksPerInstruction))
				if band(self.cmos[0x0B], 0x40) ~= 0 then
					local rate = band(self.cmos[0x0A], 15)
					if rate >= 3 then
						local period = 1193182 / 2 ^ (16 - rate)
						budget = math.min(budget, math.ceil((period - self:pitNow() % period) / self.pitTicksPerInstruction))
					end
				end
			end
			return math.max(1, budget)
		end,
		read16 = function(address)
			if self.a20 and address+2<=self.ram.size and (address+2<=0xA0000 or address>=0x100000) and not (self.pci.romEnabled and address<self.pci.romBase+self.pci.romSize and address+2>self.pci.romBase) then return buffer.readu16(self.ram.buffer,address) end
			if self.pci.romEnabled then local value=self.pci:readROM(address,16);if value~=nil then return value end end
			if self.highROMBase and address>=self.highROMBase then
				local offset=address-self.highROMBase
				if offset+2<=buffer.len(self.firmwareROM) then return buffer.readu16(self.firmwareROM,offset) end
				return nil
			end
			if not self.a20 then address = band(address, 0xFFEFFFFF) end
			local offset = self.vga:linearOffset(address)
			if offset and offset + 2 <= buffer.len(self.vga.linearMemory) then return buffer.readu16(self.vga.linearMemory, offset) end
			if address + 2 <= self.ram.size and (address < 0xA0000 or address >= 0xC0000 or not self.vga:isGraphics()) then return buffer.readu16(self.ram.buffer, address) end
		end,
		read32 = function(address)
			if self.a20 and address+4<=self.ram.size and (address+4<=0xA0000 or address>=0x100000) and not (self.pci.romEnabled and address<self.pci.romBase+self.pci.romSize and address+4>self.pci.romBase) then return buffer.readu32(self.ram.buffer,address) end
			if self.pci.romEnabled then local value=self.pci:readROM(address,32);if value~=nil then return value end end
			if self.highROMBase and address>=self.highROMBase then
				local offset=address-self.highROMBase
				if offset+4<=buffer.len(self.firmwareROM) then return buffer.readu32(self.firmwareROM,offset) end
				return nil
			end
			if not self.a20 then address = band(address, 0xFFEFFFFF) end
			local offset = self.vga:linearOffset(address)
			if offset and offset + 4 <= buffer.len(self.vga.linearMemory) then return buffer.readu32(self.vga.linearMemory, offset) end
			if address + 4 <= self.ram.size and (address < 0xA0000 or address >= 0xC0000 or not self.vga:isGraphics()) then return buffer.readu32(self.ram.buffer, address) end
		end,
		write16 = function(address, value)
			if self.a20 and not self.diagnostics and address+2<=self.ram.size and (address+2<=0xA0000 or address>=0x100000) then buffer.writeu16(self.ram.buffer,address,value);return true end
			if self.highROMBase and address>=self.highROMBase then return true end
			if self.diagnostics then return nil end
			if not self.a20 then address = band(address, 0xFFEFFFFF) end
			local offset = self.vga:linearOffset(address)
			if offset and offset + 2 <= buffer.len(self.vga.linearMemory) then buffer.writeu16(self.vga.linearMemory, offset, value); self.vga.generation += 1; return true end
			if address + 2 <= self.ram.size and (address < 0xA0000 or address >= 0xC0000 or not self.vga:isGraphics()) then buffer.writeu16(self.ram.buffer, address, value); return true end
		end,
		write32 = function(address, value)
			if self.a20 and not self.diagnostics and address+4<=self.ram.size and (address+4<=0xA0000 or address>=0x100000) then buffer.writeu32(self.ram.buffer,address,value);return true end
			if self.highROMBase and address>=self.highROMBase then return true end
			if self.diagnostics then return nil end
			if not self.a20 then address = band(address, 0xFFEFFFFF) end
			local offset = self.vga:linearOffset(address)
			if offset and offset + 4 <= buffer.len(self.vga.linearMemory) then buffer.writeu32(self.vga.linearMemory, offset, value); self.vga.generation += 1; return true end
			if address + 4 <= self.ram.size and (address < 0xA0000 or address >= 0xC0000 or not self.vga:isGraphics()) then buffer.writeu32(self.ram.buffer, address, value); return true end
		end,
		read8 = function(address)
			if self.a20 and address+1<=self.ram.size and (address+1<=0xA0000 or address>=0x100000) and not (self.pci.romEnabled and address<self.pci.romBase+self.pci.romSize and address+1>self.pci.romBase) then return buffer.readu8(self.ram.buffer,address) end
			if self.pci.romEnabled then local value=self.pci:readROM(address,8);if value~=nil then return value end end
			if self.highROMBase and address>=self.highROMBase then return buffer.readu8(self.firmwareROM,address-self.highROMBase) end
			if not self.a20 then address = band(address, 0xFFEFFFFF) end
			local offset = self.vga:linearOffset(address)
			if offset then return buffer.readu8(self.vga.linearMemory, offset) end
			if address >= 0xA0000 and address < 0xC0000 and self.vga:isGraphics() then return self.vga:readMemory(address) end
			return self.ram:read8(address) or 0xFF
		end,
		write8 = function(address, value)
			if self.a20 and not self.diagnostics and address+1<=self.ram.size and (address+1<=0xA0000 or address>=0x100000) then buffer.writeu8(self.ram.buffer,address,value);return true end
			if self.highROMBase and address>=self.highROMBase then return true end
			local original = address
			if not self.a20 then address = band(address, 0xFFEFFFFF) end
			local offset = self.vga:linearOffset(address)
			if offset then buffer.writeu8(self.vga.linearMemory, offset, value); self.vga.generation += 1; return true end
			if address >= 0xA0000 and address < 0xC0000 and self.vga:isGraphics() then self.vga:writeMemory(address, value); return true end
			if self.diagnostics and ((address == 0x3CFF and self.cpu and self.cpu.instructionCount > 1700000) or address == 0x967360 or original == 0x967360) and self.cpu then
				self.watchWrites[#self.watchWrites + 1] = string.format("%04X:%04X %08X -> %02X a20=%s", self.cpu.segments.cs, self.cpu.eip, original, value, tostring(self.a20))
				if #self.watchWrites > 64 then table.remove(self.watchWrites, 1) end
			end
			if address>=self.ram.size then return true end
			return self.ram:write8(address, value)
		end,
		onSoftwareInterrupt = function(vector, cpu) return self:softwareInterrupt(vector, cpu) end,
		ioRead = function(port, width) return self:readPort(port, width) end,
		ioWrite = function(port, width, value) return self:writePort(port, width, value) end,
	}, { segmented = true, legacy386 = options.legacy386 ~= false, cr0 = 0, cs = 0, ds = 0, es = 0, ss = 0, eip = 0x7C00,
		defaultOperandSize = 16, defaultAddressSize = 16, stackAddressSize = 16,
		eflags = 0x202, traceBytes = self.diagnostics, maxRepIterationsPerStep = 4096,
		fastSpinLoops = options.fastSpinLoops ~= false, fastSumLoops = options.fastSumLoops ~= false,
		fastRepStrings = options.fastRepStrings ~= false, reuseDecodeState = true, maxSpinInstructions = 4096 })
	for _, name in ipairs({ "cs", "ds", "es", "ss", "fs", "gs" }) do self.cpu:loadSegment(name, 0) end
	self.cpu:setReg16(CPU.REG.ESP, 0x7C00)
	self.cpu:setReg8(2, 0x80) -- DL: first fixed disk
	self.cpu.idtr = { base = 0, limit = 0x3FF }
	if self.firmware then
		assert(#options.systemFirmware<=0x40000,"PC firmware ROM too large")
		self.ram:load(0x100000-#options.systemFirmware,options.systemFirmware)
		if options.videoFirmware then self.ram:load(0xC0000,options.videoFirmware) end
		self.cpu:loadSegment("cs",0xF000);self.cpu.eip=0xFFF0
		self.phase="firmware"
	else
		self:initializeBIOS()
		self:loadSectors(0, 1, 0x7C00)
		self.phase = "mbr"
	end
	return self
end

function PC:emit(text)
	self.transcript ..= text
	if #self.transcript > 262144 then self.transcript = self.transcript:sub(-262144) end
	if self.onOutput then self.onOutput(text) end
end

function PC:initializeBIOS()
	local ram = self.ram.buffer
	for vector = 0, 255 do
		buffer.writeu16(ram, vector * 4, 0x1000 + vector * 8)
		buffer.writeu16(ram, vector * 4 + 2, 0xF000)
		buffer.writeu8(ram, 0xF1000 + vector * 8, 0xCD)
		buffer.writeu8(ram, 0xF1001 + vector * 8, 0xFE)
		buffer.writeu8(ram, 0xF1002 + vector * 8, 0xCF)
	end
	-- Timer/keyboard EOIs must be visible guest OUT instructions. In VM86,
	-- Windows owns a virtual PIC and cannot observe a host-side PIC mutation.
	buffer.writeu8(ram,0xF1042,0xE9);buffer.writeu16(ram,0xF1043,0x3500-0x1045)
	buffer.writestring(ram,0xF3500,string.char(0xCD,0x1C,0x50,0xB0,0x20,0xE6,0x20,0x58,0xCF))
	buffer.writeu8(ram,0xF104A,0xE9);buffer.writeu16(ram,0xF104B,0x3510-0x104D)
	buffer.writestring(ram,0xF3510,string.char(0x50,0xE4,0x60,0xB0,0x20,0xE6,0x20,0x58,0xCF))
	buffer.writestring(ram, 0xFFFF5, "01/01/95")
	buffer.writeu8(ram, 0xFFFFE, 0xFC)
	buffer.writeu16(ram, 0x410, 0x0024)
	buffer.writeu16(ram, 0x413, 640)
	buffer.writeu16(ram, 0x44A, 80)
	buffer.writeu16(ram, 0x44C, 4000)
	buffer.writeu8(ram, 0x449, 3)
	buffer.writeu8(ram, 0x484, 24)
	buffer.writeu16(ram, 0x485, 16)
	buffer.writeu8(ram, 0x475, 1)
	buffer.writeu16(ram, 0x41A, 0x1E)
	buffer.writeu16(ram, 0x41C, 0x1E)
	buffer.writeu16(ram, 0x480, 0x1E)
	buffer.writeu16(ram, 0x482, 0x3E)
	-- Fixed-disk parameter table: 914 cylinders, 16 heads, 63 sectors/track.
	buffer.writeu16(ram, 0x104, 0x2000)
	buffer.writeu16(ram, 0x106, 0xF000)
	buffer.writeu16(ram, 0xF2000, 914)
	buffer.writeu8(ram, 0xF2002, 16)
	buffer.writeu8(ram, 0xF200E, 63)
end

function PC:transferGuestBuffer(cpu, address, data, offset, count, toGuest)
	-- BIOS buffers are linear guest addresses, including when Windows calls
	-- the ROM in a paged VM86 task. Translate every page before copying any
	-- bytes; copying directly into physical RAM bypasses Windows mappings.
	local chunks, done = {}, 0
	while done < count do
		local linear = address + done
		local size = math.min(count - done, 4096 - band(linear, 4095))
		local physical = cpu:translateLinear(linear, toGuest and "write" or "read")
		if not self.a20 then physical = band(physical, 0xFFEFFFFF) end
		chunks[#chunks + 1] = { physical, size, done }
		done += size
	end
	for _, chunk in ipairs(chunks) do
		local physical, size, position = chunk[1], chunk[2], offset + chunk[3]
		if physical + size <= self.ram.size and (physical + size <= 0xA0000 or physical >= 0xC0000 or not self.vga:isGraphics()) then
			if toGuest then buffer.copy(self.ram.buffer, physical, data, position, size)
			else buffer.copy(data, position, self.ram.buffer, physical, size) end
		else
			for i = 0, size - 1 do
				if toGuest then cpu:physicalWrite8(physical + i, buffer.readu8(data, position + i))
				else buffer.writeu8(data, position + i, cpu:physicalRead8(physical + i)) end
			end
		end
	end
end

function PC:loadSectors(lba, count, address, guestCPU)
	if lba < 0 or count < 0 or (lba + count) * 512 > self.disk.logicalBytes
		or address < 0 or address + count * 512 > (guestCPU and 0x100000000 or self.ram.size) then return false end
	local target = guestCPU and buffer.create(count * 512) or self.ram.buffer
	local targetOffset = guestCPU and 0 or address
	if not self.disk:readInto(target, targetOffset, lba * 512, count * 512) then return false end
	for i = 0, count - 1 do
		local written = self.writes[lba + i]
		if written then buffer.copy(target, targetOffset + i * 512, written) end
	end
	if guestCPU then self:transferGuestBuffer(guestCPU, address, target, 0, count * 512, true) end
	self.reads += count
	if lba == 63 then self.phase = "partition-boot-sector" end
	return true
end

function PC:vbeBIOS(cpu)
	local function done(ok) cpu:setReg16(0, ok and 0x004F or 0x014F); return true end
	local function clear(address, count) for i = 0, count - 1 do cpu:write8(address + i, 0) end end
	local function text(address, value) for i = 1, #value do cpu:write8(address + i - 1, value:byte(i)) end end
	local ax, bx = cpu:getReg16(0), cpu:getReg16(3)
	local vga, address = self.vga, cpu:segmentAddress("es", cpu:getReg16(7))
	if ax == 0x4F00 then
		clear(address, 512); text(address, "VESA"); cpu:write16(address + 4, 0x0200)
		cpu:write32(address + 6, 0xF0002500); cpu:write32(address + 14, 0xF0002400); cpu:write16(address + 18, 128)
		local modes = {}; for mode in pairs(vga.vbeModes) do modes[#modes + 1] = mode end; table.sort(modes)
		for index, mode in ipairs(modes) do buffer.writeu16(self.ram.buffer, 0xF2400 + (index - 1) * 2, mode) end
		buffer.writeu16(self.ram.buffer, 0xF2400 + #modes * 2, 0xFFFF)
		buffer.writestring(self.ram.buffer, 0xF2500, "RoEMU local VBE 2.0\0")
		return done(true)
	elseif ax == 0x4F01 then
		local mode = vga.vbeModes[band(cpu:getReg16(1), 0x3FFF)]
		if not mode then return done(false) end
		local bytes = math.ceil(mode.bpp / 8)
		clear(address, 256); cpu:write16(address, 0x009B); cpu:write8(address + 2, 7)
		cpu:write16(address + 4, 64); cpu:write16(address + 6, 64); cpu:write16(address + 8, 0xA000)
		cpu:write16(address + 16, mode.width * bytes); cpu:write16(address + 18, mode.width); cpu:write16(address + 20, mode.height)
		cpu:write8(address + 22, 8); cpu:write8(address + 23, 16); cpu:write8(address + 24, 1)
		cpu:write8(address + 25, mode.bpp); cpu:write8(address + 26, 1); cpu:write8(address + 27, mode.bpp == 8 and 4 or 6)
		cpu:write8(address + 29, math.min(255, math.floor(buffer.len(vga.linearMemory) / (mode.width * mode.height * bytes)) - 1))
		if mode.bpp > 8 then
			local mask = mode.bpp == 15 and { 5,10,5,5,5,0,1,15 } or mode.bpp == 16 and { 5,11,6,5,5,0,0,0 } or { 8,16,8,8,8,0,mode.bpp == 32 and 8 or 0,24 }
			for index, value in ipairs(mask) do cpu:write8(address + 30 + index, value) end
		end
		cpu:write32(address + 40, vga.linearBase)
		return done(true)
	elseif ax == 0x4F02 then
		local number = band(bx, 0x3FFF); local mode = vga.vbeModes[number]
		if not mode then return done(false) end
		vga:writeVBE(4, 0); vga:writeVBE(1, mode.width); vga:writeVBE(2, mode.height); vga:writeVBE(3, mode.bpp)
		vga:writeVBE(4, 1 + (band(bx, 0x4000) ~= 0 and 0x40 or 0) + (band(bx, 0x8000) ~= 0 and 0x80 or 0))
		self.vbeModeNumber, self.videoMode = number, number
		return done(true)
	elseif ax == 0x4F03 then cpu:setReg16(3, vga:vbeEnabled() and bor(self.vbeModeNumber or 0x105, band(vga.vbe[4], 0x40) ~= 0 and 0x4000 or 0) or self.videoMode); return done(true)
	elseif ax == 0x4F05 then
		if band(bx, 255) ~= 0 then return done(false) end
		if band(bx, 0xFF00) == 0 then vga:writeVBE(5, cpu:getReg16(2)) else cpu:setReg16(2, vga.vbe[5]) end
		return done(true)
	elseif ax == 0x4F06 then
		local bytes = math.ceil(vga.vbe[3] / 8)
		if band(bx, 255) == 0 then vga:writeVBE(6, cpu:getReg16(1))
		elseif band(bx, 255) == 2 then vga:writeVBE(6, math.floor(cpu:getReg16(1) / bytes)) end
		cpu:setReg16(3, vga.vbe[6] * bytes); cpu:setReg16(1, vga.vbe[6]); cpu:setReg16(2, vga:readVBE(7)); return done(true)
	elseif ax == 0x4F07 then
		if band(bx, 255) == 1 then cpu:setReg16(1, vga.vbe[8]); cpu:setReg16(2, vga.vbe[9])
		else vga:writeVBE(8, cpu:getReg16(1)); vga:writeVBE(9, cpu:getReg16(2)) end
		return done(true)
	elseif ax == 0x4F08 then
		if band(bx, 255) == 0 and rshift(bx, 8) ~= 6 then return done(false) end
		cpu:setReg8(7, 6); return done(true)
	elseif ax == 0x4F09 then
		local count, first = cpu:getReg16(1), cpu:getReg16(2)
		if first + count > 256 then return done(false) end
		for i = 0, count - 1 do
			for channel = 0, 2 do
				local offset = (first + i) * 3 + 2 - channel
				if band(bx, 255) == 1 then cpu:write8(address + i * 4 + channel, buffer.readu8(vga.palette, offset))
				else buffer.writeu8(vga.palette, offset, band(cpu:read8(address + i * 4 + channel), 63)) end
			end
		end
		vga.generation += 1; return done(true)
	end
	return done(false)
end

function PC:pciBIOS(cpu)
	local function done(ok) cpu:setReg8(4, ok and 0 or 0x86); cpu:setFlag(CPU.FLAG.CF, not ok); return true end
	local operation = cpu:getReg8(0)
	if operation == 1 then
		cpu:setReg8(0, 1); cpu:setReg16(3, 0x0210); cpu:setReg8(1, 0); cpu:setReg32(2, 0x20494350); return done(true)
	elseif operation == 2 or operation == 3 then
		if cpu:getReg16(6) ~= 0 then return done(false) end
		for devfn in pairs(self.pci.config) do
			local match = operation == 2 and self.pci:readConfig(devfn, 0, 16) == cpu:getReg16(2) and self.pci:readConfig(devfn, 2, 16) == cpu:getReg16(1)
				or operation == 3 and rshift(self.pci:readConfig(devfn, 8, 32), 8) == band(cpu:getReg32(1), 0xFFFFFF)
			if match then cpu:setReg16(3, devfn); return done(true) end
		end
		return done(false)
	elseif operation >= 8 and operation <= 13 then
		local devfn, offset = cpu:getReg16(3), cpu:getReg16(7)
		if not self.pci.config[devfn] then return done(false) end
		local width = ({ [8] = 8, [9] = 16, [10] = 32, [11] = 8, [12] = 16, [13] = 32 })[operation]
		if operation < 11 then
			local value = self.pci:readConfig(devfn, offset, width)
			if width == 8 then cpu:setReg8(1, value) elseif width == 16 then cpu:setReg16(1, value) else cpu:setReg32(1, value) end
		else self.pci:writeConfig(devfn, offset, width, cpu:getReg32(1)) end
		return done(true)
	end
	return done(false)
end

function PC:softwareInterrupt(vector, cpu)
	if self.firmware then return false end
	if not cpu:isRealMode() then return false end
	if vector == 0xFE and cpu.segments.cs == 0xF000 and self.biosATAPending
		and self.biosATAPending.completions[cpu.eip] then
		local pending = self.biosATAPending
		self.biosATAPending = nil
		self.biosATACompleted += 1
		if cpu:getFlag(CPU.FLAG.CF) then self.biosATAErrors += 1 end
		local saved = cpu:segmentAddress("ss", cpu:getReg16(4) + 4)
		cpu:write16(saved, bor(band(cpu:read16(saved), 0xFFFE), cpu:getFlag(CPU.FLAG.CF) and 1 or 0))
		if not cpu:getFlag(CPU.FLAG.CF) and pending.read then self.reads += pending.count end
		return true
	end
	local trampoline = vector == 0xFE and cpu.segments.cs == 0xF000
	if band(cpu.cr0, 1) ~= 0 and not trampoline then return false end
	if not trampoline and (vector==8 or vector==9) then return false end
	if trampoline then vector = math.floor((cpu.eip - 0x1002) / 8) end
	if not trampoline and cpu:read16(vector * 4 + 2) ~= 0xF000 then return false end
	if trampoline and vector == 0x13 and band(cpu.cr0, 1) ~= 0 and self:beginBIOSATA(cpu) then return true end
	local handled = self:bios(vector, cpu)
	if handled and trampoline then
		local saved = cpu:segmentAddress("ss", cpu:getReg16(4) + 4)
		local old = cpu:read16(saved)
		-- Hardware IRQ chains must restore the interrupted FLAGS unchanged.
		-- Only documented BIOS result flags belong in a chained IRET frame.
		local mask = (vector == 0x13 or vector == 0x15 or vector == 0x1A or vector >= 0x20) and 1
			or vector == 0x16 and 0x40 or 0
		cpu:write16(saved, bor(band(old, bit.bnot(mask)), band(cpu.eflags, mask)))
	end
	return handled
end

function PC:beginBIOSATA(cpu)
	local ah = cpu:getReg8(4)
	if self.biosATAPending or cpu:getReg8(2) ~= 0x80 or (ah ~= 2 and ah ~= 3 and ah ~= 0x42 and ah ~= 0x43) then return false end
	local lba, count, address
	if ah == 2 or ah == 3 then
		local cx = cpu:getReg16(1)
		local cylinder = bor(rshift(cx, 8), lshift(band(cx, 0xC0), 2))
		lba = (cylinder * 16 + cpu:getReg8(6)) * 63 + band(cx, 63) - 1
		count, address = cpu:getReg8(0), cpu:segmentAddress("es", cpu:getReg16(3))
	else
		local dap = cpu:segmentAddress("ds", cpu:getReg16(6))
		if cpu:read32(dap + 12) ~= 0 then return false end
		lba, count = cpu:read32(dap + 8), cpu:read16(dap + 2)
		address = cpu:read16(dap + 6) * 16 + cpu:read16(dap + 4)
	end
	if count < 1 or count > 256 or lba < 0 or (lba + count) * 512 > self.disk.logicalBytes
		or address < 0 or address + count * 512 > 0x100000 then return false end
	-- Execute a small 16-bit ROM PIO routine. Its IN/OUT instructions pass
	-- through the guest's TSS I/O bitmap: Win95 observes BIOS disk traffic
	-- in VM86 mode to associate the DOS drive with the IDE controller.
	local code, labels, fixes = {}, {}, {}
	local function emit(...) for _, byte in ipairs({...}) do code[#code + 1] = byte end end
	local function word(value) emit(band(value,255),band(rshift(value,8),255)) end
	local function movDX(port) emit(0xBA); word(port) end
	local function out(value) emit(0xB0,band(value,255),0xEE) end
	local function label(name) labels[name] = #code end
	local function jump(opcode,name) emit(0x0F,opcode); fixes[#fixes+1] = {#code+1,name}; word(0) end
	local read = ah == 2 or ah == 0x42
	emit(0x66,0x9C,0x66,0x60,0x06,0x1E,0xFA) -- PUSHFD/PUSHAD/ES/DS/CLI
	movDX(0x3F6); out(2) -- Polling BIOS I/O, IRQ14 disabled until completion.
	movDX(0x1F7); emit(0xEC)
	movDX(0x1F6); out(0xE0 + band(rshift(lba,24),15))
	movDX(0x1F2); out(count)
	for index=0,2 do emit(0x42); out(rshift(lba,index*8)) end
	movDX(0x1F7); out(read and 0x20 or 0x30)
	emit(0xB8); word(math.floor(address/16)); emit(0x8E,read and 0xC0 or 0xD8)
	emit(0xBD); word(count)
	label("sector")
	movDX(0x1F7)
	emit(0xB9); word(0xFFFF)
	label("poll")
	emit(0x49); jump(0x84,"error")
	emit(0xEC,0xA8,1); jump(0x85,"error")
	emit(0xA8,0x80); jump(0x85,"poll")
	emit(0xA8,8); jump(0x84,"poll")
	emit(read and 0xBF or 0xBE); word(address%16)
	emit(0xB9); word(256); movDX(0x1F0); emit(0xFC,0xF3,read and 0x6D or 0x6F)
	emit(0x4D); jump(0x84,"success")
	emit(0x8C,read and 0xC0 or 0xD8,0x83,0xC0,0x20,0x8E,read and 0xC0 or 0xD8)
	jump(0x85,"sector") -- Segment increment cannot set ZF for conventional buffers.
	label("success")
	movDX(0x1F7); emit(0xEC)
	movDX(0xA0); out(0x66); movDX(0x20); out(0x62)
	movDX(0x3F6); out(0)
	emit(0x1F,0x07,0x66,0x61,0x66,0x9D,0xB4,0,0xF8,0xCD,0xFE)
	local success = 0x4000 + #code
	emit(0xCF)
	label("error")
	movDX(0xA0); out(0x66); movDX(0x20); out(0x62)
	movDX(0x3F6); out(0)
	emit(0x1F,0x07,0x66,0x61,0x66,0x9D,0xB4,0x20,0xF9,0xCD,0xFE)
	local failure = 0x4000 + #code
	emit(0xCF)
	for _, fix in ipairs(fixes) do
		local displacement = labels[fix[2]] - (fix[1]+1)
		code[fix[1]],code[fix[1]+1] = band(displacement,255),band(rshift(displacement,8),255)
	end
	for i,byte in ipairs(code) do buffer.writeu8(self.ram.buffer,0xF4000+i-1,byte) end
	self.biosATAPending = { read=read,count=count,completions={[success]=true,[failure]=true} }
	self.biosATAStarted += 1
	local key=string.format("13:%04X",cpu:getReg16(0))
	self.biosCounts[key]=(self.biosCounts[key] or 0)+1
	cpu.eip=0x4000
	return true
end

function PC:bios(vector, cpu)
	local ah, al = cpu:getReg8(4), cpu:getReg8(0)
	local ax = cpu:getReg16(0)
	local key = string.format("%02X:%04X", vector, ax)
	self.biosCounts[key] = (self.biosCounts[key] or 0) + 1
	self.lastBIOS[#self.lastBIOS + 1] = key
	if #self.lastBIOS > 32 then table.remove(self.lastBIOS, 1) end
	local function carry(value) cpu:setFlag(CPU.FLAG.CF, value) end
	if vector == 0x13 then
		if cpu:getReg8(2) ~= 0x80 then cpu:setReg8(4, 1); carry(true); return true end
		if ah == 0 or ah == 1 then cpu:setReg8(4, 0); carry(false)
		elseif ah == 8 then
			cpu:setReg16(1, bor(lshift(band(913, 0xFF), 8), 63, rshift(band(913, 0x300), 2)))
			cpu:setReg8(6, 15); cpu:setReg8(2, 1); cpu:setReg8(4, 0); carry(false)
		elseif ah == 0x15 then
			cpu:setReg8(4, 3); cpu:setReg16(1, rshift(self.disk.logicalBytes / 512, 16))
			cpu:setReg16(2, self.disk.logicalBytes / 512); carry(false)
		elseif ah == 0x41 then
			cpu:setReg16(3, 0xAA55); cpu:setReg16(1, 0x0007); cpu:setReg8(4, 0x30); carry(false)
		elseif ah == 2 or ah == 3 or ah == 0x42 or ah == 0x43 then
			local lba, count, address
			if ah == 2 or ah == 3 then
				local cx = cpu:getReg16(1)
				local cylinder = bor(rshift(cx, 8), lshift(band(cx, 0xC0), 2))
				lba = (cylinder * 16 + cpu:getReg8(6)) * 63 + band(cx, 63) - 1
				count = al
				address = cpu:segmentAddress("es", cpu:getReg16(3))
			else
				local dap = cpu:segmentAddress("ds", cpu:getReg16(6))
				count = cpu:read16(dap + 2)
				address = cpu:read16(dap + 6) * 16 + cpu:read16(dap + 4)
				lba = cpu:read32(dap + 8)
				if cpu:read32(dap + 12) ~= 0 then carry(true); cpu:setReg8(4, 1); return true end
			end
			local ok
			if ah == 2 or ah == 0x42 then
				ok = self:loadSectors(lba, count, address, cpu)
			else
				ok = lba >= 0 and count > 0 and (lba + count) * 512 <= self.disk.logicalBytes
				if ok then
					for i = 0, count - 1 do
						local value = buffer.create(512)
						self:transferGuestBuffer(cpu, address + i * 512, value, 0, 512, false)
						self.writes[lba + i] = value
					end
				end
			end
			cpu:setReg8(4, ok and 0 or 4); carry(not ok)
		elseif ah == 0x48 then
			local address = cpu:segmentAddress("ds", cpu:getReg16(6))
			cpu:write16(address, 0x1A); cpu:write16(address + 2, 2)
			cpu:write32(address + 4, 914); cpu:write32(address + 8, 16); cpu:write32(address + 12, 63)
			cpu:write32(address + 16, self.disk.logicalBytes / 512); cpu:write32(address + 20, 0)
			cpu:write16(address + 24, 512); cpu:setReg8(4, 0); carry(false)
		else cpu:setReg8(4, 1); carry(true) end
		return true
	elseif vector == 0x10 then
		if ah == 0x4F then return self:vbeBIOS(cpu) end
		if ah == 0x0E then
			local char = string.char(al)
			if al == 13 then self.cursorX = 0
			elseif al == 10 then self.cursorY = (self.cursorY + 1) % self.rows
			elseif al == 8 then self.cursorX = math.max(0, self.cursorX - 1)
			elseif al >= 32 then
				cpu:write16(0xB8000 + (self.cursorY * self.columns + self.cursorX) * 2, al + 0x700)
				self.cursorX += 1
				if self.cursorX >= self.columns then self.cursorX = 0; self.cursorY = (self.cursorY + 1) % self.rows end
			end
			self:emit(char)
		elseif ah == 0 then
			self.videoMode = band(al, 0x7F)
			self.vga:setMode(self.videoMode)
			cpu:write8(0x449, self.videoMode)
			self.cursorX, self.cursorY = 0, 0
		elseif ah == 0x0F then cpu:setReg8(4, self.columns); cpu:setReg8(0, self.videoMode); cpu:setReg8(7, 0)
		elseif ah == 2 then self.cursorX = cpu:getReg8(2); self.cursorY = cpu:getReg8(6)
		elseif ah == 3 then cpu:setReg16(2, self.cursorY * 256 + self.cursorX); cpu:setReg16(1, 0x0607)
		elseif ah == 5 then cpu:write8(0x462, al)
		elseif ah == 8 then cpu:setReg16(0, cpu:read16(0xB8000 + (self.cursorY * self.columns + self.cursorX) * 2))
		elseif ax == 0x1A00 then cpu:setReg8(0, 0x1A); cpu:setReg16(3, 8)
		elseif ah == 0x4F then cpu:setReg16(0, 0x014F)
		elseif ah == 0x12 then cpu:setReg8(7, 0); cpu:setReg8(3, 3)
		elseif ah == 0x06 or ah == 0x07 or ah == 0x09 or ah == 0x0A or ah == 0x0B or ah == 0x11 then
			-- Text-mode programming has no host side effects.
		else error(string.format("BIOS video service missing %04X", ax)) end
		return true
	elseif vector == 0x11 then cpu:setReg16(0, 0x24); return true
	elseif vector == 0x12 then cpu:setReg16(0, 640); return true
	elseif vector == 0x15 then
		if ah == 0xC2 then
			if al == 0 then self.mouseEnabled = cpu:getReg8(7) ~= 0
			elseif al == 1 then cpu:setReg16(3, 0x00AA)
			elseif al == 4 then cpu:setReg8(7, 0)
			elseif al == 6 then cpu:setReg16(3, 0); cpu:setReg16(1, 0)
			elseif al == 7 then self.mouseHandler = { segment = cpu.segments.es, offset = cpu:getReg16(3) } end
			cpu:setReg8(4, 0); carry(false)
		elseif ah == 0x88 then cpu:setReg16(0, math.min(0xFC00, self.ram.size / 1024 - 1024)); carry(false)
		elseif ax == 0xE801 then
			local low = math.min(15 * 1024, self.ram.size / 1024 - 1024)
			local high = math.max(0, (self.ram.size - 16 * 1024 * 1024) / 65536)
			cpu:setReg16(0, low); cpu:setReg16(3, high); cpu:setReg16(1, low); cpu:setReg16(2, high); carry(false)
		elseif cpu:getReg32(0) == 0xE820 then
			local regions = { { 0, 0x9FC00, 1 }, { 0x9FC00, 0x60400, 2 }, { 0x100000, self.ram.size - 0x100000, 1 } }
			local i = cpu:getReg32(3) + 1
			local region = regions[i]
			if not region then carry(true) else
				local address = cpu:segmentAddress("es", cpu:getReg16(7))
				cpu:write32(address, region[1]); cpu:write32(address + 4, 0)
				cpu:write32(address + 8, region[2]); cpu:write32(address + 12, 0); cpu:write32(address + 16, region[3])
				cpu:setReg32(0, 0x534D4150); cpu:setReg32(1, 20); cpu:setReg32(3, i == #regions and 0 or i); carry(false)
			end
		elseif ah == 0x24 then
			if al == 0 or al == 1 then self.a20 = al == 1
			elseif al == 2 then cpu:setReg8(0, self.a20 and 1 or 0)
			elseif al == 3 then cpu:setReg16(3, 3) end
			cpu:setReg8(4, 0); carry(false)
		elseif ah == 0xC0 then
			cpu:loadSegment("es", 0xF000); cpu:setReg16(3, 0x2100)
			cpu:write16(0xF2100, 8); cpu:write8(0xF2102, 0xFC); cpu:write8(0xF2105, 0x70); carry(false)
		else cpu:setReg8(4, 0x86); carry(true) end
		return true
	elseif vector == 0x16 then
		if ah == 1 or ah == 0x11 then
			cpu:setFlag(CPU.FLAG.ZF, #self.keyboard == 0)
			if #self.keyboard > 0 then cpu:setReg16(0, self.keyboard[1]) end
		elseif ah == 0 or ah == 0x10 then
			if #self.keyboard == 0 then
				self.waitingKeyboard = true
				cpu.eip = cpu._instructionStart
			else cpu:setReg16(0, table.remove(self.keyboard, 1)); self.waitingKeyboard = false end
		elseif ah == 2 or ah == 0x12 then cpu:setReg16(0, 0)
		elseif ah == 5 then self.keyboard[#self.keyboard + 1] = cpu:getReg16(1); cpu:setReg8(0, 0)
		else error(string.format("BIOS keyboard missing %04X", ax)) end
		return true
	elseif vector == 0x1A then
		if ah == 0xB1 then return self:pciBIOS(cpu) end
		if ah == 0 then
			cpu:setReg16(1, rshift(self.ticks, 16)); cpu:setReg16(2, self.ticks); cpu:setReg8(0, 0); carry(false)
		elseif ah == 2 then cpu:setReg16(1, 0x1200); cpu:setReg16(2, 0); carry(false)
		elseif ah == 4 then cpu:setReg16(1, 0x1995); cpu:setReg16(2, 0x0824); carry(false)
		else carry(true) end
		return true
	elseif vector == 9 then
		return true
	elseif vector == 8 then
		self.ticks += 1
		cpu:write32(0x46C, self.ticks)
		return true
	elseif vector == 9 or vector == 0x1C then return true
	elseif vector == 0x17 then cpu:setReg8(4, 0x90); return true
	elseif vector == 0x14 then cpu:setReg16(0, 0x8000); return true
	elseif vector >= 0x20 then
		-- Uninstalled optional DOS/BIOS multiplex service. Report absence; do
		-- not fabricate a driver or a successful service result.
		if vector == 0x67 then cpu:setReg8(4, 0x80) end
		carry(true)
		return true
	end
	error(string.format("Unimplemented BIOS INT %02X AX=%04X at %04X:%04X", vector, ax, cpu.segments.cs, cpu.eip))
end

function PC:kbcReply(byte, auxiliary)
	self.kbcOutput[#self.kbcOutput + 1] = { byte = byte, auxiliary = auxiliary == true }
	if #self.kbcOutput == 1 and band(self.kbcConfig, auxiliary and 2 or 1) ~= 0 then self.pic:raise(auxiliary and 12 or 1) end
end

function PC:kbcDeviceWrite(value, auxiliary)
	local argument = auxiliary and self.mouseArgument or self.keyboardArgument
	if argument then
		if auxiliary then self.mouseArgument = nil else self.keyboardArgument = nil end
		self:kbcReply(0xFA, auxiliary)
		if argument == 0xF0 and not auxiliary then
			if value == 0 then self:kbcReply(self.keyboardScanSet, false) else self.keyboardScanSet = value end
		end
		return
	end
	if value == 0xEE and not auxiliary then self:kbcReply(0xEE, false); return end
	self:kbcReply(0xFA, auxiliary)
	if value == 0xFF then self:kbcReply(0xAA, auxiliary); if auxiliary then self:kbcReply(0, true) end
	elseif value == 0xF2 then
		if auxiliary then self:kbcReply(0, true) else self:kbcReply(0xAB, false); self:kbcReply(0x83, false) end
	elseif value == 0xF3 or value == 0xF0 or value == 0xED or value == 0xE8 then
		if auxiliary then self.mouseArgument = value else self.keyboardArgument = value end
	elseif auxiliary and (value == 0xE9 or value == 0xEB) then
		self:kbcReply(value == 0xE9 and 0x20 or 8, true); self:kbcReply(0, true); self:kbcReply(0, true)
	elseif value == 0xF4 then if auxiliary then self.mouseEnabled = true else self.keyboardEnabled = true end
	elseif value == 0xF5 then if auxiliary then self.mouseEnabled = false else self.keyboardEnabled = false end end
end

local scanCharacters = "\27" .. "1234567890-=\8\tqwertyuiop[]\13" .. "\0as" .. "dfghjkl;'`" .. "\0\\zxcvbnm,./"
local shiftedKeys={ ["!"]="1",["@"]="2",["#"]="3",["$"]="4",["%"]="5",["^"]="6",["&"]="7",["*"]="8",["("]="9",[")"]="0",
	["_"]="-",["+"]="=",["{"]="[",["}"]="]",["|"]="\\",[":"]=";",['"']="'",["<"]=",",[">"]=".",["?"]="/",["~"]="`" }

function PC:queueKey(scan,down,extended)
	if type(scan)~="number" or scan%1~=0 or scan<1 or scan>0x7F or type(down)~="boolean" then return false end
	if self.keyboardEnabled==false or #self.deviceInput>=4096 then return false end
	self.deviceInput[#self.deviceInput+1]={scan=scan,down=down,extended=extended==true}
	return true
end

function PC:serviceInput()
	if #self.kbcOutput>0 or #self.deviceInput==0 then return end
	local now=self:pitNow()
	if now<self.nextInputTick then return end
	local item=self.deviceInput[1]
	if band(self.kbcConfig,item.mouse and 0x20 or 0x10)~=0 then return end
	if item.mouse then
		for _,byte in ipairs(item.bytes) do self:kbcReply(byte,true) end
	else
		local key=item.scan+(item.extended and 0x100 or 0)
		local pressed=self.keyHeldTicks[key]
		-- Keep synthesized key taps long enough for the guest's deferred key
		-- processing, rather than making and releasing a key in one host slice.
		if not item.down and pressed and now-pressed<23864 then return end
		if item.down then self.keyHeldTicks[key]=now else self.keyHeldTicks[key]=nil end
		if item.extended then self:kbcReply(0xE0,false) end
		self:kbcReply(item.scan+(item.down and 0 or 0x80),false)
	end
	table.remove(self.deviceInput,1)
	self.nextInputTick=now+(item.mouse and 1194 or 23864)
end

function PC:queueMouse(dx,dy,buttons)
	if not self.mouseEnabled or band(self.kbcConfig,0x20)~=0 then return false end
	dx,dy=math.clamp(math.round(dx),-255,255),math.clamp(-math.round(dy),-255,255)
	if #self.deviceInput>=4096 then return false end
	self.deviceInput[#self.deviceInput+1]={mouse=true,bytes={8+band(buttons or 0,7)+(dx<0 and 0x10 or 0)+(dy<0 and 0x20 or 0),band(dx,255),band(dy,255)}}
	return true
end

function PC:pointerPort()
	local cpu=self.cpu
	if cpu:getReg32(0)~=0x564D5868 then return 0xFFFFFFFF end
	local command=band(cpu:getReg32(1),0xFFFF)
	local argument=cpu:getReg32(3)
	if command==10 then cpu:setReg32(3,0x564D5868);return 6
	elseif command==40 then return self.pointerEnabled and #self.pointerQueue or 0xFFFF0000
	elseif command==39 then
		local words={0,0,0,0}
		for i=1,math.min(argument,4,#self.pointerQueue) do words[i]=table.remove(self.pointerQueue,1) end
		cpu:setReg32(3,words[2]);cpu:setReg32(1,words[3]);cpu:setReg32(2,words[4])
		if #self.pointerQueue==0 then self.pointerTailMove=false end
		return words[1]
	elseif command==41 then
		if argument==0x45414552 then
			self.pointerEnabled=true;table.clear(self.pointerQueue)
			self.pointerQueue[1]=0x3442554A;self.pointerTailMove=false
		elseif argument==0xF5 then
			self.pointerEnabled=false;self.pointerAbsolute=false;table.clear(self.pointerQueue)
		elseif argument==0x53424152 then self.pointerAbsolute=true
		elseif argument==0x4C455252 then self.pointerAbsolute=false end
		return 0
	end
	return 0xFFFFFFFF
end

function PC:queuePointer(x,y,buttons)
	x,y=math.clamp(math.round(x),0,65535),math.clamp(math.round(y),0,65535)
	buttons=band(buttons or 0,7)
	local previousX,previousY=self.pointerX,self.pointerY
	local move=self.pointerButtons==buttons
	self.pointerX,self.pointerY,self.pointerButtons=x,y,buttons
	if not (self.pointerEnabled and self.pointerAbsolute) then
		local width,height=self.vga.vbe[1],self.vga.vbe[2]
		return self:queueMouse(previousX and (x-previousX)*width/65535 or 0,previousY and (y-previousY)*height/65535 or 0,buttons)
	end
	if not self.mouseEnabled or band(self.kbcConfig,0x20)~=0 then return false end
	local queue=self.pointerQueue
	if move and self.pointerTailMove and #queue>=4 then
		queue[#queue-2],queue[#queue-1]=x,y
	else
		-- Keep button edges in order; collapse only consecutive motion packets.
		if #queue>1020 then return false end
		local flags=(band(buttons,1)~=0 and 0x20 or 0)+(band(buttons,2)~=0 and 0x10 or 0)+(band(buttons,4)~=0 and 8 or 0)
		queue[#queue+1]=flags;queue[#queue+1]=x;queue[#queue+1]=y;queue[#queue+1]=0
		self.pointerTailMove=move
	end
	local tail=self.deviceInput[#self.deviceInput]
	if move and tail and tail.pointerMove then return true end
	local accepted=self:queueMouse(0,0,buttons)
	if accepted then self.deviceInput[#self.deviceInput].pointerMove=move end
	return accepted
end

function PC:queueTextByte(byte)
	if byte == 10 then byte = 13 elseif byte == 127 then byte = 8 end
	local character = string.char(byte)
	local lower = string.lower(character)
	local control=byte>=1 and byte<=26 and byte~=8 and byte~=9 and byte~=13
	if control then lower=string.char(byte+96) end
	local base=shiftedKeys[character] or lower
	local scan = scanCharacters:find(base, 1, true) or (byte == 32 and 0x39 or 0)
	self.keyboard[#self.keyboard + 1] = scan * 256 + byte
	if scan > 0 then
		local shift = not control and (lower ~= character or shiftedKeys[character]~=nil)
		if control then self:queueKey(0x1D,true,false) end
		if shift then self:queueKey(0x2A,true,false) end
		self:queueKey(scan,true,false);self:queueKey(scan,false,false)
		if shift then self:queueKey(0x2A,false,false) end
		if control then self:queueKey(0x1D,false,false) end
	end
end

function PC:pitNow()
	return (self.realtimeClock and self.pitClockTicks or self.cpu.instructionCount * self.pitTicksPerInstruction) + self.pitIdleTicks
end

function PC:pitCount(channel)
	local elapsed = channel.gate and math.floor(math.max(0, self:pitNow() - channel.loaded)) or 0
	if channel.mode == 3 then return band(channel.reload - (elapsed * 2) % channel.reload, 0xFFFF) end
	if channel.mode == 2 then return band(channel.reload - elapsed % channel.reload, 0xFFFF) end
	return band(channel.reload - elapsed, 0xFFFF)
end

function PC:pitOutput(channel)
	if not channel.gate and (channel.mode == 2 or channel.mode == 3) then return true end
	local elapsed = math.max(0, self:pitNow() - channel.loaded)
	if channel.mode == 3 then return elapsed % channel.reload < math.ceil(channel.reload / 2) end
	if channel.mode == 2 then return elapsed % channel.reload ~= channel.reload - 1 end
	return elapsed >= channel.reload
end

function PC:pitRead(index)
	local channel = self.pitChannels[index]
	if channel.status ~= nil then local status = channel.status; channel.status = nil; return status end
	local count = channel.latched or self:pitCount(channel)
	local high = channel.access == 2 or (channel.access == 3 and (channel.latched ~= nil and channel.latchHigh or channel.latched == nil and channel.readHigh))
	local value = high and rshift(count, 8) or band(count, 255)
	if channel.latched ~= nil then
		if channel.access ~= 3 or high then channel.latched = nil; channel.latchHigh = false else channel.latchHigh = true end
	elseif channel.access == 3 then channel.readHigh = not channel.readHigh end
	return value
end

function PC:pitWrite(port, value)
	if port == 0x43 then
		local index, access = rshift(value, 6), band(rshift(value, 4), 3)
		local function latch(channel)
			if channel.latched == nil then channel.latched = self:pitCount(channel); channel.latchHigh = false end
		end
		if index == 3 then
			for selected = 0, 2 do
				local channel = self.pitChannels[selected]
				if band(value, lshift(2, selected)) ~= 0 then
					if band(value, 0x20) == 0 then latch(channel) end
					if band(value, 0x10) == 0 and channel.status == nil then
						channel.status = (self:pitOutput(channel) and 0x80 or 0) + channel.access * 16 + channel.mode * 2
					end
				end
			end
		else
			local channel = self.pitChannels[index]
			if access == 0 then latch(channel) else
				channel.access, channel.mode = access, band(rshift(value, 1), 7)
				if channel.mode >= 6 then channel.mode -= 4 end
				channel.readHigh, channel.writeHigh = false, false
				channel.latched, channel.status = nil, nil
			end
		end
	else
		local channel = self.pitChannels[port - 0x40]
		local count = value
		if channel.access == 2 then count *= 256
		elseif channel.access == 3 then
			if not channel.writeHigh then channel.low = value; channel.writeHigh = true; return end
			count = channel.low + value * 256; channel.writeHigh = false
		end
		channel.reload = count == 0 and 65536 or count
		channel.loaded, channel.irqCycle = self:pitNow(), 0
	end
end

function PC:readPort(port, width)
	self.portsRead[port] = (self.portsRead[port] or 0) + 1
	if port==0x5658 and width==32 then return self:pointerPort() end
	if port >= 0xCF8 and port <= 0xCFF then return self.pci:readPort(port, width) end
	if port==0x4D0 or port==0x4D1 then return self.portState[port] or 0 end
	if port == 0x1CE then return self.vga.vbeIndex elseif port == 0x1CF then return self.vga:readVBE(self.vga.vbeIndex) end
	if (port >= 0x1F0 and port <= 0x1F7) or port == 0x3F6 then return self.ata:readPort(port, width) end
	if port >= 0x3B0 and port <= 0x3DF then
		if width > 8 then
			local result = 0
			for offset = 0, width / 8 - 1 do result += self:readPort(port + offset, 8) * 2 ^ (offset * 8) end
			return result
		end
		local value = self.vga:readPort(port)
		if value ~= nil then return value end
	end
	if port == 0x92 then return self.a20 and 2 or 0 end
	if port == 0x20 or port == 0x21 or port == 0xA0 or port == 0xA1 then return self.pic:read(port) end
	if port == 0x3C9 then
		local value = buffer.readu8(self.palette, self.dacRead % 768)
		self.dacRead = (self.dacRead + 1) % 768
		return value
	end
	if port == 0x64 then return 4 + (#self.kbcOutput > 0 and (self.kbcOutput[1].auxiliary and 0x21 or 1) or 0) end
	if port == 0x60 then
		local item = table.remove(self.kbcOutput, 1)
		local nextItem = self.kbcOutput[1]
		if nextItem and band(self.kbcConfig, nextItem.auxiliary and 2 or 1) ~= 0 then self.pic:raise(nextItem.auxiliary and 12 or 1) end
		return item and item.byte or 0
	end
	if port == 0x3DA then self.retrace = not self.retrace; return self.retrace and 9 or 0 end
	if port == 0x61 then
		self.refresh = not self.refresh
		return bor(band(self.portState[port] or 0, 15), self.refresh and 0x10 or 0, self:pitOutput(self.pitChannels[2]) and 0x20 or 0)
	end
	if port == 0x71 then
		local index = band(self.portState[0x70] or 0, 0x7F)
		local seconds = math.floor(self:pitNow() / 1193182)
		local function encoded(value) return band(self.cmos[0x0B], 4) ~= 0 and value or math.floor(value / 10) * 16 + value % 10 end
		local time = { [0] = encoded(seconds % 60), [2] = encoded(math.floor(seconds / 60) % 60),
			[4] = encoded((12 + math.floor(seconds / 3600)) % 24), [6] = 5, [7] = 0x24, [8] = 8, [9] = 0x95 }
		if time[index] ~= nil then return time[index] end
		if index == 0x0C then local value = self.cmos[index]; self.cmos[index] = 0; return value end
		if self.cmos[index] ~= nil then return self.cmos[index] end
		local extended = math.min(0xFC00, self.ram.size / 1024 - 1024)
		return ({ [0x10] = 0, [0x12] = 0xF0, [0x19] = 47, [0x1B] = 0x92, [0x1C] = 3, [0x1D] = 16,
			[0x1E] = 255, [0x1F] = 255, [0x20] = 8, [0x21] = 0x92, [0x22] = 3, [0x23] = 63,
			[0x14] = 0x24, [0x15] = 0x80, [0x16] = 2, [0x17] = band(extended, 255), [0x18] = rshift(extended, 8),
			[0x30] = band(extended, 255), [0x31] = rshift(extended, 8), [0x32] = 0x19 })[band(index, 0x7F)] or 0
	end
	if port >= 0x40 and port <= 0x42 then return self:pitRead(port - 0x40) end
	-- An unconnected ISA/PCI I/O port floats high. Echoing previous writes
	-- makes Windows detect network/sound adapters that are not installed.
	return width == 8 and 0xFF or width == 16 and 0xFFFF or 0xFFFFFFFF
end

function PC:writePort(port, width, value)
	self.portsWritten[port] = value
	self.portState[port] = band(value, 0xFF)
	if port==0x4D0 or port==0x4D1 then self.portState[port]=band(value,port==0x4D0 and 0xF8 or 0xDE);return end
	if port >= 0xCF8 and port <= 0xCFF then self.pci:writePort(port, width, value); return end
	if port == 0x1CE then self.vga.vbeIndex = band(value, 0xFFFF); return elseif port == 0x1CF then self.vga:writeVBE(self.vga.vbeIndex, band(value, 0xFFFF)); return end
	if (port >= 0x1F0 and port <= 0x1F7) or port == 0x3F6 then self.ata:writePort(port, width, value); return end
	if port == 0x71 then
		local index = band(self.portState[0x70] or 0, 0x7F)
		if index ~= 0x0C and index ~= 0x0D then self.cmos[index] = band(value, 255) end
	end
	if port >= 0x3B0 and port <= 0x3DF then
		for offset = 0, width / 8 - 1 do self.vga:writePort(port + offset, band(rshift(value, offset * 8), 255)) end
		return
	end
	if port >= 0x40 and port <= 0x43 then self:pitWrite(port, band(value, 255)) end
	if port == 0x61 then
		local channel = self.pitChannels[2]
		local gate = band(value, 1) ~= 0
		if gate and not channel.gate then channel.loaded = self:pitNow() end
		channel.gate = gate
	end
	if port == 0x3C8 then self.dacWrite = band(value, 255) * 3 end
	if port == 0x3C7 then self.dacRead = band(value, 255) * 3 end
	if port == 0x3C9 then buffer.writeu8(self.palette, self.dacWrite % 768, band(value, 63)); self.dacWrite = (self.dacWrite + 1) % 768 end
	if port == 0x92 then self.a20 = band(value, 2) ~= 0 end
	if port == 0x64 then
		self.kbcCommand = value
		if value == 0xDD then self.a20 = false elseif value == 0xDF then self.a20 = true end
		if value == 0xD0 then self:kbcReply(self.a20 and 3 or 1, false)
		elseif value == 0x20 then self:kbcReply(self.kbcConfig, false)
		elseif value == 0xAA then self:kbcReply(0x55, false)
		elseif value == 0xAB or value == 0xA9 then self:kbcReply(0, false)
		elseif value == 0xAD then self.kbcConfig = bor(self.kbcConfig, 0x10)
		elseif value == 0xAE then self.kbcConfig = band(self.kbcConfig, 0xEF)
		elseif value == 0xA7 then self.kbcConfig = bor(self.kbcConfig, 0x20)
		elseif value == 0xA8 then self.kbcConfig = band(self.kbcConfig, 0xDF) end
	end
	if port == 0x60 then
		if self.kbcCommand == 0xD1 then self.a20 = band(value, 2) ~= 0
		elseif self.kbcCommand == 0x60 then self.kbcConfig = value
		elseif self.kbcCommand == 0xD2 or self.kbcCommand == 0xD3 then self:kbcReply(value, self.kbcCommand == 0xD3)
		else self:kbcDeviceWrite(value, self.kbcCommand == 0xD4) end
		self.kbcCommand = nil
	end
	if port == 0x60 or port == 0x64 or port == 0x92 then
		self.a20Trace[#self.a20Trace + 1] = string.format("%04X:%04X %02X=%02X a20=%s", self.cpu.segments.cs, self.cpu.eip, port, value, tostring(self.a20))
		if #self.a20Trace > 32 then table.remove(self.a20Trace, 1) end
	end
	if port == 0x20 or port == 0x21 or port == 0xA0 or port == 0xA1 then self.pic:write(port, band(value, 255)) end
	if port == 0xE9 or port == 0x3F8 or port==0x402 then self:emit(string.char(band(value, 0xFF))) end
end

function PC:syncClock()
	if not self.realtimeClock then return end
	local now=self.hostClock()
	self.pitClockTicks+=math.max(0,(now-self.pitLastHostTime)*1193182-(self.clockMinimum or 0))
	self.pitLastHostTime=now;self.clockMinimum=0
end

function PC:runSlice(deadline)
	self:syncClock()
	local result
	repeat
		for _=1,64 do
			result=self:step(true)
			if result.kind~="ok" or self.waitingKeyboard then break end
		end
		self:syncClock()
		if result.kind~="ok" or self.waitingKeyboard then break end
	until self.hostClock()>=deadline
	return result
end

function PC:step(deferClock)
	local cpu = self.cpu
	self:serviceInput()
	self.stepCalls += 1
	if self.diagnostics and cpu:getReg32(7) == 0x967360 and not self.targetTracing then self.targetTracing = 160 end
	if type(self.targetTracing) == "number" and self.targetTracing > 0 then
		self.targetTracing -= 1
		self.targetTrace[#self.targetTrace + 1] = string.format("%04X:%04X CX=%08X SI=%08X DI=%08X SP=%04X FL=%04X a20=%s target=%02X",
			cpu.segments.cs, cpu.eip, cpu:getReg32(1), cpu:getReg32(6), cpu:getReg32(7), cpu:getReg16(4), cpu.eflags, tostring(self.a20), self.ram:read8(0x967360) or 0)
	end
	if self.diagnostics or self.traceEveryStep or self.stepCalls % 1024 == 0 then
		self.traceIndex = self.traceIndex % 32 + 1
		local row = self.trace[self.traceIndex] or {}
		row.cs, row.ip, row.ax, row.cx, row.dx, row.bx = cpu.segments.cs, cpu.eip, cpu:getReg32(0), cpu:getReg32(1), cpu:getReg32(2), cpu:getReg32(3)
		row.ss, row.sp, row.ds, row.es = cpu.segments.ss, cpu:getReg32(4), cpu.segments.ds, cpu.segments.es
		row.si, row.di, row.bp, row.flags = cpu:getReg32(6), cpu:getReg32(7), cpu:getReg32(5), cpu.eflags
		self.trace[self.traceIndex] = row
	end
	local beforeInstructions = cpu.instructionCount
	local result = cpu:step()
	if self.realtimeClock then
		local minimum=(cpu.instructionCount-beforeInstructions)*self.pitTicksPerInstruction
		self.pitClockTicks+=minimum;self.clockMinimum=(self.clockMinimum or 0)+minimum
		if not deferClock then self:syncClock() end
	end
	if result.kind == "exception" then
		if self.onFault and self.onFault(result,cpu,self)==true then
			self.faultCheckpoint={cpuState=cpu:exportState(),ram=buffer.create(self.ram.size)}
			buffer.copy(self.faultCheckpoint.ram,0,self.ram.buffer)
		end
		local key = string.format("%d:%04X:%08X", result.vector, cpu.segments.cs, cpu.eip)
		self.exceptionCounts[key] = (self.exceptionCounts[key] or 0) + 1
		if result.vector==13 and cpu.cpl==3 and band(cpu.eflags,CPU.FLAG.VM)==0 and not self.userFaultSites[key] and #self.userFaults<32 then
			self.userFaultSites[key]=true
			local fault={cs=cpu.segments.cs,eip=cpu.eip,flags=cpu.eflags,detail=result.detail,errorCode=result.errorCode,
				registers=table.clone(cpu.regs),segments=table.clone(cpu.segments),csBase=cpu.segmentCache.cs.base,
				csLimit=cpu.segmentCache.cs.limit,ssBase=cpu.segmentCache.ss.base,ssBig=cpu.stackAddressSize==32,
				ldtr=table.clone(cpu.ldtr),gdtr=table.clone(cpu.gdtr)}
			fault.caches={};for name,entry in pairs(cpu.segmentCache) do fault.caches[name]=table.clone(entry) end
			fault.descriptors={}
			for name,selector in pairs(cpu.segments) do
				local tab=band(selector,4)~=0 and cpu.ldtr or cpu.gdtr
				pcall(function() fault.descriptors[name]={cpu:systemRead32(tab.base+band(selector,0xFFF8)),cpu:systemRead32(tab.base+band(selector,0xFFF8)+4)} end)
			end
			local oldCr2=cpu.cr2
			local bytes={}
			pcall(function() for i=-16,47 do bytes[#bytes+1]=string.format("%02X",cpu:systemRead8(cpu.segmentCache.cs.base+cpu.eip+i)) end end)
			fault.code=table.concat(bytes)
			bytes={}
			local sp=cpu.stackAddressSize==16 and cpu:getReg16(4) or cpu:getReg32(4)
			pcall(function() for i=0,127 do bytes[#bytes+1]=string.format("%02X",cpu:systemRead8(cpu.segmentCache.ss.base+sp+i)) end end)
			fault.stack=table.concat(bytes)
			cpu.cr2=oldCr2
			self.userFaults[#self.userFaults+1]=fault
			if self.onUserFault and self.onUserFault(fault)==true then
				self.faultCheckpoint={cpuState=cpu:exportState(),ram=buffer.create(self.ram.size)}
				buffer.copy(self.faultCheckpoint.ram,0,self.ram.buffer)
			end
		end
	end
	if result.kind == "exception" and #self.exceptions < 12 then
		self.exceptions[#self.exceptions + 1] = { cs = cpu.segments.cs, ip = cpu.eip, detail = result.detail }
	end
	if result.kind == "exception" and ((band(cpu.cr0, 1) == 0 and cpu:read16(result.vector * 4 + 2) ~= 0xF000) or band(cpu.cr0, 1) ~= 0) then
		local hasError = ({ [8] = true, [10] = true, [11] = true, [12] = true, [13] = true, [14] = true, [17] = true })[result.vector]
		local errorCode = band(cpu.cr0, 1) ~= 0 and hasError and result.errorCode or nil
		local faultClass = result.rewind ~= false and not (result.vector == 1 and result.detail == "instruction breakpoint")
		local ok, failure = pcall(cpu._deliverInterrupt, cpu, result.vector, false, cpu.eip, errorCode, faultClass)
		if ok then result = { kind = "ok", deliveredException = result.vector }
		else result = { kind = "host_error", message = tostring(failure) } end
	end
	local timer = self.pitChannels[0]
	if result.kind == "halted" and cpu:getFlag(CPU.FLAG.IF) and not self.realtimeClock then
		self.pitIdleTicks += timer.reload - (self:pitNow() - timer.loaded) % timer.reload
	end
	local cycle = math.floor((self:pitNow() - timer.loaded) / timer.reload)
	if cycle > timer.irqCycle and (timer.mode == 2 or timer.mode == 3 or timer.irqCycle == 0) then self.pic:raise(0) end
	timer.irqCycle = cycle
	if band(self.cmos[0x0B], 0x40) ~= 0 then
		local rate = band(self.cmos[0x0A], 15)
		if rate >= 3 then
			local rtcCycle = math.floor(self:pitNow() / 1193182 * 2 ^ (16 - rate))
			if rtcCycle ~= self.rtcCycle then self.cmos[0x0C] = 0xC0; self.pic:raise(8) end
			self.rtcCycle = rtcCycle
		end
	end
	if (result.kind == "ok" or result.kind == "halted") and cpu:getFlag(CPU.FLAG.IF) and cpu.interruptShadow == 0 then
		local vector = self.pic:nextVector()
		if vector then
			local interrupt = cpu:interrupt(vector)
			local key = string.format("%02X", vector)
			self.irqCounts[key] = (self.irqCounts[key] or 0) + 1
			result = interrupt.kind == "interrupt" and { kind = "ok", hardwareInterrupt = vector } or interrupt
		end
	end
	if result.kind ~= "ok" then self.lastResult = result end
	return result
end

function PC:getStatus()
	if self.firmware then
		self.videoMode=buffer.readu8(self.ram.buffer,0x449)
		if not self.windowsStartingObserved then
			local text={};for i=0,1999 do text[#text+1]=string.char(buffer.readu8(self.ram.buffer,0xB8000+i*2)) end
			self.windowsStartingObserved=table.concat(text):find("Starting Windows 95",1,true)~=nil
		end
	end
	return { phase = self.phase, instructions = self.cpu.instructionCount, reads = self.reads,
		windowsStartingObserved=self.windowsStartingObserved or self.transcript:find("Starting Windows 95",1,true)~=nil,
		firmware=self.firmware and "SeaBIOS" or "RoEMU BIOS",
		userFaults=self.userFaults,
		cs = self.cpu.segments.cs, eip = self.cpu.eip, cr0 = self.cpu.cr0, cr3 = self.cpu.cr3,
		cr4 = self.cpu.cr4, cpl = self.cpu.cpl, flags = self.cpu.eflags, exceptionCounts = self.exceptionCounts,
		registers = table.clone(self.cpu.regs),
		pic = { master = self.pic.master, slave = self.pic.slave },
		pit = self.pitChannels[0], clock = self:pitNow(), irqCounts = self.irqCounts,
		biosATA = { started=self.biosATAStarted, completed=self.biosATACompleted, errors=self.biosATAErrors, pending=self.biosATAPending~=nil },
		vbe = { enabled = self.vga:vbeEnabled(), width = self.vga.vbe[1], height = self.vga.vbe[2], bpp = self.vga.vbe[3] },
		last = self.lastResult, lastBIOS = self.lastBIOS, transcript = self.transcript,
		biosCounts = self.biosCounts, waitingKeyboard = self.waitingKeyboard,
		portsRead = self.portsRead, portsWritten = self.portsWritten,
		trace = self.trace, traceIndex = self.traceIndex }
end

return PC

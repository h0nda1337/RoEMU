--!native
--!optimize 2
-- RoEMU headless i386 backend, phase 1.
-- Flat 32-bit execution core with callback-only memory and I/O.

local bit = bit32
local band, bor, bxor = bit.band, bit.bor, bit.bxor
local bnot, lshift, rshift, arshift = bit.bnot, bit.lshift, bit.rshift, bit.arshift

local CPU = {}
CPU.__index = CPU

CPU.REG = {
	EAX = 0, ECX = 1, EDX = 2, EBX = 3,
	ESP = 4, EBP = 5, ESI = 6, EDI = 7,
}

CPU.FLAG = {
	CF = 0x00000001,
	RESERVED = 0x00000002,
	PF = 0x00000004,
	AF = 0x00000010,
	ZF = 0x00000040,
	SF = 0x00000080,
	TF = 0x00000100,
	IF = 0x00000200,
	DF = 0x00000400,
	OF = 0x00000800,
	IOPL = 0x00003000,
	NT = 0x00004000,
	RF = 0x00010000,
	VM = 0x00020000,
}

CPU.EXCEPTION = {
	DE = 0, DB = 1, BP = 3, OF = 4, BR = 5, UD = 6,
	NM = 7, DF = 8, TS = 10, NP = 11, SS = 12,
	GP = 13, PF = 14,
}

local EXCEPTION_NAMES = {
	[0] = "#DE", [1] = "#DB", [3] = "#BP", [4] = "#OF",
	[5] = "#BR", [6] = "#UD", [7] = "#NM", [8] = "#DF",
	[10] = "#TS", [11] = "#NP", [12] = "#SS", [13] = "#GP",
	[14] = "#PF",
}

local REG = CPU.REG
local FLAG = CPU.FLAG
local TWO32 = 0x100000000

local function u32(value)
	return band(tonumber(value) or 0, 0xFFFFFFFF)
end

local function widthMask(width)
	if width == 8 then return 0xFF end
	if width == 16 then return 0xFFFF end
	return 0xFFFFFFFF
end

local function normalize(value, width)
	return band(value or 0, widthMask(width))
end

local function signed(value, width)
	value = normalize(value, width)
	local sign = 2 ^ (width - 1)
	if value >= sign then
		return value - 2 ^ width
	end
	return value
end

local function signExtend(value, fromWidth, toWidth)
	return normalize(signed(value, fromWidth), toWidth)
end

local function parityEven(value)
	value = band(value, 0xFF)
	local ones = 0
	for _ = 1, 8 do
		ones = ones + band(value, 1)
		value = rshift(value, 1)
	end
	return band(ones, 1) == 0
end

local function cloneArray(source, count)
	local result = {}
	for index = 1, count do
		result[index] = u32(source and source[index] or 0)
	end
	return result
end

local function instructionFault(cpu, vector, errorCode, detail, extra)
	local fault = {
		__x86Exception = true,
		kind = "exception",
		vector = vector,
		name = EXCEPTION_NAMES[vector] or ("#" .. tostring(vector)),
		errorCode = u32(errorCode or 0),
		detail = detail,
		eip = u32(cpu._instructionStart or cpu.eip),
		linearAddress = extra and extra.linearAddress or nil,
		access = extra and extra.access or nil,
		rewind = extra == nil or extra.rewind ~= false,
	}
	error(fault, 0)
end

local function flagIsSet(cpu, flag)
	return band(cpu.eflags, flag) ~= 0
end

function CPU:_setFlag(flag, enabled)
	if enabled then
		self.eflags = bor(self.eflags, flag)
	else
		self.eflags = band(self.eflags, bnot(flag))
	end
	self.eflags = bor(u32(self.eflags), FLAG.RESERVED)
end

function CPU:getFlag(flag)
	return flagIsSet(self, flag)
end

function CPU:setFlag(flag, enabled)
	self:_setFlag(flag, enabled == true)
end

local function updateZSP(cpu, result, width)
	result = normalize(result, width)
	cpu:_setFlag(FLAG.ZF, result == 0)
	cpu:_setFlag(FLAG.SF, band(result, 2 ^ (width - 1)) ~= 0)
	cpu:_setFlag(FLAG.PF, parityEven(result))
end

local function addValues(cpu, left, right, carry, width)
	left, right = normalize(left, width), normalize(right, width)
	carry = carry or 0
	local sum = left + right + carry
	local mask = widthMask(width)
	local result = normalize(sum, width)
	local signBit = 2 ^ (width - 1)
	cpu:_setFlag(FLAG.CF, sum > mask)
	cpu:_setFlag(FLAG.AF, band(left, 0xF) + band(right, 0xF) + carry > 0xF)
	cpu:_setFlag(FLAG.OF,
		band(left, signBit) == band(right, signBit)
		and band(left, signBit) ~= band(result, signBit))
	updateZSP(cpu, result, width)
	return result
end

local function subValues(cpu, left, right, borrow, width)
	left, right = normalize(left, width), normalize(right, width)
	borrow = borrow or 0
	local subtrahend = right + borrow
	local result = normalize(left - subtrahend, width)
	local signBit = 2 ^ (width - 1)
	cpu:_setFlag(FLAG.CF, left < subtrahend)
	cpu:_setFlag(FLAG.AF, band(left, 0xF) < band(right, 0xF) + borrow)
	cpu:_setFlag(FLAG.OF,
		band(left, signBit) ~= band(right, signBit)
		and band(left, signBit) ~= band(result, signBit))
	updateZSP(cpu, result, width)
	return result
end

local function logicalResult(cpu, value, width)
	value = normalize(value, width)
	cpu:_setFlag(FLAG.CF, false)
	cpu:_setFlag(FLAG.OF, false)
	-- AF is architecturally undefined. Clearing it is deterministic and matches
	-- common software expectations without pretending it carries information.
	cpu:_setFlag(FLAG.AF, false)
	updateZSP(cpu, value, width)
	return value
end

local function applyALU(cpu, operation, left, right, width)
	if operation == 0 then
		return addValues(cpu, left, right, 0, width)
	elseif operation == 1 then
		return logicalResult(cpu, bor(left, right), width)
	elseif operation == 2 then
		return addValues(cpu, left, right, flagIsSet(cpu, FLAG.CF) and 1 or 0, width)
	elseif operation == 3 then
		return subValues(cpu, left, right, flagIsSet(cpu, FLAG.CF) and 1 or 0, width)
	elseif operation == 4 then
		return logicalResult(cpu, band(left, right), width)
	elseif operation == 5 or operation == 7 then
		return subValues(cpu, left, right, 0, width)
	elseif operation == 6 then
		return logicalResult(cpu, bxor(left, right), width)
	end
	instructionFault(cpu, CPU.EXCEPTION.UD, 0, "unknown ALU operation")
end

local function conditionTrue(cpu, condition)
	local cf = flagIsSet(cpu, FLAG.CF)
	local pf = flagIsSet(cpu, FLAG.PF)
	local zf = flagIsSet(cpu, FLAG.ZF)
	local sf = flagIsSet(cpu, FLAG.SF)
	local of = flagIsSet(cpu, FLAG.OF)
	if condition == 0 then return of end
	if condition == 1 then return not of end
	if condition == 2 then return cf end
	if condition == 3 then return not cf end
	if condition == 4 then return zf end
	if condition == 5 then return not zf end
	if condition == 6 then return cf or zf end
	if condition == 7 then return not cf and not zf end
	if condition == 8 then return sf end
	if condition == 9 then return not sf end
	if condition == 10 then return pf end
	if condition == 11 then return not pf end
	if condition == 12 then return sf ~= of end
	if condition == 13 then return sf == of end
	if condition == 14 then return zf or sf ~= of end
	return not zf and sf == of
end

function CPU.new(callbacks, options)
	callbacks = callbacks or {}
	options = options or {}
	local self = setmetatable({}, CPU)
	self.callbacks = callbacks
	self.regs = { 0, 0, 0, 0, 0, 0, 0, 0 }
	self.eip = u32(options.eip or 0)
	self.eflags = bor(u32(options.eflags or FLAG.RESERVED), FLAG.RESERVED)
	self.cr0 = u32(options.cr0 or 0x00000001)
	self.cr2 = u32(options.cr2 or 0)
	self.cr3 = u32(options.cr3 or 0)
	self.segments = {
		cs = band(options.cs or 0x0008, 0xFFFF),
		ds = band(options.ds or 0x0010, 0xFFFF),
		es = band(options.es or 0x0010, 0xFFFF),
		ss = band(options.ss or 0x0010, 0xFFFF),
		fs = band(options.fs or 0, 0xFFFF),
		gs = band(options.gs or 0, 0xFFFF),
	}
	self.gdtr = { base = u32(options.gdtBase or 0), limit = band(options.gdtLimit or 0, 0xFFFF) }
	self.idtr = { base = u32(options.idtBase or 0), limit = band(options.idtLimit or 0, 0xFFFF) }
	self.cpl = band(options.cpl or 0, 3)
	self.defaultOperandSize = options.defaultOperandSize == 16 and 16 or 32
	self.defaultAddressSize = options.defaultAddressSize == 16 and 16 or 32
	self.stackAddressSize = options.stackAddressSize == 16 and 16 or 32
	self.segmented = options.segmented == true
	self.segmentCache = {}
	self.cr4 = u32(options.cr4 or 0)
	self.ldtr = { base = 0, limit = 0, selector = 0 }
	self.tr = { base = 0, limit = 0, selector = 0 }
	self.dr = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [6] = 0xFFFF0FF0, [7] = 0x400 }
	self.interruptShadow = 0
	self.tlb = {}
	self._restartRegs, self._restartSegments, self._restartCaches = {}, {}, {}
	self._transactionActive = false
	self._decodeContext = {}
	self.halted = false
	self.instructionCount = 0
	self.cycleCount = 0
	self.lastException = nil
	self.lastInstruction = nil
	self.interruptHandlers = {}
	self.options = {
		legacy386 = options.legacy386 == true,
		traceBytes = options.traceBytes ~= false,
		fastSpinLoops = options.fastSpinLoops == true,
		fastSumLoops = options.fastSumLoops == true,
		fastRepStrings = options.fastRepStrings ~= false,
		reuseDecodeState = options.reuseDecodeState == true,
		maxSpinInstructions = math.max(1, math.floor(tonumber(options.maxSpinInstructions) or 1)),
		strictLock = options.strictLock ~= false,
		maxRepIterationsPerStep = math.max(1,
			math.floor(tonumber(options.maxRepIterationsPerStep) or 0x100000)),
	}
	if options.regs ~= nil then
		for index = 0, 7 do
			self:setReg32(index, options.regs[index + 1] or options.regs[index] or 0)
		end
	end
	return self
end

function CPU:getReg32(index)
	index = band(index or 0, 7)
	return u32(self.regs[index + 1])
end

function CPU:setReg32(index, value)
	index = band(index or 0, 7)
	self.regs[index + 1] = u32(value)
end

function CPU:getReg16(index)
	return band(self:getReg32(index), 0xFFFF)
end

function CPU:setReg16(index, value)
	local old = self:getReg32(index)
	self:setReg32(index, bor(band(old, 0xFFFF0000), band(value, 0xFFFF)))
end

function CPU:getReg8(index)
	index = band(index or 0, 7)
	if index < 4 then
		return band(self:getReg32(index), 0xFF)
	end
	return band(rshift(self:getReg32(index - 4), 8), 0xFF)
end

function CPU:setReg8(index, value)
	index = band(index or 0, 7)
	value = band(value or 0, 0xFF)
	if index < 4 then
		local old = self:getReg32(index)
		self:setReg32(index, bor(band(old, 0xFFFFFF00), value))
	else
		local base = index - 4
		local old = self:getReg32(base)
		self:setReg32(base, bor(band(old, 0xFFFF00FF), lshift(value, 8)))
	end
end

local function getRegister(cpu, index, width)
	if width == 8 then return cpu:getReg8(index) end
	if width == 16 then return cpu:getReg16(index) end
	return cpu:getReg32(index)
end

local function setRegister(cpu, index, width, value)
	if width == 8 then cpu:setReg8(index, value)
	elseif width == 16 then cpu:setReg16(index, value)
	else cpu:setReg32(index, value) end
end

function CPU:_memoryFault(address, access, reason, pageErrorCode)
	address = u32(address)
	self.cr2 = address
	local code = pageErrorCode
	if type(code) ~= "number" then
		code = access == "write" and 0x2 or 0
	end
	instructionFault(self, CPU.EXCEPTION.PF, code,
		"memory " .. tostring(access) .. " failed: " .. tostring(reason or "unmapped"),
		{ linearAddress = address, access = access })
end

function CPU:physicalRead8(address, access)
	address = u32(address)
	local callback = self.callbacks.read8
	if callback == nil then
		self:_memoryFault(address, access or "read", "read8 callback missing")
	end
	local value, detail = callback(address, self, access or "read")
	if value == nil then
		local code = type(detail) == "table" and detail.errorCode or nil
		self:_memoryFault(address, access or "read", detail, code)
	end
	return band(value, 0xFF)
end

function CPU:physicalWrite8(address, value, access)
	address = u32(address)
	local callback = self.callbacks.write8
	if callback == nil then
		self:_memoryFault(address, access or "write", "write8 callback missing")
	end
	local ok, detail = callback(address, band(value or 0, 0xFF), self, access or "write")
	-- nil means success so ordinary Roblox callbacks do not need to return true.
	if ok == false then
		local code = type(detail) == "table" and detail.errorCode or nil
		self:_memoryFault(address, access or "write", detail, code)
	end
end

function CPU:isRealMode()
	return band(self.cr0, 1) == 0 or band(self.eflags, FLAG.VM) ~= 0
end

function CPU:loadSegment(name, selector)
	selector = band(selector, 0xFFFF)
	if self._transactionActive and not self._restartSegmentDirty then
		for segment, value in pairs(self.segments) do self._restartSegments[segment] = value; self._restartCaches[segment] = self.segmentCache[segment] end
		self._restartSegmentDirty = true
	end
	if not self.segmented then self.segments[name] = selector; return end
	local entry
	if self:isRealMode() then
		local previous = self.segmentCache[name]
		-- MOV/POP of a data segment in real mode preserves the cached limit.
		-- HIMEM's #GP handler relies on this 386 "unreal mode" behavior.
		local preserve = name ~= "cs" and band(self.eflags, FLAG.VM) == 0 and previous ~= nil
		entry = { base = selector * 16, limit = preserve and previous.limit or 0xFFFF,
			big = preserve and previous.big or false, access = preserve and previous.access or nil }
	elseif band(selector, 0xFFFC) == 0 then
		if name == "cs" or name == "ss" then instructionFault(self, CPU.EXCEPTION.GP, 0, "null code/stack selector") end
		entry = { base = 0, limit = 0, big = false, access = 0, unusable = true }
	else
		local tab = band(selector, 4) ~= 0 and self.ldtr or self.gdtr
		local offset = band(selector, 0xFFF8)
		if offset + 7 > tab.limit then instructionFault(self, CPU.EXCEPTION.GP, selector, "segment outside descriptor table") end
		local address = tab.base + offset
		local low, high = self:systemRead32(address), self:systemRead32(address + 4)
		if band(high, 0x8000) == 0 then
			instructionFault(self, name == "ss" and CPU.EXCEPTION.SS or CPU.EXCEPTION.NP,
				band(selector,0xFFFC), "segment is not present")
		end
		local base = bor(rshift(low, 16), lshift(band(high, 0xFF), 16), band(high, 0xFF000000))
		local limit = bor(band(low, 0xFFFF), band(high, 0xF0000))
		if band(high, 0x800000) ~= 0 then limit = limit * 4096 + 4095 end
		entry = { base = base, limit = limit, big = band(high, 0x400000) ~= 0, access = band(rshift(high, 8), 0xFF) }
	end
	self.segments[name], self.segmentCache[name] = selector, entry
	if name == "cs" then
		self.defaultOperandSize = entry.big and 32 or 16
		self.defaultAddressSize = self.defaultOperandSize
		self.cpl = self:isRealMode() and (band(self.eflags, FLAG.VM) ~= 0 and 3 or 0) or band(selector, 3)
	elseif name == "ss" then
		self.stackAddressSize = entry.big and 32 or 16
		self.interruptShadow = 2
	end
end

function CPU:segmentAddress(segment, offset, bytes)
	if not self.segmented then return u32(offset) end
	segment = segment or "ds"
	local entry = self.segmentCache[segment]
	if not entry then
		if self:isRealMode() then
			entry = { base = (self.segments[segment] or 0) * 16, limit = 0xFFFF, big = false }
			self.segmentCache[segment] = entry
		else
		self:loadSegment(segment, self.segments[segment] or 0)
		entry = self.segmentCache[segment]
		end
	end
	if entry.unusable then instructionFault(self, CPU.EXCEPTION.GP, 0, "access through a null data selector") end
	local last = offset + (bytes or 1) - 1
	-- Expand-down data descriptors use the limit as the excluded lower bound.
	-- Win16's flat data selector deliberately excludes the first 64 KiB.
	local expandDown = band(entry.access or 0, 0x1C) == 0x14
	local invalid = expandDown and (offset <= entry.limit or last > (entry.big and 0xFFFFFFFF or 0xFFFF))
		or not expandDown and last > entry.limit
	if invalid then
		instructionFault(self, segment == "ss" and CPU.EXCEPTION.SS or CPU.EXCEPTION.GP, 0,
			string.format("segment %s limit %08X excludes %08X..%08X", segment, entry.limit, offset, last))
	end
	return u32(entry.base + offset)
end

function CPU:translateLinear(address, access)
	address = u32(address)
	if band(self.cr0, 0x80000000) == 0 then return address end
	local function physical32(a)
		return self:physicalRead8(a) + self:physicalRead8(a + 1) * 256
			+ self:physicalRead8(a + 2) * 65536 + self:physicalRead8(a + 3) * 16777216
	end
	local function store32(a, value)
		for i = 0, 3 do self:physicalWrite8(a + i, rshift(value, i * 8)) end
	end
	local user = not self.systemAccess and (self.cpl == 3 or band(self.eflags, FLAG.VM) ~= 0)
	local code = (access == "write" and 2 or 0) + (user and 4 or 0)
	local page = rshift(address, 12)
	local cached = self.tlb[page]
	if cached then
		if (user and not cached.user) or (access == "write" and not cached.writable and (user or band(self.cr0, 0x10000) ~= 0)) then
			self:_memoryFault(address, access, "cached page permissions", code + 1)
		end
		if access == "write" and not cached.dirty then
			store32(cached.entry, bor(physical32(cached.entry), 0x40))
			cached.dirty = true
		end
		return bor(cached.base, band(address, 0xFFF))
	end
	local pdeAddress = band(self.cr3, 0xFFFFF000) + rshift(address, 22) * 4
	local pde = physical32(pdeAddress)
	if band(pde, 1) == 0 then self:_memoryFault(address, access, "PDE not present", code) end
	local large = band(pde, 0x80) ~= 0 and band(self.cr4, 0x10) ~= 0
	local pteAddress = band(pde, 0xFFFFF000) + band(rshift(address, 12), 0x3FF) * 4
	local pte = large and pde or physical32(pteAddress)
	if band(pte, 1) == 0 then self:_memoryFault(address, access, "PTE not present", code) end
	local rw = band(pde, 2) ~= 0 and band(pte, 2) ~= 0
	local us = band(pde, 4) ~= 0 and band(pte, 4) ~= 0
	if (user and not us) or (access == "write" and not rw and (user or band(self.cr0, 0x10000) ~= 0)) then
		self:_memoryFault(address, access, "page permissions", code + 1)
	end
	if band(pde, 0x20) == 0 then store32(pdeAddress, bor(pde, 0x20)) end
	local flags = access == "write" and 0x60 or 0x20
	if large then
		store32(pdeAddress, bor(pde, flags))
		local physical = bor(band(pde, 0xFFC00000), band(address, 0x3FFFFF))
		self.tlb[page] = { base = band(physical, 0xFFFFF000), user = us, writable = rw, dirty = access == "write", entry = pdeAddress }
		return physical
	end
	if band(pte, flags) ~= flags then store32(pteAddress, bor(pte, flags)) end
	self.tlb[page] = { base = band(pte, 0xFFFFF000), user = us, writable = rw, dirty = band(bor(pte, flags), 0x40) ~= 0, entry = pteAddress }
	return bor(band(pte, 0xFFFFF000), band(address, 0xFFF))
end

function CPU:read8(address, access)
	self:_watchMemory(address, 1, access or "read")
	return self:physicalRead8(self:translateLinear(address, access or "read"), access)
end

function CPU:write8(address, value, access)
	self:_watchMemory(address, 1, "write")
	return self:physicalWrite8(self:translateLinear(address, access or "write"), value, access)
end

function CPU:_watchMemory(address, count, access)
	if not self._transactionActive or self.systemAccess or access == "execute" or band(self.dr[7] or 0, 255) == 0 then return end
	local control = self.dr[7]
	for index = 0, 3 do
		if band(rshift(control, index * 2), 3) ~= 0 then
			local kind = band(rshift(control, 16 + index * 4), 3)
			if kind == 3 or (kind == 1 and access == "write") then
				local length = ({ [0] = 1, [1] = 2, [2] = 8, [3] = 4 })[band(rshift(control, 18 + index * 4), 3)]
				local watched = self.dr[index] or 0
				if address < watched + length and address + count > watched then self._debugMatches = bor(self._debugMatches or 0, lshift(1, index)) end
			end
		end
	end
end

function CPU:systemRead32(address)
	local previous = self.systemAccess
	self.systemAccess = true
	local ok, result = pcall(self.read32, self, address, "read")
	self.systemAccess = previous
	if not ok then error(result, 0) end
	return result
end

function CPU:systemRead8(address)
	local previous = self.systemAccess
	self.systemAccess = true
	local ok, result = pcall(self.read8, self, address, "read")
	self.systemAccess = previous
	if not ok then error(result, 0) end
	return result
end

function CPU:read16(address, access)
	self:_watchMemory(address, 2, access or "read")
	if self.callbacks.read16 and band(address, 0xFFF) <= 0xFFE then
		local value = self.callbacks.read16(self:translateLinear(address, access or "read"))
		if value ~= nil then return value end
	end
	local b0 = self:read8(address, access)
	local b1 = self:read8(address + 1, access)
	return bor(b0, lshift(b1, 8))
end

function CPU:read32(address, access)
	self:_watchMemory(address, 4, access or "read")
	if self.callbacks.read32 and band(address, 0xFFF) <= 0xFFC then
		local value = self.callbacks.read32(self:translateLinear(address, access or "read"))
		if value ~= nil then return value end
	end
	local b0 = self:read8(address, access)
	local b1 = self:read8(address + 1, access)
	local b2 = self:read8(address + 2, access)
	local b3 = self:read8(address + 3, access)
	return u32(b0 + b1 * 0x100 + b2 * 0x10000 + b3 * 0x1000000)
end

function CPU:write16(address, value, access)
	self:_watchMemory(address, 2, "write")
	value = normalize(value, 16)
	if band(address, 0xFFF) > 0xFFE then self:translateLinear(address, access or "write"); self:translateLinear(address + 1, access or "write") end
	if self.callbacks.write16 and band(address, 0xFFF) <= 0xFFE then
		if self.callbacks.write16(self:translateLinear(address, access or "write"), value) == true then return end
	end
	self:write8(address, value, access)
	self:write8(address + 1, rshift(value, 8), access)
end

function CPU:write32(address, value, access)
	self:_watchMemory(address, 4, "write")
	value = u32(value)
	if band(address, 0xFFF) > 0xFFC then self:translateLinear(address, access or "write"); self:translateLinear(address + 3, access or "write") end
	if self.callbacks.write32 and band(address, 0xFFF) <= 0xFFC then
		if self.callbacks.write32(self:translateLinear(address, access or "write"), value) == true then return end
	end
	self:write8(address, value, access)
	self:write8(address + 1, rshift(value, 8), access)
	self:write8(address + 2, rshift(value, 16), access)
	self:write8(address + 3, rshift(value, 24), access)
end

local function readWidth(cpu, address, width, access)
	if width == 8 then return cpu:read8(address, access) end
	if width == 16 then return cpu:read16(address, access) end
	return cpu:read32(address, access)
end

local function writeWidth(cpu, address, width, value, access)
	if width == 8 then cpu:write8(address, value, access)
	elseif width == 16 then cpu:write16(address, value, access)
	else cpu:write32(address, value, access) end
end

local function instructionRAM(cpu,context,address,bytes)
	if context.fetchBuffer and address>=context.fetchStart and address+bytes<=context.fetchEnd then
		return context.fetchBuffer,context.fetchOffset+address-context.fetchStart
	end
	if not cpu.callbacks.ramSpan or band(address,4095)+bytes>4096 then return nil end
	local physical=cpu:translateLinear(address,"execute")
	local length=math.min(4096-band(address,4095),15-context.length)
	if cpu.segmented then length=math.min(length,cpu.segmentCache.cs.limit-cpu.eip+1) end
	local data,offset=cpu.callbacks.ramSpan(physical,length,false)
	if data then
		context.fetchBuffer,context.fetchOffset,context.fetchStart,context.fetchEnd=data,offset,address,address+length
		context.fetchIP,context.fetchIPEnd=cpu.eip,cpu.eip+length
		return data,offset
	end
	return nil
end

local function fetch8(cpu, context)
	if context.length >= 15 then
		instructionFault(cpu, CPU.EXCEPTION.UD, 0, "instruction exceeds 15 bytes")
	end
	local value
	if context.fetchBuffer and cpu.eip>=context.fetchIP and cpu.eip<context.fetchIPEnd then
		value=buffer.readu8(context.fetchBuffer,context.fetchOffset+cpu.eip-context.fetchIP)
	else
		local address=cpu:segmentAddress("cs",cpu.eip)
		local data,offset=instructionRAM(cpu,context,address,1)
		value = data and buffer.readu8(data,offset) or cpu:read8(address,"execute")
	end
	cpu.eip = cpu.defaultAddressSize == 16 and band(cpu.eip + 1, 0xFFFF) or u32(cpu.eip + 1)
	context.length = context.length + 1
	if context.bytes ~= nil then
		context.bytes[context.length] = value
	end
	return value
end

local function fetchWide(cpu,context,bytes)
	if context.bytes or context.length+bytes>15 or band(cpu.eip,4095)>4096-bytes
		or (cpu.defaultAddressSize==16 and cpu.eip+bytes>65536) then return nil end
	if context.fetchBuffer and cpu.eip>=context.fetchIP and cpu.eip+bytes<=context.fetchIPEnd then
		local offset=context.fetchOffset+cpu.eip-context.fetchIP
		local value=bytes==2 and buffer.readu16(context.fetchBuffer,offset) or buffer.readu32(context.fetchBuffer,offset)
		cpu.eip=cpu.defaultAddressSize==16 and band(cpu.eip+bytes,65535) or u32(cpu.eip+bytes)
		context.length+=bytes
		return value
	end
	local entry=cpu.segmentCache.cs
	if cpu.segmented and (not entry or entry.unusable or cpu.eip+bytes-1>entry.limit) then return nil end
	local address=cpu:segmentAddress("cs",cpu.eip,bytes)
	local data,offset=instructionRAM(cpu,context,address,bytes)
	local value
	if data then value=bytes==2 and buffer.readu16(data,offset) or buffer.readu32(data,offset)
	else value=bytes==2 and cpu:read16(address,"execute") or cpu:read32(address,"execute") end
	cpu.eip=cpu.defaultAddressSize==16 and band(cpu.eip+bytes,65535) or u32(cpu.eip+bytes)
	context.length+=bytes
	return value
end

local function fetch16(cpu, context)
	local fast=fetchWide(cpu,context,2)
	if fast~=nil then return fast end
	local lo = fetch8(cpu, context)
	return bor(lo, lshift(fetch8(cpu, context), 8))
end

local function fetch32(cpu, context)
	local fast=fetchWide(cpu,context,4)
	if fast~=nil then return fast end
	local lo = fetch16(cpu, context)
	local hi = fetch16(cpu, context)
	return u32(lo + hi * 0x10000)
end

local function fetchImmediate(cpu, context, width)
	if width == 8 then return fetch8(cpu, context) end
	if width == 16 then return fetch16(cpu, context) end
	return fetch32(cpu, context)
end

local function parsePrefixes(cpu, context)
	context.secondaryOpcode = nil
	context.operandSize = cpu.defaultOperandSize
	context.addressSize = cpu.defaultAddressSize
	context.segment = nil
	context.lock = false
	context.rep = nil
	local operandOverride = false
	local addressOverride = false
	while true do
		local opcode = fetch8(cpu, context)
		if opcode == 0x66 then
			operandOverride = true
		elseif opcode == 0x67 then
			addressOverride = true
		elseif opcode == 0xF0 then
			context.lock = true
		elseif opcode == 0xF2 then
			context.rep = "repne"
		elseif opcode == 0xF3 then
			context.rep = "rep"
		elseif opcode == 0x26 then context.segment = "es"
		elseif opcode == 0x2E then context.segment = "cs"
		elseif opcode == 0x36 then context.segment = "ss"
		elseif opcode == 0x3E then context.segment = "ds"
		elseif opcode == 0x64 then context.segment = "fs"
		elseif opcode == 0x65 then context.segment = "gs"
		else
			context.opcode = opcode
			break
		end
	end
	if operandOverride then
		context.operandSize = cpu.defaultOperandSize == 32 and 16 or 32
	end
	if addressOverride then
		context.addressSize = cpu.defaultAddressSize == 32 and 16 or 32
	end
end

local function decodeModRM(cpu, context)
	local byte = fetch8(cpu, context)
	local mod = rshift(byte, 6)
	local reg = band(rshift(byte, 3), 7)
	local rm = band(byte, 7)
	local decoded = context.decoded or {}
	context.decoded = decoded
	decoded.byte, decoded.mod, decoded.reg, decoded.rm, decoded.sib = byte, mod, reg, rm, nil
	local operand = decoded.operand or {}
	decoded.operand = operand
	if mod == 3 then
		operand.kind, operand.index, operand.address, operand.segment = "reg", rm, nil, nil
		return decoded
	end

	local address
	local defaultSegment = "ds"
	if context.addressSize == 32 then
		local baseValue = 0
		local indexValue = 0
		local needsDisp32 = false
		if rm == 4 then
			local sib = fetch8(cpu, context)
			local scale = rshift(sib, 6)
			local index = band(rshift(sib, 3), 7)
			local base = band(sib, 7)
			decoded.sib = sib
			if index ~= 4 then
				indexValue = cpu:getReg32(index) * (2 ^ scale)
			end
			if base == 5 and mod == 0 then
				needsDisp32 = true
			else
				baseValue = cpu:getReg32(base)
				if base == 4 or base == 5 then defaultSegment = "ss" end
			end
		elseif rm == 5 and mod == 0 then
			needsDisp32 = true
		else
			baseValue = cpu:getReg32(rm)
			if rm == 4 or rm == 5 then defaultSegment = "ss" end
		end

		local displacement = 0
		if mod == 1 then
			displacement = signed(fetch8(cpu, context), 8)
		elseif mod == 2 or needsDisp32 then
			displacement = signed(fetch32(cpu, context), 32)
		end
		decoded.displacement = displacement
		address = u32(baseValue + indexValue + displacement)
	else
		local baseValue
		if rm == 0 then baseValue = cpu:getReg16(REG.EBX) + cpu:getReg16(REG.ESI)
		elseif rm == 1 then baseValue = cpu:getReg16(REG.EBX) + cpu:getReg16(REG.EDI)
		elseif rm == 2 then baseValue = cpu:getReg16(REG.EBP) + cpu:getReg16(REG.ESI)
		elseif rm == 3 then baseValue = cpu:getReg16(REG.EBP) + cpu:getReg16(REG.EDI)
		elseif rm == 4 then baseValue = cpu:getReg16(REG.ESI)
		elseif rm == 5 then baseValue = cpu:getReg16(REG.EDI)
		elseif rm == 6 then baseValue = cpu:getReg16(REG.EBP)
		else baseValue = cpu:getReg16(REG.EBX) end
		if rm == 2 or rm == 3 or (rm == 6 and mod ~= 0) then defaultSegment = "ss" end
		local displacement = 0
		if mod == 0 and rm == 6 then
			baseValue = 0
			displacement = fetch16(cpu, context)
		elseif mod == 1 then
			displacement = signed(fetch8(cpu, context), 8)
		elseif mod == 2 then
			displacement = signed(fetch16(cpu, context), 16)
		end
		decoded.displacement = displacement
		address = band(baseValue + displacement, 0xFFFF)
	end
	operand.kind, operand.index, operand.address, operand.segment = "mem", nil, u32(address), context.segment or defaultSegment
	return decoded
end

local function readOperand(cpu, operand, width)
	if operand.kind == "reg" then
		return getRegister(cpu, operand.index, width)
	end
	return readWidth(cpu, cpu:segmentAddress(operand.segment, operand.address, width / 8), width, "read")
end

local function writeOperand(cpu, operand, width, value)
	if operand.kind == "reg" then
		setRegister(cpu, operand.index, width, value)
	else
		writeWidth(cpu, cpu:segmentAddress(operand.segment, operand.address, width / 8), width, value, "write")
	end
end

local function stackPointer(cpu)
	if cpu.stackAddressSize == 16 then
		return cpu:getReg16(REG.ESP)
	end
	return cpu:getReg32(REG.ESP)
end

local function setStackPointer(cpu, value)
	if cpu.stackAddressSize == 16 then
		cpu:setReg16(REG.ESP, value)
	else
		cpu:setReg32(REG.ESP, value)
	end
end

local function push(cpu, width, value)
	local bytes = width / 8
	local pointer = normalize(stackPointer(cpu) - bytes, cpu.stackAddressSize)
	setStackPointer(cpu, pointer)
	writeWidth(cpu, cpu:segmentAddress("ss", pointer, bytes), width, value, "write")
end

local function pop(cpu, width)
	local pointer = stackPointer(cpu)
	local value = readWidth(cpu, cpu:segmentAddress("ss", pointer, width / 8), width, "read")
	setStackPointer(cpu, normalize(pointer + width / 8, cpu.stackAddressSize))
	return value
end

local function branchTarget(cpu, displacement, operandSize)
	local target = cpu.eip + displacement
	if operandSize == 16 then
		return band(target, 0xFFFF)
	end
	return u32(target)
end

local function directTarget(value, operandSize)
	if operandSize == 16 then return band(value, 0xFFFF) end
	return u32(value)
end

local function readControl(cpu, index)
	if index == 0 then return cpu.cr0 end
	if index == 2 then return cpu.cr2 end
	if index == 3 then return cpu.cr3 end
	if index == 4 then return cpu.cr4 end
	instructionFault(cpu, CPU.EXCEPTION.UD, 0, "unsupported control register CR" .. tostring(index))
end

local function writeControl(cpu, index, value)
	value = u32(value)
	if index == 0 then cpu.cr0 = value; cpu.tlb = {}; return end
	if index == 2 then cpu.cr2 = value; return end
	if index == 3 then cpu.cr3 = band(value, 0xFFFFF000); cpu.tlb = {}; return end
	if index == 4 then cpu.cr4 = value; cpu.tlb = {}; return end
	instructionFault(cpu, CPU.EXCEPTION.UD, 0, "unsupported control register CR" .. tostring(index))
end

function CPU:setInterruptHandler(vector, offset, selector, gateType, dpl)
	vector = band(vector or 0, 0xFF)
	self.interruptHandlers[vector] = {
		offset = u32(offset), selector = band(selector or self.segments.cs, 0xFFFF),
		type = gateType or 0xE, dpl = band(dpl or 0, 3), present = true,
	}
end

function CPU:clearInterruptHandler(vector)
	self.interruptHandlers[band(vector or 0, 0xFF)] = nil
end

function CPU:_resolveInterrupt(vector, software)
	local resolver = self.callbacks.resolveInterrupt
	if resolver ~= nil then
		local gate = resolver(vector, self, software == true)
		if gate ~= nil then return gate end
	end
	local installed = self.interruptHandlers[vector]
	if installed ~= nil then return installed end

	local descriptorOffset = vector * 8
	if descriptorOffset + 7 > self.idtr.limit then
		return nil, "IDT limit"
	end
	local address = u32(self.idtr.base + descriptorOffset)
	local low = self:systemRead32(address)
	local high = self:systemRead32(address + 4)
	local gateType = band(rshift(high, 8), 0x1F)
	return {
		offset = bor(band(low, 0xFFFF), band(high, 0xFFFF0000)),
		selector = band(rshift(low, 16), 0xFFFF),
		type = gateType,
		dpl = band(rshift(high, 13), 3),
		present = band(high, 0x00008000) ~= 0,
	}
end

function CPU:_deliverInterrupt(vector, software, returnEip, errorCode, faultClass)
	vector = band(vector, 0xFF)
	local softwareCallback = software and self.callbacks.onSoftwareInterrupt or nil
	if softwareCallback ~= nil then
		local response = softwareCallback(vector, self, u32(returnEip or self.eip))
		if response == true or response == "handled" then
			return true
		elseif type(response) == "table" then
			self.interruptHandlers[vector] = response
		end
	end

	if self.segmented and band(self.eflags, FLAG.VM) ~= 0 and software and band(rshift(self.eflags, 12), 3) < 3 then
		instructionFault(self, CPU.EXCEPTION.GP, 0, "INT in virtual 8086 mode requires reflection")
	end
	if self.segmented and band(self.cr0, 1) == 0 then
		push(self, 16, self.eflags)
		push(self, 16, self.segments.cs)
		push(self, 16, returnEip or self.eip)
		self:_setFlag(FLAG.IF, false)
		self:_setFlag(FLAG.TF, false)
		self:loadSegment("cs", self:read16(vector * 4 + 2))
		self.eip = self:read16(vector * 4)
		self.halted = false
		return true
	end
	local gate, reason = self:_resolveInterrupt(vector, software)
	if gate == nil then
		instructionFault(self, CPU.EXCEPTION.GP, vector * 8 + 2,
			"cannot resolve interrupt " .. tostring(vector) .. ": " .. tostring(reason))
	end
	if gate.present == false then
		instructionFault(self, CPU.EXCEPTION.NP, vector * 8 + 2, "interrupt gate not present")
	end
	if software and self.cpl > (gate.dpl or 0) then
		instructionFault(self, CPU.EXCEPTION.GP, vector * 8 + 2, "interrupt gate privilege violation")
	end
	local gateType = gate.type or 0xE
	local width
	if gateType == 0x6 or gateType == 0x7 then width = 16
	elseif gateType == 0xE or gateType == 0xF then width = 32
	else
		instructionFault(self, CPU.EXCEPTION.GP, vector * 8 + 2, "unsupported interrupt gate type")
	end
	local oldFlags, oldCS = self.eflags, self.segments.cs
	if faultClass then oldFlags = bor(oldFlags, FLAG.RF) end
	if self.segmented then
		local selector = gate.selector or self.segments.cs
		local tab = band(selector, 4) ~= 0 and self.ldtr or self.gdtr
		local descriptor = self:systemRead32(tab.base + band(selector, 0xFFF8) + 4)
		local conforming = band(descriptor, 0x0400) ~= 0
		local targetCPL = conforming and self.cpl or band(rshift(descriptor, 13), 3)
		local fromVM = band(oldFlags, FLAG.VM) ~= 0
		if targetCPL < self.cpl or fromVM then
			-- A 32-bit gate saves the full ESP even when the interrupted SS is 16-bit.
			local oldSS, oldSP = self.segments.ss, self:getReg32(REG.ESP)
			local oldES, oldDS, oldFS, oldGS = self.segments.es, self.segments.ds, self.segments.fs, self.segments.gs
			local nextSP = self:systemRead32(self.tr.base + 4 + targetCPL * 8)
			local nextSS = band(self:systemRead32(self.tr.base + 8 + targetCPL * 8), 0xFFFF)
			self.eflags = band(self.eflags, bnot(FLAG.VM))
			self.cpl = targetCPL
			self:loadSegment("ss", nextSS)
			self:setReg32(REG.ESP, nextSP)
			if fromVM then
				push(self, width, oldGS); push(self, width, oldFS); push(self, width, oldDS); push(self, width, oldES)
			end
			push(self, width, oldSS); push(self, width, oldSP)
			if fromVM then
				-- VM86 segment values are already in the interrupt frame. The
				-- handler starts with null data segments, as on a physical 386.
				self:loadSegment("ds", 0); self:loadSegment("es", 0)
				self:loadSegment("fs", 0); self:loadSegment("gs", 0)
			end
		end
		gate.selector = bor(band(selector, 0xFFFC), targetCPL)
	end
	push(self, width, oldFlags)
	push(self, width, oldCS)
	push(self, width, returnEip or self.eip)
	if errorCode ~= nil then push(self, width, errorCode) end
	self:_setFlag(FLAG.TF, false)
	self:_setFlag(FLAG.RF, false)
	self:_setFlag(FLAG.NT, false)
	if gateType == 0x6 or gateType == 0xE then
		self:_setFlag(FLAG.IF, false)
	end
	self:loadSegment("cs", band(gate.selector or self.segments.cs, 0xFFFF))
	self.eip = directTarget(gate.offset or 0, width)
	self.halted = false
	return true
end

function CPU:interrupt(vector)
	self:_saveRestartState()
	self._transactionActive = true
	local ok, result = pcall(function()
		return self:_deliverInterrupt(vector, false, self.eip)
	end)
	self._transactionActive = false
	if ok then return { kind = "interrupt", vector = band(vector, 0xFF) } end
	self:_restoreRestartState()
	if type(result) == "table" and result.__x86Exception then
		self.lastException = result
		return result
	end
	return { kind = "host_error", message = tostring(result), eip = self.eip }
end

local function performShift(cpu, operation, value, count, width)
	value = normalize(value, width)
	count = band(count, 0x1F)
	if count == 0 then return value end
	local original = value
	local signBit = 2 ^ (width - 1)
	local carry = false

	if operation == 0 or operation == 1 then
		local effective = count % width
		if effective == 0 then return value end
		for _ = 1, effective do
			if operation == 0 then
				carry = band(value, signBit) ~= 0
				value = normalize(value * 2 + (carry and 1 or 0), width)
			else
				carry = band(value, 1) ~= 0
				value = normalize(math.floor(value / 2) + (carry and signBit or 0), width)
			end
		end
		cpu:_setFlag(FLAG.CF, carry)
		if effective == 1 then
			if operation == 0 then
				cpu:_setFlag(FLAG.OF, (band(value, signBit) ~= 0) ~= carry)
			else
				local msb = band(value, signBit) ~= 0
				local nextMsb = band(value, signBit / 2) ~= 0
				cpu:_setFlag(FLAG.OF, msb ~= nextMsb)
			end
		end
		return value
	elseif operation == 2 or operation == 3 then
		local effective = count % (width + 1)
		if effective == 0 then return value end
		local cf = flagIsSet(cpu, FLAG.CF)
		for _ = 1, effective do
			if operation == 2 then
				local nextCarry = band(value, signBit) ~= 0
				value = normalize(value * 2 + (cf and 1 or 0), width)
				cf = nextCarry
			else
				local nextCarry = band(value, 1) ~= 0
				value = normalize(math.floor(value / 2) + (cf and signBit or 0), width)
				cf = nextCarry
			end
		end
		cpu:_setFlag(FLAG.CF, cf)
		if effective == 1 then
			if operation == 2 then
				cpu:_setFlag(FLAG.OF, (band(value, signBit) ~= 0) ~= cf)
			else
				local msb = band(value, signBit) ~= 0
				local nextMsb = band(value, signBit / 2) ~= 0
				cpu:_setFlag(FLAG.OF, msb ~= nextMsb)
			end
		end
		return value
	elseif operation == 4 or operation == 6 then
		for _ = 1, count do
			carry = band(value, signBit) ~= 0
			value = normalize(value * 2, width)
		end
		cpu:_setFlag(FLAG.CF, carry)
		if count == 1 then
			cpu:_setFlag(FLAG.OF, (band(value, signBit) ~= 0) ~= carry)
		end
		updateZSP(cpu, value, width)
		return value
	elseif operation == 5 then
		for _ = 1, count do
			carry = band(value, 1) ~= 0
			value = math.floor(value / 2)
		end
		cpu:_setFlag(FLAG.CF, carry)
		if count == 1 then cpu:_setFlag(FLAG.OF, band(original, signBit) ~= 0) end
		updateZSP(cpu, value, width)
		return normalize(value, width)
	elseif operation == 7 then
		for _ = 1, count do
			carry = band(value, 1) ~= 0
			value = math.floor(value / 2)
			if band(value, signBit / 2) ~= 0 or band(original, signBit) ~= 0 then
				value = value + signBit
			end
			original = value
		end
		cpu:_setFlag(FLAG.CF, carry)
		if count == 1 then cpu:_setFlag(FLAG.OF, false) end
		updateZSP(cpu, value, width)
		return normalize(value, width)
	end
	instructionFault(cpu, CPU.EXCEPTION.UD, 0, "invalid shift operation")
end

local function unsignedMultiply32(left, right)
	left, right = u32(left), u32(right)
	local a0, a1 = band(left, 0xFFFF), rshift(left, 16)
	local b0, b1 = band(right, 0xFFFF), rshift(right, 16)
	local p0 = a0 * b0
	local middle = a0 * b1 + a1 * b0
	local lowRaw = p0 + (middle % 0x10000) * 0x10000
	local low = u32(lowRaw)
	local high = u32(a1 * b1 + math.floor(middle / 0x10000) + math.floor(lowRaw / TWO32))
	return high, low
end

local function negate64(high, low)
	low = u32(bnot(low) + 1)
	high = u32(bnot(high) + (low == 0 and 1 or 0))
	return high, low
end

local function signedMultiply32(left, right)
	local negative = (signed(left, 32) < 0) ~= (signed(right, 32) < 0)
	local a = signed(left, 32) < 0 and u32(-signed(left, 32)) or u32(left)
	local b = signed(right, 32) < 0 and u32(-signed(right, 32)) or u32(right)
	local high, low = unsignedMultiply32(a, b)
	if negative then high, low = negate64(high, low) end
	return high, low
end

local function divideUnsigned64(high, low, divisor)
	high, low, divisor = u32(high), u32(low), u32(divisor)
	if divisor == 0 then return nil, nil, "divide-by-zero" end
	local quotient = 0
	local remainder = 0
	for bitIndex = 63, 0, -1 do
		local source = bitIndex >= 32 and high or low
		local sourceBit = bitIndex >= 32 and bitIndex - 32 or bitIndex
		local nextBit = band(rshift(source, sourceBit), 1)
		remainder = remainder * 2 + nextBit
		if remainder >= divisor then
			remainder = remainder - divisor
			if bitIndex >= 32 then
				return nil, nil, "quotient-overflow"
			end
			quotient = bor(quotient, lshift(1, bitIndex))
		end
	end
	return u32(quotient), u32(remainder), nil
end

local function checkIOPermission(cpu, port, width)
	if not cpu.segmented or band(cpu.cr0, 1) == 0 then return end
	if band(cpu.eflags, FLAG.VM) == 0 and cpu.cpl <= band(rshift(cpu.eflags, 12), 3) then return end
	if cpu.tr.limit < 0x67 or port + width / 8 - 1 > 0xFFFF then instructionFault(cpu, CPU.EXCEPTION.GP, 0, "I/O bitmap unavailable") end
	local mapBase = rshift(cpu:systemRead32(cpu.tr.base + 0x64), 16)
	for selected = port, port + width / 8 - 1 do
		local offset = mapBase + math.floor(selected / 8)
		if offset > cpu.tr.limit or band(cpu:systemRead8(cpu.tr.base + offset), lshift(1, selected % 8)) ~= 0 then
			instructionFault(cpu, CPU.EXCEPTION.GP, 0, "I/O port denied by TSS bitmap")
		end
	end
end

local function ioRead(cpu, port, width)
	port = band(port, 0xFFFF)
	checkIOPermission(cpu, port, width)
	local callback = cpu.callbacks.ioRead
	if callback == nil then return widthMask(width) end
	local value = callback(port, width, cpu)
	if value == nil then return widthMask(width) end
	return normalize(value, width)
end

local function ioWrite(cpu, port, width, value)
	port = band(port, 0xFFFF)
	checkIOPermission(cpu, port, width)
	local callback = cpu.callbacks.ioWrite
	if callback ~= nil then callback(port, width, normalize(value, width), cpu) end
end

local function executeALUFamily(cpu, context, opcode)
	local operation = math.floor(opcode / 8)
	local variant = band(opcode, 7)
	if operation > 7 or variant > 5 then return false end
	local width = (variant == 0 or variant == 2 or variant == 4) and 8 or context.operandSize
	if variant <= 3 then
		local modrm = decodeModRM(cpu, context)
		local rmValue = readOperand(cpu, modrm.operand, width)
		local regValue = getRegister(cpu, modrm.reg, width)
		if variant == 0 or variant == 1 then
			local result = applyALU(cpu, operation, rmValue, regValue, width)
			if operation ~= 7 then writeOperand(cpu, modrm.operand, width, result) end
		else
			local result = applyALU(cpu, operation, regValue, rmValue, width)
			if operation ~= 7 then setRegister(cpu, modrm.reg, width, result) end
		end
	else
		local immediate = fetchImmediate(cpu, context, width)
		local left = getRegister(cpu, REG.EAX, width)
		local result = applyALU(cpu, operation, left, immediate, width)
		if operation ~= 7 then setRegister(cpu, REG.EAX, width, result) end
	end
	return true
end

local function multiplyOneOperand(cpu, width, operand, signedMode)
	if width == 8 then
		local left = cpu:getReg8(0)
		local product
		if signedMode then product = signed(left, 8) * signed(operand, 8)
		else product = left * normalize(operand, 8) end
		cpu:setReg16(REG.EAX, product)
		local fits
		if signedMode then fits = product >= -128 and product <= 127
		else fits = product <= 0xFF end
		cpu:_setFlag(FLAG.CF, not fits)
		cpu:_setFlag(FLAG.OF, not fits)
	elseif width == 16 then
		local left = cpu:getReg16(REG.EAX)
		local product
		if signedMode then product = signed(left, 16) * signed(operand, 16)
		else product = left * normalize(operand, 16) end
		local encoded = product
		if encoded < 0 then encoded = encoded + TWO32 end
		cpu:setReg16(REG.EAX, encoded)
		cpu:setReg16(REG.EDX, math.floor(encoded / 0x10000))
		local fits
		if signedMode then fits = product >= -32768 and product <= 32767
		else fits = product <= 0xFFFF end
		cpu:_setFlag(FLAG.CF, not fits)
		cpu:_setFlag(FLAG.OF, not fits)
	else
		local high, low
		if signedMode then high, low = signedMultiply32(cpu:getReg32(REG.EAX), operand)
		else high, low = unsignedMultiply32(cpu:getReg32(REG.EAX), operand) end
		cpu:setReg32(REG.EAX, low)
		cpu:setReg32(REG.EDX, high)
		local fits
		if signedMode then
			fits = (band(low, 0x80000000) == 0 and high == 0)
				or (band(low, 0x80000000) ~= 0 and high == 0xFFFFFFFF)
		else
			fits = high == 0
		end
		cpu:_setFlag(FLAG.CF, not fits)
		cpu:_setFlag(FLAG.OF, not fits)
	end
end

local function truncatingDivide(numerator, divisor)
	local magnitude = math.floor(math.abs(numerator) / math.abs(divisor))
	if (numerator < 0) ~= (divisor < 0) then magnitude = -magnitude end
	return magnitude
end

local function divideOneOperand(cpu, width, operand, signedMode)
	if normalize(operand, width) == 0 then
		instructionFault(cpu, CPU.EXCEPTION.DE, 0, "division by zero")
	end
	if width == 8 then
		local numerator = cpu:getReg16(REG.EAX)
		local divisor = normalize(operand, 8)
		if signedMode then
			numerator, divisor = signed(numerator, 16), signed(divisor, 8)
		end
		local quotient = signedMode and truncatingDivide(numerator, divisor) or math.floor(numerator / divisor)
		local remainder = numerator - quotient * divisor
		if (signedMode and (quotient < -128 or quotient > 127))
			or (not signedMode and quotient > 0xFF) then
			instructionFault(cpu, CPU.EXCEPTION.DE, 0, "division quotient overflow")
		end
		cpu:setReg8(0, quotient)
		cpu:setReg8(4, remainder)
	elseif width == 16 then
		local numerator = cpu:getReg16(REG.EDX) * 0x10000 + cpu:getReg16(REG.EAX)
		local divisor = normalize(operand, 16)
		if signedMode then
			numerator, divisor = signed(numerator, 32), signed(divisor, 16)
		end
		local quotient = signedMode and truncatingDivide(numerator, divisor) or math.floor(numerator / divisor)
		local remainder = numerator - quotient * divisor
		if (signedMode and (quotient < -32768 or quotient > 32767))
			or (not signedMode and quotient > 0xFFFF) then
			instructionFault(cpu, CPU.EXCEPTION.DE, 0, "division quotient overflow")
		end
		cpu:setReg16(REG.EAX, quotient)
		cpu:setReg16(REG.EDX, remainder)
	else
		local high, low = cpu:getReg32(REG.EDX), cpu:getReg32(REG.EAX)
		local divisor = u32(operand)
		if not signedMode then
			local quotient, remainder, reason = divideUnsigned64(high, low, divisor)
			if quotient == nil then
				instructionFault(cpu, CPU.EXCEPTION.DE, 0, "division failed: " .. tostring(reason))
			end
			cpu:setReg32(REG.EAX, quotient)
			cpu:setReg32(REG.EDX, remainder)
		else
			local negativeNumerator = band(high, 0x80000000) ~= 0
			local negativeDivisor = band(divisor, 0x80000000) ~= 0
			if negativeNumerator then high, low = negate64(high, low) end
			local magnitudeDivisor = negativeDivisor and u32(-signed(divisor, 32)) or divisor
			local quotient, remainder, reason = divideUnsigned64(high, low, magnitudeDivisor)
			if quotient == nil then
				instructionFault(cpu, CPU.EXCEPTION.DE, 0, "signed division failed: " .. tostring(reason))
			end
			local negativeQuotient = negativeNumerator ~= negativeDivisor
			if (negativeQuotient and quotient > 0x80000000)
				or (not negativeQuotient and quotient > 0x7FFFFFFF) then
				instructionFault(cpu, CPU.EXCEPTION.DE, 0, "signed division quotient overflow")
			end
			if negativeQuotient then quotient = u32(-quotient) end
			if negativeNumerator then remainder = u32(-remainder) end
			cpu:setReg32(REG.EAX, quotient)
			cpu:setReg32(REG.EDX, remainder)
		end
	end
end

local function executeGroup3(cpu, context, opcode)
	local width = opcode == 0xF6 and 8 or context.operandSize
	local modrm = decodeModRM(cpu, context)
	local operation = modrm.reg
	local value = readOperand(cpu, modrm.operand, width)
	if operation == 0 then
		local immediate = fetchImmediate(cpu, context, width)
		logicalResult(cpu, band(value, immediate), width)
	elseif operation == 1 then
		instructionFault(cpu, CPU.EXCEPTION.UD, 0, "reserved group-3 operation")
	elseif operation == 2 then
		writeOperand(cpu, modrm.operand, width, normalize(bnot(value), width))
	elseif operation == 3 then
		local result = subValues(cpu, 0, value, 0, width)
		cpu:_setFlag(FLAG.CF, value ~= 0)
		writeOperand(cpu, modrm.operand, width, result)
	elseif operation == 4 then
		multiplyOneOperand(cpu, width, value, false)
	elseif operation == 5 then
		multiplyOneOperand(cpu, width, value, true)
	elseif operation == 6 then
		divideOneOperand(cpu, width, value, false)
	else
		divideOneOperand(cpu, width, value, true)
	end
end

local function executeGroup1(cpu, context, opcode)
	local width = opcode == 0x80 and 8 or context.operandSize
	local modrm = decodeModRM(cpu, context)
	local immediate
	if opcode == 0x83 then
		immediate = signExtend(fetch8(cpu, context), 8, width)
	else
		immediate = fetchImmediate(cpu, context, width)
	end
	local left = readOperand(cpu, modrm.operand, width)
	local result = applyALU(cpu, modrm.reg, left, immediate, width)
	if modrm.reg ~= 7 then writeOperand(cpu, modrm.operand, width, result) end
end

local function executeIncDec(cpu, operand, width, decrement)
	local oldCarry = flagIsSet(cpu, FLAG.CF)
	local value = readOperand(cpu, operand, width)
	local result
	if decrement then result = subValues(cpu, value, 1, 0, width)
	else result = addValues(cpu, value, 1, 0, width) end
	cpu:_setFlag(FLAG.CF, oldCarry)
	writeOperand(cpu, operand, width, result)
end

local function executeImulTruncated(cpu, width, left, right)
	if width == 16 then
		local product = signed(left, 16) * signed(right, 16)
		local result = normalize(product, 16)
		local overflow = product < -32768 or product > 32767
		cpu:_setFlag(FLAG.CF, overflow)
		cpu:_setFlag(FLAG.OF, overflow)
		return result
	end
	local high, low = signedMultiply32(left, right)
	local fits = (band(low, 0x80000000) == 0 and high == 0)
		or (band(low, 0x80000000) ~= 0 and high == 0xFFFFFFFF)
	cpu:_setFlag(FLAG.CF, not fits)
	cpu:_setFlag(FLAG.OF, not fits)
	return low
end

local function descriptorTableOperation(cpu, context, operation, operand)
	if operand.kind ~= "mem" then
		instructionFault(cpu, CPU.EXCEPTION.UD, 0, "descriptor-table instruction requires memory")
	end
	local address = cpu:segmentAddress(operand.segment, operand.address, 6)
	if operation == 0 or operation == 1 then
		local source = operation == 0 and cpu.gdtr or cpu.idtr
		cpu:write16(address, source.limit, "write")
		if context.operandSize == 16 then
			cpu:write16(address + 2, source.base, "write")
			cpu:write8(address + 4, rshift(source.base, 16), "write")
			cpu:write8(address + 5, 0, "write")
		else
			cpu:write32(address + 2, source.base, "write")
		end
	elseif operation == 2 or operation == 3 then
		local limit = cpu:read16(address, "read")
		local base
		if context.operandSize == 16 then
			base = bor(cpu:read16(address + 2, "read"), lshift(cpu:read8(address + 4, "read"), 16))
		else
			base = cpu:read32(address + 2, "read")
		end
		local destination = operation == 2 and cpu.gdtr or cpu.idtr
		destination.limit, destination.base = limit, u32(base)
	else
		instructionFault(cpu, CPU.EXCEPTION.UD, 0, "unsupported 0F 01 group operation")
	end
end

local function packAscii4(text, offset)
	local a = string.byte(text, offset) or 0x20
	local b = string.byte(text, offset + 1) or 0x20
	local c = string.byte(text, offset + 2) or 0x20
	local d = string.byte(text, offset + 3) or 0x20
	return u32(a + b * 0x100 + c * 0x10000 + d * 0x1000000)
end

local function executeCpuid(cpu)
	if cpu.options.legacy386 then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "CPUID is unavailable on an 80386") end
	local leaf = cpu:getReg32(REG.EAX)
	local subleaf = cpu:getReg32(REG.ECX)
	local callback = cpu.callbacks.cpuid
	local eax, ebx, ecx, edx
	if callback ~= nil then
		eax, ebx, ecx, edx = callback(leaf, subleaf, cpu)
	end
	if eax == nil then
		if leaf == 0 then
			local vendor = "RoEMU386Core"
			eax = 1
			ebx = packAscii4(vendor, 1)
			edx = packAscii4(vendor, 5)
			ecx = packAscii4(vendor, 9)
		elseif leaf == 1 then
			eax, ebx, ecx, edx = 0x00000300, 0, 0, 0
		else
			eax, ebx, ecx, edx = 0, 0, 0, 0
		end
	end
	cpu:setReg32(REG.EAX, eax or 0)
	cpu:setReg32(REG.EBX, ebx or 0)
	cpu:setReg32(REG.ECX, ecx or 0)
	cpu:setReg32(REG.EDX, edx or 0)
end

local function queryDescriptor(cpu, selector)
	if band(selector, 0xFFFC) == 0 then return nil end
	local localTable = band(selector, 4) ~= 0
	if localTable and band(cpu.ldtr.selector, 0xFFFC) == 0 then return nil end
	local tab = localTable and cpu.ldtr or cpu.gdtr
	local offset = band(selector, 0xFFF8)
	if offset + 7 > tab.limit then return nil end
	local low, high = cpu:systemRead32(tab.base + offset), cpu:systemRead32(tab.base + offset + 4)
	local conforming = band(high, 0x1C00) == 0x1C00
	if not conforming and band(rshift(high, 13), 3) < math.max(cpu.cpl, band(selector, 3)) then return nil end
	return low, high
end

local function executeSecondary(cpu, context)
	local opcode = fetch8(cpu, context)
	context.secondaryOpcode = opcode
	local function ring0()
		if cpu.segmented and cpu.cpl ~= 0 then instructionFault(cpu, CPU.EXCEPTION.GP, 0, "privileged system instruction") end
	end
	if opcode == 0x00 then
		local modrm = decodeModRM(cpu, context)
		if modrm.reg == 0 or modrm.reg == 1 then
			writeOperand(cpu, modrm.operand, 16, (modrm.reg == 0 and cpu.ldtr or cpu.tr).selector)
		elseif modrm.reg == 2 or modrm.reg == 3 then
			ring0()
			local selector = readOperand(cpu, modrm.operand, 16)
			local address = cpu.gdtr.base + band(selector, 0xFFF8)
			local low, high = cpu:read32(address), cpu:read32(address + 4)
			local entry = { selector = selector, base = bor(rshift(low, 16), lshift(band(high, 255), 16), band(high, 0xFF000000)),
				limit = bor(band(low, 0xFFFF), band(high, 0xF0000)) }
			if modrm.reg == 2 then cpu.ldtr = entry else cpu.tr = entry end
		elseif modrm.reg == 4 or modrm.reg == 5 then
			if cpu:isRealMode() then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "selector verification requires protected mode") end
			local low, high = queryDescriptor(cpu, readOperand(cpu, modrm.operand, 16))
			local valid = low ~= nil and band(high, 0x1000) ~= 0
			if valid then
				local code = band(high, 0x800) ~= 0
				valid = modrm.reg == 4 and (not code or band(high, 0x200) ~= 0)
					or modrm.reg == 5 and not code and band(high, 0x200) ~= 0
			end
			cpu:_setFlag(FLAG.ZF, valid)
		else instructionFault(cpu, CPU.EXCEPTION.UD, 0, "invalid system-register group") end
	elseif opcode == 0x02 or opcode == 0x03 then
		if cpu:isRealMode() then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "descriptor query requires protected mode") end
		local modrm = decodeModRM(cpu, context)
		local selector = readOperand(cpu, modrm.operand, 16)
		local low, high = queryDescriptor(cpu, selector)
		local valid = low ~= nil
		if valid and band(high, 0x1000) == 0 then
			local kind = band(rshift(high, 8), 15)
			valid = kind == 1 or kind == 2 or kind == 3 or kind == 9 or kind == 11
				or opcode == 0x02 and (kind == 4 or kind == 5 or kind == 12)
		end
		cpu:_setFlag(FLAG.ZF, valid)
		if valid then
			-- Preserve the descriptor's limit nibble, matching legacy x86 LAR.
			-- Windows round-trips it when updating access rights of >64 KiB bitmaps.
			local value = band(high, 0x00FFFF00)
			if opcode == 0x03 then
				value = bor(band(low, 0xFFFF), band(high, 0xF0000))
				if band(high, 0x800000) ~= 0 then value = value * 4096 + 4095 end
			end
			setRegister(cpu, modrm.reg, context.operandSize, value)
		end
	elseif opcode == 0x08 or opcode == 0x09 then
		ring0()
		-- INVD/WBINVD: guest RAM has no host-side CPU cache.
	elseif opcode == 0x01 then
		local modrm = decodeModRM(cpu, context)
		if modrm.reg == 2 or modrm.reg == 3 or modrm.reg == 6 or modrm.reg == 7 then ring0() end
		if modrm.reg == 4 then
			writeOperand(cpu, modrm.operand, 16, band(cpu.cr0, 0xFFFF))
		elseif modrm.reg == 6 then
			local low = band(readOperand(cpu, modrm.operand, 16), 15)
			cpu.cr0 = bor(band(cpu.cr0, 0xFFFFFFF0), low, band(cpu.cr0, 1))
		elseif modrm.reg == 7 then
			local address = cpu:segmentAddress(modrm.operand.segment, modrm.operand.address)
			cpu.tlb[rshift(address, 12)] = nil
		else descriptorTableOperation(cpu, context, modrm.reg, modrm.operand) end
	elseif opcode == 0x06 then
		ring0()
		cpu.cr0 = band(cpu.cr0, bnot(8))
	elseif opcode == 0x21 or opcode == 0x23 then
		local modrm = decodeModRM(cpu, context)
		if modrm.mod ~= 3 then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "MOV DR requires register") end
		ring0()
		if band(cpu.dr[7], 0x2000) ~= 0 then
			cpu.dr[6] = bor(cpu.dr[6], 0x2000); cpu.dr[7] = band(cpu.dr[7], bnot(0x2000))
			instructionFault(cpu, CPU.EXCEPTION.DB, 0, "debug register general detect")
		end
		local index = modrm.reg
		if index == 4 then index = 6 elseif index == 5 then index = 7 end
		if opcode == 0x21 then cpu:setReg32(modrm.rm, cpu.dr[index] or 0)
		else cpu.dr[index] = cpu:getReg32(modrm.rm) end
	elseif opcode == 0x20 or opcode == 0x22 then
		local modrm = decodeModRM(cpu, context)
		if modrm.mod ~= 3 then
			instructionFault(cpu, CPU.EXCEPTION.UD, 0, "MOV CR requires register operand")
		end
		ring0()
		if opcode == 0x20 then
			cpu:setReg32(modrm.rm, readControl(cpu, modrm.reg))
		else
			writeControl(cpu, modrm.reg, cpu:getReg32(modrm.rm))
		end
	elseif opcode >= 0x80 and opcode <= 0x8F then
		local displacement = signed(fetchImmediate(cpu, context, context.operandSize), context.operandSize)
		if conditionTrue(cpu, band(opcode, 0xF)) then
			cpu.eip = branchTarget(cpu, displacement, context.operandSize)
		end
	elseif opcode >= 0x90 and opcode <= 0x9F then
		local modrm = decodeModRM(cpu, context)
		writeOperand(cpu, modrm.operand, 8, conditionTrue(cpu, band(opcode, 0xF)) and 1 or 0)
	elseif opcode == 0xA0 or opcode == 0xA8 then
		local segment = opcode == 0xA0 and "fs" or "gs"
		push(cpu, context.operandSize, cpu.segments[segment])
	elseif opcode == 0xA1 or opcode == 0xA9 then
		local segment = opcode == 0xA1 and "fs" or "gs"
		cpu:loadSegment(segment, band(pop(cpu, context.operandSize), 0xFFFF))
	elseif opcode == 0xA2 then
		executeCpuid(cpu)
	elseif opcode == 0xAF then
		local modrm = decodeModRM(cpu, context)
		local left = getRegister(cpu, modrm.reg, context.operandSize)
		local right = readOperand(cpu, modrm.operand, context.operandSize)
		setRegister(cpu, modrm.reg, context.operandSize,
			executeImulTruncated(cpu, context.operandSize, left, right))
	elseif opcode == 0xA4 or opcode == 0xA5 or opcode == 0xAC or opcode == 0xAD then
		local modrm = decodeModRM(cpu, context)
		local width = context.operandSize
		local destination = readOperand(cpu, modrm.operand, width)
		local source = getRegister(cpu, modrm.reg, width)
		local count = band((opcode == 0xA4 or opcode == 0xAC) and fetch8(cpu, context) or cpu:getReg8(1), 31)
		if count ~= 0 then
			local right = opcode == 0xAC or opcode == 0xAD
			local result
			if right then
				result = bor(rshift(destination, count), lshift(source, width - count))
				cpu:_setFlag(FLAG.CF, band(rshift(destination, count - 1), 1) ~= 0)
			else
				result = bor(lshift(destination, count), rshift(source, width - count))
				cpu:_setFlag(FLAG.CF, band(rshift(destination, width - count), 1) ~= 0)
			end
			result = normalize(result, width)
			if count == 1 then cpu:_setFlag(FLAG.OF, band(bxor(destination, result), 2 ^ (width - 1)) ~= 0) end
			updateZSP(cpu, result, width)
			writeOperand(cpu, modrm.operand, width, result)
		end
	elseif opcode == 0xB2 or opcode == 0xB4 or opcode == 0xB5 then
		local modrm = decodeModRM(cpu, context)
		if modrm.operand.kind ~= "mem" then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "far pointer requires memory") end
		local address = cpu:segmentAddress(modrm.operand.segment, modrm.operand.address, context.operandSize / 8 + 2)
		local offset = readWidth(cpu, address, context.operandSize)
		local selector = cpu:read16(address + context.operandSize / 8)
		cpu:loadSegment(opcode == 0xB2 and "ss" or opcode == 0xB4 and "fs" or "gs", selector)
		setRegister(cpu, modrm.reg, context.operandSize, offset)
	elseif opcode == 0xBC or opcode == 0xBD then
		local modrm = decodeModRM(cpu, context)
		local value = readOperand(cpu, modrm.operand, context.operandSize)
		cpu:_setFlag(FLAG.ZF, value == 0)
		if value ~= 0 then
			local index = opcode == 0xBC and 0 or context.operandSize - 1
			local delta = opcode == 0xBC and 1 or -1
			while band(rshift(value, index), 1) == 0 do index += delta end
			setRegister(cpu, modrm.reg, context.operandSize, index)
		end
	elseif opcode == 0xA3 or opcode == 0xAB or opcode == 0xB3 or opcode == 0xBB or opcode == 0xBA then
		local modrm = decodeModRM(cpu, context)
		local width = context.operandSize
		local index = opcode == 0xBA and fetch8(cpu, context) or signed(getRegister(cpu, modrm.reg, width), width)
		local operation = opcode == 0xBA and modrm.reg or ({ [0xA3] = 4, [0xAB] = 5, [0xB3] = 6, [0xBB] = 7 })[opcode]
		if operation < 4 then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "bad bit-test group") end
		-- Register bit offsets address a bit string in memory. An immediate
		-- offset is masked to the operand width and never advances the address.
		if modrm.operand.kind == "mem" and opcode ~= 0xBA then modrm.operand.address = normalize(modrm.operand.address + math.floor(index / width) * width / 8, context.addressSize) end
		local mask = lshift(1, index % width)
		local value = readOperand(cpu, modrm.operand, width)
		cpu:_setFlag(FLAG.CF, band(value, mask) ~= 0)
		if operation == 5 then writeOperand(cpu, modrm.operand, width, bor(value, mask))
		elseif operation == 6 then writeOperand(cpu, modrm.operand, width, band(value, bnot(mask)))
		elseif operation == 7 then writeOperand(cpu, modrm.operand, width, bxor(value, mask)) end
	elseif opcode >= 0xC8 and opcode <= 0xCF then
		local value = cpu:getReg32(opcode - 0xC8)
		cpu:setReg32(opcode - 0xC8, bor(lshift(value, 24), lshift(band(value, 0xFF00), 8), rshift(band(value, 0xFF0000), 8), rshift(value, 24)))
	elseif opcode == 0xB6 or opcode == 0xB7 or opcode == 0xBE or opcode == 0xBF then
		local sourceWidth = (opcode == 0xB6 or opcode == 0xBE) and 8 or 16
		local signMode = opcode == 0xBE or opcode == 0xBF
		local modrm = decodeModRM(cpu, context)
		local value = readOperand(cpu, modrm.operand, sourceWidth)
		if signMode then value = signExtend(value, sourceWidth, context.operandSize) end
		setRegister(cpu, modrm.reg, context.operandSize, value)
	elseif opcode == 0x31 then
		if cpu.options.legacy386 then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "RDTSC is unavailable on an 80386") end
		local cycles = cpu.cycleCount
		local low = cycles % TWO32
		local high = math.floor(cycles / TWO32) % TWO32
		cpu:setReg32(REG.EAX, low)
		cpu:setReg32(REG.EDX, high)
	elseif opcode == 0x0B then
		instructionFault(cpu, CPU.EXCEPTION.UD, 0, "UD2")
	else
		instructionFault(cpu, CPU.EXCEPTION.UD, 0,
			string.format("unsupported 0F opcode %02X", opcode))
	end
end

local SEGMENT_BY_ENCODING = { [0] = "es", [1] = "cs", [2] = "ss", [3] = "ds", [4] = "fs", [5] = "gs" }

local function executeSegmentMove(cpu, context, opcode)
	local modrm = decodeModRM(cpu, context)
	local segment = SEGMENT_BY_ENCODING[modrm.reg]
	if segment == nil then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "invalid segment encoding") end
	if opcode == 0x8C then
		-- A 32-bit register destination receives a zero-extended selector.
		-- Memory destinations remain 16 bits even with a 32-bit operand size.
		local width=modrm.operand.kind=="reg" and context.operandSize or 16
		writeOperand(cpu, modrm.operand, width, cpu.segments[segment])
	else
		if segment == "cs" then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "MOV to CS is invalid") end
		cpu:loadSegment(segment, band(readOperand(cpu, modrm.operand, 16), 0xFFFF))
	end
end

local function stringIndex(cpu, register, addressSize)
	return getRegister(cpu, register, addressSize)
end

local function setStringIndex(cpu, register, addressSize, value)
	setRegister(cpu, register, addressSize, value)
end

local function executeStringOnce(cpu, opcode, width, addressSize, sourceSegment)
	local bytes = width / 8
	local delta = flagIsSet(cpu, FLAG.DF) and -bytes or bytes
	local source = stringIndex(cpu, REG.ESI, addressSize)
	local destination = stringIndex(cpu, REG.EDI, addressSize)
	local sourceOffset, destinationOffset = source, destination
	if opcode ~= 0x6C and opcode ~= 0x6D and opcode ~= 0xAA and opcode ~= 0xAB and opcode ~= 0xAE and opcode ~= 0xAF then
		source = cpu:segmentAddress(sourceSegment or "ds", source, bytes)
	end
	if opcode ~= 0x6E and opcode ~= 0x6F and opcode ~= 0xAC and opcode ~= 0xAD then destination = cpu:segmentAddress("es", destination, bytes) end
	if opcode == 0x6C or opcode == 0x6D then
		-- Validate the destination before consuming data from the I/O device.
		cpu:translateLinear(destination, "write"); cpu:translateLinear(destination + bytes - 1, "write")
		writeWidth(cpu, destination, width, ioRead(cpu, cpu:getReg16(REG.EDX), width), "write")
		setStringIndex(cpu, REG.EDI, addressSize, normalize(destinationOffset + delta, addressSize))
	elseif opcode == 0x6E or opcode == 0x6F then
		ioWrite(cpu, cpu:getReg16(REG.EDX), width, readWidth(cpu, source, width, "read"))
		setStringIndex(cpu, REG.ESI, addressSize, normalize(sourceOffset + delta, addressSize))
	elseif opcode == 0xA4 or opcode == 0xA5 then
		writeWidth(cpu, destination, width, readWidth(cpu, source, width, "read"), "write")
		setStringIndex(cpu, REG.ESI, addressSize, normalize(sourceOffset + delta, addressSize))
		setStringIndex(cpu, REG.EDI, addressSize, normalize(destinationOffset + delta, addressSize))
	elseif opcode == 0xA6 or opcode == 0xA7 then
		subValues(cpu, readWidth(cpu, source, width, "read"), readWidth(cpu, destination, width, "read"), 0, width)
		setStringIndex(cpu, REG.ESI, addressSize, normalize(sourceOffset + delta, addressSize))
		setStringIndex(cpu, REG.EDI, addressSize, normalize(destinationOffset + delta, addressSize))
	elseif opcode == 0xAA or opcode == 0xAB then
		writeWidth(cpu, destination, width, getRegister(cpu, REG.EAX, width), "write")
		setStringIndex(cpu, REG.EDI, addressSize, normalize(destinationOffset + delta, addressSize))
	elseif opcode == 0xAC or opcode == 0xAD then
		setRegister(cpu, REG.EAX, width, readWidth(cpu, source, width, "read"))
		setStringIndex(cpu, REG.ESI, addressSize, normalize(sourceOffset + delta, addressSize))
	else
		subValues(cpu, getRegister(cpu, REG.EAX, width), readWidth(cpu, destination, width, "read"), 0, width)
		setStringIndex(cpu, REG.EDI, addressSize, normalize(destinationOffset + delta, addressSize))
	end
end

local function bulkString(cpu, context, opcode, width, maximum)
	if not cpu.options.fastRepStrings or not cpu.callbacks.ramSpan or maximum<2
		or (opcode~=0xA4 and opcode~=0xA5 and opcode~=0xAA and opcode~=0xAB)
		or flagIsSet(cpu,FLAG.DF) or flagIsSet(cpu,FLAG.TF) or cpu.callbacks.onStep
		or cpu.options.traceBytes or band(cpu.dr[7] or 0,255)~=0 then return 0 end
	local bytes=width/8
	local copying=opcode==0xA4 or opcode==0xA5
	local destination=stringIndex(cpu,REG.EDI,context.addressSize)
	local source=copying and stringIndex(cpu,REG.ESI,context.addressSize) or 0
	local addressLimit=context.addressSize==16 and 65536 or 4294967296
	local function span(segment,offset)
		local linear=cpu:segmentAddress(segment,offset,bytes)
		local count=math.min(maximum,math.floor((4096-band(linear,4095))/bytes),math.floor((addressLimit-offset)/bytes))
		if cpu.segmented then
			local entry=cpu.segmentCache[segment]
			local upper=band(entry.access or 0,0x1C)==0x14 and (entry.big and 0xFFFFFFFF or 0xFFFF) or entry.limit
			count=math.min(count,math.floor((upper-offset+1)/bytes))
		end
		return linear,count
	end
	local srcLinear,srcCount
	if copying then srcLinear,srcCount=span(context.segment or "ds",source) end
	local dstLinear,count=span("es",destination)
	if copying then count=math.min(count,srcCount) end
	if count<2 then return 0 end
	local srcBuffer,srcOffset
	if copying then
		local physical=cpu:translateLinear(srcLinear,"read")
		srcBuffer,srcOffset=cpu.callbacks.ramSpan(physical,count*bytes,false)
		if not srcBuffer then return 0 end
	end
	local physical=cpu:translateLinear(dstLinear,"write")
	local dstBuffer,dstOffset=cpu.callbacks.ramSpan(physical,count*bytes,true)
	if not dstBuffer then return 0 end
	local length=count*bytes
	if copying then
		-- REP MOVS is sequential, whereas buffer.copy has memmove semantics.
		-- Aliased/overlapping physical ranges must use the scalar interpreter.
		if srcBuffer==dstBuffer and srcOffset<dstOffset+length and dstOffset<srcOffset+length then return 0 end
		buffer.copy(dstBuffer,dstOffset,srcBuffer,srcOffset,length)
		setStringIndex(cpu,REG.ESI,context.addressSize,normalize(source+length,context.addressSize))
	else
		local value=getRegister(cpu,REG.EAX,width)
		if width==8 or value==0 then buffer.fill(dstBuffer,dstOffset,value,length)
		elseif width==16 then
			local pair=value+value*65536
			for offset=0,length-4,4 do buffer.writeu32(dstBuffer,dstOffset+offset,pair) end
			if length%4~=0 then buffer.writeu16(dstBuffer,dstOffset+length-2,value) end
		else for offset=0,length-4,4 do buffer.writeu32(dstBuffer,dstOffset+offset,value) end end
	end
	setStringIndex(cpu,REG.EDI,context.addressSize,normalize(destination+length,context.addressSize))
	return count
end

local function executeString(cpu, context, opcode)
	local width = (opcode == 0x6C or opcode == 0x6E or opcode == 0xA4 or opcode == 0xA6 or opcode == 0xAA or opcode == 0xAC or opcode == 0xAE)
		and 8 or context.operandSize
	if context.rep == nil then
		executeStringOnce(cpu, opcode, width, context.addressSize, context.segment)
		return
	end
	local count = getRegister(cpu, REG.ECX, context.addressSize)
	local iterations = 0
	local maximum = cpu.options.maxRepIterationsPerStep or 0x100000
	while count ~= 0 do
		local completed=bulkString(cpu,context,opcode,width,math.min(count,maximum-iterations))
		if completed==0 then executeStringOnce(cpu, opcode, width, context.addressSize, context.segment);completed=1 end
		count = normalize(count - completed, context.addressSize)
		setRegister(cpu, REG.ECX, context.addressSize, count)
		iterations = iterations + completed
		cpu:_commitRestartState()
		local compare = opcode == 0xA6 or opcode == 0xA7 or opcode == 0xAE or opcode == 0xAF
		if compare then
			local equal = flagIsSet(cpu, FLAG.ZF)
			if (context.rep == "rep" and not equal) or (context.rep == "repne" and equal) then break end
		end
		if iterations >= maximum and count ~= 0 then
			-- Resume at the same instruction next step, preserving updated SI/DI/CX.
			cpu.eip = cpu._instructionStart
			break
		end
	end
end

local function trySumLoop(cpu, context)
	if not cpu.options.fastSumLoops or context.opcode ~= 0x03 or context.length ~= 1
		or context.operandSize ~= 32 or context.addressSize ~= 32 or cpu.options.traceBytes
		or cpu.interruptShadow ~= 0 or cpu.callbacks.onStep or flagIsSet(cpu, FLAG.TF) or band(cpu.dr[7] or 0, 255) ~= 0 then return false end
	local start = cpu._instructionStart
	if band(start, 0xFFF) > 0xFF8 or (cpu.segmented and start + 7 > cpu.segmentCache.cs.limit) then return false end
	local address = cpu:segmentAddress("cs", start)
	if not cpu.callbacks.canBatchCode or not cpu.callbacks.canBatchCode(cpu:translateLinear(address, "execute"), 8) then return false end
	-- Generic dword-summing loop: ADD EAX,[ESI]; ADD ESI,4; DEC ECX; JNZ.
	for offset, value in ipairs({ 0x06, 0x83, 0xC6, 0x04, 0x49, 0x75, 0xF8 }) do
		if cpu:read8(address + offset, "execute") ~= value then return false end
	end
	local count = cpu:getReg32(REG.ECX)
	local budget = cpu.options.maxSpinInstructions or 1
	if cpu.callbacks.spinBudget then budget = math.min(budget, cpu.callbacks.spinBudget(cpu)) end
	local iterations = math.min(count, math.floor(budget / 4))
	if iterations < 2 then return false end
	context.length = 2
	for _ = 1, iterations do
		local value = cpu:read32(cpu:segmentAddress("ds", cpu:getReg32(REG.ESI), 4))
		cpu:setReg32(REG.EAX, addValues(cpu, cpu:getReg32(REG.EAX), value, 0, 32))
		cpu:setReg32(REG.ESI, addValues(cpu, cpu:getReg32(REG.ESI), 4, 0, 32))
		local carry = flagIsSet(cpu, FLAG.CF)
		count = subValues(cpu, count, 1, 0, 32)
		cpu:setReg32(REG.ECX, count); cpu:_setFlag(FLAG.CF, carry)
		cpu.instructionCount += 4; cpu.cycleCount += 4
		cpu.eip = count == 0 and u32(start + 8) or start
		cpu:_commitRestartState()
	end
	-- CPU:step retires the final instruction and publishes the completed block.
	cpu.instructionCount -= 1; cpu.cycleCount -= 1
	context.length = 8
	return true
end

local function executeOne(cpu, context)
	parsePrefixes(cpu, context)
	local opcode = context.opcode
	if band(cpu.dr[7] or 0, 255) ~= 0 and not flagIsSet(cpu, FLAG.RF) then
		local linear = cpu:segmentAddress("cs", cpu._instructionStart)
		local matches = 0
		for index = 0, 3 do
			if band(rshift(cpu.dr[7], index * 2), 3) ~= 0 and band(rshift(cpu.dr[7], 16 + index * 4), 3) == 0 and cpu.dr[index] == linear then matches = bor(matches, lshift(1, index)) end
		end
		if matches ~= 0 then
			cpu.dr[6] = bor(cpu.dr[6], matches)
			instructionFault(cpu, CPU.EXCEPTION.DB, 0, "instruction breakpoint")
		end
	end
	if opcode ~= 0xCF and flagIsSet(cpu, FLAG.RF) then cpu:_setFlag(FLAG.RF, false) end
	if trySumLoop(cpu, context) then return end

	if opcode == 0x63 then
		if cpu:isRealMode() then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "ARPL requires protected mode") end
		local modrm = decodeModRM(cpu, context)
		local destination = readOperand(cpu, modrm.operand, 16)
		local requested = band(cpu:getReg16(modrm.reg), 3)
		local changed = band(destination, 3) < requested
		cpu:_setFlag(FLAG.ZF, changed)
		if changed then writeOperand(cpu, modrm.operand, 16, bor(band(destination, 0xFFFC), requested)) end
		return
	elseif executeALUFamily(cpu, context, opcode) then
		return
	elseif opcode == 0x27 or opcode == 0x2F then
		local original = cpu:getReg8(0)
		local carry = flagIsSet(cpu, FLAG.CF)
		local value = original
		local subtract = opcode == 0x2F
		if band(original, 15) > 9 or flagIsSet(cpu, FLAG.AF) then
			value = normalize(value + (subtract and -6 or 6), 8)
			cpu:_setFlag(FLAG.AF, true)
		else cpu:_setFlag(FLAG.AF, false) end
		if original > 0x99 or carry then
			value = normalize(value + (subtract and -0x60 or 0x60), 8)
			cpu:_setFlag(FLAG.CF, true)
		else cpu:_setFlag(FLAG.CF, false) end
		cpu:setReg8(0, value)
		updateZSP(cpu, value, 8)
	elseif opcode == 0x37 or opcode == 0x3F then
		local adjust = band(cpu:getReg8(0), 15) > 9 or flagIsSet(cpu, FLAG.AF)
		if adjust then cpu:setReg16(0, cpu:getReg16(0) + (opcode == 0x37 and 0x106 or -0x106)) end
		cpu:setReg8(0, band(cpu:getReg8(0), 15))
		cpu:_setFlag(FLAG.AF, adjust); cpu:_setFlag(FLAG.CF, adjust)
	elseif opcode == 0x06 or opcode == 0x0E or opcode == 0x16 or opcode == 0x1E then
		local segment = ({ [0x06] = "es", [0x0E] = "cs", [0x16] = "ss", [0x1E] = "ds" })[opcode]
		push(cpu, context.operandSize, cpu.segments[segment])
	elseif opcode == 0x07 or opcode == 0x17 or opcode == 0x1F then
		local segment = ({ [0x07] = "es", [0x17] = "ss", [0x1F] = "ds" })[opcode]
		cpu:loadSegment(segment, band(pop(cpu, context.operandSize), 0xFFFF))
	elseif opcode >= 0x40 and opcode <= 0x47 then
		executeIncDec(cpu, { kind = "reg", index = opcode - 0x40 }, context.operandSize, false)
	elseif opcode >= 0x48 and opcode <= 0x4F then
		executeIncDec(cpu, { kind = "reg", index = opcode - 0x48 }, context.operandSize, true)
	elseif opcode >= 0x50 and opcode <= 0x57 then
		push(cpu, context.operandSize, getRegister(cpu, opcode - 0x50, context.operandSize))
	elseif opcode >= 0x58 and opcode <= 0x5F then
		setRegister(cpu, opcode - 0x58, context.operandSize, pop(cpu, context.operandSize))
	elseif opcode == 0x60 then
		local originalStack = getRegister(cpu, REG.ESP, context.operandSize)
		push(cpu, context.operandSize, getRegister(cpu, REG.EAX, context.operandSize))
		push(cpu, context.operandSize, getRegister(cpu, REG.ECX, context.operandSize))
		push(cpu, context.operandSize, getRegister(cpu, REG.EDX, context.operandSize))
		push(cpu, context.operandSize, getRegister(cpu, REG.EBX, context.operandSize))
		push(cpu, context.operandSize, originalStack)
		push(cpu, context.operandSize, getRegister(cpu, REG.EBP, context.operandSize))
		push(cpu, context.operandSize, getRegister(cpu, REG.ESI, context.operandSize))
		push(cpu, context.operandSize, getRegister(cpu, REG.EDI, context.operandSize))
	elseif opcode == 0x61 then
		setRegister(cpu, REG.EDI, context.operandSize, pop(cpu, context.operandSize))
		setRegister(cpu, REG.ESI, context.operandSize, pop(cpu, context.operandSize))
		setRegister(cpu, REG.EBP, context.operandSize, pop(cpu, context.operandSize))
		pop(cpu, context.operandSize)
		setRegister(cpu, REG.EBX, context.operandSize, pop(cpu, context.operandSize))
		setRegister(cpu, REG.EDX, context.operandSize, pop(cpu, context.operandSize))
		setRegister(cpu, REG.ECX, context.operandSize, pop(cpu, context.operandSize))
		setRegister(cpu, REG.EAX, context.operandSize, pop(cpu, context.operandSize))
	elseif opcode >= 0x6C and opcode <= 0x6F then
		executeString(cpu, context, opcode)
	elseif opcode == 0x68 then
		push(cpu, context.operandSize, fetchImmediate(cpu, context, context.operandSize))
	elseif opcode == 0x69 or opcode == 0x6B then
		local modrm = decodeModRM(cpu, context)
		local source = readOperand(cpu, modrm.operand, context.operandSize)
		local immediate
		if opcode == 0x6B then immediate = signExtend(fetch8(cpu, context), 8, context.operandSize)
		else immediate = fetchImmediate(cpu, context, context.operandSize) end
		setRegister(cpu, modrm.reg, context.operandSize,
			executeImulTruncated(cpu, context.operandSize, source, immediate))
	elseif opcode == 0x6A then
		push(cpu, context.operandSize, signExtend(fetch8(cpu, context), 8, context.operandSize))
	elseif opcode >= 0x70 and opcode <= 0x7F then
		local displacement = signed(fetch8(cpu, context), 8)
		if conditionTrue(cpu, band(opcode, 0xF)) then
			cpu.eip = branchTarget(cpu, displacement, context.operandSize)
		end
	elseif opcode == 0x80 or opcode == 0x81 or opcode == 0x83 then
		executeGroup1(cpu, context, opcode)
	elseif opcode == 0x82 then
		instructionFault(cpu, CPU.EXCEPTION.UD, 0, "reserved opcode 82")
	elseif opcode == 0x84 or opcode == 0x85 then
		local width = opcode == 0x84 and 8 or context.operandSize
		local modrm = decodeModRM(cpu, context)
		logicalResult(cpu, band(readOperand(cpu, modrm.operand, width), getRegister(cpu, modrm.reg, width)), width)
	elseif opcode == 0x86 or opcode == 0x87 then
		local width = opcode == 0x86 and 8 or context.operandSize
		local modrm = decodeModRM(cpu, context)
		local left = readOperand(cpu, modrm.operand, width)
		local right = getRegister(cpu, modrm.reg, width)
		writeOperand(cpu, modrm.operand, width, right)
		setRegister(cpu, modrm.reg, width, left)
	elseif opcode >= 0x88 and opcode <= 0x8B then
		local width = (opcode == 0x88 or opcode == 0x8A) and 8 or context.operandSize
		local modrm = decodeModRM(cpu, context)
		if opcode == 0x88 or opcode == 0x89 then
			writeOperand(cpu, modrm.operand, width, getRegister(cpu, modrm.reg, width))
		else
			setRegister(cpu, modrm.reg, width, readOperand(cpu, modrm.operand, width))
		end
	elseif opcode == 0x8C or opcode == 0x8E then
		executeSegmentMove(cpu, context, opcode)
	elseif opcode == 0x8D then
		local modrm = decodeModRM(cpu, context)
		if modrm.operand.kind ~= "mem" then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "LEA requires memory") end
		setRegister(cpu, modrm.reg, context.operandSize, modrm.operand.address)
	elseif opcode == 0x8F then
		local modrm = decodeModRM(cpu, context)
		if modrm.reg ~= 0 then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "invalid POP r/m group") end
		local oldESP = cpu:getReg32(REG.ESP)
		local value = pop(cpu, context.operandSize)
		if modrm.operand.kind == "mem" and context.addressSize == 32 and modrm.rm == 4 and band(modrm.sib, 7) == 4 then
			modrm.operand.address = u32(modrm.operand.address + cpu:getReg32(REG.ESP) - oldESP)
		end
		writeOperand(cpu, modrm.operand, context.operandSize, value)
	elseif opcode == 0x90 then
		-- NOP (XCHG EAX,EAX)
	elseif opcode >= 0x91 and opcode <= 0x97 then
		local index = opcode - 0x90
		local eax = getRegister(cpu, REG.EAX, context.operandSize)
		local other = getRegister(cpu, index, context.operandSize)
		setRegister(cpu, REG.EAX, context.operandSize, other)
		setRegister(cpu, index, context.operandSize, eax)
	elseif opcode == 0x98 then
		if context.operandSize == 16 then
			cpu:setReg16(REG.EAX, signExtend(cpu:getReg8(0), 8, 16))
		else
			cpu:setReg32(REG.EAX, signExtend(cpu:getReg16(REG.EAX), 16, 32))
		end
	elseif opcode == 0x99 then
		if context.operandSize == 16 then
			cpu:setReg16(REG.EDX, signed(cpu:getReg16(REG.EAX), 16) < 0 and 0xFFFF or 0)
		else
			cpu:setReg32(REG.EDX, signed(cpu:getReg32(REG.EAX), 32) < 0 and 0xFFFFFFFF or 0)
		end
	elseif opcode == 0x9B then
		-- WAIT is a no-op until an x87 coprocessor is attached.
	elseif opcode == 0x9C then
		if cpu.segmented and band(cpu.eflags, FLAG.VM) ~= 0 and band(rshift(cpu.eflags, 12), 3) < 3 then instructionFault(cpu, CPU.EXCEPTION.GP, 0, "PUSHF virtual privilege") end
		push(cpu, context.operandSize, context.operandSize == 32 and band(cpu.eflags, 0x00FCFFFF) or cpu.eflags)
	elseif opcode == 0x9D then
		local mask = context.operandSize == 16 and 0xFFFF or 0xFFFFFFFF
		if cpu.segmented and band(cpu.eflags, FLAG.VM) ~= 0 and band(rshift(cpu.eflags, 12), 3) < 3 then instructionFault(cpu, CPU.EXCEPTION.GP, 0, "POPF virtual privilege") end
		local protected = context.operandSize == 16 and 0xFFFF0000 or 0x001A0000
		if cpu.segmented and band(cpu.cr0, 1) ~= 0 and cpu.cpl ~= 0 then
			protected = bor(protected, FLAG.IOPL)
			if cpu.cpl > band(rshift(cpu.eflags, 12), 3) then protected = bor(protected, FLAG.IF) end
		end
		local value = pop(cpu, context.operandSize)
		if context.operandSize == 32 then value = band(value, bnot(FLAG.RF)) end
		cpu.eflags = bor(band(cpu.eflags, protected), band(value, band(mask, bnot(protected))), FLAG.RESERVED)
	elseif opcode == 0x9E then
		local ah = cpu:getReg8(4)
		local statusMask = bor(FLAG.SF, FLAG.ZF, FLAG.AF, FLAG.PF, FLAG.CF)
		cpu.eflags = bor(band(cpu.eflags, bnot(statusMask)), band(ah, statusMask), FLAG.RESERVED)
	elseif opcode == 0x9F then
		cpu:setReg8(4, bor(band(cpu.eflags, 0xD5), FLAG.RESERVED))
	elseif opcode >= 0xA0 and opcode <= 0xA3 then
		local width = (opcode == 0xA0 or opcode == 0xA2) and 8 or context.operandSize
		local address = cpu:segmentAddress(context.segment or "ds", fetchImmediate(cpu, context, context.addressSize), width / 8)
		if opcode == 0xA0 or opcode == 0xA1 then
			setRegister(cpu, REG.EAX, width, readWidth(cpu, address, width, "read"))
		else
			writeWidth(cpu, address, width, getRegister(cpu, REG.EAX, width), "write")
		end
	elseif opcode >= 0xA4 and opcode <= 0xA7 then
		executeString(cpu, context, opcode)
	elseif opcode == 0xA8 or opcode == 0xA9 then
		local width = opcode == 0xA8 and 8 or context.operandSize
		logicalResult(cpu, band(getRegister(cpu, REG.EAX, width), fetchImmediate(cpu, context, width)), width)
	elseif opcode >= 0xAA and opcode <= 0xAF then
		executeString(cpu, context, opcode)
	elseif opcode >= 0xB0 and opcode <= 0xB7 then
		cpu:setReg8(opcode - 0xB0, fetch8(cpu, context))
	elseif opcode >= 0xB8 and opcode <= 0xBF then
		setRegister(cpu, opcode - 0xB8, context.operandSize,
			fetchImmediate(cpu, context, context.operandSize))
	elseif opcode == 0xC0 or opcode == 0xC1 then
		local width = opcode == 0xC0 and 8 or context.operandSize
		local modrm = decodeModRM(cpu, context)
		local count = fetch8(cpu, context)
		writeOperand(cpu, modrm.operand, width,
			performShift(cpu, modrm.reg, readOperand(cpu, modrm.operand, width), count, width))
	elseif opcode == 0xC2 then
		local adjustment = fetch16(cpu, context)
		cpu.eip = directTarget(pop(cpu, context.operandSize), context.operandSize)
		setStackPointer(cpu, normalize(stackPointer(cpu) + adjustment, cpu.stackAddressSize))
	elseif opcode == 0xC3 then
		cpu.eip = directTarget(pop(cpu, context.operandSize), context.operandSize)
	elseif opcode == 0xC4 or opcode == 0xC5 then
		local modrm = decodeModRM(cpu, context)
		if modrm.operand.kind ~= "mem" then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "LDS/LES requires memory") end
		local address = cpu:segmentAddress(modrm.operand.segment, modrm.operand.address, context.operandSize / 8 + 2)
		local offset = readWidth(cpu, address, context.operandSize)
		local selector = cpu:read16(address + context.operandSize / 8)
		cpu:loadSegment(opcode == 0xC4 and "es" or "ds", selector)
		setRegister(cpu, modrm.reg, context.operandSize, offset)
	elseif opcode == 0xCA or opcode == 0xCB then
		local adjustment = opcode == 0xCA and fetch16(cpu, context) or 0
		local offset, selector = pop(cpu, context.operandSize), pop(cpu, context.operandSize)
		cpu:loadSegment("cs", selector)
		cpu.eip = directTarget(offset, context.operandSize)
		setStackPointer(cpu, normalize(stackPointer(cpu) + adjustment, cpu.stackAddressSize))
	elseif opcode == 0xC6 or opcode == 0xC7 then
		local width = opcode == 0xC6 and 8 or context.operandSize
		local modrm = decodeModRM(cpu, context)
		if modrm.reg ~= 0 then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "invalid MOV immediate group") end
		writeOperand(cpu, modrm.operand, width, fetchImmediate(cpu, context, width))
	elseif opcode == 0xC8 then
		local allocation = fetch16(cpu, context)
		local nesting = band(fetch8(cpu, context), 0x1F)
		local frame = getRegister(cpu, REG.EBP, context.operandSize)
		push(cpu, context.operandSize, getRegister(cpu, REG.EBP, context.operandSize))
		local newFrame = stackPointer(cpu)
		if nesting > 0 then
			for _ = 1, nesting - 1 do
				frame = normalize(frame - context.operandSize / 8, context.operandSize)
				push(cpu, context.operandSize, readWidth(cpu, cpu:segmentAddress("ss", frame, context.operandSize / 8), context.operandSize, "read"))
			end
			push(cpu, context.operandSize, newFrame)
		end
		setRegister(cpu, REG.EBP, context.operandSize, newFrame)
		setStackPointer(cpu, normalize(stackPointer(cpu) - allocation, cpu.stackAddressSize))
	elseif opcode == 0xC9 then
		setStackPointer(cpu, getRegister(cpu, REG.EBP, cpu.stackAddressSize))
		setRegister(cpu, REG.EBP, context.operandSize, pop(cpu, context.operandSize))
	elseif opcode == 0xCC then
		cpu:_deliverInterrupt(3, true, cpu.eip)
	elseif opcode == 0xCD then
		cpu:_deliverInterrupt(fetch8(cpu, context), true, cpu.eip)
	elseif opcode == 0xCE then
		if flagIsSet(cpu, FLAG.OF) then cpu:_deliverInterrupt(4, true, cpu.eip) end
	elseif opcode == 0xCF then
		if cpu.segmented and band(cpu.eflags, FLAG.VM) ~= 0 and band(rshift(cpu.eflags, 12), 3) < 3 then instructionFault(cpu, CPU.EXCEPTION.GP, 0, "IRET virtual privilege") end
		local oldCPL, oldFlags = cpu.cpl, cpu.eflags
		local newEip = pop(cpu, context.operandSize)
		local newCs = pop(cpu, context.operandSize)
		local newFlags = pop(cpu, context.operandSize)
		if cpu.segmented and context.operandSize == 32 and cpu.cpl == 0 and band(newFlags, FLAG.VM) ~= 0 then
			local newSP, newSS = pop(cpu, 32), pop(cpu, 32)
			local newES, newDS, newFS, newGS = pop(cpu, 32), pop(cpu, 32), pop(cpu, 32), pop(cpu, 32)
			cpu.eflags = bor(newFlags, FLAG.RESERVED)
			cpu.cpl = 3
			cpu:loadSegment("cs", newCs); cpu:loadSegment("ss", newSS)
			cpu:loadSegment("es", newES); cpu:loadSegment("ds", newDS); cpu:loadSegment("fs", newFS); cpu:loadSegment("gs", newGS)
			cpu:setReg32(REG.ESP, newSP)
			cpu.eip = band(newEip, 0xFFFF)
			return
		end
		if cpu.segmented and band(cpu.cr0, 1) ~= 0 and not cpu:isRealMode() and band(newCs, 3) > cpu.cpl then
			local newSP, newSS = pop(cpu, context.operandSize), pop(cpu, context.operandSize)
			cpu.cpl = band(newCs, 3)
			cpu:loadSegment("ss", newSS)
			-- Legacy IRET restores only SP when returning to a 16-bit stack.
			setStackPointer(cpu, newSP)
		end
		cpu.eip = directTarget(newEip, context.operandSize)
		cpu:loadSegment("cs", band(newCs, 0xFFFF))
		if context.operandSize == 16 then
			cpu.eflags = bor(band(cpu.eflags, 0xFFFF0000), band(newFlags, 0xFFFF), FLAG.RESERVED)
		else
			cpu.eflags = bor(u32(newFlags), FLAG.RESERVED)
		end
		if cpu.segmented and band(cpu.cr0, 1) ~= 0 and oldCPL ~= 0 then
			local preserve = bor(FLAG.IOPL, band(oldFlags, FLAG.VM) ~= 0 and FLAG.VM or 0, 0x00180000)
			if oldCPL > band(rshift(oldFlags, 12), 3) then preserve = bor(preserve, FLAG.IF) end
			cpu.eflags = bor(band(cpu.eflags, bnot(preserve)), band(oldFlags, preserve))
		end
	elseif opcode == 0xD0 or opcode == 0xD1 or opcode == 0xD2 or opcode == 0xD3 then
		local width = (opcode == 0xD0 or opcode == 0xD2) and 8 or context.operandSize
		local count = (opcode == 0xD0 or opcode == 0xD1) and 1 or cpu:getReg8(1)
		local modrm = decodeModRM(cpu, context)
		writeOperand(cpu, modrm.operand, width,
			performShift(cpu, modrm.reg, readOperand(cpu, modrm.operand, width), count, width))
	elseif opcode == 0xD4 or opcode == 0xD5 then
		local base = fetch8(cpu, context)
		if opcode == 0xD4 then
			if base == 0 then instructionFault(cpu, CPU.EXCEPTION.DE, 0, "AAM divide by zero") end
			local value = cpu:getReg8(0)
			cpu:setReg8(4, math.floor(value / base)); cpu:setReg8(0, value % base)
		else
			cpu:setReg8(0, cpu:getReg8(0) + cpu:getReg8(4) * base); cpu:setReg8(4, 0)
		end
		updateZSP(cpu, cpu:getReg8(0), 8)
	elseif opcode == 0xD6 then
		cpu:setReg8(0, flagIsSet(cpu, FLAG.CF) and 255 or 0)
	elseif opcode == 0xD7 then
		local offset = normalize(getRegister(cpu, REG.EBX, context.addressSize) + cpu:getReg8(0), context.addressSize)
		cpu:setReg8(0, cpu:read8(cpu:segmentAddress(context.segment or "ds", offset)))
	elseif opcode >= 0xD8 and opcode <= 0xDF then
		-- An 80386 without an 80387 still decodes ESC addressing. With EM/TS
		-- enabled the OS receives #NM and can provide software floating point.
		local _modrm = decodeModRM(cpu, context)
		if band(cpu.cr0, 12) ~= 0 then instructionFault(cpu, CPU.EXCEPTION.NM, 0, "x87 unavailable (EM/TS)") end
		-- No external coprocessor is installed: FNINIT is ignored and status
		-- stores leave their memory sentinel untouched, as the detection expects.
	elseif opcode >= 0xE0 and opcode <= 0xE3 then
		local displacement = signed(fetch8(cpu, context), 8)
		local count = getRegister(cpu, REG.ECX, context.addressSize)
		local take
		if opcode == 0xE3 then
			take = count == 0
		else
			count = normalize(count - 1, context.addressSize)
			-- A self-targeting LOOP has no memory or flag side effects. Collapse
			-- only up to the platform's next interrupt boundary, retaining every
			-- retired instruction and virtual clock tick. Debug stepping stays exact.
			if opcode == 0xE2 and displacement == -2 and context.length == 2 and not cpu.options.traceBytes
				and cpu.options.fastSpinLoops and cpu.interruptShadow == 0
				and cpu.callbacks.onStep == nil
				and not flagIsSet(cpu, FLAG.TF) and band(cpu.dr[7] or 0, 255) == 0 then
				local budget = cpu.options.maxSpinInstructions or 1
				if cpu.callbacks.spinBudget then budget = math.min(budget, cpu.callbacks.spinBudget(cpu)) end
				local extra = math.min(count, math.max(0, budget - 1))
				count -= extra
				cpu.instructionCount += extra
				cpu.cycleCount += extra
			end
			setRegister(cpu, REG.ECX, context.addressSize, count)
			if opcode == 0xE0 then take = count ~= 0 and not flagIsSet(cpu, FLAG.ZF)
			elseif opcode == 0xE1 then take = count ~= 0 and flagIsSet(cpu, FLAG.ZF)
			else take = count ~= 0 end
		end
		if take then cpu.eip = branchTarget(cpu, displacement, context.operandSize) end
	elseif opcode == 0xE4 or opcode == 0xE5 then
		local width = opcode == 0xE4 and 8 or context.operandSize
		setRegister(cpu, REG.EAX, width, ioRead(cpu, fetch8(cpu, context), width))
	elseif opcode == 0xE6 or opcode == 0xE7 then
		local width = opcode == 0xE6 and 8 or context.operandSize
		ioWrite(cpu, fetch8(cpu, context), width, getRegister(cpu, REG.EAX, width))
	elseif opcode == 0xE8 then
		local displacement = signed(fetchImmediate(cpu, context, context.operandSize), context.operandSize)
		local returnAddress = cpu.eip
		push(cpu, context.operandSize, returnAddress)
		cpu.eip = branchTarget(cpu, displacement, context.operandSize)
	elseif opcode == 0xE9 then
		local displacement = signed(fetchImmediate(cpu, context, context.operandSize), context.operandSize)
		cpu.eip = branchTarget(cpu, displacement, context.operandSize)
	elseif opcode == 0xEA or opcode == 0x9A then
		local offset = fetchImmediate(cpu, context, context.operandSize)
		local selector = fetch16(cpu, context)
		if opcode == 0x9A then
			push(cpu, context.operandSize, cpu.segments.cs)
			push(cpu, context.operandSize, cpu.eip)
		end
		cpu:loadSegment("cs", selector)
		cpu.eip = directTarget(offset, context.operandSize)
	elseif opcode == 0xEB then
		cpu.eip = branchTarget(cpu, signed(fetch8(cpu, context), 8), context.operandSize)
	elseif opcode == 0xEC or opcode == 0xED then
		local width = opcode == 0xEC and 8 or context.operandSize
		setRegister(cpu, REG.EAX, width, ioRead(cpu, cpu:getReg16(REG.EDX), width))
	elseif opcode == 0xEE or opcode == 0xEF then
		local width = opcode == 0xEE and 8 or context.operandSize
		ioWrite(cpu, cpu:getReg16(REG.EDX), width, getRegister(cpu, REG.EAX, width))
	elseif opcode == 0xF4 then
		if cpu.segmented and cpu.cpl ~= 0 then instructionFault(cpu, CPU.EXCEPTION.GP, 0, "HLT privilege") end
		cpu.halted = true
	elseif opcode == 0xF5 then
		cpu:_setFlag(FLAG.CF, not flagIsSet(cpu, FLAG.CF))
	elseif opcode == 0xF6 or opcode == 0xF7 then
		executeGroup3(cpu, context, opcode)
	elseif opcode == 0xF8 then cpu:_setFlag(FLAG.CF, false)
	elseif opcode == 0xF9 then cpu:_setFlag(FLAG.CF, true)
	elseif opcode == 0xFA or opcode == 0xFB then
		if cpu.segmented and cpu.cpl > band(rshift(cpu.eflags, 12), 3) then instructionFault(cpu, CPU.EXCEPTION.GP, 0, "IF privilege") end
		cpu:_setFlag(FLAG.IF, opcode == 0xFB)
		if opcode == 0xFB then cpu.interruptShadow = 2 end
	elseif opcode == 0xFC then cpu:_setFlag(FLAG.DF, false)
	elseif opcode == 0xFD then cpu:_setFlag(FLAG.DF, true)
	elseif opcode == 0xFE then
		local modrm = decodeModRM(cpu, context)
		if modrm.reg > 1 then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "invalid FE group operation") end
		executeIncDec(cpu, modrm.operand, 8, modrm.reg == 1)
	elseif opcode == 0xFF then
		local modrm = decodeModRM(cpu, context)
		if modrm.reg == 0 or modrm.reg == 1 then
			executeIncDec(cpu, modrm.operand, context.operandSize, modrm.reg == 1)
		elseif modrm.reg == 2 then
			local target = readOperand(cpu, modrm.operand, context.operandSize)
			push(cpu, context.operandSize, cpu.eip)
			cpu.eip = directTarget(target, context.operandSize)
		elseif modrm.reg == 4 then
			cpu.eip = directTarget(readOperand(cpu, modrm.operand, context.operandSize), context.operandSize)
		elseif modrm.reg == 3 or modrm.reg == 5 then
			if modrm.operand.kind ~= "mem" then instructionFault(cpu, CPU.EXCEPTION.UD, 0, "far target requires memory") end
			local address = cpu:segmentAddress(modrm.operand.segment, modrm.operand.address, context.operandSize / 8 + 2)
			local offset = readWidth(cpu, address, context.operandSize)
			local selector = cpu:read16(address + context.operandSize / 8)
			if modrm.reg == 3 then push(cpu, context.operandSize, cpu.segments.cs); push(cpu, context.operandSize, cpu.eip) end
			cpu:loadSegment("cs", selector)
			cpu.eip = directTarget(offset, context.operandSize)
		elseif modrm.reg == 6 then
			push(cpu, context.operandSize, readOperand(cpu, modrm.operand, context.operandSize))
		else
			instructionFault(cpu, CPU.EXCEPTION.UD, 0, "far or reserved FF group operation")
		end
	elseif opcode == 0x0F then
		executeSecondary(cpu, context)
	else
		instructionFault(cpu, CPU.EXCEPTION.UD, 0, string.format("unsupported opcode %02X", opcode))
	end
end

function CPU:_commitRestartState()
	for index = 1, 8 do self._restartRegs[index] = self.regs[index] end
	self._restartFlags = self.eflags
end

function CPU:_saveRestartState()
	self:_commitRestartState()
	self._restartEip, self._restartCpl = self.eip, self.cpl
	self._restartOperand, self._restartAddress, self._restartStack = self.defaultOperandSize, self.defaultAddressSize, self.stackAddressSize
	self._restartSegmentDirty = false
end

function CPU:_restoreRestartState()
	for index = 1, 8 do self.regs[index] = self._restartRegs[index] end
	self.eflags, self.eip, self.cpl = self._restartFlags, self._restartEip, self._restartCpl
	self.defaultOperandSize, self.defaultAddressSize, self.stackAddressSize = self._restartOperand, self._restartAddress, self._restartStack
	if self._restartSegmentDirty then
		for name, value in pairs(self._restartSegments) do self.segments[name], self.segmentCache[name] = value, self._restartCaches[name] end
	end
end

function CPU:step()
	if self.halted then
		return { kind = "halted", eip = self.eip, instructionCount = self.instructionCount }
	end
	local start = self.eip
	local singleStep = flagIsSet(self, FLAG.TF)
	self._debugMatches = 0
	self._instructionStart = start
	self:_saveRestartState()
	self._transactionActive = true
	local context
	if self.options.reuseDecodeState and not self.options.traceBytes and self.callbacks.onStep == nil then
		context = self._decodeContext
		context.length, context.bytes, context.opcode = 0, nil, nil
		context.fetchBuffer=nil
	else context = { length = 0, bytes = self.options.traceBytes and {} or nil } end
	local ok, result = pcall(executeOne, self, context)
	if not ok then
		if type(result) == "table" and result.__x86Exception then
			if result.rewind then self:_restoreRestartState() end
			self._transactionActive = false
			result.length = context.length
			result.bytes = context.bytes
			self.lastException = result
			self.lastInstruction = {
				start = start, finish = self.eip, length = context.length,
				bytes = context.bytes, exception = result,
			}
			local callback = self.callbacks.onException
			if callback ~= nil then
				local action = callback(result, self)
				if action == true or action == "handled" then result.handled = true end
			end
			self._instructionStart = nil
			return result
		end
		local hostError = {
			kind = "host_error", message = tostring(result), eip = start,
			length = context.length, bytes = context.bytes,
		}
		self.lastInstruction = hostError
		self._transactionActive = false
		self._instructionStart = nil
		return hostError
	end

	-- 386 reserved FLAGS bits stay zero; AC/ID cannot be toggled to advertise
	-- a 486/Pentium instruction set that this machine does not provide.
	if self.options.legacy386 then self.eflags = bor(band(self.eflags, 0x00037FD7), FLAG.RESERVED) end
	self.instructionCount = self.instructionCount + 1
	if self.interruptShadow > 0 then self.interruptShadow -= 1 end
	self.cycleCount = self.cycleCount + 1
	self.lastException = nil
	self.lastInstruction = {
		kind = self.halted and "halted" or "ok",
		start = start,
		finish = self.eip,
		length = context.length,
		bytes = context.bytes,
		opcode = context.opcode,
		operandSize = context.operandSize,
		addressSize = context.addressSize,
	}
	self._instructionStart = nil
	self._transactionActive = false
	local loadsSS = context.opcode == 0x17 or (context.opcode == 0x8E and context.decoded and context.decoded.reg == 2)
		or (context.opcode == 0x0F and context.secondaryOpcode == 0xB2)
	local softwareInt = context.opcode == 0xCC or context.opcode == 0xCD or (context.opcode == 0xCE and not flagIsSet(self, FLAG.TF))
	local debugStatus = self._debugMatches or 0
	if singleStep and not loadsSS and not softwareInt then debugStatus = bor(debugStatus, 0x4000) end
	if debugStatus ~= 0 and not loadsSS then
		self.dr[6] = bor(self.dr[6], debugStatus)
		self.halted = false
		self.lastException = { kind = "exception", vector = CPU.EXCEPTION.DB, name = "#DB", errorCode = 0,
			eip = self.eip, rewind = false, detail = "completed instruction debug trap" }
		return self.lastException
	end
	local callback = self.callbacks.onStep
	if callback ~= nil then callback(self.lastInstruction, self) end
	return self.lastInstruction
end

function CPU:run(maxInstructions, options)
	options = options or {}
	maxInstructions = math.max(0, math.floor(tonumber(maxInstructions) or 0))
	local executed = 0
	local lastResult = nil
	while executed < maxInstructions do
		if options.shouldStop ~= nil and options.shouldStop(self, executed) then
			return { kind = "stopped", executed = executed, eip = self.eip, last = lastResult }
		end
		local oldSpin = self.options.maxSpinInstructions
		local remaining = maxInstructions - executed
		if options.shouldStop then remaining = 1 end
		if options.yieldEvery and options.onYield then remaining = math.min(remaining, options.yieldEvery - executed % options.yieldEvery) end
		self.options.maxSpinInstructions = math.min(oldSpin or 1, remaining)
		local before = self.instructionCount
		lastResult = self:step()
		self.options.maxSpinInstructions = oldSpin
		if lastResult.kind == "ok" then
			executed = executed + math.max(1, self.instructionCount - before)
		elseif lastResult.kind == "halted" then
			if self.halted then executed = executed + 1 end
			return { kind = "halted", executed = executed, eip = self.eip, last = lastResult }
		elseif lastResult.kind == "exception" and lastResult.handled then
			executed = executed + math.max(1, self.instructionCount - before)
		else
			executed = executed + math.max(0, self.instructionCount - before)
			return { kind = lastResult.kind, executed = executed, eip = self.eip, last = lastResult }
		end
		if options.yieldEvery ~= nil and options.onYield ~= nil
			and executed % options.yieldEvery == 0 then
			options.onYield(self, executed)
		end
	end
	return { kind = "limit", executed = executed, eip = self.eip, last = lastResult }
end

function CPU:resume()
	self.halted = false
end

function CPU:exportState()
	local handlers = {}
	local caches={};for name,entry in pairs(self.segmentCache) do caches[name]=table.clone(entry) end
	for vector, gate in pairs(self.interruptHandlers) do
		handlers[vector] = {
			offset = u32(gate.offset), selector = band(gate.selector or 0, 0xFFFF),
			type = gate.type, dpl = gate.dpl, present = gate.present ~= false,
		}
	end
	return {
		format = "RoEMU-i386-state-v1",
		regs = cloneArray(self.regs, 8),
		eip = u32(self.eip), eflags = u32(self.eflags),
		cr0 = u32(self.cr0), cr2 = u32(self.cr2), cr3 = u32(self.cr3),
		segments = {
			cs = self.segments.cs, ds = self.segments.ds, es = self.segments.es,
			ss = self.segments.ss, fs = self.segments.fs, gs = self.segments.gs,
		},
		gdtr = { base = self.gdtr.base, limit = self.gdtr.limit },
		idtr = { base = self.idtr.base, limit = self.idtr.limit },
		cpl = self.cpl,
		defaultOperandSize = self.defaultOperandSize,
		defaultAddressSize = self.defaultAddressSize,
		stackAddressSize = self.stackAddressSize,
		segmented = self.segmented, segmentCache = caches, cr4 = self.cr4, ldtr = table.clone(self.ldtr), tr = table.clone(self.tr), dr = table.clone(self.dr),
		halted = self.halted,
		instructionCount = self.instructionCount,
		cycleCount = self.cycleCount,
		interruptHandlers = handlers,
	}
end

function CPU:importState(state)
	assert(type(state) == "table", "i386 state must be a table")
	self.regs = cloneArray(state.regs, 8)
	self.eip = u32(state.eip)
	self.eflags = bor(u32(state.eflags), FLAG.RESERVED)
	self.cr0, self.cr2, self.cr3 = u32(state.cr0), u32(state.cr2), u32(state.cr3)
	for _, name in ipairs({ "cs", "ds", "es", "ss", "fs", "gs" }) do
		if state.segments and state.segments[name] ~= nil then
			self.segments[name] = band(state.segments[name], 0xFFFF)
		end
	end
	if state.gdtr then self.gdtr = { base = u32(state.gdtr.base), limit = band(state.gdtr.limit or 0, 0xFFFF) } end
	if state.idtr then self.idtr = { base = u32(state.idtr.base), limit = band(state.idtr.limit or 0, 0xFFFF) } end
	self.cpl = band(state.cpl or self.cpl, 3)
	self.defaultOperandSize = state.defaultOperandSize == 16 and 16 or 32
	self.defaultAddressSize = state.defaultAddressSize == 16 and 16 or 32
	self.stackAddressSize = state.stackAddressSize == 16 and 16 or 32
	self.segmented = state.segmented == true
	self.segmentCache = {};for name,entry in pairs(state.segmentCache or {}) do self.segmentCache[name]=table.clone(entry) end
	self.cr4 = state.cr4 or 0
	self.ldtr = state.ldtr and table.clone(state.ldtr) or { base = 0, limit = 0, selector = 0 }
	self.tr = state.tr and table.clone(state.tr) or { base = 0, limit = 0, selector = 0 }
	self.dr = {};for key,value in pairs(state.dr or { [6]=0xFFFF0FF0,[7]=0x400 }) do self.dr[tonumber(key)]=value end
	self.interruptShadow = 0
	self.tlb = {}
	self.halted = state.halted == true
	self.instructionCount = tonumber(state.instructionCount) or 0
	self.cycleCount = tonumber(state.cycleCount) or 0
	self.interruptHandlers = {}
	for vector, gate in pairs(state.interruptHandlers or {}) do
		self.interruptHandlers[tonumber(vector)] = {
			offset = u32(gate.offset), selector = band(gate.selector or 0, 0xFFFF),
			type = gate.type, dpl = gate.dpl, present = gate.present ~= false,
		}
	end
	self.lastException = nil
	self.lastInstruction = nil
	return self
end

CPU.serializeState = CPU.exportState
CPU.restoreState = CPU.importState

function CPU:reset(optionsOrState)
	optionsOrState = optionsOrState or {}
	if optionsOrState.format == "RoEMU-i386-state-v1" then
		return self:importState(optionsOrState)
	end
	local fresh = CPU.new(self.callbacks, optionsOrState)
	self.options = fresh.options
	return self:importState(fresh:exportState())
end

return CPU

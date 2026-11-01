--!native
--!optimize 2
-- PLIC QEMU virt, suficiente para un hart con contextos M y S.

local bit = bit32
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

local PLIC = {}
PLIC.__index = PLIC

local function source_count(cfg)
	if type(cfg) == "number" then return math.max(1, math.floor(cfg)) end
	if type(cfg) ~= "table" then return 95 end
	if type(cfg.num_sources) == "number" then return math.max(1, math.floor(cfg.num_sources)) end
	if type(cfg.nsrc) == "number" then return math.max(1, math.floor(cfg.nsrc)) end
	if type(cfg.sources) == "number" then return math.max(1, math.floor(cfg.sources)) end
	if type(cfg.sources) == "table" then return math.max(1, #cfg.sources) end
	return 95
end

function PLIC.new(cfg)
	local self = setmetatable({}, PLIC)
	self.num_sources = source_count(cfg)
	self.prio = table.create(self.num_sources, 0)
	self.pending = table.create(self.num_sources, false)
	self.level = table.create(self.num_sources, false)
	self.enabled = { [0] = table.create(self.num_sources, false), [1] = table.create(self.num_sources, false) }
	self.threshold = { [0] = 0, [1] = 0 }
	self.claimed = { [0] = 0, [1] = 0 }
	self._core = nil
	return self
end

function PLIC:_best(context)
	local best, bestPriority = 0, -1
	local enabled = self.enabled[context]
	local threshold = self.threshold[context] or 0
	for irq = 1, self.num_sources do
		local priority = self.prio[irq] or 0
		if self.pending[irq] and enabled[irq] and priority > threshold and priority > bestPriority then
			best, bestPriority = irq, priority
		end
	end
	return best
end

function PLIC:_update_lines()
	local core = self._core
	if not core then return end
	if type(core.set_meip) == "function" then core:set_meip(self:_best(0) ~= 0) end
	if type(core.set_seip) == "function" then core:set_seip(self:_best(1) ~= 0) end
end

function PLIC:bind_core(core)
	self._core = core
	self:_update_lines()
end

function PLIC:set_source_level(irq, asserted)
	irq = math.floor(tonumber(irq) or 0)
	if irq < 1 or irq > self.num_sources then return end
	local level = asserted and true or false
	self.level[irq] = level
	if level then self.pending[irq] = true end
	self:_update_lines()
end

function PLIC:raise_irq(irq)
	self:set_source_level(irq, true)
end

function PLIC:complete_irq(irq)
	irq = math.floor(tonumber(irq) or 0)
	if irq < 1 or irq > self.num_sources then return end
	self.pending[irq] = self.level[irq] and true or false
	self:_update_lines()
end

local function read_bits(values, first, count, limit)
	local word = 0
	for bitIndex = 0, count - 1 do
		local irq = first + bitIndex
		if irq <= limit and values[irq] then word = bor(word, lshift(1, bitIndex)) end
	end
	return word
end

local function write_enable_bits(self, context, first, value)
	local enabled = self.enabled[context]
	for bitIndex = 0, 31 do
		local irq = first + bitIndex
		if irq >= 1 and irq <= self.num_sources then
			enabled[irq] = band(value, lshift(1, bitIndex)) ~= 0
		end
	end
	self:_update_lines()
end

function PLIC:read32(addr)
	addr = band(tonumber(addr) or 0, 0xFFFFFFFF)
	if addr < 0x1000 and addr % 4 == 0 then
		local irq = addr // 4
		return (irq >= 1 and irq <= self.num_sources) and (self.prio[irq] or 0) or 0
	end
	if addr >= 0x1000 and addr < 0x1080 and addr % 4 == 0 then
		local first = ((addr - 0x1000) // 4) * 32
		return read_bits(self.pending, first, 32, self.num_sources)
	end
	for context = 0, 1 do
		local base = 0x2000 + context * 0x80
		if addr >= base and addr < base + 0x80 and addr % 4 == 0 then
			local first = ((addr - base) // 4) * 32
			return read_bits(self.enabled[context], first, 32, self.num_sources)
		end
		local contextBase = 0x200000 + context * 0x1000
		if addr == contextBase then return self.threshold[context] or 0 end
		if addr == contextBase + 4 then
			local irq = self:_best(context)
			self.claimed[context] = irq
			if irq ~= 0 then self.pending[irq] = false end
			self:_update_lines()
			return irq
		end
	end
	return 0
end

function PLIC:write32(addr, value)
	addr = band(tonumber(addr) or 0, 0xFFFFFFFF)
	value = band(tonumber(value) or 0, 0xFFFFFFFF)
	if addr < 0x1000 and addr % 4 == 0 then
		local irq = addr // 4
		if irq >= 1 and irq <= self.num_sources then self.prio[irq] = band(value, 0x7) end
		self:_update_lines()
		return
	end
	for context = 0, 1 do
		local base = 0x2000 + context * 0x80
		if addr >= base and addr < base + 0x80 and addr % 4 == 0 then
			local first = ((addr - base) // 4) * 32
			write_enable_bits(self, context, first, value)
			return
		end
		local contextBase = 0x200000 + context * 0x1000
		if addr == contextBase then
			self.threshold[context] = band(value, 0x7)
			self:_update_lines()
			return
		elseif addr == contextBase + 4 then
			self.claimed[context] = 0
			self:complete_irq(value)
			return
		end
	end
end

return { new = PLIC.new }

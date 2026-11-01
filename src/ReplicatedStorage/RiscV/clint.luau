-- ReplicatedStorage/RiscV/clint.lua
-- CLINT mínimo compatible con QEMU virt (RV32) + reflejo CSR time/timeh

local bor, band = bit32.bor, bit32.band

local rshift, lshift = bit32.rshift, bit32.lshift

local CLINT_BASE  = 0x02000000
local REGION_SIZE = 0x00010000

local CSR_TIME  = 0xC01
local CSR_TIMEH = 0xC81

local function normalize(off)
	if off < REGION_SIZE then
		return off
	end
	if off >= CLINT_BASE and off < CLINT_BASE + REGION_SIZE then
		return off - CLINT_BASE
	end
	return off
end

local function u64(lo, hi)
	lo = lo % 2^32
	hi = hi % 2^32
	return hi * 2^32 + lo
end

local function split64(x)
	x = math.max(0, x)
	local lo = x % 2^32
	local hi = (x - lo) / 2^32
	return lo, hi
end

local CLINT = {}
CLINT.__index = CLINT

function CLINT.new(core)
	local self = setmetatable({}, CLINT)

	self.msip      = 0
	self.mtime_lo  = 0
	self.mtime_hi  = 0
	self.mcmp_lo   = 0xFFFFFFFF
	self.mcmp_hi   = 0xFFFFFFFF

	self._mtip_raised = false
	self._core = core or nil

	return self
end

function CLINT:bind_core(core)
	self._core = core
end

function CLINT:get_mtime()
	return u64(self.mtime_lo, self.mtime_hi)
end

function CLINT:_mtimecmp()
	return u64(self.mcmp_lo, self.mcmp_hi)
end

function CLINT:_update_mtip()
	local c = self._core
	if not c or not c.set_mtip then return end

	local t   = self:get_mtime()
	local cmp = self:_mtimecmp()
	local want = (t >= cmp)

	if want ~= self._mtip_raised then
		self._mtip_raised = want
		c:set_mtip(want)
	end
end

function CLINT:set_mtimecmp_abs(t)
	self.mcmp_lo, self.mcmp_hi = split64(t or 0)
	self:_update_mtip()
end

function CLINT:set_mtimecmp_delta(delta)
	local t = self:get_mtime() + math.max(0, delta or 0)
	self:set_mtimecmp_abs(t)
end

function CLINT:read32(off)
	off = normalize(off)

	if off == 0x0000 then return self.msip end
	if off == 0x4000 then return self.mcmp_lo end
	if off == 0x4004 then return self.mcmp_hi end
	if off == 0xBFF8 then return self.mtime_lo end
	if off == 0xBFFC then return self.mtime_hi end

	return 0
end

function CLINT:write32(off, val)
	off = normalize(off)
	val = band(val or 0, 0xFFFFFFFF)

	if off == 0x0000 then
		self.msip = band(val, 1)
		if self._core and self._core.set_msip then
			self._core:set_msip(self.msip ~= 0)
		end
		return
	end

	if off == 0x4000 then
		self:set_mtimecmp_abs(u64(val, self.mcmp_hi)); return
	end
	if off == 0x4004 then
		self:set_mtimecmp_abs(u64(self.mcmp_lo, val)); return
	end

	if off == 0xBFF8 then
		self.mtime_lo = val
		self:_update_mtip()
		return
	end
	if off == 0xBFFC then
		self.mtime_hi = val
		self:_update_mtip()
		return
	end
end

function CLINT:tick(cycles, core)
	cycles = tonumber(cycles) or 1
	if cycles <= 0 then return end

	if core and core ~= self._core then
		self._core = core
	end

	local t = self:get_mtime() + cycles
	self.mtime_lo, self.mtime_hi = split64(t)

	self:_update_mtip()

	-- Reflejar CSR time/timeh
	local c = self._core
	if c and c.cpu and c.cpu.csr then
		c.cpu.csr[CSR_TIME]  = self.mtime_lo
		c.cpu.csr[CSR_TIMEH] = self.mtime_hi
	end
end

return { new = CLINT.new }

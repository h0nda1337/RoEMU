--!native
--!optimize 2
-- ReplicatedStorage/RiscV/core
-- RV32IMC core (Luau) con:
--  - RVC (16-bit) + RV32M
--  - Bus RAM/ROM/MMIO
--  - Traps M/S/U con delegacion medeleg/mideleg y mret/sret
--  - IRQs de maquina y supervisor (timer/software/external)
--  - ECALL opcional tipo "SBI": si cpu.on_sbi(...) maneja, se salta trap
--  - CSR cycle/time/instret (y high) mínimos
--  - Compat: cpu.regs proxy (0..31), cpu.csrs alias, cpu.csr_mtvec/csr_mstatus..., cpu.mem[addr] byte-proxy
--  - core.on_trap(mcause, mtval, core, cpu) callback

local bit  = bit32
local band, bor, bxor = bit.band, bit.bor, bit.bxor
local lshift, rshift  = bit.lshift, bit.rshift
local arshift, bnot   = bit.arshift, bit.bnot

local function u32(x) return band(tonumber(x) or 0, 0xFFFFFFFF) end
local function s32(x)
	x = u32(x)
	if x >= 0x80000000 then return x - 0x100000000 end
	return x
end
local function sext(x, bits)
	local m = lshift(1, bits - 1)
	x = band(x, lshift(1, bits) - 1)
	return (bxor(x, m)) - m
end
local function get_bits(v, hi, lo)
	local w = hi - lo + 1
	return band(rshift(v, lo), lshift(1, w) - 1)
end

-- ==== CSR addrs (mínimos) ====
local CSR = {
	SSTATUS=0x100, SIE=0x104, STVEC=0x105, SCOUNTEREN=0x106,
	SSCRATCH=0x140, SEPC=0x141, SCAUSE=0x142, STVAL=0x143, SIP=0x144,
	SATP=0x180,
	MSTATUS=0x300, MISA=0x301, MIE=0x304, MTVEC=0x305, MSCRATCH=0x340,
	MEDELEG=0x302, MIDELEG=0x303, MCOUNTEREN=0x306,
	MEPC=0x341, MCAUSE=0x342, MTVAL=0x343, MIP=0x344,

	-- counters (RO)
	CYCLE=0xC00, TIME=0xC01, INSTRET=0xC02,
	CYCLEH=0xC80, TIMEH=0xC81, INSTRETH=0xC82,
}

-- MSTATUS bits
local MSTATUS_SIE  = 0x2
local MSTATUS_MIE  = 0x8
local MSTATUS_SPIE = 0x20
local MSTATUS_MPIE = 0x80
local MSTATUS_SPP  = 0x100
local MSTATUS_MPP_SHIFT = 11
local MSTATUS_MPRV = 0x00020000
local SSTATUS_MASK = 0x800DE122

-- MIP/MIE bits
local MIP_SSIP = lshift(1,1)
local MIP_MSIP = lshift(1,3)
local MIP_STIP = lshift(1,5)
local MIP_MTIP = lshift(1,7)
local MIP_SEIP = lshift(1,9)
local MIP_MEIP = lshift(1,11)

local MIE_SSIE = MIP_SSIP
local MIE_MSIE = MIP_MSIP
local MIE_STIE = MIP_STIP
local MIE_MTIE = lshift(1,7)
local MIE_SEIE = MIP_SEIP
local MIE_MEIE = lshift(1,11)

-- Causes
local CAUSE_IRQ_S_SOFT  = 0x80000001
local CAUSE_IRQ_M_TIMER = 0x80000007
local CAUSE_IRQ_S_TIMER = 0x80000005
local CAUSE_IRQ_S_EXT   = 0x80000009
local CAUSE_IRQ_M_EXT   = 0x8000000B
local CAUSE_IRQ_M_SOFT  = 0x80000003
local CAUSE_ILLEGAL     = 2
local CAUSE_BREAKPOINT  = 3
local CAUSE_ECALL_U     = 8
local CAUSE_ECALL_S     = 9
local CAUSE_ECALL_M     = 11
local CAUSE_INST_PAGE_FAULT  = 12
local CAUSE_LOAD_PAGE_FAULT  = 13
local CAUSE_STORE_PAGE_FAULT = 15

local PRIV_U = 0
local PRIV_S = 1
local PRIV_M = 3

-- ==== Bus ====
local function new_bus()
	return {
		regions = {},
		map = function(self, lo, hi, rd, wr, tick)
			local region = {lo=lo, hi=hi, rd=rd, wr=wr, tick=tick}
			table.insert(self.regions, region)
			return region
		end,
		find = function(self, addr)
			for _,r in ipairs(self.regions) do
				if addr >= r.lo and addr <= r.hi then return r end
			end
		end,
		read32 = function(self, addr)
			local r = self:find(addr); if not r then return 0 end
			return r.rd(addr)
		end,
		write32 = function(self, addr, val)
			local r = self:find(addr); if r and r.wr then r.wr(addr, val) end
		end,
		tick = function(self, cycles)
			for _,r in ipairs(self.regions) do
				if r.tick then r.tick(cycles) end
			end
		end
	}
end

local function new_ram(lo, size_bytes)
	local hi = lo + size_bytes - 1
	local mem = buffer.create(size_bytes)

	-- Compatibilidad para utilidades antiguas. La ruta caliente usa el buffer.
	local bytes = setmetatable({}, {
		__index = function(_, index)
			if type(index) ~= "number" then return nil end
			local off = index - 1
			if off < 0 or off >= size_bytes then return nil end
			return buffer.readu8(mem, off)
		end,
		__newindex = function(_, index, value)
			if type(index) ~= "number" then return end
			local off = index - 1
			if off < 0 or off >= size_bytes then return end
			buffer.writeu8(mem, off, value)
		end,
		__len = function()
			return size_bytes
		end,
	})

	local function rd32(addr)
		local off = addr - lo
		if off < 0 or off + 3 >= size_bytes then return 0 end
		return buffer.readu32(mem, off)
	end

	local function wr32(addr, val)
		local off = addr - lo
		if off < 0 or off + 3 >= size_bytes then return end
		buffer.writeu32(mem, off, val)
	end

	return {
		lo = lo,
		hi = hi,
		rd = rd32,
		wr = wr32,
		bytes = bytes,
		buffer = mem,
		size = size_bytes,
	}
end

local function new_rom(lo, bytes)
	local hi = lo + #bytes - 1
	local function rd32(addr)
		local off = addr - lo
		local b0 = bytes[off+1] or 0
		local b1 = bytes[off+2] or 0
		local b2 = bytes[off+3] or 0
		local b3 = bytes[off+4] or 0
		return bor(b0, lshift(b1,8), lshift(b2,16), lshift(b3,24))
	end
	return { lo=lo, hi=hi, rd=rd32, wr=nil }
end

-- ==== Core forward decl (para mem-proxy) ====
local Core = {}; Core.__index = Core

-- ==== Unaligned helpers (read/write byte/half/word) ====
local function loadN(core, addr, size, signed, access)
	addr = u32(addr)
	core.__mem_access = access or "R"
	if size == 1 then
		local v = core:read8(addr)
		return u32(signed and sext(v, 8) or v)
	elseif size == 2 then
		local v = core:read16(addr)
		return u32(signed and sext(v, 16) or v)
	end

	local function rd32(a) return core:read32(a) end
	local word = rd32(band(addr, 0xFFFFFFFC))
	local off = band(addr, 3)
	local v

	if off==0 then
		v = word
	else
		local w2 = rd32(band(addr+4, 0xFFFFFFFC))
		local s = off*8
		v = bor(rshift(word, s), lshift(w2, 32 - s))
	end
	return u32(v)
end

local function storeN(core, addr, size, val)
	addr, val = u32(addr), u32(val)
	core.__mem_access = "W"
	if size==1 then
		core:write8(addr, val)
		return
	elseif size==2 then
		core:write16(addr, val)
		return
	else
		local base = band(addr, 0xFFFFFFFC)
		if band(addr,3)==0 then
			core:write32(base, val)
		else
			local off = band(addr, 3)
			local s   = off*8
			local w   = core:read32(base)
			local low = bor(band(w, bnot(lshift(0xFFFFFFFF, s))), lshift(val, s))
			core:write32(base, low)
			local w2  = core:read32(base+4)
			local high= bor(band(w2, bnot(rshift(0xFFFFFFFF, 32 - s))), rshift(val, 32 - s))
			core:write32(base+4, high)
		end
	end
end

local function rawRead8(core, addr)
	addr = u32(addr)
	local ram = core.__main_ram
	if ram and addr >= ram.lo and addr <= ram.hi then
		return buffer.readu8(ram.buffer, addr - ram.lo)
	end
	local region = core.bus:find(addr)
	if not region then return 0 end
	if region.rd8 then return band(region.rd8(addr), 0xFF) end
	local base = band(addr, 0xFFFFFFFC)
	local word = region.rd and region.rd(base) or 0
	return band(rshift(word, band(addr, 3) * 8), 0xFF)
end

local function rawWrite8(core, addr, val)
	addr, val = u32(addr), band(u32(val), 0xFF)
	local ram = core.__main_ram
	if ram and addr >= ram.lo and addr <= ram.hi then
		buffer.writeu8(ram.buffer, addr - ram.lo, val)
		return
	end
	local region = core.bus:find(addr)
	if not region then return end
	if region.wr8 then region.wr8(addr, val); return end
	if not region.wr then return end
	local base = band(addr, 0xFFFFFFFC)
	local shift = band(addr, 3) * 8
	local old = region.rd and region.rd(base) or 0
	local mask = bnot(lshift(0xFF, shift))
	region.wr(base, bor(band(old, mask), lshift(val, shift)))
end

function Core:read8(addr)
	return rawRead8(self, addr)
end

function Core:write8(addr, val)
	rawWrite8(self, addr, val)
end

function Core:read16(addr)
	addr = u32(addr)
	return bor(rawRead8(self, addr), lshift(rawRead8(self, u32(addr + 1)), 8))
end

function Core:write16(addr, val)
	addr, val = u32(addr), u32(val)
	rawWrite8(self, addr, val)
	rawWrite8(self, u32(addr + 1), rshift(val, 8))
end

-- ==== regs proxy ====
local function make_regs_proxy(x)
	return setmetatable({}, {
		__index = function(_, k)
			if type(k) ~= "number" then return nil end
			if k == 0 then return 0 end
			return x[k+1] or 0
		end,
		__newindex = function(_, k, v)
			if type(k) ~= "number" then return end
			if k == 0 then return end
			x[k+1] = u32(v or 0)
		end
	})
end

-- ==== CPU object + compat fields ====
local function new_cpu(core_ref)
	local cpu_raw = {
		pc=0, x=table.create(32,0), csr={}, priv=PRIV_M, halted=false,
		cycles=0, instret=0,
		_core = core_ref,
	}

	cpu_raw.regs = make_regs_proxy(cpu_raw.x) -- compat regs[0..31]
	cpu_raw.csrs = cpu_raw.csr               -- alias

	-- cpu.mem[address] byte-proxy
	cpu_raw.mem = setmetatable({}, {
		__index = function(_, addr)
			if type(addr) ~= "number" then return nil end
			return core_ref:read8(addr)
		end,
		__newindex = function(_, addr, v)
			if type(addr) ~= "number" then return end
			core_ref:write8(addr, v or 0)
		end,
	})

	-- cpu:run(...) compat (delegado)
	function cpu_raw:run(steps, yieldEvery)
		return self._core:run(steps, yieldEvery)
	end

	-- Compat CSR “planos” (cpu.csr_mtvec = ...)
	local csr_key_to_addr = {
		csr_mstatus = CSR.MSTATUS,
		csr_mie     = CSR.MIE,
		csr_mip     = CSR.MIP,
		csr_mtvec   = CSR.MTVEC,
		csr_mepc    = CSR.MEPC,
		csr_mcause  = CSR.MCAUSE,
		csr_mtval   = CSR.MTVAL,
	}

	return setmetatable(cpu_raw, {
		__index = function(t, k)
			if k == "mode" then
				return t.priv
			end
			local a = csr_key_to_addr[k]
			if a then
				return t.csr[a] or 0
			end
			return rawget(t, k)
		end,
		__newindex = function(t, k, v)
			if k == "mode" then
				t.priv = u32(v) % 4
				return
			end
			local a = csr_key_to_addr[k]
			if a then
				-- MTVEC alineado
				if a == CSR.MTVEC then v = band(u32(v), 0xFFFFFFFC) end
				t.csr[a] = u32(v)
				return
			end
			rawset(t, k, v)
		end
	})
end

-- ==== CSR read/write ====
local function counter_hi(value)
	return u32(math.floor((tonumber(value) or 0) / 0x100000000))
end

local function csr_read(core, cpu, addr)
	addr = u32(addr)
	local v = cpu.csr[addr] or 0

	-- MISA (RV32 + I M C)
	if addr == CSR.MISA then
		return u32(0x40141105) -- RV32 + A/C/I/M/S/U
	end
	if addr == CSR.SSTATUS then
		return band(cpu.csr[CSR.MSTATUS] or 0, SSTATUS_MASK)
	end
	if addr == CSR.SIE then
		return band(cpu.csr[CSR.MIE] or 0, cpu.csr[CSR.MIDELEG] or 0)
	end
	if addr == CSR.SIP then
		return band(cpu.csr[CSR.MIP] or 0, cpu.csr[CSR.MIDELEG] or 0)
	end

	-- Counters RV32. CLINT refleja time/timeh en la tabla CSR.
	if addr == CSR.CYCLE then return u32(cpu.cycles) end
	if addr == CSR.CYCLEH then return counter_hi(cpu.cycles) end
	if addr == CSR.TIME then return u32(cpu.csr[CSR.TIME] or cpu.cycles) end
	if addr == CSR.TIMEH then return u32(cpu.csr[CSR.TIMEH] or counter_hi(cpu.cycles)) end
	if addr == CSR.INSTRET then return u32(cpu.instret) end
	if addr == CSR.INSTRETH then return counter_hi(cpu.instret) end

	return u32(v)
end

local function normalize_tvec(val)
	local mode = band(val, 0x3)
	if mode > 1 then mode = 0 end
	return bor(band(val, 0xFFFFFFFC), mode)
end

local function csr_write(core, cpu, addr, val)
	addr = u32(addr); val = u32(val)
	if addr == CSR.SSTATUS then
		local old = cpu.csr[CSR.MSTATUS] or 0
		cpu.csr[CSR.MSTATUS] = bor(band(old, bnot(SSTATUS_MASK)), band(val, SSTATUS_MASK))
		return
	elseif addr == CSR.SIE then
		local mask = cpu.csr[CSR.MIDELEG] or 0
		local old = cpu.csr[CSR.MIE] or 0
		cpu.csr[CSR.MIE] = bor(band(old, bnot(mask)), band(val, mask))
		return
	elseif addr == CSR.SIP then
		local mask = cpu.csr[CSR.MIDELEG] or 0
		local old = cpu.csr[CSR.MIP] or 0
		cpu.csr[CSR.MIP] = bor(band(old, bnot(mask)), band(val, mask))
		return
	end

	if addr == CSR.MTVEC or addr == CSR.STVEC then val = normalize_tvec(val) end
	if addr == CSR.MEPC or addr == CSR.SEPC then val = band(val, 0xFFFFFFFE) end
	-- Counters RO: ignorar
	if addr == CSR.CYCLE or addr == CSR.CYCLEH or addr == CSR.TIME or addr == CSR.TIMEH or addr == CSR.INSTRET or addr == CSR.INSTRETH then
		return
	end
	local old = cpu.csr[addr]
	cpu.csr[addr] = val
	if addr == CSR.SATP and old ~= val and type(core.__flush_sv32) == "function" then
		pcall(core.__flush_sv32, core)
	end
end

local function set_mip(cpu, bits_set, bits_clr)
	local mip = cpu.csr[CSR.MIP] or 0
	mip = bor(band(mip, bnot(bits_clr or 0)), bits_set or 0)
	cpu.csr[CSR.MIP] = u32(mip)
end

local function trap_delegated_to_s(cpu, cause)
	if (cpu.priv or PRIV_M) == PRIV_M then return false end
	local code = band(cause, 0x7FFFFFFF)
	local deleg = band(cause, 0x80000000) ~= 0
		and (cpu.csr[CSR.MIDELEG] or 0)
		or (cpu.csr[CSR.MEDELEG] or 0)
	return band(deleg, lshift(1, code)) ~= 0
end

local function interrupt_globally_enabled(cpu, targetPriv)
	local current = cpu.priv or PRIV_M
	if current < targetPriv then return true end
	if current > targetPriv then return false end
	local status = cpu.csr[CSR.MSTATUS] or 0
	if targetPriv == PRIV_M then return band(status, MSTATUS_MIE) ~= 0 end
	return band(status, MSTATUS_SIE) ~= 0
end

-- ==== Trap enter / mret / sret ====
local function trap_enter(core, cause, tval)
	local cpu = core.cpu
	local delegated = trap_delegated_to_s(cpu, cause)
	local mstatus = cpu.csr[CSR.MSTATUS] or 0

	if delegated then
		csr_write(core, cpu, CSR.SEPC, cpu.pc)
		csr_write(core, cpu, CSR.SCAUSE, cause)
		csr_write(core, cpu, CSR.STVAL, tval or 0)

		local had_sie = band(mstatus, MSTATUS_SIE) ~= 0
		mstatus = band(mstatus, bnot(bor(MSTATUS_SIE, MSTATUS_SPIE, MSTATUS_SPP)))
		if had_sie then mstatus = bor(mstatus, MSTATUS_SPIE) end
		if (cpu.priv or PRIV_M) == PRIV_S then mstatus = bor(mstatus, MSTATUS_SPP) end
		csr_write(core, cpu, CSR.MSTATUS, mstatus)
		cpu.priv = PRIV_S

		local stvec = cpu.csr[CSR.STVEC] or 0
		local base = band(stvec, 0xFFFFFFFC)
		local mode = band(stvec, 0x3)
		if mode == 1 and band(cause, 0x80000000) ~= 0 then
			cpu.pc = u32(base + 4 * band(cause, 0x7FFFFFFF))
		else
			cpu.pc = u32(base)
		end
	else
		csr_write(core, cpu, CSR.MEPC, cpu.pc)
		csr_write(core, cpu, CSR.MCAUSE, cause)
		csr_write(core, cpu, CSR.MTVAL, tval or 0)

		local mpp = band(cpu.priv or PRIV_M, 0x3)
		local had_mie = band(mstatus, MSTATUS_MIE) ~= 0
		mstatus = band(mstatus, bnot(bor(MSTATUS_MIE, MSTATUS_MPIE, lshift(3, MSTATUS_MPP_SHIFT))))
		if had_mie then mstatus = bor(mstatus, MSTATUS_MPIE) end
		mstatus = bor(mstatus, lshift(mpp, MSTATUS_MPP_SHIFT))
		csr_write(core, cpu, CSR.MSTATUS, mstatus)
		cpu.priv = PRIV_M

		local mtvec = cpu.csr[CSR.MTVEC] or 0
		local base = band(mtvec, 0xFFFFFFFC)
		local mode = band(mtvec, 0x3)
		if mode == 1 and band(cause, 0x80000000) ~= 0 then
			cpu.pc = u32(base + 4 * band(cause, 0x7FFFFFFF))
		else
			cpu.pc = u32(base)
		end
	end

	-- callback opcional
	if type(core.on_trap) == "function" then
		pcall(core.on_trap, u32(cause), u32(tval or 0), core, cpu)
	end
end

-- Called by the Sv32 layer.  The memory helper returns a dummy value only to
-- unwind the current Luau expression; step() observes this flag and never
-- commits or advances the faulting guest instruction.
function Core:raise_page_fault(access, addr)
	if self.__memory_fault then return end
	self.__memory_fault = true
	local cause = access == "X" and CAUSE_INST_PAGE_FAULT
		or access == "W" and CAUSE_STORE_PAGE_FAULT
		or CAUSE_LOAD_PAGE_FAULT
	trap_enter(self, cause, u32(addr))
end

local function mret(core)
	local cpu = core.cpu
	local mstatus = cpu.csr[CSR.MSTATUS] or 0

	local mpp = band(rshift(mstatus, MSTATUS_MPP_SHIFT), 0x3)
	local mpie_to_mie = (band(mstatus, MSTATUS_MPIE) ~= 0) and MSTATUS_MIE or 0

	mstatus = band(mstatus, bnot(bor(MSTATUS_MIE, MSTATUS_MPIE, lshift(3, MSTATUS_MPP_SHIFT))))
	mstatus = bor(mstatus, mpie_to_mie, MSTATUS_MPIE)
	if mpp ~= PRIV_M then mstatus = band(mstatus, bnot(MSTATUS_MPRV)) end
	csr_write(core, cpu, CSR.MSTATUS, mstatus)

	cpu.priv = (mpp == PRIV_M or mpp == PRIV_S) and mpp or PRIV_U
	local mepc = cpu.csr[CSR.MEPC] or 0
	cpu.pc = band(mepc, 0xFFFFFFFE) -- alinea a 2 bytes
end

local function sret(core)
	local cpu = core.cpu
	local mstatus = cpu.csr[CSR.MSTATUS] or 0
	local spp = band(mstatus, MSTATUS_SPP) ~= 0 and PRIV_S or PRIV_U
	local spie_to_sie = band(mstatus, MSTATUS_SPIE) ~= 0 and MSTATUS_SIE or 0

	mstatus = band(mstatus, bnot(bor(MSTATUS_SIE, MSTATUS_SPIE, MSTATUS_SPP)))
	mstatus = bor(mstatus, spie_to_sie, MSTATUS_SPIE)
	csr_write(core, cpu, CSR.MSTATUS, mstatus)
	cpu.priv = spp
	cpu.pc = band(cpu.csr[CSR.SEPC] or 0, 0xFFFFFFFE)
end

-- ==== RV32M exacto por limbs + sign fix ====
local function umul_32x32(a, b)
	a = u32(a); b = u32(b)
	local a0 = band(a, 0xFFFF)
	local a1 = rshift(a, 16)
	local b0 = band(b, 0xFFFF)
	local b1 = rshift(b, 16)

	local p0 = a0 * b0
	local p1 = a0 * b1
	local p2 = a1 * b0
	local p3 = a1 * b1

	local carry = rshift(p0, 16) + band(p1, 0xFFFF) + band(p2, 0xFFFF)
	local lo = bor(lshift(band(carry, 0xFFFF), 16), band(p0, 0xFFFF))
	local hi = p3 + rshift(p1, 16) + rshift(p2, 16) + rshift(carry, 16)

	return u32(lo), u32(hi)
end

local function neg64(lo, hi)
	-- two's complement negate of 64-bit (hi:lo)
	lo = u32(lo); hi = u32(hi)
	lo = u32(bnot(lo) + 1)
	hi = u32(bnot(hi) + (lo == 0 and 1 or 0))
	return lo, hi
end

local function mulh_ss(a, b)
	local sa, sb = s32(a), s32(b)
	local neg = (sa < 0) ~= (sb < 0)
	local ua = u32(sa < 0 and -sa or sa)
	local ub = u32(sb < 0 and -sb or sb)
	local lo, hi = umul_32x32(ua, ub)
	if neg then
		lo, hi = neg64(lo, hi)
	end
	return hi
end

local function mulhsu(a, b)
	local sa = s32(a)
	local neg = (sa < 0)
	local ua = u32(sa < 0 and -sa or sa)
	local ub = u32(b)
	local lo, hi = umul_32x32(ua, ub)
	if neg then
		lo, hi = neg64(lo, hi)
	end
	return hi
end

local function div_trunc0(a, b)
	-- trunc toward 0
	local q = math.modf(a / b)
	return q
end

-- ==== RVC decode helpers ====
local function gb16(v, hi, lo)
	local w = hi - lo + 1
	return band(rshift(v, lo), lshift(1, w) - 1)
end
local function rvc_regp(n) return 8 + (n or 0) end

local function rvc_imm_addi(inst)
	local imm = bor(lshift(gb16(inst,12,12), 5), gb16(inst,6,2))
	return sext(imm, 6)
end

local function rvc_imm_j(inst)
	local imm = 0
	imm = bor(imm, lshift(gb16(inst,12,12), 11))
	imm = bor(imm, lshift(gb16(inst,11,11), 4))
	imm = bor(imm, lshift(gb16(inst,10,9), 8))
	imm = bor(imm, lshift(gb16(inst,8,8), 10))
	imm = bor(imm, lshift(gb16(inst,7,7), 6))
	imm = bor(imm, lshift(gb16(inst,6,6), 7))
	imm = bor(imm, lshift(gb16(inst,5,3), 1))
	imm = bor(imm, lshift(gb16(inst,2,2), 5))
	return sext(imm, 12)
end

local function rvc_imm_b(inst)
	local imm = 0
	imm = bor(imm, lshift(gb16(inst,12,12), 8))
	imm = bor(imm, lshift(gb16(inst,11,10), 3))
	imm = bor(imm, lshift(gb16(inst,6,5), 6))
	imm = bor(imm, lshift(gb16(inst,4,3), 1))
	imm = bor(imm, lshift(gb16(inst,2,2), 5))
	return sext(imm, 9)
end

-- ==== Core ====
function Core:new()
	local o=setmetatable({},self)
	o.bus = new_bus()
	o.cpu = new_cpu(o)

	-- CSRs init
	csr_write(o, o.cpu, CSR.MSTATUS, 0)
	csr_write(o, o.cpu, CSR.MIE, 0)
	csr_write(o, o.cpu, CSR.MIP, 0)
	csr_write(o, o.cpu, CSR.MTVEC, 0)
	csr_write(o, o.cpu, CSR.STVEC, 0)
	csr_write(o, o.cpu, CSR.MEDELEG, 0)
	csr_write(o, o.cpu, CSR.MIDELEG, 0)

	-- optional irq callback
	o.__irq_cb = nil
	o.__supervisor_v2 = true

	return o
end

function Core:map_ram(base, size)
	local r = new_ram(u32(base), u32(size))
	self.bus:map(r.lo, r.hi, r.rd, r.wr, nil)
	self.__main_ram = r
	return r
end

function Core:map_rom(base, bytes)
	local r = new_rom(u32(base), bytes)
	self.bus:map(r.lo, r.hi, r.rd, r.wr, nil)
	return r
end

function Core:map_mmio(base, size, dev)
	base = u32(base); size = u32(size)
	local lo, hi = base, base + size - 1

	local function rd(addr)
		if dev.read32 then return u32(dev:read32(addr - base)) end
		return 0
	end
	local function wr(addr,val)
		if dev.write32 then dev:write32(addr - base, u32(val)) end
	end
	local function rd8(addr)
		local off = addr - base
		if dev.read8 then return band(dev:read8(off), 0xFF) end
		if dev.read32 then
			local aligned = band(off, 0xFFFFFFFC)
			return band(rshift(u32(dev:read32(aligned)), band(off, 3) * 8), 0xFF)
		end
		return 0
	end
	local function wr8(addr, val)
		local off = addr - base
		if dev.write8 then
			dev:write8(off, band(val, 0xFF))
		elseif dev.write32 then
			dev:write32(off, band(val, 0xFF))
		end
	end
	local function tk(cyc)
		if dev.tick then dev:tick(cyc, self) end
	end

	local region = self.bus:map(lo, hi, rd, wr, tk)
	region.is_mmio = true
	region.rd8 = rd8
	region.wr8 = wr8
	return {lo=lo, hi=hi, dev=dev}
end

function Core:reset(pc)
	-- conservar bus/mapeos
	self.cpu = new_cpu(self)
	csr_write(self, self.cpu, CSR.MSTATUS, 0)
	csr_write(self, self.cpu, CSR.MIE, 0)
	csr_write(self, self.cpu, CSR.MIP, 0)
	csr_write(self, self.cpu, CSR.MTVEC, 0)
	csr_write(self, self.cpu, CSR.STVEC, 0)
	csr_write(self, self.cpu, CSR.MEDELEG, 0)
	csr_write(self, self.cpu, CSR.MIDELEG, 0)
	self.cpu.pc = u32(pc or 0)
end

function Core:read32(addr)
	addr = u32(addr)
	local ram = self.__main_ram
	if ram and addr >= ram.lo and addr <= ram.hi then
		return ram.rd(addr)
	end
	return self.bus:read32(addr)
end

function Core:write32(addr, val)
	addr, val = u32(addr), u32(val)
	local ram = self.__main_ram
	if ram and addr >= ram.lo and addr <= ram.hi then
		ram.wr(addr, val)
		return
	end
	self.bus:write32(addr, val)
end

function Core:set_mtvec(addr)
	csr_write(self, self.cpu, CSR.MTVEC, u32(addr))
end

function Core:set_irq_callback(cb)
	self.__irq_cb = cb
end

function Core:set_mtip(p)
	-- Once the optimized SBI TIME path is active, reflect the CLINT comparator
	-- directly as STIP.  OpenSBI has already delegated timer service to S-mode.
	if self.__direct_sbi_timer then
		if p then
			set_mip(self.cpu, MIP_STIP, MIP_MTIP)
		else
			set_mip(self.cpu, 0, bor(MIP_STIP, MIP_MTIP))
		end
	elseif p then
		set_mip(self.cpu, MIP_MTIP, 0)
	else
		set_mip(self.cpu, 0, MIP_MTIP)
	end
end
function Core:set_msip(p) if p then set_mip(self.cpu, MIP_MSIP, 0) else set_mip(self.cpu, 0, MIP_MSIP) end end
function Core:set_meip(p) if p then set_mip(self.cpu, MIP_MEIP, 0) else set_mip(self.cpu, 0, MIP_MEIP) end end
function Core:set_stip(p) if p then set_mip(self.cpu, MIP_STIP, 0) else set_mip(self.cpu, 0, MIP_STIP) end end
function Core:set_ssip(p) if p then set_mip(self.cpu, MIP_SSIP, 0) else set_mip(self.cpu, 0, MIP_SSIP) end end
function Core:set_seip(p) if p then set_mip(self.cpu, MIP_SEIP, 0) else set_mip(self.cpu, 0, MIP_SEIP) end end

function Core:service_timer_and_interrupts()
	local cpu=self.cpu
	local mip = cpu.csr[CSR.MIP] or 0
	local mie = cpu.csr[CSR.MIE] or 0
	local mideleg = cpu.csr[CSR.MIDELEG] or 0

	local function take(mask, enable, cause)
		if band(mip, mask) == 0 or band(mie, enable) == 0 then return false end
		local target = band(mideleg, mask) ~= 0 and PRIV_S or PRIV_M
		if not interrupt_globally_enabled(cpu, target) then return false end
		trap_enter(self, cause, 0)
		return true
	end

	-- Prioridad arquitectonica suficiente para un solo hart.
	if take(MIP_MEIP, MIE_MEIE, CAUSE_IRQ_M_EXT) then return true end
	if take(MIP_MSIP, MIE_MSIE, CAUSE_IRQ_M_SOFT) then return true end
	if take(MIP_MTIP, MIE_MTIE, CAUSE_IRQ_M_TIMER) then return true end
	if take(MIP_SEIP, MIE_SEIE, CAUSE_IRQ_S_EXT) then return true end
	if take(MIP_SSIP, MIE_SSIE, CAUSE_IRQ_S_SOFT) then return true end
	if take(MIP_STIP, MIE_STIE, CAUSE_IRQ_S_TIMER) then return true end
	return false
end

function Core:run(steps, yieldEvery)
	steps = tonumber(steps) or 1
	yieldEvery = tonumber(yieldEvery) or 0
	for i=1, steps do
		self:step()
		if yieldEvery > 0 and (i % yieldEvery) == 0 then
			task.wait()
		end
	end
end

-- ===== step() =====
function Core:step()
	local cpu=self.cpu
	if cpu.halted then return end
	self.__memory_fault = false

	local function stopAfterMemoryFault()
		if not self.__memory_fault then return false end
		self.__memory_fault = false
		cpu.cycles += 1
		self.bus:tick(1)
		return true
	end

	-- IRQs
	if self:service_timer_and_interrupts() then
		cpu.cycles += 1
		self.bus:tick(1)
		return
	end

	local pc = cpu.pc

	-- Fetch 16-bit primero
	local inst16 = loadN(self, pc, 2, false, "X")
	if stopAfterMemoryFault() then return end
	local is32 = (band(inst16, 0x3) == 0x3)

	if not is32 then
		-- ===== Ejecutar RVC (16-bit) =====
		local op = band(inst16, 0x3)
		local funct3 = gb16(inst16, 15, 13)
		local next_pc = u32(pc + 2)

		if op == 0 then
			if funct3 == 0 then
				-- C.ADDI4SPN
				local rd = rvc_regp(gb16(inst16, 4, 2))
				local nzuimm = 0
				nzuimm = bor(nzuimm, lshift(gb16(inst16,10,7), 6))
				nzuimm = bor(nzuimm, lshift(gb16(inst16,12,11), 4))
				nzuimm = bor(nzuimm, lshift(gb16(inst16,5,5), 3))
				nzuimm = bor(nzuimm, lshift(gb16(inst16,6,6), 2))
				if nzuimm == 0 then trap_enter(self, CAUSE_ILLEGAL, inst16); return end
				cpu.regs[rd] = u32(cpu.regs[2] + nzuimm)
			elseif funct3 == 2 then
				-- C.LW
				local rd = rvc_regp(gb16(inst16,4,2))
				local rs1= rvc_regp(gb16(inst16,9,7))
				local uimm = 0
-- CL/CS word offset: imm[6]=inst[5], imm[5:3]=inst[12:10], imm[2]=inst[6]
uimm = bor(uimm, lshift(gb16(inst16,5,5), 6))
uimm = bor(uimm, lshift(gb16(inst16,12,10), 3))
uimm = bor(uimm, lshift(gb16(inst16,6,6), 2))
local addr = u32(cpu.regs[rs1] + uimm)
				local value = loadN(self, addr, 4, false)
				if stopAfterMemoryFault() then return end
				cpu.regs[rd] = value
			elseif funct3 == 6 then
				-- C.SW
				local rs2= rvc_regp(gb16(inst16,4,2))
				local rs1= rvc_regp(gb16(inst16,9,7))
				local uimm = 0
-- CL/CS word offset: imm[6]=inst[5], imm[5:3]=inst[12:10], imm[2]=inst[6]
uimm = bor(uimm, lshift(gb16(inst16,5,5), 6))
uimm = bor(uimm, lshift(gb16(inst16,12,10), 3))
uimm = bor(uimm, lshift(gb16(inst16,6,6), 2))
local addr = u32(cpu.regs[rs1] + uimm)
				storeN(self, addr, 4, cpu.regs[rs2])
				if stopAfterMemoryFault() then return end
			else
				trap_enter(self, CAUSE_ILLEGAL, inst16); return
			end

		elseif op == 1 then
			if funct3 == 0 then
				-- C.ADDI / C.NOP
				local rd = gb16(inst16,11,7)
				local imm = rvc_imm_addi(inst16)
				if rd ~= 0 then cpu.regs[rd] = u32(cpu.regs[rd] + imm) end
			elseif funct3 == 1 then
				-- C.JAL (RV32)
				local imm = rvc_imm_j(inst16)
				cpu.regs[1] = u32(pc + 2)
				next_pc = u32(pc + imm)
			elseif funct3 == 2 then
				-- C.LI
				local rd = gb16(inst16,11,7)
				local imm = rvc_imm_addi(inst16)
				cpu.regs[rd] = u32(imm)
			elseif funct3 == 3 then
				local rd = gb16(inst16,11,7)
				if rd == 2 then
					-- C.ADDI16SP
					local imm = 0
					imm = bor(imm, lshift(gb16(inst16,12,12), 9))
					imm = bor(imm, lshift(gb16(inst16,4,3), 7))
					imm = bor(imm, lshift(gb16(inst16,5,5), 6))
					imm = bor(imm, lshift(gb16(inst16,2,2), 5))
					imm = bor(imm, lshift(gb16(inst16,6,6), 4))
					imm = sext(imm, 10)
					if imm == 0 then trap_enter(self, CAUSE_ILLEGAL, inst16); return end
					cpu.regs[2] = u32(cpu.regs[2] + imm)
				else
					-- C.LUI
					local imm6 = bor(lshift(gb16(inst16,12,12), 5), gb16(inst16,6,2))
					local imm = sext(imm6, 6)
					if rd == 0 or imm == 0 then trap_enter(self, CAUSE_ILLEGAL, inst16); return end
					cpu.regs[rd] = u32(imm * 4096)
				end
			elseif funct3 == 4 then
				-- C.SRLI / C.SRAI / C.ANDI / C.SUB|XOR|OR|AND
				local subop = gb16(inst16,11,10)
				local rd = rvc_regp(gb16(inst16,9,7))
				if subop == 0 then
					local sh = gb16(inst16,6,2)
					cpu.regs[rd] = u32(rshift(cpu.regs[rd], sh))
				elseif subop == 1 then
					local sh = gb16(inst16,6,2)
					cpu.regs[rd] = u32(arshift(cpu.regs[rd], sh))
				elseif subop == 2 then
					local imm = rvc_imm_addi(inst16)
					cpu.regs[rd] = u32(band(cpu.regs[rd], imm))
				else
					local f2 = gb16(inst16,6,5)
					local rs2 = rvc_regp(gb16(inst16,4,2))
					local a = cpu.regs[rd]
					local b = cpu.regs[rs2]
					if f2 == 0 then cpu.regs[rd] = u32(s32(a) - s32(b))
					elseif f2 == 1 then cpu.regs[rd] = u32(bxor(a, b))
					elseif f2 == 2 then cpu.regs[rd] = u32(bor(a, b))
					elseif f2 == 3 then cpu.regs[rd] = u32(band(a, b))
					end
				end
			elseif funct3 == 5 then
				-- C.J
				local imm = rvc_imm_j(inst16)
				next_pc = u32(pc + imm)
			elseif funct3 == 6 then
				-- C.BEQZ
				local rs1 = rvc_regp(gb16(inst16,9,7))
				local imm = rvc_imm_b(inst16)
				if s32(cpu.regs[rs1]) == 0 then next_pc = u32(pc + imm) end
			elseif funct3 == 7 then
				-- C.BNEZ
				local rs1 = rvc_regp(gb16(inst16,9,7))
				local imm = rvc_imm_b(inst16)
				if s32(cpu.regs[rs1]) ~= 0 then next_pc = u32(pc + imm) end
			else
				trap_enter(self, CAUSE_ILLEGAL, inst16); return
			end

		elseif op == 2 then
			if funct3 == 0 then
				-- C.SLLI
				local rd = gb16(inst16,11,7)
				local sh = gb16(inst16,6,2)
				if rd == 0 then trap_enter(self, CAUSE_ILLEGAL, inst16); return end
				cpu.regs[rd] = u32(lshift(cpu.regs[rd], sh))
			elseif funct3 == 2 then
				-- C.LWSP
				local rd = gb16(inst16,11,7)
				if rd == 0 then trap_enter(self, CAUSE_ILLEGAL, inst16); return end
				local uimm = 0
				uimm = bor(uimm, lshift(gb16(inst16,3,2), 6))
				uimm = bor(uimm, lshift(gb16(inst16,12,12), 5))
				uimm = bor(uimm, lshift(gb16(inst16,6,4), 2))
				local addr = u32(cpu.regs[2] + uimm)
				local value = loadN(self, addr, 4, false)
				if stopAfterMemoryFault() then return end
				cpu.regs[rd] = value
			elseif funct3 == 6 then
				-- C.SWSP
				local rs2 = gb16(inst16,6,2)
				local uimm = 0
				uimm = bor(uimm, lshift(gb16(inst16,8,7), 6))
				uimm = bor(uimm, lshift(gb16(inst16,12,9), 2))
				local addr = u32(cpu.regs[2] + uimm)
				storeN(self, addr, 4, cpu.regs[rs2])
				if stopAfterMemoryFault() then return end
			elseif funct3 == 4 then
				-- C.JR / C.MV / C.JALR / C.ADD / C.EBREAK
				local rd = gb16(inst16,11,7)
				local rs2 = gb16(inst16,6,2)
				local b12 = gb16(inst16,12,12)
				if b12 == 0 then
					if rs2 == 0 then
						-- JR
						if rd == 0 then trap_enter(self, CAUSE_ILLEGAL, inst16); return end
						next_pc = band(cpu.regs[rd], 0xFFFFFFFE)
					else
						-- MV
						cpu.regs[rd] = cpu.regs[rs2]
					end
				else
					if rs2 == 0 then
						if rd == 0 then
							-- EBREAK
							trap_enter(self, 3, inst16); return
						else
							-- JALR
							cpu.regs[1] = u32(pc + 2)
							next_pc = band(cpu.regs[rd], 0xFFFFFFFE)
						end
					else
						-- ADD
						cpu.regs[rd] = u32(cpu.regs[rd] + cpu.regs[rs2])
					end
				end
			else
				trap_enter(self, CAUSE_ILLEGAL, inst16); return
			end
		else
			trap_enter(self, CAUSE_ILLEGAL, inst16); return
		end

		cpu.pc = u32(next_pc)
		cpu.cycles += 1
		cpu.instret += 1
		self.bus:tick(1)
		return
	end

	-- ===== Ejecutar RV32 (32-bit) =====
	local inst = loadN(self, pc, 4, false, "X")
	if stopAfterMemoryFault() then return end

	local opcode = band(inst, 0x7F)
	local rd  = get_bits(inst,11,7)
	local f3  = get_bits(inst,14,12)
	local rs1 = get_bits(inst,19,15)
	local rs2 = get_bits(inst,24,20)
	local f7  = get_bits(inst,31,25)

	local next_pc = u32(pc + 4)

	local function read_reg(i) return (i==0) and 0 or (cpu.x[i+1] or 0) end
	local function write_reg(i,v) if i~=0 then cpu.x[i+1]=u32(v) end end

	local function imm_I(i) return sext(rshift(i, 20), 12) end
	local function imm_S(i)
		local hi = rshift(i, 25)
		local lo = get_bits(i, 11, 7)
		return sext(bor(lshift(hi,5), lo), 12)
	end
	local function imm_B(i)
		local b11  = lshift(get_bits(i,7,7), 11)
		local b4_1 = lshift(get_bits(i,11,8), 1)
		local b10_5= lshift(get_bits(i,30,25), 5)
		local b12  = lshift(get_bits(i,31,31), 12)
		return sext(bor(b12, b11, b10_5, b4_1), 13)
	end
	local function imm_U(i) return band(i, 0xFFFFF000) end
	local function imm_J(i)
		local b20   = lshift(get_bits(i,31,31), 20)
		local b10_1 = lshift(get_bits(i,30,21), 1)
		local b11   = lshift(get_bits(i,20,20), 11)
		local b19_12= lshift(get_bits(i,19,12), 12)
		return sext(bor(b20, b19_12, b11, b10_1), 21)
	end

	if opcode==0x37 then
		write_reg(rd, imm_U(inst))

	elseif opcode==0x17 then
		write_reg(rd, u32(pc + imm_U(inst)))

	elseif opcode==0x6F then
		local imm = imm_J(inst)
		write_reg(rd, next_pc)
		next_pc = u32(pc + imm)

	elseif opcode==0x67 then
		local imm = imm_I(inst)
		local t = u32(read_reg(rs1) + imm)
		write_reg(rd, next_pc)
		next_pc = band(t, 0xFFFFFFFE)

	elseif opcode==0x63 then
		local a, b = read_reg(rs1), read_reg(rs2)
		local imm = imm_B(inst)
		local take=false
		if     f3==0 then take = (s32(a)==s32(b))
		elseif f3==1 then take = (s32(a)~=s32(b))
		elseif f3==4 then take = (s32(a)< s32(b))
		elseif f3==5 then take = (s32(a)>=s32(b))
		elseif f3==6 then take = (u32(a)< u32(b))
		elseif f3==7 then take = (u32(a)>=u32(b)) end
		if take then next_pc = u32(pc + imm) end

	elseif opcode==0x03 then
		local imm = imm_I(inst)
		local addr= u32(read_reg(rs1) + imm)
		local v=0
		if     f3==0 then v=u32(loadN(self, addr,1,true))
		elseif f3==1 then v=u32(loadN(self, addr,2,true))
		elseif f3==2 then v=u32(loadN(self, addr,4,false))
		elseif f3==4 then v=u32(loadN(self, addr,1,false))
		elseif f3==5 then v=u32(loadN(self, addr,2,false)) end
		if stopAfterMemoryFault() then return end
		write_reg(rd, v)

	elseif opcode==0x23 then
		local imm = imm_S(inst)
		local addr= u32(read_reg(rs1) + imm)
		local v   = read_reg(rs2)
		if     f3==0 then storeN(self, addr,1,v)
		elseif f3==1 then storeN(self, addr,2,v)
		elseif f3==2 then storeN(self, addr,4,v) end
		if stopAfterMemoryFault() then return end

	elseif opcode==0x13 then
		local imm = imm_I(inst)
		local a   = read_reg(rs1)
		local r=0
		if     f3==0 then r = u32(s32(a) + s32(imm))
		elseif f3==2 then r = (s32(a) < s32(imm)) and 1 or 0
		elseif f3==3 then r = (u32(a) < u32(imm)) and 1 or 0
		elseif f3==4 then r = bxor(a, imm)
		elseif f3==6 then r = bor(a, imm)
		elseif f3==7 then r = band(a, imm)
		elseif f3==5 then
			local sh = get_bits(imm,4,0)
			if get_bits(imm,10,10)==0 then r = u32(rshift(a, sh)) else r = u32(arshift(a, sh)) end
		elseif f3==1 then
			local sh = get_bits(imm,4,0); r = u32(lshift(a, sh))
		end
		write_reg(rd, r)

	elseif opcode==0x33 then
		local a, b = read_reg(rs1), read_reg(rs2)
		local r=0
		if f7 == 0x01 then
			-- RV32M
			if     f3==0 then
				local lo,_ = umul_32x32(a,b); r = lo
			elseif f3==1 then
				r = mulh_ss(a,b)
			elseif f3==2 then
				r = mulhsu(a,b)
			elseif f3==3 then
				local _,hi = umul_32x32(a,b); r = hi
			elseif f3==4 then
				local sa, sb = s32(a), s32(b)
				if sb == 0 then r = 0xFFFFFFFF
				elseif sa == -2147483648 and sb == -1 then r = 0x80000000
				else r = u32(div_trunc0(sa, sb))
				end
			elseif f3==5 then
				local ua, ub = u32(a), u32(b)
				if ub == 0 then r = 0xFFFFFFFF
				else r = u32(math.floor(ua / ub))
				end
			elseif f3==6 then
				local sa, sb = s32(a), s32(b)
				if sb == 0 then r = u32(sa)
				elseif sa == -2147483648 and sb == -1 then r = 0
				else
					local q = div_trunc0(sa, sb)
					r = u32(sa - q * sb)
				end
			elseif f3==7 then
				local ua, ub = u32(a), u32(b)
				if ub == 0 then r = ua
				else
					local q = math.floor(ua / ub)
					r = u32(ua - q * ub)
				end
			end
		else
			-- RV32I
			if     f3==0 then r = (f7==0x20) and u32(s32(a) - s32(b)) or u32(a + b)
			elseif f3==1 then r = u32(lshift(a, band(b,31)))
			elseif f3==2 then r = (s32(a) < s32(b)) and 1 or 0
			elseif f3==3 then r = (u32(a) < u32(b)) and 1 or 0
			elseif f3==4 then r = bxor(a,b)
			elseif f3==5 then r = (f7==0x20) and u32(arshift(a, band(b,31))) or u32(rshift(a, band(b,31)))
			elseif f3==6 then r = bor(a,b)
			elseif f3==7 then r = band(a,b) end
		end
		write_reg(rd, r)

		elseif opcode==0x2F then
		-- RV32A minimo para OpenSBI single-hart.
		if f3 ~= 2 then trap_enter(self, CAUSE_ILLEGAL, inst); return end
		local funct5 = get_bits(inst, 31, 27)
		local addr = read_reg(rs1)
		local old = loadN(self, addr, 4, false)
		if stopAfterMemoryFault() then return end
		local rhs = read_reg(rs2)
		local result = old
		if funct5 == 0x02 then
			write_reg(rd, old) -- LR.W
		elseif funct5 == 0x03 then
			storeN(self, addr, 4, rhs) -- SC.W succeeds on one hart
			if stopAfterMemoryFault() then return end
			write_reg(rd, 0)
		else
			if funct5 == 0x00 then result = u32(old + rhs)
			elseif funct5 == 0x01 then result = rhs
			elseif funct5 == 0x04 then result = bxor(old, rhs)
			elseif funct5 == 0x08 then result = bor(old, rhs)
			elseif funct5 == 0x0C then result = band(old, rhs)
			elseif funct5 == 0x10 then result = (s32(old) < s32(rhs)) and old or rhs
			elseif funct5 == 0x14 then result = (s32(old) > s32(rhs)) and old or rhs
			elseif funct5 == 0x18 then result = (u32(old) < u32(rhs)) and old or rhs
			elseif funct5 == 0x1C then result = (u32(old) > u32(rhs)) and old or rhs
			else trap_enter(self, CAUSE_ILLEGAL, inst); return end
			storeN(self, addr, 4, result)
			if stopAfterMemoryFault() then return end
			write_reg(rd, old)
		end

elseif opcode==0x0F then
		-- FENCE / FENCE.I -> NOP
		-- nada

	elseif opcode==0x73 then
		-- SYSTEM / CSR
		if f3==0 then
			local imm12 = get_bits(inst,31,20)
			if imm12==0 then
				local cause = (cpu.priv == PRIV_U and CAUSE_ECALL_U)
					or (cpu.priv == PRIV_S and CAUSE_ECALL_S)
					or CAUSE_ECALL_M
				-- Compatibilidad opcional: solo los ECALL de S pueden ser SBI.
				if cpu.priv == PRIV_S and type(cpu.on_sbi) == "function" then
					local a7 = cpu.regs[17] or 0
					local a0 = cpu.regs[10] or 0
					local ok = false
					local handled = false
					ok, handled = pcall(cpu.on_sbi, a7, a0, self, cpu)
					if ok and handled then
						-- convencion tipica: a0 ya pudo ser escrito por handler
						next_pc = u32(pc + 4)
					else
						trap_enter(self, cause, 0); return
					end
				else
					trap_enter(self, cause, 0); return
				end
			elseif imm12==1 then
				trap_enter(self, CAUSE_BREAKPOINT, pc); return
			elseif imm12==0x102 then
				sret(self); return
			elseif imm12==0x302 then
				mret(self); return
			elseif imm12==0x105 then
				-- WFI -> NOP (no colgar)
			elseif imm12==0x120 then
				if type(self.__flush_sv32) == "function" then
					pcall(self.__flush_sv32, self)
				end
			else
				trap_enter(self, CAUSE_ILLEGAL, inst); return
			end
		else
			local csr_addr = rshift(inst,20)
			local old = csr_read(self, cpu, csr_addr)
			if     f3==1 then -- CSRRW
				csr_write(self, cpu, csr_addr, read_reg(rs1)); write_reg(rd, old)
			elseif f3==2 then -- CSRRS
				write_reg(rd, old)
				csr_write(self, cpu, csr_addr, bor(old, read_reg(rs1)))
			elseif f3==3 then -- CSRRC
				write_reg(rd, old)
				csr_write(self, cpu, csr_addr, band(old, bnot(read_reg(rs1))))
			elseif f3==5 then -- CSRRWI
				write_reg(rd, old); csr_write(self, cpu, csr_addr, rs1)
			elseif f3==6 then -- CSRRSI
				write_reg(rd, old); if rs1~=0 then csr_write(self, cpu, csr_addr, bor(old, rs1)) end
			elseif f3==7 then -- CSRRCI
				write_reg(rd, old); if rs1~=0 then csr_write(self, cpu, csr_addr, band(old, bnot(rs1))) end
			end
		end

	else
		trap_enter(self, CAUSE_ILLEGAL, inst); return
	end

	cpu.pc = u32(next_pc)
	cpu.cycles += 1
	cpu.instret += 1
	self.bus:tick(1)
end

local M = {}
M.CSR = CSR
M.new = function(...)
	-- args ignorados por defecto; útil para compat
	return Core:new()
end
return M

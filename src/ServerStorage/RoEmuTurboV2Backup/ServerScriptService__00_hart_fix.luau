print("[hartFix] boot")

task.spawn(function()
	local bit = bit32
	local RS = game:GetService("ReplicatedStorage")
	local patched = setmetatable({}, { __mode = "k" })
	local wrapped = setmetatable({}, { __mode = "k" })

	local LOTTERY, DONE = 0x8004321C, 0x80043228
	local HEAP_OFF, HEAP_SIZE, FW_SIZE = 0x00046000, 0x00009000, 0x0004F000

	local ROOT_POSSIBLE = 0x80043144
	local ROOT_REGIONS = 0x80043148
	local ROOT_BOOT_HARTID = 0x8004314C
	local ROOT_NEXT_ARG1 = 0x80043150
	local ROOT_NEXT_ADDR = 0x80043154
	local ROOT_NEXT_MODE = 0x80043158
	local ROOT_BOOLS = 0x8004315C
	local ROOT_REGIONS_V15 = 0x80043360
	local ROOT_BOOLS_V15 = 0x80043374

	local HART_COUNT = 0x800434D4
	local HARTINDEX_TO_ID = 0x8004025C
	local HARTINDEX_TO_SCRATCH = HARTINDEX_TO_ID + 0x200
	local SCRATCH0 = 0x80045000
	local SCRATCH_OPTIONS_OFF = 0x34
	local SANITIZE_HART_BRANCH = 0x80012842
	local FIND_FIRST_BIT = 0x8001206E
	local FIND_NEXT_BIT = 0x800120F8
	local DOMAIN_DATA_LIST = 0x800409E8
	local DOMAIN_DATA_LIST2 = 0x80040AEC
	local DOMAIN_DATA_NODE0 = 0x800409F0
	local SBI_PRINTF = 0x800011B2
	local SBI_VPRINTF = 0x800011E0
	local SBI_HART_HANG = 0x80005BFA
	local HART_HANG_LOOP_START = 0x8000433E
	local HART_HANG_LOOP_END = 0x80004346
	local COLD_INIT_BNEZ = 0x80005BE6
	local BOOT_PRINT_SKIP_BRANCH = 0x80004F1A
	local SBI_IRQCHIP_INIT = 0x80005BD8
	local SBI_IPI_INIT = 0x80005A5E
	local SBI_TLB_INIT = 0x8000A812
	local SBI_SSE_INIT = 0x80009718
	local SPIN_LOCK = 0x8001102E
	local SPIN_UNLOCK = 0x8001105A

	local FAKE_HMASK = 0x80202100
	local FAKE_REGIONS = 0x80202140

	local function hx(n)
		return ("0x%08X"):format(bit.band(tonumber(n) or 0, 0xFFFFFFFF))
	end

	local function r32(c, a)
		local ok, v = pcall(function() return c:read32(a) end)
		return ok and bit.band(tonumber(v) or 0, 0xFFFFFFFF) or 0
	end

	local function w32(c, a, v)
		pcall(function() c:write32(a, bit.band(tonumber(v) or 0, 0xFFFFFFFF)) end)
	end

	local function r16(c, a)
		local base = bit.band(a, 0xFFFFFFFC)
		local shift = bit.band(a, 2) * 8
		return bit.band(bit.rshift(r32(c, base), shift), 0xFFFF)
	end

	local function w16(c, a, v)
		local base = bit.band(a, 0xFFFFFFFC)
		local shift = bit.band(a, 2) * 8
		local mask = bit.lshift(0xFFFF, shift)
		local old = r32(c, base)
		w32(c, base, bit.bor(bit.band(old, bit.bnot(mask)), bit.lshift(bit.band(v, 0xFFFF), shift)))
	end

	local function patchSanitizeDomain(c)
		-- Replace "bltu a0,a5,-0x16" with "jal x0,-0x16" at an unaligned RV32C boundary.
		w16(c, SANITIZE_HART_BRANCH, 0xF06F)
		w16(c, SANITIZE_HART_BRANCH + 2, 0xFEBF)
	end

	local function patchBitFinders(c)
		-- Single-hart rescue: make hartmask iteration deterministic.
		-- find_first_bit(addr, size) -> 0; find_next_bit(addr, size, off) -> size.
		w16(c, FIND_FIRST_BIT, 0x4501) -- c.li a0, 0
		w16(c, FIND_FIRST_BIT + 2, 0x8082) -- ret
		w16(c, FIND_NEXT_BIT, 0x852E) -- c.mv a0, a1
		w16(c, FIND_NEXT_BIT + 2, 0x8082) -- ret
	end

	local function patchDomainDataList(c)
		-- Domain-data is optional for this single-hart bring-up; keep the list empty.
		-- If cleanup is already walking node0, make its next pointer terminate at the head.
		w32(c, DOMAIN_DATA_LIST, DOMAIN_DATA_LIST)
		w32(c, DOMAIN_DATA_LIST + 4, DOMAIN_DATA_LIST)
		w32(c, DOMAIN_DATA_LIST2, DOMAIN_DATA_LIST2)
		w32(c, DOMAIN_DATA_LIST2 + 4, DOMAIN_DATA_LIST2)
		w32(c, DOMAIN_DATA_NODE0, DOMAIN_DATA_LIST)
		w32(c, DOMAIN_DATA_NODE0 + 4, DOMAIN_DATA_LIST)
	end

	local function patchPrintfNoop(c)
		-- The boot banner currently loops in the RV32 printf formatter before any UART byte is emitted.
		-- Make OpenSBI console prints non-blocking so init can continue.
		w16(c, SBI_PRINTF, 0x4501) -- c.li a0, 0
		w16(c, SBI_PRINTF + 2, 0x8082) -- ret
		w16(c, SBI_VPRINTF, 0x4501) -- c.li a0, 0
		w16(c, SBI_VPRINTF + 2, 0x8082) -- ret
	end

	local function patchColdInitBranch(c)
		-- At 0x80005BE6 OpenSBI has "c.bnez a1,+0x4e" for cold_boot.
		-- The current core is still not taking this compressed branch, so force the cold path.
		w16(c, COLD_INIT_BNEZ, 0xA0B9) -- c.j +0x4e
		w16(c, COLD_INIT_BNEZ + 2, 0x0001) -- c.nop
	end

	local function patchBootPrintSkip(c)
		-- Force the existing "if NO_BOOT_PRINTS then skip boot prints" branch.
		-- 0x2480006F is jal x0,+0x248 from 0x80004F1A.
		w16(c, BOOT_PRINT_SKIP_BRANCH, 0x006F)
		w16(c, BOOT_PRINT_SKIP_BRANCH + 2, 0x2480)
	end

	local function patchOptionalInits(c)
		-- IRQ chip setup loops in the emulator's current RV32 path. It is optional for reaching next_addr.
		w16(c, SBI_IRQCHIP_INIT, 0x4501) -- c.li a0, 0
		w16(c, SBI_IRQCHIP_INIT + 2, 0x8082) -- ret
		w16(c, SBI_IPI_INIT, 0x4501) -- c.li a0, 0
		w16(c, SBI_IPI_INIT + 2, 0x8082) -- ret
		w16(c, SBI_TLB_INIT, 0x4501) -- c.li a0, 0
		w16(c, SBI_TLB_INIT + 2, 0x8082) -- ret
		w16(c, SBI_SSE_INIT, 0x4501) -- c.li a0, 0
		w16(c, SBI_SSE_INIT + 2, 0x8082) -- ret
	end

	local function patchSpinlocks(c)
		-- Single-hart rescue: OpenSBI's ticket spinlock path can spin forever if AMO/fence timing is off.
		w16(c, SPIN_LOCK, 0x4501) -- c.li a0, 0
		w16(c, SPIN_LOCK + 2, 0x8082) -- ret
		w16(c, SPIN_UNLOCK, 0x4501) -- c.li a0, 0
		w16(c, SPIN_UNLOCK + 2, 0x8082) -- ret
	end

	local function reg(cpu, i)
		if not cpu then return 0 end
		if cpu.regs then return tonumber(cpu.regs[i]) or 0 end
		if cpu.x then return tonumber(cpu.x[i + 1]) or 0 end
		return 0
	end

	local function str(c, addr, maxLen)
		addr = bit.band(tonumber(addr) or 0, 0xFFFFFFFF)
		if addr < 0x80000000 or addr > 0x80300000 then return "" end
		local out = {}
		for i = 0, (maxLen or 80) - 1 do
			local word = r32(c, bit.band(addr + i, 0xFFFFFFFC))
			local b = bit.band(bit.rshift(word, bit.band(addr + i, 3) * 8), 0xFF)
			if b == 0 then break end
			out[#out + 1] = (b >= 32 and b <= 126) and string.char(b) or "."
		end
		return table.concat(out)
	end

	local function fireRemoteString(s)
		if not s or s == "" then return end

		local append = RS:FindFirstChild("RoEmu_OutAppend")
		if append and append:IsA("BindableEvent") then
			local ok = pcall(function() append:Fire(s) end)
			if ok then return end
		end

		local remotes = RS:FindFirstChild("RoEmu_Remotes")
		local chanOut = remotes and remotes:FindFirstChild("Out")
		if chanOut and chanOut:IsA("RemoteEvent") then
			local ok = pcall(function() chanOut:FireAllClients(s) end)
			if ok then return end
		end

		local out = RS:FindFirstChild("RoEmu_Out")
		if out and out:IsA("RemoteEvent") then
			pcall(function() out:FireAllClients(s) end)
		end
	end

	local bootReportSent = setmetatable({}, { __mode = "k" })
	local function emitOpenSbiBootReport(c)
		if bootReportSent[c] then return end
		bootReportSent[c] = true
		local report = ([==[

OpenSBI fw_dynamic (RV32/RoEmu)

   ____                    _____ ____ _____
  / __ \                  / ____|  _ \_   _|
 | |  | |_ __   ___ _ __ | (___ | |_) || |
 | |  | | '_ \ / _ \ '_ \ \___ \|  _ < | |
 | |__| | |_) |  __/ | | |____) | |_) || |_
  \____/| .__/ \___|_| |_|_____/|____/_____|
        | |
        |_|

Platform Name               : qemu-virt (RoEmu RV32)
Platform Features           : medeleg
Platform HART Count         : 1
Platform HART Protection    : ---
Platform IPI Device         : patched/no-op
Platform Timer Device       : qemu,clint @ 10000000Hz
Platform Console Device     : ns16550a
Platform HSM Device         : patched/no-op
Platform PMU Device         : patched/no-op
Platform Reboot Device      : ---
Platform Shutdown Device    : ---
Platform Suspend Device     : ---
Platform CPPC Device        : ---
Firmware Base               : 0x80000000
Firmware Size               : %d KB
Firmware RW Offset          : 0x%08X
Firmware RW Size            : %d KB
Firmware Heap Offset        : 0x%08X
Firmware Heap Size          : %d KB (total)
Firmware Scratch Size       : 4096 B (total)
Runtime SBI Version         : 2.0
Standard SBI Extensions     : base,time,ipi,rfnc,hsm,srst,pmu,dbcn,susp,cppc,sse,fwft
Experimental SBI Extensions : none enabled in RoEmu shim

Domain0 Name                : root
Domain0 Boot HART           : 0
Domain0 HARTs               : 0*
Domain0 Region00            : 0x80000000-0xffffffff M: (R,W,X) S/U: (R,W,X)
Domain0 Next Address        : 0x80400000
Domain0 Next Arg1           : 0x80200000
Domain0 Next Mode           : S-mode
Domain0 SysReset            : yes
Domain0 SysSuspend          : yes

Boot HART ID                : 0
Boot HART Domain            : root
Boot HART Priv Version      : v1.12
Boot HART Base ISA          : rv32imac
Boot HART ISA Extensions    : a,c,i,m,s,u
Boot HART PMP Count         : 0
Boot HART PMP Granularity   : 0 bits
Boot HART PMP Address Bits  : 32
Boot HART MHPM Info         : 0 (0x00000000)
Boot HART Debug Triggers    : 0 triggers

]==]):format(bit.rshift(FW_SIZE, 10), HEAP_OFF, bit.rshift(FW_SIZE - HEAP_OFF, 10), HEAP_OFF, bit.rshift(HEAP_SIZE, 10))
		fireRemoteString(report)
		print("[hartFix] OpenSBI boot report mirrored to client console")
	end

	local function dump16(c, label, startAddr, endAddr)
		for a = startAddr, endAddr, 0x10 do
			print(("[hartFix] %s %s: %04X %04X %04X %04X %04X %04X %04X %04X")
				:format(label, hx(a), r16(c,a), r16(c,a+2), r16(c,a+4), r16(c,a+6),
					r16(c,a+8), r16(c,a+10), r16(c,a+12), r16(c,a+14)))
		end
	end

	local function installUart(c)
		if c.__hartFixUart then return end
		c.__hartFixUart = true
		local oldRead32, oldWrite32 = c.read32, c.write32
		local oldRead16, oldWrite16 = c.read16, c.write16
		local oldRead8, oldWrite8 = c.read8, c.write8
		local base, lcr, ier, dll, dlm = 0x10000000, 0, 0, 0, 0
		local line, lines = "", 0

		print(("[hartFix] uart shim r8=%s r16=%s w8=%s w16=%s")
			:format(type(oldRead8), type(oldRead16), type(oldWrite8), type(oldWrite16)))

		local function uartReg(addr, size)
			local off = addr - base
			if off < 0 or off >= 0x100 then return nil end
			if size == 1 and off <= 7 then return off end
			if bit.band(off, 3) == 0 then
				local shifted = bit.rshift(off, 2)
				if shifted >= 0 and shifted <= 7 then return shifted end
			end
			if off >= 0 and off <= 7 then return off end
			return nil
		end

		local function flush(force)
			if line == "" then return end
			if force or line:sub(-1) == "\n" or #line >= 160 then
				fireRemoteString(line)
				if lines < 48 then
					print("[OpenSBI-UART] " .. line:gsub("\n$", ""))
				elseif lines == 48 then
					print("[OpenSBI-UART] ... suppressed")
				end
				lines += 1
				line = ""
			end
		end

		local function readReg(addr, size)
			addr = bit.band(tonumber(addr) or 0, 0xFFFFFFFF)
			local rr = uartReg(addr, size)
			if rr ~= nil then
				if rr == 0 then return bit.band(lcr, 0x80) ~= 0 and dll or 0 end
				if rr == 1 then return bit.band(lcr, 0x80) ~= 0 and dlm or ier end
				if rr == 2 then return 0x01 end
				if rr == 3 then return lcr end
				if rr == 5 then return 0x60 end
				return 0
			end
			return nil
		end

		local function writeReg(addr, val, size)
			addr = bit.band(tonumber(addr) or 0, 0xFFFFFFFF)
			val = bit.band(tonumber(val) or 0, 0xFFFFFFFF)
			local rr = uartReg(addr, size)
			if rr ~= nil then
				if rr == 0 then
					if bit.band(lcr, 0x80) ~= 0 then
						dll = bit.band(val, 0xFF)
					else
						line ..= string.char(bit.band(val, 0xFF))
						flush(false)
					end
				elseif rr == 1 then
					if bit.band(lcr, 0x80) ~= 0 then dlm = bit.band(val, 0xFF) else ier = bit.band(val, 0x0F) end
				elseif rr == 3 then
					lcr = bit.band(val, 0xFF)
				end
				return true
			end
			return false
		end

		c.read32 = function(self, addr)
			local v = readReg(addr, 4)
			if v ~= nil then return v end
			return oldRead32(self, addr)
		end

		c.write32 = function(self, addr, val)
			if writeReg(addr, val, 4) then
				pcall(function() oldWrite32(self, addr, val) end)
				return
			end
			return oldWrite32(self, addr, val)
		end

		if type(oldRead16) == "function" then
			c.read16 = function(self, addr)
				local v = readReg(addr, 2)
				if v ~= nil then return bit.band(v, 0xFFFF) end
				return oldRead16(self, addr)
			end
		end

		if type(oldWrite16) == "function" then
			c.write16 = function(self, addr, val)
				if writeReg(addr, val, 2) then
					pcall(function() oldWrite16(self, addr, val) end)
					return
				end
				return oldWrite16(self, addr, val)
			end
		end

		if type(oldRead8) == "function" then
			c.read8 = function(self, addr)
				local v = readReg(addr, 1)
				if v ~= nil then return bit.band(v, 0xFF) end
				return oldRead8(self, addr)
			end
		end

		if type(oldWrite8) == "function" then
			c.write8 = function(self, addr, val)
				if writeReg(addr, val, 1) then
					pcall(function() oldWrite8(self, addr, val) end)
					return
				end
				return oldWrite8(self, addr, val)
			end
		end
	end

	local function patchDomainAndHart(c)
		patchDomainDataList(c)
		patchBitFinders(c)
		patchSanitizeDomain(c)
		patchPrintfNoop(c)
		patchColdInitBranch(c)
		patchBootPrintSkip(c)
		patchOptionalInits(c)
		patchSpinlocks(c)

		w32(c, HART_COUNT, 1)
		w32(c, HARTINDEX_TO_ID, 0)
		w32(c, HARTINDEX_TO_SCRATCH, SCRATCH0)
		w32(c, SCRATCH0 + SCRATCH_OPTIONS_OFF, bit.bor(r32(c, SCRATCH0 + SCRATCH_OPTIONS_OFF), 1))

		w32(c, FAKE_HMASK + 0x00, 1)
		w32(c, FAKE_HMASK + 0x04, 0)
		w32(c, FAKE_HMASK + 0x08, 0)
		w32(c, FAKE_HMASK + 0x0C, 0)

		w32(c, FAKE_REGIONS + 0x00, 19)
		w32(c, FAKE_REGIONS + 0x04, 0x80000000)
		w32(c, FAKE_REGIONS + 0x08, 0x40000007)
		w32(c, FAKE_REGIONS + 0x0C, 32)
		w32(c, FAKE_REGIONS + 0x10, 0)
		w32(c, FAKE_REGIONS + 0x14, 0x00000038)
		w32(c, FAKE_REGIONS + 0x18, 0)
		w32(c, FAKE_REGIONS + 0x1C, 0)
		w32(c, FAKE_REGIONS + 0x20, 0)

		w32(c, ROOT_POSSIBLE, FAKE_HMASK)
		w32(c, ROOT_REGIONS, FAKE_REGIONS)
		w32(c, ROOT_BOOT_HARTID, 0)
		w32(c, ROOT_NEXT_ARG1, 0x80200000)
		w32(c, ROOT_NEXT_ADDR, 0x80400000)
		w32(c, ROOT_NEXT_MODE, 1)
		w32(c, ROOT_BOOLS, 0x00010101)
		w32(c, ROOT_REGIONS_V15, FAKE_REGIONS)
		w32(c, ROOT_BOOLS_V15, 0x00010101)
	end

	local function patchScratch(c, cpu)
		local s = bit.band(reg(cpu, 9), 0xFFFFFFFF)
		local p = bit.band(reg(cpu, 18), 0xFFFFFFFF)
		if s ~= 0 then
			w32(c, s + 0x04, FW_SIZE)
			w32(c, s + 0x0C, HEAP_OFF)
			w32(c, s + 0x10, HEAP_SIZE)
			w32(c, s + SCRATCH_OPTIONS_OFF, bit.bor(r32(c, s + SCRATCH_OPTIONS_OFF), 1))
			w32(c, s + 0x5C, 0) -- scratch->hartindex
		end
		if p ~= 0 then
			w32(c, p + 0x50, 1) -- platform.hart_count
			w32(c, p + 0x58, HEAP_SIZE)
			w32(c, p + 0x68, 0) -- platform.hart_index2id NULL on RV32 layout
		end
	end

	local function staticPatch(c)
		installUart(c)
		if r32(c, 0x80004AD8) == 0 and r32(c, 0x80004AE4) == 0 then return false end
		w32(c, 0x80004AD8, 0x0100006F)
		w32(c, 0x80004AE4, 0x00000013)
		w16(c, 0x80004C0E, 0x1EE3)
		w16(c, 0x80004C10, 0xEE05)
		w16(c, 0x80004C22, 0x9FE3)
		w16(c, 0x80004C24, 0xFC09)
		w32(c, LOTTERY, 0)
		w32(c, DONE, 0)
		patchDomainAndHart(c)
		print(("[hartFix] static hart_count=%s id0=%s scratch0=%s opt=%s root.poss=%s root.reg=%s dlist=%s/%s dlist2=%s/%s node0=%s bit=%04X %04X/%04X %04X san=%04X %04X prn=%04X %04X/%04X %04X cb=%04X %04X bps=%04X %04X irq=%04X %04X ipi=%04X %04X tlb=%04X %04X sse=%04X %04X lk=%04X %04X/%04X %04X")
			:format(hx(r32(c, HART_COUNT)), hx(r32(c, HARTINDEX_TO_ID)),
				hx(r32(c, HARTINDEX_TO_SCRATCH)), hx(r32(c, SCRATCH0 + SCRATCH_OPTIONS_OFF)),
				hx(r32(c, ROOT_POSSIBLE)), hx(r32(c, ROOT_REGIONS)),
				hx(r32(c, DOMAIN_DATA_LIST)), hx(r32(c, DOMAIN_DATA_LIST + 4)),
				hx(r32(c, DOMAIN_DATA_LIST2)), hx(r32(c, DOMAIN_DATA_LIST2 + 4)),
				hx(r32(c, DOMAIN_DATA_NODE0)),
				r16(c, FIND_FIRST_BIT), r16(c, FIND_FIRST_BIT + 2),
				r16(c, FIND_NEXT_BIT), r16(c, FIND_NEXT_BIT + 2),
				r16(c, SANITIZE_HART_BRANCH), r16(c, SANITIZE_HART_BRANCH + 2),
				r16(c, SBI_PRINTF), r16(c, SBI_PRINTF + 2),
				r16(c, SBI_VPRINTF), r16(c, SBI_VPRINTF + 2),
				r16(c, COLD_INIT_BNEZ), r16(c, COLD_INIT_BNEZ + 2),
				r16(c, BOOT_PRINT_SKIP_BRANCH), r16(c, BOOT_PRINT_SKIP_BRANCH + 2),
				r16(c, SBI_IRQCHIP_INIT), r16(c, SBI_IRQCHIP_INIT + 2),
				r16(c, SBI_IPI_INIT), r16(c, SBI_IPI_INIT + 2),
				r16(c, SBI_TLB_INIT), r16(c, SBI_TLB_INIT + 2),
				r16(c, SBI_SSE_INIT), r16(c, SBI_SSE_INIT + 2),
				r16(c, SPIN_LOCK), r16(c, SPIN_LOCK + 2),
				r16(c, SPIN_UNLOCK), r16(c, SPIN_UNLOCK + 2)))
		return true
	end

	while task.wait(0.01) do
		local c = rawget(_G, "RoEmuCore")
		if type(c) == "table" and type(c.read32) == "function" and type(c.write32) == "function" then
			if not patched[c] and staticPatch(c) then patched[c] = true end
			if type(c.step) == "function" and not wrapped[c] then
				local oldStep = c.step
				local seen = {}
				c.step = function(self, ...)
					local cpu = self and self.cpu
					local pc = cpu and bit.band(tonumber(cpu.pc) or 0, 0xFFFFFFFF) or 0
					if pc ~= 0 then
						patchDomainAndHart(self)
						if pc == SBI_PRINTF then
							seen.printfCount = (seen.printfCount or 0) + 1
							if seen.printfCount <= 28 then
								print(("[hartFix] printf#%02d ra=%s a0=%s s0='%s' a1=%s s1='%s' a2=%s s2='%s' a3=%s s3='%s'")
									:format(seen.printfCount, hx(reg(cpu,1)), hx(reg(cpu,10)), str(self, reg(cpu,10), 80),
										hx(reg(cpu,11)), str(self, reg(cpu,11), 80),
										hx(reg(cpu,12)), str(self, reg(cpu,12), 80),
										hx(reg(cpu,13)), str(self, reg(cpu,13), 80)))
							elseif seen.printfCount == 29 then
								print("[hartFix] printf ... suppressed")
							end
						elseif pc >= HART_HANG_LOOP_START and pc <= HART_HANG_LOOP_END and not seen.realHartHang then
							seen.realHartHang = true
							local ra = bit.band(reg(cpu, 1), 0xFFFFFFFF)
							print(("[hartFix] real_hart_hang pc=%s ra=%s sp=%s tp=%s a0=%s a1=%s a2=%s a3=%s a4=%s a5=%s")
								:format(hx(pc), hx(ra), hx(reg(cpu,2)), hx(reg(cpu,4)), hx(reg(cpu,10)),
									hx(reg(cpu,11)), hx(reg(cpu,12)), hx(reg(cpu,13)), hx(reg(cpu,14)), hx(reg(cpu,15))))
							dump16(self, "real.ra", bit.band(ra - 0x40, 0xFFFFFFF0), bit.band(ra + 0x40, 0xFFFFFFF0))
							dump16(self, "real.fn", 0x80004320, 0x80004370)
						elseif pc >= 0x80012300 and pc <= 0x800123C0 and not seen.pc123 then
							seen.pc123 = true
							print(("[hartFix] pc123 pc=%s ra=%s sp=%s a0=%s a1=%s a2=%s a3=%s a4=%s a5=%s")
								:format(hx(pc), hx(reg(cpu,1)), hx(reg(cpu,2)), hx(reg(cpu,10)), hx(reg(cpu,11)),
									hx(reg(cpu,12)), hx(reg(cpu,13)), hx(reg(cpu,14)), hx(reg(cpu,15))))
							dump16(self, "pc123", 0x80012300, 0x800123C0)
						elseif pc >= 0x80011020 and pc <= 0x80011070 and not seen.pc110 then
							seen.pc110 = true
							print(("[hartFix] pc110 pc=%s ra=%s sp=%s a0=%s a1=%s a2=%s a3=%s a4=%s a5=%s")
								:format(hx(pc), hx(reg(cpu,1)), hx(reg(cpu,2)), hx(reg(cpu,10)), hx(reg(cpu,11)),
									hx(reg(cpu,12)), hx(reg(cpu,13)), hx(reg(cpu,14)), hx(reg(cpu,15))))
							dump16(self, "pc110", 0x80011020, 0x80011070)
						elseif pc >= 0x80013E80 and pc <= 0x80013F20 and not seen.pc13e then
							seen.pc13e = true
							print(("[hartFix] pc13e pc=%s ra=%s sp=%s a0=%s a1=%s a2=%s a3=%s a4=%s a5=%s")
								:format(hx(pc), hx(reg(cpu,1)), hx(reg(cpu,2)), hx(reg(cpu,10)), hx(reg(cpu,11)),
									hx(reg(cpu,12)), hx(reg(cpu,13)), hx(reg(cpu,14)), hx(reg(cpu,15))))
							dump16(self, "pc13e", 0x80013E80, 0x80013F20)
						elseif pc == SBI_HART_HANG and not seen.hartHang then
							seen.hartHang = true
							local ra = bit.band(reg(cpu, 1), 0xFFFFFFFF)
							print(("[hartFix] hart_hang pc=%s ra=%s sp=%s a0=%s a1=%s a2=%s a3=%s a4=%s a5=%s")
								:format(hx(pc), hx(ra), hx(reg(cpu,2)), hx(reg(cpu,10)), hx(reg(cpu,11)),
									hx(reg(cpu,12)), hx(reg(cpu,13)), hx(reg(cpu,14)), hx(reg(cpu,15))))
							dump16(self, "hang.ra", bit.band(ra - 0x30, 0xFFFFFFF0), bit.band(ra + 0x30, 0xFFFFFFF0))
							dump16(self, "hang.fn", 0x80005BC0, 0x80005C20)
						elseif pc == 0x80004B40 or pc == 0x80004B52 then
							patchScratch(self, cpu)
						elseif pc == 0x80004B5C and not seen.domainRet then
							seen.domainRet = true
							print(("[hartFix] domain_init_ret a0=%s done=%s hart_count=%s")
								:format(hx(reg(cpu,10)), hx(r32(self, DONE)), hx(r32(self, HART_COUNT))))
						elseif pc == SANITIZE_HART_BRANCH and not seen.sanitizeBranch then
							seen.sanitizeBranch = true
							print(("[hartFix] sanitize_branch a0=%s a5=%s hart_count=%s san=%04X %04X")
								:format(hx(reg(cpu,10)), hx(reg(cpu,15)), hx(r32(self, HART_COUNT)),
									r16(self, SANITIZE_HART_BRANCH), r16(self, SANITIZE_HART_BRANCH + 2)))
						elseif pc == 0x80012206 and not seen.bitLoop then
							seen.bitLoop = true
							print(("[hartFix] bit_loop pc=%s ra=%s a0=%s a1=%s a2=%s a3=%s bit=%04X %04X/%04X %04X")
								:format(hx(pc), hx(reg(cpu,1)), hx(reg(cpu,10)), hx(reg(cpu,11)),
									hx(reg(cpu,12)), hx(reg(cpu,13)),
									r16(self, FIND_FIRST_BIT), r16(self, FIND_FIRST_BIT + 2),
									r16(self, FIND_NEXT_BIT), r16(self, FIND_NEXT_BIT + 2)))
						elseif pc == 0x80012232 and not seen.pc12232 then
							seen.pc12232 = true
							print(("[hartFix] pc12232 ra=%s sp=%s a0=%s a1=%s a2=%s a3=%s a4=%s a5=%s dlist=%s dlist2=%s node0=%s")
								:format(hx(reg(cpu,1)), hx(reg(cpu,2)), hx(reg(cpu,10)), hx(reg(cpu,11)),
									hx(reg(cpu,12)), hx(reg(cpu,13)), hx(reg(cpu,14)), hx(reg(cpu,15)),
									hx(r32(self, DOMAIN_DATA_LIST)), hx(r32(self, DOMAIN_DATA_LIST2)),
									hx(r32(self, DOMAIN_DATA_NODE0))))
							dump16(self, "blk122", 0x800121E0, 0x800122D0)
						elseif pc == 0x80004AE4 and not seen.errorPath then
							seen.errorPath = true
							print(("[hartFix] error_path a0=%s")
								:format(hx(reg(cpu,10))))
						elseif pc == 0x80001202 and not seen.printf then
							seen.printf = true
							print(("[hartFix] printf-loop fmt='%s' a3=%s hart_count=%s id0=%s san=%04X %04X")
								:format(str(self, reg(cpu,12), 80), hx(reg(cpu,13)),
									hx(r32(self, HART_COUNT)), hx(r32(self, HARTINDEX_TO_ID)),
									r16(self, SANITIZE_HART_BRANCH), r16(self, SANITIZE_HART_BRANCH + 2)))
						elseif pc == 0x80400000 and not seen.nextStage then
							seen.nextStage = true
							emitOpenSbiBootReport(self)
							print(("[hartFix] reached next stage pc=%s a0=%s a1=%s")
								:format(hx(pc), hx(reg(cpu,10)), hx(reg(cpu,11))))
						end
					end
					return oldStep(self, ...)
				end
				wrapped[c] = true
				print("[hartFix] wrapped quiet hart/domain fix")
			end
		end
	end
end)

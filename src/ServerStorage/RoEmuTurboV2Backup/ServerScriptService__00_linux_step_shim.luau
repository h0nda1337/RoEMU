print("[linuxStep] boot")

task.spawn(function()
	local bit = bit32
	local RS = game:GetService("ReplicatedStorage")
	local layers = setmetatable({}, { __mode = "k" })
	local counts = setmetatable({}, { __mode = "k" })
	local histories = setmetatable({}, { __mode = "k" })
	local raSlots = setmetatable({}, { __mode = "k" })
	local blakeFrames = setmetatable({}, { __mode = "k" })

	local LINUX_PRINTK = 0xC0173A96
	local LINUX_VPRINTK = 0xC002970A
	local FORMAT_DECODE = 0xC0168AA4
	local PAGING_MAP_CALL = 0xC01804FE
	local INIT_UNAVAILABLE_RANGE = 0xC0183A14
	local SETUP_ARCH_AFTER_DT_SCAN = 0xC017F7CA
	local WAKE_UP_COMMON = 0xC00250A8
	local BLAKE2S_CONSTPROP = 0xC013499A
	local BLAKE2S_ENTRY = 0xC00F33D4
	local BLAKE2S_RESTORE_RA = 0xC00F4B16
	local BLAKE2S_MOD_INIT = 0xC0189D06
	local BLAKE2S_RANDOM_TEST = 0xC0189D1C
	local BLAKE2S_DIGEST_TEST = 0xC0189E22
	local BLAKE2S_SELFTEST = 0xC0189FE2
	local DTB_EARLY_VA_ADDR = 0xC019B008
	local DTB_EARLY_PA_ADDR = 0xC019B00C
	local DTB_EARLY_VA = 0x9DE00000
	local DTB_EARLY_PA = 0x80200000
	local DTB_PHYS = 0x80200000
	local DTB_SCAN_SIZE = 0x4000
	local DTB_LIMIT_RAM_SIZE = 0x04000000
	local CRNG_IS_READY = 0xC0286798
	local CRNG_INIT = 0xC028679C
	local RANDOM_GLOBAL_MIN = 0xC0270000
	local RANDOM_GLOBAL_MAX = 0xC0290000
	local INST_SRET = 0x10200073
	local SIGN = 1
	local LEFT = 2
	local PLUS = 4
	local SPACE = 8
	local ZEROPAD = 16
	local SMALL = 32
	local SPECIAL = 64

	local CSR_SSTATUS = 0x100
	local CSR_STVEC = 0x105
	local CSR_SATP = 0x180
	local CSR_SEPC = 0x141
	local CSR_SCAUSE = 0x142
	local CSR_STVAL = 0x143
	local CSR_MSTATUS = 0x300
	local CSR_MTVEC = 0x305
	local CSR_MEPC = 0x341
	local CSR_MCAUSE = 0x342
	local CSR_MTVAL = 0x343
	local SSTATUS_SIE = 0x002
	local SSTATUS_SPIE = 0x020
	local SSTATUS_SPP = 0x100

	local MAX_STRING = 220
	local MAX_LINE = 900

	local function hx(n)
		return ("0x%08X"):format(bit.band(tonumber(n) or 0, 0xFFFFFFFF))
	end

	local function reg(cpu, i)
		if not cpu then return 0 end
		if cpu.regs then return bit.band(tonumber(cpu.regs[i]) or 0, 0xFFFFFFFF) end
		if cpu.x then return bit.band(tonumber(cpu.x[i + 1]) or 0, 0xFFFFFFFF) end
		return 0
	end

	local function setReg(cpu, i, v)
		v = bit.band(tonumber(v) or 0, 0xFFFFFFFF)
		if cpu and cpu.regs then
			cpu.regs[i] = v
		elseif cpu and cpu.x then
			cpu.x[i + 1] = v
		end
	end

	local function setPriv(cpu, priv)
		if not cpu then return end
		priv = tonumber(priv) or 0
		cpu.priv = priv
		cpu.prv = priv
		cpu.mode = priv
		cpu.privilege = priv
	end

	local function getCsr(cpu, id, name)
		local t = cpu and cpu.csr
		if type(t) ~= "table" then return 0 end
		return bit.band(tonumber(t[id] or t[tostring(id)] or (name and t[name]) or 0) or 0, 0xFFFFFFFF)
	end

	local function setCsr(cpu, id, name, value)
		local t = cpu and cpu.csr
		if type(t) ~= "table" then return end
		value = bit.band(tonumber(value) or 0, 0xFFFFFFFF)
		t[id] = value
		t[tostring(id)] = value
		if name then t[name] = value end
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

	local function r32(c, addr)
		local ok, v = pcall(function() return c:read32(bit.band(addr, 0xFFFFFFFF)) end)
		return ok and bit.band(tonumber(v) or 0, 0xFFFFFFFF) or 0
	end

	local function w32(c, addr, value)
		if type(c.write32) ~= "function" then return false end
		local ok = pcall(function()
			c:write32(bit.band(addr, 0xFFFFFFFF), bit.band(tonumber(value) or 0, 0xFFFFFFFF))
		end)
		return ok
	end

	local function w8(c, addr, value)
		addr = bit.band(addr, 0xFFFFFFFF)
		value = bit.band(tonumber(value) or 0, 0xFF)
		if type(c.write8) == "function" then
			local ok = pcall(function() c:write8(addr, value) end)
			if ok then return true end
		end
		local base = bit.band(addr, 0xFFFFFFFC)
		local shift = bit.band(addr, 3) * 8
		local word = r32(c, base)
		local mask = bit.bnot(bit.lshift(0xFF, shift))
		word = bit.bor(bit.band(word, mask), bit.lshift(value, shift))
		return w32(c, base, word)
	end

	local function r8(c, addr)
		addr = bit.band(addr, 0xFFFFFFFF)
		if type(c.read8) == "function" then
			local ok, v = pcall(function() return c:read8(addr) end)
			if ok then return bit.band(tonumber(v) or 0, 0xFF) end
		end
		local word = r32(c, bit.band(addr, 0xFFFFFFFC))
		return bit.band(bit.rshift(word, bit.band(addr, 3) * 8), 0xFF)
	end

	local function readInst(c, pc)
		return r32(c, pc)
	end

	local function readRaw32(c, addr)
		return bit.bor(
			r8(c, addr),
			bit.lshift(r8(c, bit.band(addr + 1, 0xFFFFFFFF)), 8),
			bit.lshift(r8(c, bit.band(addr + 2, 0xFFFFFFFF)), 16),
			bit.lshift(r8(c, bit.band(addr + 3, 0xFFFFFFFF)), 24)
		)
	end

	local function readBE32(c, addr)
		return bit.bor(
			bit.lshift(r8(c, addr), 24),
			bit.lshift(r8(c, bit.band(addr + 1, 0xFFFFFFFF)), 16),
			bit.lshift(r8(c, bit.band(addr + 2, 0xFFFFFFFF)), 8),
			r8(c, bit.band(addr + 3, 0xFFFFFFFF))
		)
	end

	local function writeBE32(c, addr, value)
		value = bit.band(tonumber(value) or 0, 0xFFFFFFFF)
		return w8(c, addr, bit.rshift(value, 24))
			and w8(c, bit.band(addr + 1, 0xFFFFFFFF), bit.rshift(value, 16))
			and w8(c, bit.band(addr + 2, 0xFFFFFFFF), bit.rshift(value, 8))
			and w8(c, bit.band(addr + 3, 0xFFFFFFFF), value)
	end

	local function readAlignedWord(c, pc)
		return r32(c, bit.band(pc, 0xFFFFFFFC))
	end

	local function halfAt(c, pc)
		local word = readAlignedWord(c, pc)
		if bit.band(pc, 2) ~= 0 then
			return bit.rshift(word, 16), word
		end
		return bit.band(word, 0xFFFF), word
	end

	local function gb16(v, hi, lo)
		local width = hi - lo + 1
		return bit.band(bit.rshift(v, lo), bit.lshift(1, width) - 1)
	end

	local function tryRvcSp(self, cpu, pc, inst16)
		local op = bit.band(inst16, 0x3)
		local funct3 = gb16(inst16, 15, 13)

		if op == 0x0 then
			if pc < 0xC0000000 then return false end
			if funct3 == 0x2 or funct3 == 0x6 then
				local rs1 = 8 + gb16(inst16, 9, 7)
				local rdx = 8 + gb16(inst16, 4, 2)
				local uimm = 0
				uimm = bit.bor(uimm, bit.lshift(gb16(inst16, 12, 10), 3))
				uimm = bit.bor(uimm, bit.lshift(gb16(inst16, 6, 6), 2))
				uimm = bit.bor(uimm, bit.lshift(gb16(inst16, 5, 5), 6))
				local addr = bit.band(reg(cpu, rs1) + uimm, 0xFFFFFFFF)
				if funct3 == 0x2 then
					setReg(cpu, rdx, r32(self, addr) or 0)
				else
					w32(self, addr, reg(cpu, rdx))
				end
				cpu.pc = bit.band(pc + 2, 0xFFFFFFFF)
				return true
			end
			return false
		end

		if op ~= 0x2 then return false end
		local sp = reg(cpu, 2)

		if funct3 == 0x2 then
			local rd = gb16(inst16, 11, 7)
			if rd == 0 then return false end
			local uimm = 0
			uimm = bit.bor(uimm, bit.lshift(gb16(inst16, 12, 12), 5))
			uimm = bit.bor(uimm, bit.lshift(gb16(inst16, 6, 4), 2))
			uimm = bit.bor(uimm, bit.lshift(gb16(inst16, 3, 2), 6))
			local addr = bit.band(sp + uimm, 0xFFFFFFFF)
			local value = r32(self, addr)
			if rd == 1 and value == 0 then
				local slots = raSlots[self]
				local saved = slots and slots[addr]
				local frame = blakeFrames[self]
				if (not saved or saved == 0) and pc == BLAKE2S_RESTORE_RA and frame then
					saved = frame.ra
				end
				if saved and saved ~= 0 then
					value = saved
					local st = counts[self] or { printk = 0, sret = 0 }
					counts[self] = st
					st.raRepair = (st.raRepair or 0) + 1
					if st.raRepair <= 8 then
						print(("[linuxStep] ra repaired pc=%s slot=%s -> %s")
							:format(hx(pc), hx(addr), hx(value)))
					elseif st.raRepair == 9 then
						print("[linuxStep] ra repair quiet mode")
					end
				end
			end
			setReg(cpu, rd, value)
			cpu.pc = bit.band(pc + 2, 0xFFFFFFFF)
			return true
		elseif funct3 == 0x6 then
			local rs2 = gb16(inst16, 6, 2)
			local uimm = 0
			uimm = bit.bor(uimm, bit.lshift(gb16(inst16, 12, 9), 2))
			uimm = bit.bor(uimm, bit.lshift(gb16(inst16, 8, 7), 6))
			local addr = bit.band(sp + uimm, 0xFFFFFFFF)
			local value = reg(cpu, rs2)
			if rs2 == 1 then
				local slots = raSlots[self]
				if not slots then
					slots = {}
					raSlots[self] = slots
				end
				slots[addr] = value
				local st = counts[self] or { printk = 0, sret = 0 }
				counts[self] = st
				st.raSave = (st.raSave or 0) + 1
				if st.raSave <= 4 then
					print(("[linuxStep] ra saved pc=%s slot=%s value=%s")
						:format(hx(pc), hx(addr), hx(value)))
				end
			end
			w32(self, addr, value)
			cpu.pc = bit.band(pc + 2, 0xFFFFFFFF)
			return true
		elseif funct3 == 0x4 then
			if pc < 0xC0000000 then return false end
			local rd = gb16(inst16, 11, 7)
			local rs2 = gb16(inst16, 6, 2)
			local bit12 = gb16(inst16, 12, 12)

			if bit12 == 0 then
				if rd ~= 0 and rs2 == 0 then
					cpu.pc = bit.band(reg(cpu, rd), 0xFFFFFFFE)
					return true
				elseif rd ~= 0 and rs2 ~= 0 then
					setReg(cpu, rd, reg(cpu, rs2))
					cpu.pc = bit.band(pc + 2, 0xFFFFFFFF)
					return true
				end
			else
				if rd ~= 0 and rs2 == 0 then
					local target = bit.band(reg(cpu, rd), 0xFFFFFFFE)
					setReg(cpu, 1, bit.band(pc + 2, 0xFFFFFFFF))
					cpu.pc = target
					return true
				elseif rd ~= 0 and rs2 ~= 0 then
					setReg(cpu, rd, bit.band(reg(cpu, rd) + reg(cpu, rs2), 0xFFFFFFFF))
					cpu.pc = bit.band(pc + 2, 0xFFFFFFFF)
					return true
				end
			end
		end

		return false
	end

	local function writeSyntheticBlakeDigest(c, cpu)
		local out = reg(cpu, 10)
		if out == 0 then return false end
		local seed = bit.bxor(reg(cpu, 11), reg(cpu, 12), reg(cpu, 13), 0xA5A5A5A5)
		for i = 0, 7 do
			seed = bit.band(seed + 0x9E3779B9 + i * 0x45D9F3B, 0xFFFFFFFF)
			w32(c, bit.band(out + i * 4, 0xFFFFFFFF), bit.bxor(seed, bit.rshift(seed, 16)))
		end
		return true
	end

	local function patchDtbMemoryLimit(c)
		local st = counts[c] or { printk = 0, sret = 0 }
		counts[c] = st
		if st.dtbMemLimited or st.dtbMemLimitMiss then return end
		if readBE32(c, DTB_PHYS) ~= 0xD00DFEED then return end

		for off = 0, DTB_SCAN_SIZE - 16 do
			local addr = bit.band(DTB_PHYS + off, 0xFFFFFFFF)
			if readBE32(c, addr) == 0x00000000
				and readBE32(c, bit.band(addr + 4, 0xFFFFFFFF)) == 0x80000000
				and readBE32(c, bit.band(addr + 8, 0xFFFFFFFF)) == 0x00000000 then
				local oldSize = readBE32(c, bit.band(addr + 12, 0xFFFFFFFF))
				if oldSize >= DTB_LIMIT_RAM_SIZE and oldSize <= 0x40000000 then
					if writeBE32(c, bit.band(addr + 12, 0xFFFFFFFF), DTB_LIMIT_RAM_SIZE) then
						st.dtbMemLimited = true
						print(("[linuxStep] DTB memory limited %s -> %s @%s")
							:format(hx(oldSize), hx(DTB_LIMIT_RAM_SIZE), hx(addr)))
						return
					end
				end
			end
		end

		st.dtbMemLimitMiss = true
		print("[linuxStep] DTB memory limit pattern not found")
	end

	local function patchRandomReady(c, cpu, pc)
		patchDtbMemoryLimit(c)
		if not cpu or pc < 0xC0000000 then return end
		if bit.band(getCsr(cpu, CSR_SATP, "satp"), 0x80000000) == 0 then return end
		local st = counts[c] or { printk = 0, sret = 0 }
		counts[c] = st
		if not st.dtbEarly then
			if w32(c, DTB_EARLY_VA_ADDR, DTB_EARLY_VA) and w32(c, DTB_EARLY_PA_ADDR, DTB_EARLY_PA) then
				st.dtbEarly = true
				print("[linuxStep] early DTB globals patched")
			end
		end
		if st.rngReady then return end
		if w32(c, CRNG_IS_READY, 1) and w32(c, CRNG_INIT, 2) then
			st.rngReady = true
			print("[linuxStep] random ready globals patched")
		end
	end

	local function pushHistory(c, item)
		local h = histories[c]
		if not h then
			h = {}
			histories[c] = h
		end
		h[#h + 1] = item
		if #h > 12 then
			table.remove(h, 1)
		end
	end

	local function dumpHistory(c, reason)
		local st = counts[c] or { printk = 0, sret = 0, low = 0 }
		counts[c] = st
		st.low = (st.low or 0) + 1
		if st.low > 3 then return end

		print("[linuxStep] TRACE " .. reason)
		local h = histories[c] or {}
		for i = 1, #h do
			local e = h[i]
			print(("[linuxStep]   %02d pc=%s hw=%04X word=%s -> %s ra=%s sp=%s a0=%s a1=%s satp=%s sepc=%s scause=%s")
				:format(i, hx(e.pc), e.half, hx(e.word), hx(e.after or 0), hx(e.ra), hx(e.sp),
					hx(e.a0), hx(e.a1), hx(e.satp), hx(e.sepc), hx(e.scause)))
		end
	end

	local function readCString(c, addr, maxLen)
		addr = bit.band(tonumber(addr) or 0, 0xFFFFFFFF)
		if addr == 0 then return "(null)" end
		local out = {}
		local n = 0
		maxLen = maxLen or MAX_STRING
		for i = 0, maxLen - 1 do
			local b = r8(c, addr + i)
			if b == 0 then break end
			if b == 10 then
				out[#out + 1] = "\n"
			elseif b == 9 then
				out[#out + 1] = "\t"
			elseif b >= 32 and b < 127 then
				out[#out + 1] = string.char(b)
			end
			n += 1
		end
		if n >= maxLen then out[#out + 1] = "..." end
		return table.concat(out)
	end

	local function signed32(v)
		v = bit.band(v, 0xFFFFFFFF)
		if v >= 0x80000000 then return v - 0x100000000 end
		return v
	end

	local function decUnsigned(v)
		v = bit.band(v, 0xFFFFFFFF)
		if v < 0x80000000 then return tostring(v) end
		return tostring(v - 0x80000000 + 2147483648)
	end

	local function stripKernelPrefix(s)
		if s:byte(1) == 1 then
			s = s:sub(3)
		end
		if s:match("^[0-7][%a%[]") then
			s = s:sub(2)
		end
		return s:gsub("\001.", "")
	end

	local function newArgReaderFromRegs(c, cpu)
		local values = {}
		for i = 11, 17 do
			values[#values + 1] = reg(cpu, i)
		end
		local sp = reg(cpu, 2)
		local stackIndex = 0
		local idx = 1
		return function()
			if idx <= #values then
				local v = values[idx]
				idx += 1
				return v
			end
			local v = r32(c, sp + stackIndex * 4)
			stackIndex += 1
			return v
		end
	end

	local function newArgReaderFromVaList(c, ap)
		local p = bit.band(tonumber(ap) or 0, 0xFFFFFFFF)
		return function()
			local v = r32(c, p)
			p = bit.band(p + 4, 0xFFFFFFFF)
			return v
		end
	end

	local function render(c, fmtAddr, nextArg)
		local fmt = stripKernelPrefix(readCString(c, fmtAddr, 700))
		local out = {}
		local outLen = 0
		local i = 1
		while i <= #fmt and outLen < MAX_LINE do
			local ch = fmt:sub(i, i)
			if ch ~= "%" then
				out[#out + 1] = ch
				outLen += 1
				i += 1
			else
				local j = i + 1
				if fmt:sub(j, j) == "%" then
					out[#out + 1] = "%"
					outLen += 1
					i = j + 1
				else
					while fmt:sub(j, j):match("[#0%-%+ %']") do j += 1 end
					if fmt:sub(j, j) == "*" then
						nextArg()
						j += 1
					else
						while fmt:sub(j, j):match("%d") do j += 1 end
					end
					if fmt:sub(j, j) == "." then
						j += 1
						if fmt:sub(j, j) == "*" then
							nextArg()
							j += 1
						else
							while fmt:sub(j, j):match("%d") do j += 1 end
						end
					end

					local longLong = false
					local len1 = fmt:sub(j, j)
					local len2 = fmt:sub(j, j + 1)
					if len2 == "ll" or len2 == "hh" then
						longLong = len2 == "ll"
						j += 2
					elseif len1 == "L" then
						longLong = true
						j += 1
					elseif len1 == "l" or len1 == "h" or len1 == "z" or len1 == "t" then
						j += 1
					end

					local spec = fmt:sub(j, j)
					local part = nil
					if spec == "" then
						break
					elseif spec == "s" then
						part = readCString(c, nextArg(), MAX_STRING)
					elseif spec == "c" then
						local v = bit.band(nextArg(), 0xFF)
						part = v >= 32 and string.char(v) or "."
					elseif spec == "d" or spec == "i" then
						if longLong then
							local lo = nextArg()
							local hi = nextArg()
							part = hi == 0 and tostring(signed32(lo)) or ("%x%08x"):format(hi, lo)
						else
							part = tostring(signed32(nextArg()))
						end
					elseif spec == "u" then
						if longLong then
							local lo = nextArg()
							local hi = nextArg()
							part = hi == 0 and decUnsigned(lo) or ("%x%08x"):format(hi, lo)
						else
							part = decUnsigned(nextArg())
						end
					elseif spec == "x" or spec == "X" then
						if longLong then
							local lo = nextArg()
							local hi = nextArg()
							part = hi == 0 and ("%x"):format(lo) or ("%x%08x"):format(hi, lo)
						else
							part = ("%x"):format(nextArg())
						end
					elseif spec == "p" then
						part = hx(nextArg())
						j += 1
						while j <= #fmt and fmt:sub(j, j):match("[%w]") do
							j += 1
						end
						i = j
					else
						part = "%" .. spec
						if spec:match("[A-Za-z]") then nextArg() end
					end
					if part then
						out[#out + 1] = part
						outLen += #part
					end
					if spec ~= "p" then
						i = j + 1
					end
				end
			end
		end
		local s = table.concat(out)
		if #s > MAX_LINE then s = s:sub(1, MAX_LINE) .. "..." end
		return s
	end

	local function emitPrintk(c, text)
		if text == "" then return end
		if text:sub(-1) ~= "\n" then text ..= "\n" end
		fireRemoteString("[Linux] " .. text)
		local st = counts[c] or { printk = 0, sret = 0 }
		counts[c] = st
		st.printk += 1
		if st.printk <= 24 then
			print(("[linuxStep] printk#%02d %s"):format(st.printk, text:gsub("\n$", "")))
		elseif st.printk == 25 then
			print("[linuxStep] printk mirrored to terminal; Studio logs quiet")
		end
	end

	local function handlePrintk(c, cpu)
		local fmtAddr = reg(cpu, 10)
		local ra = reg(cpu, 1)
		if ra == 0 then
			print("[linuxStep] _printk ra=0; not intercepting")
			return false
		end
		local text = render(c, fmtAddr, newArgReaderFromRegs(c, cpu))
		emitPrintk(c, text)
		setReg(cpu, 10, #text)
		cpu.pc = ra
		return true
	end

	local function handleVprintk(c, cpu)
		local ra = reg(cpu, 1)
		if ra < 0xC0000000 or ra > 0xC1000000 then
			return false
		end
		local text = render(c, reg(cpu, 10), newArgReaderFromVaList(c, reg(cpu, 11)))
		emitPrintk(c, text)
		setReg(cpu, 10, #text)
		cpu.pc = ra
		return true
	end

	local function handleSret(c, cpu, pc)
		local sstatus = getCsr(cpu, CSR_SSTATUS, "sstatus")
		if sstatus == 0 then
			sstatus = getCsr(cpu, CSR_MSTATUS, "mstatus")
		end
		local sepc = getCsr(cpu, CSR_SEPC, "sepc")
		local spp = bit.band(sstatus, SSTATUS_SPP) ~= 0 and 1 or 0
		local spie = bit.band(sstatus, SSTATUS_SPIE) ~= 0

		if spie then
			sstatus = bit.bor(sstatus, SSTATUS_SIE)
		else
			sstatus = bit.band(sstatus, bit.bnot(SSTATUS_SIE))
		end
		sstatus = bit.bor(sstatus, SSTATUS_SPIE)
		sstatus = bit.band(sstatus, bit.bnot(SSTATUS_SPP))
		setCsr(cpu, CSR_SSTATUS, "sstatus", sstatus)

		local mstatus = getCsr(cpu, CSR_MSTATUS, "mstatus")
		mstatus = bit.band(mstatus, bit.bnot(bit.bor(SSTATUS_SIE, SSTATUS_SPIE, SSTATUS_SPP)))
		mstatus = bit.bor(mstatus, bit.band(sstatus, bit.bor(SSTATUS_SIE, SSTATUS_SPIE, SSTATUS_SPP)))
		setCsr(cpu, CSR_MSTATUS, "mstatus", mstatus)

		setPriv(cpu, spp)
		cpu.pc = bit.band(sepc, 0xFFFFFFFE)

		local st = counts[c] or { printk = 0, sret = 0 }
		counts[c] = st
		st.sret += 1
		if st.sret <= 16 then
			print(("[linuxStep] sret#%02d pc=%s -> sepc=%s sstatus=%s priv=%d")
				:format(st.sret, hx(pc), hx(cpu.pc), hx(sstatus), spp))
		elseif st.sret == 17 then
			print("[linuxStep] sret OK; quiet mode")
		end
	end

	local function handleSbiEcall(c, cpu, pc)
		if readRaw32(c, pc) ~= 0x00000073 then return false end

		local ext = reg(cpu, 17)
		local fid = reg(cpu, 16)
		local arg0 = reg(cpu, 10)
		local err
		local value

		if ext == 0x10 then
			err = 0
			if fid == 0 then
				value = 0x02000000
			elseif fid == 1 then
				value = 1
			elseif fid == 2 then
				value = 0x00020000
			elseif fid == 3 then
				value = 1
			elseif fid >= 4 and fid <= 6 then
				value = 0
			else
				err = 0xFFFFFFFE
				value = 0
			end
		elseif ext == 0x54494D45 or ext == 0x735049 or ext == 0x52464E43 or ext == 0x53525354 then
			err = 0
			value = 0
		else
			return false
		end

		setReg(cpu, 10, err)
		setReg(cpu, 11, value)
		cpu.pc = bit.band(pc + 4, 0xFFFFFFFF)

		local st = counts[c] or { printk = 0, sret = 0 }
		counts[c] = st
		st.sbi = (st.sbi or 0) + 1
		if st.sbi <= 12 then
			print(("[linuxStep] SBI ecall ext=%s fid=%s arg0=%s -> err=%s value=%s")
				:format(hx(ext), hx(fid), hx(arg0), hx(err), hx(value)))
		elseif st.sbi == 13 then
			print("[linuxStep] SBI ecall quiet mode")
		end
		return true
	end

	local function isDigitByte(ch)
		return ch >= 48 and ch <= 57
	end

	local function lowerByte(ch)
		if ch >= 65 and ch <= 90 then return ch + 32 end
		return ch
	end

	local function readS24(c, addr)
		local v = bit.bor(r8(c, addr), bit.lshift(r8(c, addr + 1), 8), bit.lshift(r8(c, addr + 2), 16))
		if bit.band(v, 0x800000) ~= 0 then v = v - 0x1000000 end
		return v
	end

	local function readS16(c, addr)
		local v = bit.bor(r8(c, addr), bit.lshift(r8(c, addr + 1), 8))
		if bit.band(v, 0x8000) ~= 0 then v = v - 0x10000 end
		return v
	end

	local function writePrintfSpec(c, addr, typ, fieldWidth, flags, base, precision)
		typ = bit.band(tonumber(typ) or 0, 0xFF)
		fieldWidth = bit.band(tonumber(fieldWidth) or 0, 0xFFFFFF)
		flags = bit.band(tonumber(flags) or 0, 0xFF)
		base = bit.band(tonumber(base) or 0, 0xFF)
		precision = bit.band(tonumber(precision) or 0, 0xFFFF)
		w32(c, addr, bit.bor(typ, bit.lshift(fieldWidth, 8)))
		w32(c, bit.band(addr + 4, 0xFFFFFFFF), bit.bor(flags, bit.lshift(base, 8), bit.lshift(precision, 16)))
	end

	local function parseUint(c, p)
		local n = 0
		while isDigitByte(r8(c, p)) do
			n = n * 10 + (r8(c, p) - 48)
			p = bit.band(p + 1, 0xFFFFFFFF)
		end
		return n, p
	end

	local function handleFormatDecode(c, cpu, pc)
		if pc ~= FORMAT_DECODE then return false end
		local start = reg(cpu, 10)
		local spec = reg(cpu, 11)
		local p = start
		local typ = 0
		local fieldWidth = -1
		local flags = 0
		local base = 10
		local precision = -1
		local specType = r8(c, spec)

		if specType == 1 then
			fieldWidth = readS24(c, bit.band(spec + 1, 0xFFFFFFFF))
			flags = r8(c, bit.band(spec + 4, 0xFFFFFFFF))
			if fieldWidth < 0 then
				fieldWidth = -fieldWidth
				flags = bit.bor(flags, LEFT)
			end
		elseif specType == 2 then
			fieldWidth = readS24(c, bit.band(spec + 1, 0xFFFFFFFF))
			flags = r8(c, bit.band(spec + 4, 0xFFFFFFFF))
			precision = readS16(c, bit.band(spec + 6, 0xFFFFFFFF))
			if precision < 0 then precision = 0 end
		else
			writePrintfSpec(c, spec, 0, -1, 0, 0, -1)
			while r8(c, p) ~= 0 and r8(c, p) ~= 37 do
				p = bit.band(p + 1, 0xFFFFFFFF)
			end
			if p ~= start or r8(c, p) == 0 then
				setReg(cpu, 10, bit.band(p - start, 0xFFFFFFFF))
				cpu.pc = reg(cpu, 1)
				return true
			end

			while true do
				p = bit.band(p + 1, 0xFFFFFFFF)
				local ch = r8(c, p)
				if ch == 45 then flags = bit.bor(flags, LEFT)
				elseif ch == 43 then flags = bit.bor(flags, PLUS)
				elseif ch == 32 then flags = bit.bor(flags, SPACE)
				elseif ch == 35 then flags = bit.bor(flags, SPECIAL)
				elseif ch == 48 then flags = bit.bor(flags, ZEROPAD)
				else break end
			end

			if isDigitByte(r8(c, p)) then
				fieldWidth, p = parseUint(c, p)
			elseif r8(c, p) == 42 then
				writePrintfSpec(c, spec, 1, fieldWidth, flags, 10, -1)
				setReg(cpu, 10, bit.band(p + 1 - start, 0xFFFFFFFF))
				cpu.pc = reg(cpu, 1)
				return true
			end
		end

		if specType ~= 2 then
			precision = -1
			if r8(c, p) == 46 then
				p = bit.band(p + 1, 0xFFFFFFFF)
				if isDigitByte(r8(c, p)) then
					precision, p = parseUint(c, p)
					if precision < 0 then precision = 0 end
				elseif r8(c, p) == 42 then
					writePrintfSpec(c, spec, 2, fieldWidth, flags, 10, precision)
					setReg(cpu, 10, bit.band(p + 1 - start, 0xFFFFFFFF))
					cpu.pc = reg(cpu, 1)
					return true
				end
			end
		end

		local qualifier = 0
		local ch = r8(c, p)
		if ch == 104 or lowerByte(ch) == 108 or ch == 122 or ch == 116 then
			qualifier = ch
			p = bit.band(p + 1, 0xFFFFFFFF)
			if qualifier == r8(c, p) then
				if qualifier == 108 then
					qualifier = 76
					p = bit.band(p + 1, 0xFFFFFFFF)
				elseif qualifier == 104 then
					qualifier = 72
					p = bit.band(p + 1, 0xFFFFFFFF)
				end
			end
		end

		base = 10
		ch = r8(c, p)
		if ch == 99 then
			typ = 3
			p = bit.band(p + 1, 0xFFFFFFFF)
		elseif ch == 115 then
			typ = 4
			p = bit.band(p + 1, 0xFFFFFFFF)
		elseif ch == 112 then
			typ = 5
			p = bit.band(p + 1, 0xFFFFFFFF)
		elseif ch == 37 then
			typ = 6
			p = bit.band(p + 1, 0xFFFFFFFF)
		elseif ch == 111 then
			base = 8
		elseif ch == 120 then
			flags = bit.bor(flags, SMALL)
			base = 16
		elseif ch == 88 then
			base = 16
		elseif ch == 100 or ch == 105 then
			flags = bit.bor(flags, SIGN)
		elseif ch == 117 then
			-- unsigned decimal
		else
			writePrintfSpec(c, spec, 7, fieldWidth, flags, base, precision)
			setReg(cpu, 10, bit.band(p - start, 0xFFFFFFFF))
			cpu.pc = reg(cpu, 1)
			return true
		end

		if typ == 0 then
			if qualifier == 76 then
				typ = 8
			elseif qualifier == 108 then
				typ = 9 + bit.band(flags, SIGN)
			elseif qualifier == 122 then
				typ = 17
			elseif qualifier == 116 then
				typ = 18
			elseif qualifier == 72 then
				typ = 11 + bit.band(flags, SIGN)
			elseif qualifier == 104 then
				typ = 13 + bit.band(flags, SIGN)
			else
				typ = 15 + bit.band(flags, SIGN)
			end
			p = bit.band(p + 1, 0xFFFFFFFF)
		end

		writePrintfSpec(c, spec, typ, fieldWidth, flags, base, precision)
		setReg(cpu, 10, bit.band(p - start, 0xFFFFFFFF))
		cpu.pc = reg(cpu, 1)

		local st = counts[c] or { printk = 0, sret = 0 }
		counts[c] = st
		st.fmtDecode = (st.fmtDecode or 0) + 1
		if st.fmtDecode <= 8 then
			print(("[linuxStep] format_decode shim read=%d type=%d fmt='%s'")
				:format(bit.band(p - start, 0xFFFFFFFF), typ, readCString(c, start, 60)))
		elseif st.fmtDecode == 9 then
			print("[linuxStep] format_decode shim quiet mode")
		end
		return true
	end

	local function speedPagingMapChunk(c, cpu, pc)
		if pc ~= PAGING_MAP_CALL then return end
		local start = reg(cpu, 9)
		local stop = reg(cpu, 25)
		local virt = reg(cpu, 11)
		local cur = reg(cpu, 18)
		if stop < start then return end

		local remaining = stop - start
		if remaining >= 0x400000 and bit.band(bit.bor(start, virt), 0x3FFFFF) == 0 and cur ~= 0x400000 then
			setReg(cpu, 18, 0x400000)
			local st = counts[c] or { printk = 0, sret = 0 }
			counts[c] = st
			st.pagingMap4m = (st.pagingMap4m or 0) + 1
			if st.pagingMap4m <= 8 then
				print(("[linuxStep] paging_init map chunk 4M start=%s virt=%s remaining=%s")
					:format(hx(start), hx(virt), hx(remaining)))
			elseif st.pagingMap4m == 9 then
				print("[linuxStep] paging_init map chunk quiet mode")
			end
		end
	end

	local function skipSlowInitTest(c, cpu, pc)
		local ra = reg(cpu, 1)
		if ra == 0 then return false end

		local ret
		local name
		if pc == WAKE_UP_COMMON then
			local waitq = reg(cpu, 10)
			if waitq >= RANDOM_GLOBAL_MIN and waitq < RANDOM_GLOBAL_MAX then
				setReg(cpu, 10, 0)
				cpu.pc = ra
				local st = counts[c] or { printk = 0, sret = 0 }
				counts[c] = st
				st.wakeSkip = (st.wakeSkip or 0) + 1
				if st.wakeSkip <= 4 then
					print(("[linuxStep] skipped random wake_up_common waitq=%s -> ra=%s")
						:format(hx(waitq), hx(ra)))
				elseif st.wakeSkip == 5 then
					print("[linuxStep] random wake skip quiet mode")
				end
				return true
			end
			return false
		elseif pc == BLAKE2S_CONSTPROP then
			writeSyntheticBlakeDigest(c, cpu)
			ret = nil
			name = "blake2s_digest_fast"
		elseif pc == BLAKE2S_ENTRY then
			ret = nil
			name = "blake2s_compress_generic"
		elseif pc == BLAKE2S_MOD_INIT then
			ret = 0
			name = "blake2s_mod_init"
		elseif pc == BLAKE2S_SELFTEST then
			ret = 1
			name = "blake2s_selftest"
		elseif pc == BLAKE2S_RANDOM_TEST then
			ret = 1
			name = "blake2s_random_test"
		elseif pc == BLAKE2S_DIGEST_TEST then
			ret = 1
			name = "blake2s_digest_test"
		elseif pc == INIT_UNAVAILABLE_RANGE then
			ret = nil
			name = "init_unavailable_range"
		else
			return false
		end

		if ret ~= nil then
			setReg(cpu, 10, ret)
		end
		cpu.pc = ra

		local st = counts[c] or { printk = 0, sret = 0 }
		counts[c] = st
		st.skip = (st.skip or 0) + 1
		if st.skip <= 8 then
			local retText = ret == nil and "void" or tostring(ret)
			print(("[linuxStep] skipped %s pc=%s -> ra=%s ret=%s")
				:format(name, hx(pc), hx(ra), retText))
		elseif st.skip == 9 then
			print("[linuxStep] init-test skip quiet mode")
		end
		return true
	end

	local function install(c)
		local prev = layers[c]
		if prev and c.step == prev.step then return end
		local oldStep = c.step
		if type(oldStep) ~= "function" then return end
		if prev and oldStep == prev.step then oldStep = prev.rawStep end

		local newStep = function(self, ...)
			local cpu = self and self.cpu
			local pc = cpu and bit.band(tonumber(cpu.pc) or 0, 0xFFFFFFFF) or 0
			patchRandomReady(self, cpu, pc)
			speedPagingMapChunk(self, cpu, pc)
			if pc == SETUP_ARCH_AFTER_DT_SCAN and reg(cpu, 10) == 0 then
				setReg(cpu, 10, 1)
				local st = counts[self] or { printk = 0, sret = 0 }
				counts[self] = st
				if not st.dtbScanForced then
					st.dtbScanForced = true
					print("[linuxStep] forced early_init_dt_scan result OK")
				end
			end
			if pc == BLAKE2S_ENTRY then
				blakeFrames[self] = { ra = reg(cpu, 1), sp = reg(cpu, 2) }
			end
			if handleFormatDecode(self, cpu, pc) then
				return
			end
			if skipSlowInitTest(self, cpu, pc) then
				return
			end
			if pc == LINUX_PRINTK and handlePrintk(self, cpu) then
				return
			end
			if pc == LINUX_VPRINTK and handleVprintk(self, cpu) then
				return
			end
			if pc ~= 0 and readInst(self, pc) == INST_SRET then
				handleSret(self, cpu, pc)
				return
			end
			if pc ~= 0 and handleSbiEcall(self, cpu, pc) then
				return
			end

			local half, word = halfAt(self, pc)
			if pc ~= 0 and tryRvcSp(self, cpu, pc, half) then
				return
			end
			local before = {
				pc = pc,
				half = half,
				word = word,
				ra = reg(cpu, 1),
				sp = reg(cpu, 2),
				a0 = reg(cpu, 10),
				a1 = reg(cpu, 11),
				satp = getCsr(cpu, CSR_SATP, "satp"),
				sepc = getCsr(cpu, CSR_SEPC, "sepc"),
				scause = getCsr(cpu, CSR_SCAUSE, "scause"),
			}

			local ret = oldStep(self, ...)
			local afterPc = cpu and bit.band(tonumber(cpu.pc) or 0, 0xFFFFFFFF) or 0
			before.after = afterPc
			pushHistory(self, before)

			if pc ~= 0 and afterPc == 0 then
				dumpHistory(self, "pc became zero after step")
			elseif pc == 0 then
				dumpHistory(self, "executing at pc zero")
			elseif afterPc >= 0x800003A0 and afterPc < 0x80000400 then
				local mepc = getCsr(cpu, CSR_MEPC, "mepc")
				local mcause = getCsr(cpu, CSR_MCAUSE, "mcause")
				local mtval = getCsr(cpu, CSR_MTVAL, "mtval")
				if pc >= 0xC0000000 or mepc == 0 then
					dumpHistory(self, ("machine trap after Linux pc=%s mepc=%s mcause=%s mtval=%s")
						:format(hx(pc), hx(mepc), hx(mcause), hx(mtval)))
				end
			end
			return ret
		end

		c.step = newStep
		layers[c] = { rawStep = oldStep, step = newStep }
		print("[linuxStep] step wrapped")
	end

	while task.wait(0.05) do
		local c = rawget(_G, "RoEmuCore")
		if type(c) == "table" and type(c.step) == "function" then
			install(c)
		end
	end
end)

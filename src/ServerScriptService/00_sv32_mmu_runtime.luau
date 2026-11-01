--!native
--!optimize 2
print("[sv32fast] boot")

task.spawn(function()
	local bit = bit32
	local layers = setmetatable({}, { __mode = "k" })
	local states = setmetatable({}, { __mode = "k" })

	local CSR_SATP = 0x180
	local CSR_MSTATUS = 0x300
	local MSTATUS_MPRV = 0x00020000
	local PTE_V = 0x001
	local PTE_R = 0x002
	local PTE_W = 0x004
	local PTE_X = 0x008
	local PTE_A = 0x040
	local PTE_D = 0x080

	local function hx(n)
		return ("0x%08X"):format(bit.band(tonumber(n) or 0, 0xFFFFFFFF))
	end

	local function csr(cpu, id)
		local t = cpu and cpu.csr
		if type(t) ~= "table" then return 0 end
		return bit.band(tonumber(t[id] or t[tostring(id)] or t.satp or t.SATP) or 0, 0xFFFFFFFF)
	end

	local function getState(self)
		local st = states[self]
		if not st then
			st = {
				satp = false,
				tlb = {},
				bad = {},
				fallbackLogged = false,
				loggedTranslations = 0,
				hits = 0,
				misses = 0,
			}
			states[self] = st
		end
		return st
	end

	local function rawR32(self, rawRead32, addr)
		local ok, v = pcall(function()
			return rawRead32(self, bit.band(addr, 0xFFFFFFFF))
		end)
		if ok then return bit.band(tonumber(v) or 0, 0xFFFFFFFF) end
		return 0
	end

	local function rawW32(self, rawWrite32, addr, value)
		if type(rawWrite32) ~= "function" then return end
		pcall(function()
			rawWrite32(self, bit.band(addr, 0xFFFFFFFF), bit.band(value, 0xFFFFFFFF))
		end)
	end

	local function pteIsValid(pte)
		if bit.band(pte, PTE_V) == 0 then return false end
		if bit.band(pte, PTE_W) ~= 0 and bit.band(pte, PTE_R) == 0 then return false end
		return true
	end

	local function pteIsLeaf(pte)
		return bit.band(pte, bit.bor(PTE_R, PTE_X)) ~= 0
	end

	local function markAccessed(self, rawWrite32, pteAddr, pte, access)
		local want = PTE_A
		if access == "W" then
			want = bit.bor(PTE_A, PTE_D)
		end
		if bit.band(pte, want) ~= want then
			rawW32(self, rawWrite32, pteAddr, bit.bor(pte, want))
		end
	end

	local function maybeLogTranslation(st, access, va, pa, level, pteAddr)
		st.loggedTranslations += 1
		if st.loggedTranslations <= 8 then
			print(("[sv32fast] %s VA %s -> PA %s L%d pte@%s")
				:format(access, hx(va), hx(pa), level, hx(pteAddr)))
		elseif st.loggedTranslations == 9 then
			print("[sv32fast] translations OK; quiet mode")
		elseif st.loggedTranslations % 200000 == 0 then
			print(("[sv32fast] translations=%d tlbHits=%d tlbMisses=%d")
				:format(st.loggedTranslations, st.hits, st.misses))
		end
	end

	local function translate(self, va, access, rawRead32, rawWrite32)
		va = bit.band(tonumber(va) or 0, 0xFFFFFFFF)
		local cpu = self and self.cpu
		local satp = csr(cpu, CSR_SATP)
		local mode = bit.rshift(satp, 31)
		local st = getState(self)
		local priv = bit.band(tonumber(cpu and cpu.priv) or 3, 0x3)
		local mstatus = csr(cpu, CSR_MSTATUS)

		-- SATP no participa en accesos M salvo que MPRV lo solicite.
		if priv == 3 and bit.band(mstatus, MSTATUS_MPRV) == 0 then
			return va
		end

		if st.satp ~= satp then
			st.satp = satp
			st.tlb = {}
			st.bad = {}
			st.loggedTranslations = 0
			st.hits = 0
			st.misses = 0
			if mode == 1 then
				print(("[sv32fast] satp=%s root=%s; TLB reset")
					:format(hx(satp), hx(bit.band(satp, 0x003FFFFF) * 0x1000)))
			end
		end

		if mode ~= 1 then return va end

		local page = bit.rshift(va, 12)
		local off = bit.band(va, 0xFFF)
		local cached = st.tlb[page]
		if cached then
			st.hits += 1
			if access == "W" and not cached.dirty then
				markAccessed(self, rawWrite32, cached.pteAddr, cached.pte, "W")
				cached.dirty = true
			end
			return bit.band(cached.paBase + off, 0xFFFFFFFF)
		end

		st.misses += 1
		local rootPpn = bit.band(satp, 0x003FFFFF)
		local vpn1 = bit.band(bit.rshift(va, 22), 0x3FF)
		local vpn0 = bit.band(page, 0x3FF)

		local pteAddr = rootPpn * 0x1000 + vpn1 * 4
		local pte = rawR32(self, rawRead32, pteAddr)
		if not pteIsValid(pte) then
			local key = vpn1
			if not st.bad[key] then
				st.bad[key] = true
				print(("[sv32fast] page fault L1 for %s VA %s pte@%s=%s")
					:format(access, hx(va), hx(pteAddr), hx(pte)))
			end
			if type(self.raise_page_fault) == "function" then
				self:raise_page_fault(access, va)
			end
			return nil
		end

		local level = 1
		if not pteIsLeaf(pte) then
			local nextPpn = bit.rshift(pte, 10)
			pteAddr = nextPpn * 0x1000 + vpn0 * 4
			pte = rawR32(self, rawRead32, pteAddr)
			level = 0
			if not pteIsValid(pte) or not pteIsLeaf(pte) then
				local key = page
				if not st.bad[key] then
					st.bad[key] = true
					print(("[sv32fast] page fault L0 for %s VA %s pte@%s=%s")
						:format(access, hx(va), hx(pteAddr), hx(pte)))
				end
				if type(self.raise_page_fault) == "function" then
					self:raise_page_fault(access, va)
				end
				return nil
			end
		end

		markAccessed(self, rawWrite32, pteAddr, pte, access)

		local ppn0 = bit.band(bit.rshift(pte, 10), 0x3FF)
		local ppn1 = bit.band(bit.rshift(pte, 20), 0xFFF)
		local paBase
		if level == 1 then
			paBase = ppn1 * 0x400000 + vpn0 * 0x1000
		else
			paBase = ppn1 * 0x400000 + ppn0 * 0x1000
		end
		paBase = bit.band(paBase, 0xFFFFFFFF)

		st.tlb[page] = {
			paBase = paBase,
			pteAddr = pteAddr,
			pte = pte,
			dirty = access == "W",
		}

		local pa = bit.band(paBase + off, 0xFFFFFFFF)
		maybeLogTranslation(st, access, va, pa, level, pteAddr)
		return pa
	end

	local function normalizeRead(c, self, addr)
		if addr == nil then
			return c, self
		end
		return self, addr
	end

	local function normalizeWrite(c, self, addr, val)
		if val == nil then
			return c, self, addr
		end
		return self, addr, val
	end

	local function install(c)
		local prev = layers[c]
		if prev
			and c.read32 == prev.read32
			and c.write32 == prev.write32
			and c.read16 == prev.read16
			and c.write16 == prev.write16
			and c.read8 == prev.read8
			and c.write8 == prev.write8 then
			return
		end

		local oldRead32 = c.read32
		local oldWrite32 = c.write32
		local oldRead16 = c.read16
		local oldWrite16 = c.write16
		local oldRead8 = c.read8
		local oldWrite8 = c.write8

		if prev then
			if oldRead32 == prev.read32 then oldRead32 = prev.rawRead32 end
			if oldWrite32 == prev.write32 then oldWrite32 = prev.rawWrite32 end
			if oldRead16 == prev.read16 then oldRead16 = prev.rawRead16 end
			if oldWrite16 == prev.write16 then oldWrite16 = prev.rawWrite16 end
			if oldRead8 == prev.read8 then oldRead8 = prev.rawRead8 end
			if oldWrite8 == prev.write8 then oldWrite8 = prev.rawWrite8 end
		end

		if type(oldRead32) ~= "function" or type(oldWrite32) ~= "function" then return end

		local function canBypassTranslation(obj, addr)
			addr = bit.band(tonumber(addr) or 0, 0xFFFFFFFF)
			local cpu = obj and obj.cpu
			local satp = csr(cpu, CSR_SATP)
			local priv = bit.band(tonumber(cpu and cpu.priv) or 3, 0x3)
			if priv == 3 and bit.band(csr(cpu, CSR_MSTATUS), MSTATUS_MPRV) == 0 then
				return true, addr
			end
			return bit.rshift(satp, 31) ~= 1 and addr < 0xC0000000, addr
		end

		local newRead32 = function(self, addr)
			local obj, a = normalizeRead(c, self, addr)
			local bypass; bypass, a = canBypassTranslation(obj, a)
			if bypass then return oldRead32(obj, a) end
			local access = obj.__mem_access == "X" and "X" or "R"
			local pa = translate(obj, a, access, oldRead32, oldWrite32)
			if pa == nil then return 0 end
			return oldRead32(obj, pa)
		end

		local newWrite32 = function(self, addr, val)
			local obj, a, v = normalizeWrite(c, self, addr, val)
			local bypass; bypass, a = canBypassTranslation(obj, a)
			if bypass then return oldWrite32(obj, a, v) end
			local pa = translate(obj, a, "W", oldRead32, oldWrite32)
			if pa == nil then return end
			return oldWrite32(obj, pa, v)
		end

		local newRead16
		if type(oldRead16) == "function" then
			newRead16 = function(self, addr)
				local obj, a = normalizeRead(c, self, addr)
				local bypass; bypass, a = canBypassTranslation(obj, a)
				if bypass then return oldRead16(obj, a) end
				local access = obj.__mem_access == "X" and "X" or "R"
				local pa = translate(obj, a, access, oldRead32, oldWrite32)
				if pa == nil then return 0 end
				return oldRead16(obj, pa)
			end
		end

		local newWrite16
		if type(oldWrite16) == "function" then
			newWrite16 = function(self, addr, val)
				local obj, a, v = normalizeWrite(c, self, addr, val)
				local bypass; bypass, a = canBypassTranslation(obj, a)
				if bypass then return oldWrite16(obj, a, v) end
				local pa = translate(obj, a, "W", oldRead32, oldWrite32)
				if pa == nil then return end
				return oldWrite16(obj, pa, v)
			end
		end

		local newRead8
		if type(oldRead8) == "function" then
			newRead8 = function(self, addr)
				local obj, a = normalizeRead(c, self, addr)
				local bypass; bypass, a = canBypassTranslation(obj, a)
				if bypass then return oldRead8(obj, a) end
				local access = obj.__mem_access == "X" and "X" or "R"
				local pa = translate(obj, a, access, oldRead32, oldWrite32)
				if pa == nil then return 0 end
				return oldRead8(obj, pa)
			end
		end

		local newWrite8
		if type(oldWrite8) == "function" then
			newWrite8 = function(self, addr, val)
				local obj, a, v = normalizeWrite(c, self, addr, val)
				local bypass; bypass, a = canBypassTranslation(obj, a)
				if bypass then return oldWrite8(obj, a, v) end
				local pa = translate(obj, a, "W", oldRead32, oldWrite32)
				if pa == nil then return end
				return oldWrite8(obj, pa, v)
			end
		end

		c.read32 = newRead32
		c.write32 = newWrite32
		if newRead16 then c.read16 = newRead16 end
		if newWrite16 then c.write16 = newWrite16 end
		if newRead8 then c.read8 = newRead8 end
		if newWrite8 then c.write8 = newWrite8 end

		c.__flush_sv32 = function(obj)
			local st = getState(obj or c)
			st.tlb = {}
			st.bad = {}
			st.hits = 0
			st.misses = 0
		end

		layers[c] = {
			rawRead32 = oldRead32,
			rawWrite32 = oldWrite32,
			rawRead16 = oldRead16,
			rawWrite16 = oldWrite16,
			rawRead8 = oldRead8,
			rawWrite8 = oldWrite8,
			read32 = newRead32,
			write32 = newWrite32,
			read16 = newRead16,
			write16 = newWrite16,
			read8 = newRead8,
			write8 = newWrite8,
		}

		print(("[sv32fast] wrapped memory methods r8=%s r16=%s r32=%s")
			:format(type(oldRead8), type(oldRead16), type(oldRead32)))
	end

	while task.wait(0.1) do
		local c = rawget(_G, "RoEmuCore")
		if type(c) == "table" and type(c.read32) == "function" and type(c.write32) == "function" then
			install(c)
		end
	end
end)

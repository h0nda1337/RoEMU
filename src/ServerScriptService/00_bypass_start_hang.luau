print("[00_bypass_start_hang] boot CaribeOS rv32-fwinfo")

task.spawn(function()
	local F = 0x87DFF000
	local D = 0x87E00000
	local N = 0x80200000
	local E = 0x80000000
	local H = 0x800003A0
	local LOTTERY = 0x80040000
	local STATUS = 0x80040004
	local MAGIC = 0x4942534F
	local done = nil
	local bit = bit32

	local function r(c, a)
		local ok, v = pcall(function() return c:read32(a) end)
		return ok and bit.band(tonumber(v) or 0, 0xFFFFFFFF) or 0
	end

	local function w(c, a, v)
		pcall(function() c:write32(a, bit.band(tonumber(v) or 0, 0xFFFFFFFF)) end)
	end

	local function setreg(cpu, i, v)
		v = bit.band(tonumber(v) or 0, 0xFFFFFFFF)
		if cpu.regs then cpu.regs[i] = v end
		if cpu.x then cpu.x[i + 1] = v end
	end

	local function writeFwInfo(c)
		for off = 0, 0x3C, 4 do w(c, F + off, 0) end
		w(c, F + 0x00, MAGIC)
		w(c, F + 0x04, 2)
		w(c, F + 0x08, N) -- RV32 unsigned long next_addr
		w(c, F + 0x0C, 1) -- next_mode = S
		w(c, F + 0x10, 0) -- options
		w(c, F + 0x14, 0) -- boot_hart = hart 0
		-- CaribeBootX ocupa next_addr; no escribir una instruccion de parking ahi.
	end

	while task.wait(0.01) do
		local c = rawget(_G, "RoEmuCore")
		if c ~= done and type(c) == "table" and type(c.read32) == "function" and type(c.write32) == "function" then
			local oldLottery = r(c, LOTTERY)
			local oldStatus = r(c, STATUS)

			if r(c, H) == 0x10500073 then
				w(c, H, 0x00000513)
				w(c, H + 4, 0x00018082)
			end

			writeFwInfo(c)
			w(c, LOTTERY, 0)
			w(c, STATUS, 0)

			local p = c.cpu
			if p then
				p.halted = false
				p.pc = E
				setreg(p, 10, 0)
				setreg(p, 11, D)
				setreg(p, 12, F)
				if p.csr then
					for _, k in ipairs({ 0x300, 0x304, 0x344, 0x305, 0x341, 0x342, 0x343 }) do
						p.csr[k] = 0
					end
				end
			end

			print(("[00_bypass_start_hang] patched hang; rv32-fwinfo @0x%08X next=0x%08X mode=S dtb=0x%08X boot_hart=0; lottery old=0x%08X status old=0x%08X; PC reset")
				:format(F, N, D, oldLottery, oldStatus))
			done = c
		end
	end
end)

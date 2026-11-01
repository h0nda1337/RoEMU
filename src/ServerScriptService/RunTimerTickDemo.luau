-- ServerScriptService/RunTimerTickDemo
-- FreeRTOS RV32 QEMU VIRT con diagnóstico (traps + dump inicial)

local RunService = game:GetService("RunService")
local RS         = game:GetService("ReplicatedStorage")
local RV         = RS:WaitForChild("RiscV")

local Core   = require(RV:WaitForChild("core"))
local UARTM  = require(RV:WaitForChild("devices"):WaitForChild("uart16550"))
local ELF32  = require(RV:WaitForChild("elf32"))
local CLINTM = require(RV:WaitForChild("clint"))

local function listNames(folder)
	local t = {}
	for _,ch in ipairs(folder:GetChildren()) do t[#t+1] = ch.Name end
	table.sort(t)
	return table.concat(t, ", ")
end

local function require_firmware(modName)
	local fw = RV:FindFirstChild("firmware")
	local obj = (fw and fw:FindFirstChild(modName)) or RV:FindFirstChild(modName)
	if not obj then
		error(("[RunTimerTickDemo] No se encontró '%s'.\nRV: %s\nRV.firmware: %s")
			:format(modName, listNames(RV), fw and listNames(fw) or "<no firmware folder>"), 2)
	end
	local ok, mod = pcall(require, obj)
	if not ok then error(("[RunTimerTickDemo] require(%s) falló: %s"):format(obj:GetFullName(), tostring(mod)), 2) end
	return mod
end

local FreeRtosElfTable = require_firmware("FreeRTOS_RV32_QEMU_VIRT")

local function ensureRemote(name)
	local re = RS:FindFirstChild(name)
	if not re then
		re = Instance.new("RemoteEvent")
		re.Name = name
		re.Parent = RS
	end
	return re
end

local OutAppend = RS:FindFirstChild("RoEmu_OutAppend")
local OutRE     = ensureRemote("RoEmu_Out")
local function out(s)
	if not s or #s == 0 then return end
	if OutAppend and OutAppend.Fire then OutAppend:Fire(s) else OutRE:FireAllClients(s) end
end
local function log(s) out((s or "") .. "\n") end

log("[TimerDemo] boot FreeRTOS timer test")

local core = Core.new()
core:reset(0x80000000)
local ram = core:map_ram(0x80000000, 2 * 1024 * 1024)

local uart = UARTM.new({
	writeChar = function(ch)
		ch = tonumber(ch) or 0
		out(string.char(ch % 256))
	end,
})

local uart_dev = uart
if uart_dev.read32 == nil then
	uart_dev = {
		read32 = function(_, ofs) return (uart.read8 and uart:read8(ofs)) or 0 end,
		write32 = function(_, ofs, val)
			val = tonumber(val) or 0
			if uart.write8 then uart:write8(ofs, bit32.band(val, 0xFF)) end
		end,
		tick = function(_, cyc, _core) if uart.tick then uart:tick(cyc, _core) end end,
	}
end
core:map_mmio(0x10000000, 0x100, uart_dev)

local clint = CLINTM.new()
if clint.bind_core then clint:bind_core(core) end
core:map_mmio(0x02000000, 0x100000, clint)

log(("[TimerDemo] ELF table bytes=%d"):format(#FreeRtosElfTable))

local function bytes_table_to_string(t)
	local n = #t
	local chunkSize = 4096
	local chunks = {}
	local pos = 1
	while pos <= n do
		local last = math.min(pos + chunkSize - 1, n)
		local buf = table.create(last - pos + 1)
		local bi = 1
		for i = pos, last do
			buf[bi] = string.char(t[i])
			bi += 1
		end
		chunks[#chunks + 1] = table.concat(buf)
		pos = last + 1
	end
	return table.concat(chunks)
end

local elf_blob = bytes_table_to_string(FreeRtosElfTable)
log(("[TimerDemo] ELF blob bytes=%d"):format(#elf_blob))

local entry = ELF32.load(elf_blob, ram, { allow_relative = true })
core.cpu.pc = entry
log(("[TimerDemo] entry=0x%08X"):format(entry))

-- Dump primeras 8 bytes para detectar RV32C
local function peek8(addr)
	if addr < ram.lo or addr > ram.hi then return 0 end
	return ram.bytes[(addr - ram.lo) + 1] or 0
end
do
	local b0,b1,b2,b3 = peek8(entry), peek8(entry+1), peek8(entry+2), peek8(entry+3)
	local b4,b5,b6,b7 = peek8(entry+4), peek8(entry+5), peek8(entry+6), peek8(entry+7)
	local hw = b0 + b1*256
	local is32 = (bit32.band(hw, 0x3) == 0x3)
	log(("[TimerDemo][Diag] first8 = %02X %02X %02X %02X %02X %02X %02X %02X")
		:format(b0,b1,b2,b3,b4,b5,b6,b7))
	log(("[TimerDemo][Diag] first_halfword=0x%04X bits[1:0]=0x%X => %s")
		:format(hw, bit32.band(hw,3), is32 and "32-bit" or "COMPRESSED (RV32C)"))
end

-- Trap logger
local trap_count = 0
local last_pc = nil
core.on_trap = function(mcause, mtval, _core, _cpu)
	trap_count += 1
	local pc = _cpu and _cpu.pc or 0
	log(("[TimerDemo][TRAP] #%d mcause=0x%08X mtval=0x%08X pc=0x%08X")
		:format(trap_count, tonumber(mcause) or 0, tonumber(mtval) or 0, pc))
	if last_pc == pc and trap_count >= 50 then
		log("[TimerDemo] demasiados traps repetidos; halting para diagnóstico.")
		_core.cpu.halted = true
	end
	last_pc = pc
end

local STEPS_PER_FRAME = 20000
RunService.Heartbeat:Connect(function()
	if core.cpu.halted then return end
	for _ = 1, STEPS_PER_FRAME do
		if core.cpu.halted then break end
		core:step()
	end
end)

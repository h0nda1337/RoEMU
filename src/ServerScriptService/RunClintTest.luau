-- ServerScriptService/RunClintTest  (con historial para la GUI)
local RS = game:GetService("ReplicatedStorage")
local RV = RS:WaitForChild("RiscV")

local Print  = require(RV:WaitForChild("RoEmu_Print"))
local Core   = require(RV:WaitForChild("core"))
local UARTM  = require(RV:WaitForChild("devices"):WaitForChild("uart16550"))
local CLINTM = require((RV:FindFirstChild("clint")) or RV.devices:WaitForChild("clint"))

-- === Remotos + historial ===
local OutRE = RS:FindFirstChild("RoEmu_Out") or Instance.new("RemoteEvent")
OutRE.Name = "RoEmu_Out"; OutRE.Parent = RS
local OutRF = RS:FindFirstChild("RoEmu_OutGet") or Instance.new("RemoteFunction")
OutRF.Name = "RoEmu_OutGet"; OutRF.Parent = RS

local out_buf, out_hist = "", ""
local function out_flush()
	if #out_buf > 0 then
		OutRE:FireAllClients(out_buf)
		out_hist ..= out_buf
		if #out_hist > 200000 then out_hist = string.sub(out_hist, #out_hist-200000+1) end
		out_buf = ""
	end
end
OutRF.OnServerInvoke = function() return out_hist end
local function out_write(ch)
	out_buf ..= ch
	if ch == "\n" or #out_buf >= 512 then out_flush() end
end
local function puts_str(s)
	for i = 1, #s do out_write(s:sub(i,i)) end
end

-- === Core + devices ===
Print.mirrorToOutput(true)
Print.println("[CLINT] test boot")

local cpu = Core.new()
cpu:reset(0x80000000)
local ram = cpu:map_ram(0x80000000, 64*1024)

local uart = UARTM.new({
	writeChar = function(ch)
		-- ch puede ser número o string; normaliza
		local c = (typeof(ch) == "number") and string.char(ch % 256)
			or ((typeof(ch) == "string") and ch:sub(1,1) or "?")
		Print.raw(c)
		out_write(c)
	end
})
cpu:map_mmio(0x10000000, 0x100, uart)

local CLINT = CLINTM.new()
cpu:map_mmio(0x02000000, 0x10000, CLINT)
if CLINT.bind_core then CLINT:bind_core(cpu) end

-- mtvec -> MRET
local function put32(t,w)
	t[#t+1]=bit32.band(w,0xFF)
	t[#t+1]=bit32.band(bit32.rshift(w,8),0xFF)
	t[#t+1]=bit32.band(bit32.rshift(w,16),0xFF)
	t[#t+1]=bit32.band(bit32.rshift(w,24),0xFF)
end
local TRAP = {}; put32(TRAP, 0x30200073)
cpu:map_rom(0x00000000, TRAP); cpu.csrs.mtvec = 0

-- Habilitar MIE + MTIE
cpu.csrs[0x300] = bit32.bor(cpu.csrs[0x300] or 0, 0x8)
cpu.csrs[0x304] = bit32.bor(cpu.csrs[0x304] or 0, bit32.lshift(1,7))

-- PROG: ECALL ; JAL -4 (ECALL inactivo)
local PROG = {}; put32(PROG, 0x00000073); put32(PROG, 0xFFDFF06F)
for i=1,#PROG do ram.bytes[i]=PROG[i] end
cpu.regs[17] = 0; cpu.regs[10] = 0

-- Demo
local DELTA = 5000
puts_str("Hi!\n")
CLINT:set_mtimecmp_delta(DELTA)

local CSR_MIP, MIP_MTIP = 0x344, bit32.lshift(1,7)
for _=1,150000 do
	cpu:step()
	if bit32.band(cpu.csrs[CSR_MIP] or 0, MIP_MTIP) ~= 0 then
		CLINT:set_mtimecmp_delta(DELTA)
		cpu.csrs[CSR_MIP] = bit32.band(cpu.csrs[CSR_MIP], bit32.bnot(MIP_MTIP))
		puts_str("tick\n")
	end
end

out_flush()
Print.println("[CLINT] test done")

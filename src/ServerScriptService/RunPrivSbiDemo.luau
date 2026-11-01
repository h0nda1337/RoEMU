-- ServerScriptService/RunPrivSbiDemo (ticks software, sin CLINT)
local RS = game:GetService("ReplicatedStorage")
local RV = RS:WaitForChild("RiscV")
local Print = require(RV:WaitForChild("RoEmu_Print"))
local Core  = require(RV:WaitForChild("core"))
local UARTM = require(RV:WaitForChild("devices"):WaitForChild("uart16550"))

Print.mirrorToOutput(true)

-- ---- salida a GUI (RoEmu_Out) con snapshot ----
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
local function out_write(ch) out_buf ..= ch; if ch == "\n" or #out_buf >= 512 then out_flush() end end
-- ------------------------------------------------

local function put32(t, w)
	t[#t+1] = bit32.band(w, 0xFF)
	t[#t+1] = bit32.band(bit32.rshift(w, 8), 0xFF)
	t[#t+1] = bit32.band(bit32.rshift(w,16), 0xFF)
	t[#t+1] = bit32.band(bit32.rshift(w,24), 0xFF)
end

Print.println("[RoEmu] [SbiDemo] boot")

local cpu = Core.new()
cpu:reset(0x80000000)
local ram = cpu:map_ram(0x80000000, 64*1024)

local uart = UARTM.new({
	writeChar = function(ch)
		Print.raw(ch)
		out_write(ch)
	end
})
cpu:map_mmio(0x10000000, 0x100, uart)

-- mtvec -> MRET (por compatibilidad; no usamos IRQ reales aquí)
local TRAP = {}; put32(TRAP, 0x30200073); cpu:map_rom(0x00000000, TRAP); cpu.csrs.mtvec = 0

-- ECALL ; JAL x0,-4
local PROG = {}; put32(PROG, 0x00000073); put32(PROG, 0xFFDFF06F)
for i=1,#PROG do ram.bytes[i] = PROG[i] end
Print.printf("[SbiDemo] PROG bytes=%d\n", #PROG)

-- “syscalls” mínimos: a7=1 -> putchar(a0)
cpu.on_sbi = function(a7, a0)
	if a7 == 1 then uart:write32(0, a0 or 0); return true end
	return false
end

-- ---- imprime "Hi!\n" por ECALL ----
for c in ("Hi!\n"):gmatch(".") do
	cpu.regs[17] = 1    -- a7 = putchar
	cpu.regs[10] = string.byte(c)
	cpu:step(); cpu:step()
end

-- 🔧 muy importante: desactivar el “syscall” en el bucle infinito
cpu.regs[17] = 0       -- a7 = 0  => futuros ECALL no hacen nada
cpu.regs[10] = 0

-- ---- ticks software cada N pasos ----
local STEPS_BETWEEN_TICKS = 5000
local TOTAL_STEPS         = 120000
local acc = 0
for i = 1, TOTAL_STEPS do
	cpu:step()
	acc += 1
	if acc >= STEPS_BETWEEN_TICKS then
		acc = 0
		for _,ch in ipairs{ "t","i","c","k","\n" } do
			uart:write32(0, string.byte(ch))
		end
	end
end

out_flush()
Print.println("[RoEmu] [SbiDemo] done")

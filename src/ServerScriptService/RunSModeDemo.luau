-- ServerScriptService/RunSModeDemo
local Core     = require(game.ReplicatedStorage.RiscV.core)
local Platform = require(game.ReplicatedStorage.RiscV.platform)

local seenDot = false
local plat = Platform.new(function(byte)
	local c = string.char(byte)
	print(string.format("[UART] %s", c))
	if c == '.' then seenDot = true end
end)

local cpu = Core.new({ pc = 0x80000000, platform = plat })
cpu.mode = 1

local function w32(a, w)
	cpu.mem[a]     = bit32.band(w,0xFF)
	cpu.mem[a+1]   = bit32.band(bit32.rshift(w,8),0xFF)
	cpu.mem[a+2]   = bit32.band(bit32.rshift(w,16),0xFF)
	cpu.mem[a+3]   = bit32.band(bit32.rshift(w,24),0xFF)
end
local function load(addr, words)
	for i,w in ipairs(words) do w32(addr + (i-1)*4, w) end
end

-- ROM: imprime "Hi\n" por ECALL y bucle
local MAIN = {
	0x00100893, 0x04800513, 0x00000073,
	0x06900513, 0x00000073,
	0x00A00513, 0x00000073,
	0x0000006F,
}

-- Handler: imprime '.' (no rearma nada)
local HANDLER = {
	0x100000B7, 0x02E00113, 0x00208023, -- putchar('.')
	0x30200073,                         -- MRET
}

print("[RoEMU] Hi y un solo punto (paramos tras verlo)…")
load(0x80000000, MAIN)
load(0x80000100, HANDLER)
cpu.pc = 0x80000000

-- Sin IRQ durante el Hi
cpu.csr_mtvec   = 0x80000100
cpu.csr_mie     = 0
cpu.csr_mstatus = 0
plat.clint.time    = 0
plat.clint.timecmp = 0x7FFFFFFF

-- Ejecuta lo justo para 'Hi\n'
cpu:run(16)

-- Programa 1 tick y habilita IRQs
plat.clint.timecmp = plat.clint.time + 1000
cpu.csr_mie        = bit32.bor(cpu.csr_mie, bit32.lshift(1,7)) -- MTIE
cpu.csr_mstatus    = bit32.bor(cpu.csr_mstatus, bit32.lshift(1,3)) -- MIE

-- Avanza de a 1 hasta ver un solo '.'
local safety = 2000
while not seenDot and safety > 0 do
	cpu:run(1)
	safety -= 1
end

print("[RoEMU] Fin demo.")

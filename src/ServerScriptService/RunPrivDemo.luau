-- ServerScriptService/RunPrivDemo
local RS = game:GetService("ReplicatedStorage")
local RV = RS:WaitForChild("RiscV")

local printf = require(RV:WaitForChild("RoEmu_Print"))
local Core   = require(RV:WaitForChild("core"))

printf("[RoEmu] [PrivDemo] boot")

-- (Opcional) solo para ver que el monitor está disponible; no es indispensable
local ok, monitor = pcall(function() return RV:WaitForChild("RoEmu_Monitor", 5) end)
if ok and monitor then printf("[RoEmu_Server] Monitor OK.") end

-- 1) Crear el core ANTES de colgar callbacks
local core = Core.new()
core:reset(0x80000000)

-- 2) (Opcional) callback informativo de trampa: cuélgalo en el *core*
--    Esto ya no provoca “attempt to index nil with 'on_trap'”
core.on_trap = function(cause, tval)
	printf(string.format("[PrivDemo] trap cause=0x%X tval=0x%X", cause or -1, tval or 0))
end

-- 3) Mapa mínimo: RAM + ROM de vector con MRET en 0x0 (para que regrese de trampa)
local bit  = bit32
local band, rshift = bit.band, bit.rshift

local function write_word(t, w)
	table.insert(t, band(w,0xFF))
	table.insert(t, band(rshift(w,8),0xFF))
	table.insert(t, band(rshift(w,16),0xFF))
	table.insert(t, band(rshift(w,24),0xFF))
end

-- 64 KiB de RAM en 0x80000000
core:map_ram(0x80000000, 64*1024)

-- Vector de trampa (ROM) en 0x00000000: MRET (0x30200073)
local trap_rom = {}
write_word(trap_rom, 0x30200073)
core:map_rom(0x00000000, trap_rom)

-- Programa mínimo en 0x80000000: ECALL; luego JAL x0, 0 (loop)
local prog = {}
write_word(prog, 0x00000073) -- ECALL
write_word(prog, 0x0000006F) -- JAL x0, 0   (bucle)
core:map_rom(0x80000000, prog)

-- 4) Ejecutar unos pasos para ver el comportamiento
for _=1,200 do core:step() end

printf("[RoEmu] [PrivDemo] done")

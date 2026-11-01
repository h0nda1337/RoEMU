-- RunOpenSbiDemo.server.lua
-- Demo: ejecuta OpenSBI fw_payload.elf (tabla de bytes en RiscV/firmware/Firmware)
-- y muestra por la consola / monitor lo que salga por la UART.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RiscV = ReplicatedStorage:WaitForChild("RiscV")

-- ==== helpers de logging =====================================================

local RoEmuOut = ReplicatedStorage:WaitForChild("RoEmu_Out")

local function emit(line)
	-- texto para el monitor in-game
	RoEmuOut:FireAllClients(line)
	-- y también al output normal de Studio
	print(line)
end

local function emitTag(tag, msg)
	emit(string.format("[%s] %s", tag, msg))
end

-- ==== localizar módulos ======================================================

local CoreMod = require(RiscV:WaitForChild("core"))

-- CLINT (puede estar en RiscV.clint o RiscV.devices.clint)
local function requireOptional(path1, path2)
	local obj = RiscV:FindFirstChild(path1)
	if not obj and RiscV:FindFirstChild("devices") then
		obj = RiscV.devices:FindFirstChild(path2 or path1)
	end
	return obj and require(obj) or nil
end

local ClintMod     = assert(requireOptional("clint"), "No encuentro módulo CLINT")
local Uart16550Mod = assert(requireOptional("uart16550"), "No encuentro módulo uart16550")
local PlicModule   = requireOptional("plic")  -- opcional

-- Firmware: tu ModuleScript con la tabla gigante de fw_payload.elf
local FirmwareFolder = RiscV:WaitForChild("firmware")
local FirmwareMod    = require(FirmwareFolder:WaitForChild("Firmware"))
-- Soporta tanto:
--   return { 1,2,3,... }
-- como
--   return { bytes = {1,2,3,...} }
local fw_bytes       = FirmwareMod.bytes or FirmwareMod
assert(type(fw_bytes) == "table", "Firmware debe devolver una tabla de bytes")

-- ==== helpers sobre el core ==================================================

local function core_step(core, cycles)
	cycles = cycles or 1000
	if type(core.run) == "function" then
		return core:run(cycles)
	elseif type(core.step) == "function" then
		return core:step(cycles)
	elseif type(core.run_cycles) == "function" then
		return core:run_cycles(cycles)
	else
		error("El core RISC-V no expone run/step/run_cycles; ajusta core_step().")
	end
end

-- Mapea un dispositivo con métodos read32/write32 en una región MMIO.
local function map_mmio32(core, base, size, dev)
	if type(core.map_mmio32) == "function" then
		core:map_mmio32(
			base,
			size,
			function(off) return dev:read32(off) end,
			function(off, value) dev:write32(off, value) end
		)
	elseif type(core.map_mmio) == "function" then
		core:map_mmio(
			base,
			size,
			function(off, sz)
				if sz ~= 4 then return 0 end
				return dev:read32(off)
			end,
			function(off, value, sz)
				if sz ~= 4 then return end
				dev:write32(off, value)
			end
		)
	else
		error("El core no tiene map_mmio / map_mmio32; adapta map_mmio32().")
	end
end

-- ==== main ===================================================================

emitTag("OpenSBI", "boot")
emitTag("OpenSBI", ("firmware bytes=%d"):format(#fw_bytes))

-- Crear core (el shim 00_RoEmu_CoreCompat ya lo parcha)
local core = CoreMod.new({
	hartid   = 0,
	mem_size = 128 * 1024 * 1024,  -- 128 MiB como 'virt'
})

-- ---- CLINT (mtime / msip) ---------------------------------------------------
local clint = ClintMod.new()
-- Mapa estándar de la máquina 'virt': CLINT en 0x0200_0000
map_mmio32(core, 0x02000000, 0x10000, clint)
clint:bind_core(core)

-- ---- UART 16550 -------------------------------------------------------------
local band = bit32.band
local uart_line_buf = ""

local uart = Uart16550Mod.new({
	writeChar = function(byte)
		local ch = string.char(band(byte, 0xFF))

		-- Mandar carácter crudo al cliente (para que lo veas en tiempo real)
		RoEmuOut:FireAllClients(ch)

		-- buffer de línea para log bonito
		uart_line_buf = uart_line_buf .. ch
		if ch == "\n" then
			emitTag("UART", uart_line_buf:gsub("\n$", ""))
			uart_line_buf = ""
		end
	end,
})

-- UART 16550 de 'virt' está en 0x1000_0000
map_mmio32(core, 0x10000000, 0x100, uart)

-- ---- PLIC (opcional, por si lo tienes) -------------------------------------
local plic
if PlicModule then
	plic = PlicModule.new({
		num_sources = 32,
		num_targets = 1,
	})
	-- PLIC típico de 'virt': 0x0C00_0000
	map_mmio32(core, 0x0C000000, 0x400000, plic)

	-- Conectar la IRQ de UART a, por ejemplo, la fuente 10 del PLIC
	if uart.setIrqSink and plic.set_source_level then
		uart:setIrqSink(function(level)
			plic:set_source_level(10, level)
		end)
	end
end

-- ---- callback de interrupciones del core ------------------------------------
if type(core.set_irq_callback) == "function" then
	core:set_irq_callback(function(irq_type)
		-- OpenSBI hace casi todo; aquí solo podrías loguear si quieres:
		-- emitTag("IRQ", tostring(irq_type))
	end)
end

-- ---- Cargar firmware --------------------------------------------------------
local info
local ok, err = pcall(function()
	-- OpenSBI genérico para 'virt' arranca en 0x8000_0000
	info = core:load_elf(fw_bytes, 0x80000000)
end)

if not ok then
	emitTag("OpenSBI", "ERROR load_elf: " .. tostring(err))
	return
end

if info and info.entry then
	emitTag("OpenSBI", ("entry=0x%08X"):format(info.entry))
end

-- ---- Bucle de ejecución -----------------------------------------------------

local MAX_STEPS       = 4000        -- 4000 * 2000 = 8e6 ciclos aprox
local CYCLES_PER_STEP = 2000

for step = 1, MAX_STEPS do
	local ok_step, err_step = pcall(function()
		core_step(core, CYCLES_PER_STEP)
	end)

	if not ok_step then
		emitTag("OpenSBI", "ERROR en paso: " .. tostring(err_step))
		break
	end

	-- avanzar temporizador
	if clint.tick then
		clint:tick(CYCLES_PER_STEP, core)
	end
end

emitTag("OpenSBI", "demo terminada (fin de pasos)")

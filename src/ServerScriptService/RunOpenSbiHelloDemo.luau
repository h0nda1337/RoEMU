-- RunOpenSbiHelloDemo
-- Demo: cargar fw_payload_hello (OpenSBI + hello_smode) y ejecutarlo
-- usando el board_minimal + UART16550 para consola.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RiscV = ReplicatedStorage:WaitForChild("RiscV")

-- Board y dispositivos ya existentes en tu proyecto
local BoardMinimal = require(RiscV:WaitForChild("board_minimal"))

-- Firmware generado desde fw_payload.elf (tu tabla gigante)
local fw_payload_bytes = require(RiscV:WaitForChild("firmware"):WaitForChild("fw_payload_hello"))

-- Atajo a bit32
local band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

local M = {}

----------------------------------------------------------------------
-- Helpers para leer valores little-endian desde la tabla de bytes
----------------------------------------------------------------------

local function u16_le(t, idx)
	-- idx es 1-based (Lua); en ELF los offsets son 0-based
	local b0 = t[idx] or 0
	local b1 = t[idx + 1] or 0
	return b0 + lshift(b1, 8)
end

local function u32_le(t, idx)
	local b0 = t[idx]     or 0
	local b1 = t[idx + 1] or 0
	local b2 = t[idx + 2] or 0
	local b3 = t[idx + 3] or 0
	return b0
		+ lshift(b1, 8)
		+ lshift(b2, 16)
		+ lshift(b3, 24)
end

----------------------------------------------------------------------
-- Loader ELF32 muy simple (sólo PT_LOAD) directamente a la RAM del board
----------------------------------------------------------------------

local function load_elf32_into_mem(mem, bytes, log)
	-- Comprobamos cabecera ELF mínima
	if not bytes[1] or bytes[1] ~= 0x7F
		or bytes[2] ~= string.byte("E")
		or bytes[3] ~= string.byte("L")
		or bytes[4] ~= string.byte("F")
	then
		log("ERROR: firmware no parece ELF (magic incorrecto)")
		return nil
	end

	-- Offsets de cabecera ELF32 (little endian)
	-- ver especificación ELF32:
	-- e_entry   @ offset 24 (4 bytes)
	-- e_phoff   @ offset 28 (4 bytes)
	-- e_phentsize @ 42 (2 bytes)
	-- e_phnum   @ 44 (2 bytes)

	local e_entry     = u32_le(bytes, 24 + 1)
	local e_phoff     = u32_le(bytes, 28 + 1)
	local e_phentsize = u16_le(bytes, 42 + 1)
	local e_phnum     = u16_le(bytes, 44 + 1)

	log(string.format("ELF: entry=0x%08X phoff=0x%X phentsize=%d phnum=%d",
		e_entry, e_phoff, e_phentsize, e_phnum))

	if e_phoff == 0 or e_phnum == 0 then
		log("ERROR: ELF sin program headers")
		return nil
	end

	local PT_LOAD = 1

	for i = 0, e_phnum - 1 do
		local ph_off = e_phoff + i * e_phentsize
		local idx = ph_off + 1  -- 1-based

		local p_type   = u32_le(bytes, idx + 0)
		local p_offset = u32_le(bytes, idx + 4)
		local p_vaddr  = u32_le(bytes, idx + 8)
		local p_filesz = u32_le(bytes, idx + 16)
		local p_memsz  = u32_le(bytes, idx + 20)

		if p_type == PT_LOAD and p_memsz > 0 then
			log(string.format(
				"SEG: vaddr=0x%08X filesz=%d memsz=%d (offset=0x%X)",
				p_vaddr, p_filesz, p_memsz, p_offset
				))

			-- Copiar la parte inicial desde el ELF
			for ofs = 0, p_filesz - 1 do
				local src_idx = p_offset + 1 + ofs
				local b = bytes[src_idx] or 0
				-- mem debe exponer write8(addr, value)
				mem:write8(p_vaddr + ofs, b)
			end

			-- Rellenar el resto del memsz con 0 (BSS)
			for ofs = p_filesz, p_memsz - 1 do
				mem:write8(p_vaddr + ofs, 0)
			end
		end
	end

	return e_entry
end

----------------------------------------------------------------------
-- Bucle principal de ejecución: corre el core y hace tick al CLINT
----------------------------------------------------------------------

local function run_with_timer(core, clint, max_cycles)
	max_cycles = max_cycles or (5 * 10^6)
	local remaining = max_cycles
	local SLICE = 10000

	while remaining > 0 do
		local step = math.min(SLICE, remaining)

		-- Compat: run(cycles, on_step) viene del shim 00_RoEmu_CoreCompat
		local executed = core:run(step, function(delta_cycles)
			if clint and clint.tick then
				clint:tick(delta_cycles, core)
			end
		end)

		if not executed or executed <= 0 then
			break
		end

		remaining -= executed
	end
end

----------------------------------------------------------------------
-- API pública: M.run(out_fn)
-- out_fn(msg:string) -> lo que ya usa RoEmu_Bootstrap para imprimir
----------------------------------------------------------------------

function M.run(out)
	-- Helper local para prefijar el tag de esta demo
	local function log(msg)
		out("[OpenSBI Demo] " .. msg)
	end

	log("boot")
	log(string.format("fw_payload bytes=%d", #fw_payload_bytes))

	-- Crear board mínimo reutilizando tu board_minimal
	-- Ajusta ram_size / clock_hz si quieres.
	local board, err = BoardMinimal.new({
		ram_size = 64 * 1024 * 1024,   -- 64 MiB
		clock_hz = 10 * 1000 * 1000,   -- 10 MHz aprox.
		on_uart_tx = function(byte)
			-- Aquí sale lo que imprima OpenSBI/payload vía UART16550.
			-- Lo mandamos tal cual al cliente; tu GUI ya se encarga de dibujarlo.
			local ch = string.char(byte & 0xFF)
			out(ch)
		end,
	})

	if not board then
		log("ERROR creando board: " .. tostring(err))
		return
	end

	log("board_minimal creado")

	if not board.mem then
		log("ERROR: board.mem es nil (asegúrate de que board_minimal expone 'mem')")
		return
	end
	if not board.core then
		log("ERROR: board.core es nil (asegúrate de que board_minimal expone 'core')")
		return
	end

	-- Cargar ELF (OpenSBI fw_payload) en la RAM del board
	local entry = load_elf32_into_mem(board.mem, fw_payload_bytes, log)
	if not entry then
		log("ERROR al cargar ELF; abortando demo")
		return
	end

	log(string.format("entry final = 0x%08X", entry))

	-- Colocar el PC del core en la entry
	if board.core.set_pc then
		board.core:set_pc(entry)
	else
		board.core.pc = entry
	end

	-- Opcional: si tu core tiene mtvec configurable aquí podría ir,
	-- pero OpenSBI ya se encarga de reconfigurar cosas en M-mode.

	log("ejecutando core con CLINT (timer) conectado…")
	run_with_timer(board.core, board.clint, 5 * 10^6)

	log("fin de la demo (si OpenSBI hizo shutdown, dejará de imprimir)")
end

return M

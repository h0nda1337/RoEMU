--!optimize 2
-- ReplicatedStorage/RiscV/elf32
-- Loader ELF32 (LE) con múltiples PT_LOAD y .bss
-- Soporta:
--   1) ELFs con p_vaddr / p_paddr ABSOLUTOS dentro de la RAM (0x8000_0000...)
--   2) ELFs con p_vaddr / p_paddr RELATIVOS (0x0, 0x40000, etc.) => se relocalizan a ram.lo + offset
--
-- Uso:
--   local ELF32 = require(RS.RiscV.elf32)
--   local entry = ELF32.load(blob_string, ram_map)   -- ram_map = retorno de Core:map_ram

local M = {}

local band, rshift = bit32.band, bit32.rshift

-- Ponlo true si quieres logs por segmento
M.DEBUG = false

local function u8(s,i)   return s:byte(i) end
local function u16le(s,i)
	local b1,b2 = s:byte(i,i+1); return b1 + b2*256
end
local function u32le(s,i)
	local b1,b2,b3,b4 = s:byte(i,i+3)
	return b1 + b2*256 + b3*65536 + b4*16777216
end

local function assertf(cond, fmt, ...)
	if not cond then error(string.format(fmt, ...), 2) end
end

local function in_range(a, lo, hi)
	return (a >= lo) and (a <= hi)
end

-- Decide a qué dirección real cargar el segmento
local function resolve_load_addr(p_vaddr, p_paddr, ram_lo, ram_hi)
	local ram_size = (ram_hi - ram_lo) + 1

	-- 1) Preferir p_paddr absoluto si cae en RAM
	if in_range(p_paddr, ram_lo, ram_hi) then
		return p_paddr, "abs(p_paddr)"
	end

	-- 2) Si no, probar p_vaddr absoluto
	if in_range(p_vaddr, ram_lo, ram_hi) then
		return p_vaddr, "abs(p_vaddr)"
	end

	-- 3) Relativo: si p_paddr es pequeño, usar ram_lo + p_paddr
	if p_paddr >= 0 and p_paddr < ram_size then
		return ram_lo + p_paddr, "rel(p_paddr)"
	end

	-- 4) Relativo: si p_vaddr es pequeño, usar ram_lo + p_vaddr
	if p_vaddr >= 0 and p_vaddr < ram_size then
		return ram_lo + p_vaddr, "rel(p_vaddr)"
	end

	return nil, "unmapped"
end

local function resolve_entry(e_entry, ram_lo, ram_hi)
	local ram_size = (ram_hi - ram_lo) + 1
	if in_range(e_entry, ram_lo, ram_hi) then
		return e_entry, "abs"
	end
	if e_entry >= 0 and e_entry < ram_size then
		return ram_lo + e_entry, "rel"
	end
	return e_entry, "raw"
end

function M.load(blob, ram)
	assert(type(blob)=="string", "elf32.load: blob debe ser string")
	assert(type(ram)=="table" and ram.bytes and ram.lo and ram.hi, "elf32.load: ram inválida")

	assertf(#blob >= 52, "ELF32: header incompleto")
	assertf(blob:sub(1,4) == "\x7FELF", "ELF32: magic inválido")

	local EI_CLASS = u8(blob,5)
	local EI_DATA  = u8(blob,6)
	assertf(EI_CLASS==1, "ELF32: se esperaba clase 1 (32-bit), got %d", EI_CLASS)
	assertf(EI_DATA==1,  "ELF32: se esperaba little-endian, got %d", EI_DATA)

	local e_entry     = u32le(blob, 25)
	local e_phoff     = u32le(blob, 29)
	local e_phentsize = u16le(blob, 43)
	local e_phnum     = u16le(blob, 45)

	assertf(e_phoff>0 and e_phnum>0, "ELF32: no hay program headers")
	assertf(e_phentsize>=32, "ELF32: e_phentsize inesperado: %d", e_phentsize)

	local PT_LOAD = 1
	local bytes, lo, hi = ram.bytes, ram.lo, ram.hi

	for i=0, e_phnum-1 do
		local off = e_phoff + i*e_phentsize

		local p_type   = u32le(blob, off+1)    -- +0
		local p_offset = u32le(blob, off+5)    -- +4
		local p_vaddr  = u32le(blob, off+9)    -- +8
		local p_paddr  = u32le(blob, off+13)   -- +12
		local p_filesz = u32le(blob, off+17)   -- +16
		local p_memsz  = u32le(blob, off+21)   -- +20
		-- p_flags @ +24, p_align @ +28

		if p_type == PT_LOAD and p_memsz > 0 then
			local load_addr, how = resolve_load_addr(p_vaddr, p_paddr, lo, hi)
			assertf(load_addr ~= nil,
				"ELF32: segmento fuera de RAM (vaddr=0x%08X paddr=0x%08X memsz=0x%X) RAM=0x%08X..0x%08X",
				p_vaddr, p_paddr, p_memsz, lo, hi)

			local seg_lo = load_addr
			local seg_hi = load_addr + p_memsz - 1
			assertf(seg_lo >= lo and seg_hi <= hi,
				"ELF32: segmento fuera de RAM (0x%08X..0x%08X no cabe en 0x%08X..0x%08X)",
				seg_lo, seg_hi, lo, hi)

			assertf(p_offset + p_filesz <= #blob,
				"ELF32: p_offset+p_filesz fuera del blob (off=0x%X filesz=0x%X blob=%d)",
				p_offset, p_filesz, #blob)

			if M.DEBUG then
				print(("[ELF32] PT_LOAD via %s: vaddr=0x%08X paddr=0x%08X -> load=0x%08X filesz=0x%X memsz=0x%X")
					:format(how, p_vaddr, p_paddr, load_addr, p_filesz, p_memsz))
			end

			-- Copia y zero-fill acelerados, sin cambiar la disposición ELF.
			local base_index = (load_addr - lo) + 1
			if ram.buffer then
				if p_filesz > 0 then
					buffer.writestring(ram.buffer, base_index - 1, blob:sub(p_offset + 1, p_offset + p_filesz))
				end
				if p_memsz > p_filesz then
					buffer.fill(ram.buffer, base_index - 1 + p_filesz, 0, p_memsz - p_filesz)
				end
			else
				for k=0, p_filesz-1 do bytes[base_index + k] = blob:byte(p_offset + 1 + k) end
				for k=p_filesz, p_memsz-1 do bytes[base_index + k] = 0 end
			end
		end
	end

	local entry_abs, mode = resolve_entry(e_entry, lo, hi)
	if M.DEBUG then
		print(("[ELF32] entry %s: 0x%08X -> 0x%08X"):format(mode, e_entry, entry_abs))
	end

	return entry_abs
end

return M


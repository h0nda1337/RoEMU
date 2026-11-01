-- RunElfMultiSegDemo — ELF32 con 2 PT_LOAD (texto RX y data+bss RW) y verificación de .bss
local RunService = game:GetService("RunService")
local RS         = game:GetService("ReplicatedStorage")
local RV         = RS:WaitForChild("RiscV")

local Core   = require(RV:WaitForChild("core"))
local UARTM  = require(RV:WaitForChild("devices"):WaitForChild("uart16550"))
local ELF32  = require(RV:WaitForChild("elf32"))
local SBI    = require(RV:WaitForChild("sbi_min"))

-- ===== Salida GUI =====
local OutRE = RS:FindFirstChild("RoEmu_Out") or Instance.new("RemoteEvent"); OutRE.Name="RoEmu_Out"; OutRE.Parent=RS
local OutRF = RS:FindFirstChild("RoEmu_OutGet") or Instance.new("RemoteFunction"); OutRF.Name="RoEmu_OutGet"; OutRF.Parent=RS
local out_buf, out_hist = "", ""
local function out_flush() if #out_buf>0 then OutRE:FireAllClients(out_buf); out_hist..=out_buf; if #out_hist>200000 then out_hist=out_hist:sub(#out_hist-200000+1) end; out_buf="" end end
OutRF.OnServerInvoke=function() return out_hist end
local function out_char(n) local c=(typeof(n)=="number") and string.char(n%256) or (type(n)=="string" and n:sub(1,1) or "?"); out_buf..=c; if c=="\n" or #out_buf>=512 then out_flush() end end
local function puts(s) for i=1,#s do out_char(s:byte(i)) end end

puts("[MultiSeg] boot\n")

-- ===== Core / RAM / UART =====
local cpu = Core.new(); cpu:reset(0x80000000)
local ram = cpu:map_ram(0x80000000, 256*1024)  -- 256 KiB
local uart = UARTM.new({ writeChar=function(ch) out_char(ch) end })
cpu:map_mmio(0x10000000, 0x100, uart)

-- Entrada (no es necesaria, pero la dejamos conectada por si el binario la usara)
local InRE = RS:FindFirstChild("RoEmu_Input") or Instance.new("RemoteEvent"); InRE.Name="RoEmu_Input"; InRE.Parent=RS
InRE.OnServerEvent:Connect(function(_, line) if type(line)=="string" then uart:rx_line(line) end end)

-- ===== SBI por tabla =====
SBI.attach(cpu, {
	[1] = function(a0) uart:write32(0, a0 or 0) end, -- putchar
	[3] = function() local b=uart.read_byte_nonblock and uart:read_byte_nonblock() or nil; return b and (b%256) or 0xFFFFFFFF end,
	[8] = function() cpu.halted = true end,
})

-- ===== Helpers LE =====
local band, rshift = bit32.band, bit32.rshift
local function le16(n) return string.char(band(n,0xFF), band(rshift(n,8),0xFF)) end
local function le32(n) return string.char(band(n,0xFF), band(rshift(n,8),0xFF), band(rshift(n,16),0xFF), band(rshift(n,24),0xFF)) end
local function align4(n) local r = n % 4; return r==0 and n or (n + (4-r)) end

-- ===== Código RV32I de prueba: imprime "OK\n" vía SBI (a7=1) y bucle =====
local code_words = { 0x00100893, 0x04F00513,0x00000073, 0x04B00513,0x00000073, 0x00A00513,0x00000073, 0x0000006F } -- 'O','K','\n'
local function words_to_le_bytes(t) local s=table.create(#t); for i,w in ipairs(t) do s[i]=le32(w) end; return table.concat(s) end
local text_blob = words_to_le_bytes(code_words)

-- ===== Segmento DATA (+BSS)
local data_init = "DATA-INIT"           -- bytes presentes en archivo
local bss_size  = 64                    -- bytes NO presentes en archivo, deben quedar en 0

-- ===== Construcción del ELF con 2 PH =====
local EH_SIZE, PH_SIZE = 52, 32
local PH_OFF           = EH_SIZE
local TEXT_VA          = 0x80000000
local DATA_VA          = 0x80004000     -- otra página (sencilla separación)
local ENTRY            = TEXT_VA

local OFF_TEXT         = align4(EH_SIZE + 2*PH_SIZE)
local OFF_DATA         = align4(OFF_TEXT + #text_blob)

local function build_ehdr()
	local ident = string.char(0x7F,0x45,0x4C,0x46, 1,1,1,0, 0,0,0,0,0,0,0,0)
	return table.concat({
		ident,
		le16(2),            -- ET_EXEC
		le16(243),          -- EM_RISCV
		le32(1),            -- e_version
		le32(ENTRY),        -- e_entry
		le32(PH_OFF),       -- e_phoff
		le32(0),            -- e_shoff
		le32(0),            -- e_flags
		le16(EH_SIZE),      -- e_ehsize
		le16(PH_SIZE),      -- e_phentsize
		le16(2),            -- e_phnum = 2
		le16(40), le16(0), le16(0)
	})
end

local function phdr(ptype, off, vaddr, filesz, memsz, flags, align)
	return table.concat({ le32(ptype), le32(off), le32(vaddr), le32(vaddr),
		le32(filesz), le32(memsz), le32(flags), le32(align) })
end

local eh  = build_ehdr()
local ph1 = phdr(1, OFF_TEXT, TEXT_VA, #text_blob, #text_blob, 5, 4)                    -- RX
local ph2 = phdr(1, OFF_DATA, DATA_VA, #data_init, #data_init + bss_size, 6, 4)         -- RW
local pad_text = string.rep("\0", OFF_TEXT - (EH_SIZE + 2*PH_SIZE))
local pad_data = string.rep("\0", OFF_DATA - (OFF_TEXT + #text_blob))
local elf_blob = eh .. ph1 .. ph2 .. pad_text .. text_blob .. pad_data .. data_init

puts(("[MultiSeg] ELF bytes=%d  text=%d  data_init=%d  bss=%d\n"):format(#elf_blob, #text_blob, #data_init, bss_size))

-- ===== Cargar en RAM y arrancar =====
local entry = ELF32.load(elf_blob, ram)
cpu.pc = entry

-- ===== Verificación host de .data y .bss en RAM =====
local function peek(addr, len)
	local base = ram.lo
	local t = table.create(len)
	for i=0, len-1 do t[i+1] = ram.bytes[(addr - base + 1) + i] or 0 end
	return t
end
local function bytes_to_str(t) local s=table.create(#t); for i,b in ipairs(t) do s[i]=string.char(b) end; return table.concat(s) end

local data_loaded = bytes_to_str(peek(DATA_VA, #data_init))
local bss_loaded  = peek(DATA_VA + #data_init, bss_size)
local nonzero = 0; for _,b in ipairs(bss_loaded) do if (b or 0) ~= 0 then nonzero += 1 end end

puts(("[CHECK] .data: \"%s\"\n"):format(data_loaded))
puts(("[CHECK] .bss nonzero bytes: %d (esperado: 0)\n"):format(nonzero))

-- ===== Ejecutar unas tandas (no bloqueante) y terminar =====
local STEPS_PER_FRAME, frames_left, running = 4000, 120, true
local hb; hb = RunService.Heartbeat:Connect(function()
	if not running then return end
	for _=1, STEPS_PER_FRAME do cpu:step(); if cpu.halted then running=false; break end end
	frames_left -= 1
	if frames_left<=0 or not running then if hb then hb:Disconnect() end; puts("[MultiSeg] done\n"); out_flush() end
end)

out_flush()

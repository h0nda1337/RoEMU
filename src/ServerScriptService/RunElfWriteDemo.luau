-- RunElfWriteDemo (autosuficiente): genera un ELF RV32I mínimo,
-- lo carga a memoria y ejecuta write(1, buf, n); imprime por consola Roblox.

local RS   = game:GetService("ReplicatedStorage")
local Core = require(RS.RiscV.core)
local bit  = bit32

-- Plataforma inline: imprime cada byte que envía el core
local plat = {
	uart_write = function(self, b)
		print("[UART]", string.char(bit.band(b or 0, 0xFF)))
	end
}

-- ------------------ helpers memoria ------------------
local function w8(mem,a,v)  mem[a] = bit.band(v or 0, 0xFF) end
local function w32(mem,a,v)
	w8(mem,a,   v)
	w8(mem,a+1, bit.rshift(v,8))
	w8(mem,a+2, bit.rshift(v,16))
	w8(mem,a+3, bit.rshift(v,24))
end

-- ------------------ mini ensamblador ------------------
local X = { a0=10, a1=11, a2=12, a7=17, zero=0 }
local function ADDI(rd,rs1,imm) imm = bit.band(imm,0xFFF)
	return bit.bor(bit.lshift(imm,20), bit.lshift(rs1,15), bit.lshift(0,12), bit.lshift(rd,7), 0x13)
end
local function LUI(rd,imm20)
	return bit.bor(bit.lshift(imm20,12), bit.lshift(rd,7), 0x37)
end
local ECALL = 0x00000073

local MSG    = "Hello from write() via ELF\n"
local MSG_VA = 0x80000100
local ENTRY  = 0x80000000

local function build_text_words()
	return {
		ADDI(X.a7, X.zero, 64),      -- a7=64 (write)
		ADDI(X.a0, X.zero, 1),       -- a0=1 (stdout)
		LUI (X.a1, 0x80000),         -- a1=0x80000000
		ADDI(X.a1, X.a1, 0x100),     -- a1=0x80000100 (buffer)
		ADDI(X.a2, X.zero, #MSG),    -- a2=len
		ECALL,                       -- write
		ADDI(X.a7, X.zero, 93),      -- a7=93 (exit)
		ECALL,                       -- exit
	}
end

-- ------------------ ELF builder mínimo ------------------
local function pack32(x)
	return string.char(
		bit.band(x,0xFF),
		bit.band(bit.rshift(x,8),0xFF),
		bit.band(bit.rshift(x,16),0xFF),
		bit.band(bit.rshift(x,24),0xFF)
	)
end
local function eh16(x) return string.char(bit.band(x,0xFF), bit.band(bit.rshift(x,8),0xFF)) end
local function eh32(x) return pack32(x) end

local function makeELF(textWords, entryVA)
	local bytes = {}
	-- e_ident
	bytes[#bytes+1] = "\127ELF"
	bytes[#bytes+1] = "\1"   -- ELF32
	bytes[#bytes+1] = "\1"   -- LSB
	bytes[#bytes+1] = "\1"
	bytes[#bytes+1] = "\0"
	bytes[#bytes+1] = string.rep("\0",8)

	-- Ehdr (ELF32)
	local e_type=2; local e_machine=243; local e_version=1
	local e_entry=entryVA; local e_phoff=52
	bytes[#bytes+1] = eh16(e_type)
	bytes[#bytes+1] = eh16(e_machine)
	bytes[#bytes+1] = eh32(e_version)
	bytes[#bytes+1] = eh32(e_entry)
	bytes[#bytes+1] = eh32(e_phoff)
	bytes[#bytes+1] = eh32(0)      -- e_shoff
	bytes[#bytes+1] = eh32(0)      -- e_flags
	bytes[#bytes+1] = eh16(52)     -- e_ehsize
	bytes[#bytes+1] = eh16(32)     -- e_phentsize
	bytes[#bytes+1] = eh16(1)      -- e_phnum
	bytes[#bytes+1] = eh16(0)      -- e_shentsize
	bytes[#bytes+1] = eh16(0)      -- e_shnum
	bytes[#bytes+1] = eh16(0)      -- e_shstrndx

	-- Phdr único: PT_LOAD .text
	local p_type=1; local p_offset=0x80
	local textBlobT = {}
	for _,w in ipairs(textWords) do textBlobT[#textBlobT+1]=pack32(w) end
	local textBlob = table.concat(textBlobT)

	bytes[#bytes+1] = eh32(p_type)
	bytes[#bytes+1] = eh32(p_offset)
	bytes[#bytes+1] = eh32(entryVA)  -- p_vaddr
	bytes[#bytes+1] = eh32(entryVA)  -- p_paddr
	bytes[#bytes+1] = eh32(#textBlob)
	bytes[#bytes+1] = eh32(#textBlob)
	bytes[#bytes+1] = eh32(5)        -- PF_R|PF_X
	bytes[#bytes+1] = eh32(0x1000)   -- align

	-- padding hasta 0x80 y payload
	local hdr = table.concat(bytes)
	if #hdr < p_offset then
		hdr = hdr .. string.rep("\0", p_offset - #hdr)
	end
	return hdr .. textBlob
end

-- ------------------ Loader ELF32 mínimo ------------------
local function u16(s,i) local b1,b2=s:byte(i,i+1); return b1 + bit.lshift(b2,8) end
local function u32(s,i) local b1,b2,b3,b4=s:byte(i,i+3); return b1 + bit.lshift(b2,8) + bit.lshift(b3,16) + bit.lshift(b4,24) end

local function loadELFToMemory(mem, elf)
	if elf:sub(1,4) ~= "\127ELF" then error("Not an ELF") end
	local e_phoff     = u32(elf, 29)
	local e_phentsize = u16(elf, 43)
	local e_phnum     = u16(elf, 45)
	for idx=0,e_phnum-1 do
		local off = e_phoff + idx*e_phentsize + 1
		local p_type   = u32(elf, off + 0)
		local p_offset = u32(elf, off + 4)
		local p_vaddr  = u32(elf, off + 8)
		local p_filesz = u32(elf, off + 16)
		if p_type == 1 then
			for i=0,p_filesz-1 do
				local b = elf:byte(p_offset + 1 + i) or 0
				mem[p_vaddr + i] = b
			end
		end
	end
end

-- ------------------ flujo principal ------------------
print("[RunElfWrite] boot")
local code = build_text_words()
local elf  = makeELF(code, ENTRY)
print(("[RunElfWrite] ELF bytes=%d"):format(#elf))
print(("[RunElfWrite] entry=0x%08X"):format(ENTRY))

local mem = {}
loadELFToMemory(mem, elf)

-- Aseguramos el buffer en memoria (por si tu loader real no mete .data):
for i=1,#MSG do mem[MSG_VA + (i-1)] = string.byte(MSG, i) end

local cpu = Core.new({ pc = ENTRY, mem = mem, platform = plat, mode = 1 })
cpu:run(2000)
print("[RunElfWrite] done")

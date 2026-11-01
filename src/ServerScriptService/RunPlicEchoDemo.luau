-- RunPlicEchoDemo — PLIC + IRQ externa “host input” (fuente 1)
local RunService = game:GetService("RunService")
local RS         = game:GetService("ReplicatedStorage")
local RV         = RS:WaitForChild("RiscV")

local Core   = require(RV:WaitForChild("core"))
local ELF32  = require(RV:WaitForChild("elf32"))
local SBI    = require(RV:WaitForChild("sbi_min"))
local CLINT  = require(RV:WaitForChild("clint"))
local PLIC   = require(RV:WaitForChild("plic"))

-- Salida a TextLabel
local BusBE = RS:WaitForChild("RoEmu_OutAppend")
local function out(s)  if s and #s>0 then BusBE:Fire(s) end end
local function log(s)  BusBE:Fire((s or "").."\n") end

log("[PLIC Demo] boot")

-- Core + RAM
local cpu = Core.new(); cpu:reset(0x80000000)
local ram = cpu:map_ram(0x80000000, 256*1024)

-- CLINT (solo para tener timer si quieres usarlo en el futuro)
local clint = CLINT.new(); clint:bind_core(cpu)
cpu:map_mmio(0x02000000, 0x100000, clint)

-- PLIC @ 0x0C00_0000
local plic = PLIC.new(8); plic:bind_core(cpu)
cpu:map_mmio(0x0C000000, 0x400000, plic)

-- Vector de trap = MRET
local function put32(t,w)
	t[#t+1]=bit32.band(w,0xFF)
	t[#t+1]=bit32.band(bit32.rshift(w,8),0xFF)
	t[#t+1]=bit32.band(bit32.rshift(w,16),0xFF)
	t[#t+1]=bit32.band(bit32.rshift(w,24),0xFF)
end
local TRAP={}; put32(TRAP, 0x30200073); cpu:map_rom(0x00000000, TRAP)
pcall(function() cpu.csrs.MTVEC = 0 end)

-- Cola de entrada “host” -> genera fuente 1
local rxq = {}

-- Conectar RoEmu_Input (líneas del cliente)
local InRE = RS:WaitForChild("RoEmu_Input")
InRE.OnServerEvent:Connect(function(_player, line)
	if typeof(line) == "string" and #line > 0 then
		for i = 1, #line do
			table.insert(rxq, string.byte(line, i))
			plic:raise(1) -- fuente 1 pendiente
		end
	end
end)

-- on_trap: IRQ externa -> claim, consumir cola, complete
cpu.on_trap = function(mcause, _)
	if tonumber(mcause) == 0x8000000B then
		-- reclamar
		local id = plic:read32(0x200004)
		if id == 1 then
			local ch = table.remove(rxq, 1)
			if ch then
				log(("irq rx: %q (%d)"):format(string.char(ch), ch))
				-- si siguen datos, re-levanta
				if #rxq > 0 then plic:raise(1) end
			end
			-- completar
			plic:write32(0x200004, 1)
		end
	end
end

-- SBI mínimo (solo console_putchar para log desde invitado si hiciera falta)
SBI.attach(cpu, {
	[1] = function(a0) out(string.char((a0 or 0)%256)) end, -- putchar
	[8] = function() cpu.halted = true end
})

-- Invitado: habilitar MEIE/MIE y bucle vacío (para que el core corra)
local band, rshift, lshift, bor = bit32.band, bit32.rshift, bit32.lshift, bit32.bor
local function le16(n) return string.char(band(n,0xFF), band(rshift(n,8),0xFF)) end
local function le32(n) return string.char(band(n,0xFF), band(rshift(n,8),0xFF), band(rshift(n,16),0xFF), band(rshift(n,24),0xFF)) end
local function words_to_le_bytes(t) local s=table.create(#t); for i,w in ipairs(t) do s[i]=le32(w) end; return table.concat(s) end

local function enc_addi(rd, rs1, imm12) return bor(lshift(band(imm12,0xFFF),20), lshift(rs1,15), lshift(0,12), lshift(rd,7), 0x13) end
local function enc_csrrsi(rd, csr, zimm5) return bor(lshift(band(csr,0xFFF),20), lshift(band(zimm5,0x1F),15), lshift(6,12), lshift(rd,7), 0x73) end
local function enc_csrrs(rd, csr, rs1)  return bor(lshift(band(csr,0xFFF),20), lshift(rs1,15), lshift(2,12), lshift(rd,7), 0x73) end

local X0, A0 = 0, 10
local CSR_MSTATUS, CSR_MIE = 0x300, 0x304
local MSTATUS_MIE, MIE_MEIE = 0x8, bit32.lshift(1,11)
local JAL0 = 0x0000006F

-- Habilitar MEIE y MIE global; bucle infinito
local program = {
	enc_addi(A0, X0, MIE_MEIE),              -- li a0, (1<<11)
	enc_csrrs(X0, CSR_MIE, A0),              -- csrrs x0, mie, a0   (MEIE)
	enc_csrrsi(X0, CSR_MSTATUS, MSTATUS_MIE),-- csrrsi x0, mstatus, 0x8 (MIE)
	JAL0,                                    -- loop
}
local text_blob = words_to_le_bytes(program)

-- ELF 1 PT_LOAD
local EH_SIZE, PH_SIZE = 52,32
local PH_OFF, CODE_OFF = EH_SIZE, EH_SIZE + PH_SIZE
local ENTRY, VADDR = 0x80000000, 0x80000000
local ident = string.char(0x7F,0x45,0x4C,0x46, 1,1,1,0, 0,0,0,0,0,0,0,0)
local function EH() return table.concat{ ident, le16(2), le16(243), le32(1), le32(ENTRY), le32(PH_OFF), le32(0), le32(0), le16(EH_SIZE), le16(PH_SIZE), le16(1), le16(40), le16(0), le16(0) } end
local function PH() return table.concat{ le32(1), le32(CODE_OFF), le32(VADDR), le32(VADDR), le32(#text_blob), le32(#text_blob), le32(5), le32(4) } end
local elf_blob = EH() .. PH() .. text_blob
log(("[PLIC Demo] ELF bytes=%d"):format(#elf_blob))

local entry = ELF32.load(elf_blob, ram); cpu.pc = entry

-- Ejecutar
local STEPS_PER_FRAME = 16000
RunService.Heartbeat:Connect(function()
	if cpu.halted then return end
	for _=1, STEPS_PER_FRAME do
		if cpu.halted then break end
		cpu:step()
	end
end)

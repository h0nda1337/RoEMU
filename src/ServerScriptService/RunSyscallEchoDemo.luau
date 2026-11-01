-- ServerScriptService/RunSyscallEchoDemo
-- Echo interactivo con syscalls read(63)/write(64)/exit(93).
-- Corrección: no escribir si read() devuelve 0 (evita '\x00' en bucle).

local RS   = game:GetService("ReplicatedStorage")
local Core = require(RS:WaitForChild("RiscV"):WaitForChild("core"))
local b32  = bit32
local bor, band, lshift, rshift = b32.bor, b32.band, b32.lshift, b32.rshift

----------------------------------------------------------------------
-- Canal de entrada desde el cliente (RemoteEvent simple)
----------------------------------------------------------------------
local InputRE = RS:FindFirstChild("RoEmu_Input")
if not InputRE then
	InputRE = Instance.new("RemoteEvent")
	InputRE.Name = "RoEmu_Input"
	InputRE.Parent = RS
end

-- FIFO para stdin
local fifo = table.create(512); local head, tail = 1, 1
local function push(b) fifo[tail] = b; tail += 1 end
local function pop() if head < tail then local v = fifo[head]; head += 1; return v end end

InputRE.OnServerEvent:Connect(function(_, text)
	for i = 1, #text do push(string.byte(text, i)) end
end)

----------------------------------------------------------------------
-- Plataforma (cómo atiende la VM las syscalls)
----------------------------------------------------------------------
local platform = {
	stdin_read = function(cpu, ptr, n)
		local wrote = 0
		while wrote < n do
			local b = pop()
			if not b then break end
			cpu.mem[ptr + wrote] = b
			wrote += 1
		end
		return wrote
	end,
	uart_write = function(_, byte)
		local ch = (byte >= 32 and byte < 127) and string.char(byte) or string.format("\\x%02X", byte)
		print(("[UART] %s"):format(ch))
	end,
}

----------------------------------------------------------------------
-- Ensamblador mínimo RV32I
----------------------------------------------------------------------
local function w8(mem, addr, v)  mem[addr] = band(v, 0xFF) end
local function w32(mem, addr, v)
	mem[addr    ] = band(v,0xFF)
	mem[addr + 1] = band(rshift(v, 8),0xFF)
	mem[addr + 2] = band(rshift(v,16),0xFF)
	mem[addr + 3] = band(rshift(v,24),0xFF)
end

local function I(op, rd, f3, rs1, imm)
	imm = band(imm, 0xFFF)
	return bor(lshift(imm,20), lshift(band(rs1,31),15), lshift(band(f3,7),12), lshift(band(rd,31),7), band(op,0x7F))
end
local function U(op, rd, imm20)
	return bor(lshift(band(imm20,0xFFFFF),12), lshift(band(rd,31),7), band(op,0x7F))
end
local function S(op, f3, rs1, rs2, imm)
	imm = band(imm, 0xFFF)
	local hi, lo = rshift(imm,5), band(imm,31)
	return bor(lshift(hi,25), lshift(band(rs2,31),20), lshift(band(rs1,31),15), lshift(band(f3,7),12), lshift(lo,7), band(op,0x7F))
end
local function B(op, f3, rs1, rs2, imm)
	imm = band(imm, 0x1FFF)
	local b12 = band(rshift(imm,12),1)
	local b10_5 = band(rshift(imm,5),0x3F)
	local b4_1 = band(rshift(imm,1),0x0F)
	local b11 = band(rshift(imm,11),1)
	return bor(lshift(b12,31), lshift(b10_5,25), lshift(band(rs2,31),20), lshift(band(rs1,31),15), lshift(band(f3,7),12), lshift(b4_1,8), lshift(b11,7), band(op,0x7F))
end
local function J(op, rd, imm)
	imm = band(imm, 0x1FFFFF)
	local b20 = band(rshift(imm,20),1)
	local b10_1 = band(rshift(imm,1),0x3FF)
	local b11 = band(rshift(imm,11),1)
	local b19_12 = band(rshift(imm,12),0xFF)
	return bor(lshift(b20,31), lshift(b10_1,21), lshift(b11,20), lshift(b19_12,12), lshift(band(rd,31),7), band(op,0x7F))
end

local OPC_LUI=0x37; local OPC_OPIMM=0x13; local OPC_LOAD=0x03; local OPC_BRANCH=0x63; local OPC_JAL=0x6F; local OPC_SYS=0x73
local F3I = { ADDI=0 }
local F3L = { LB=0 }
local F3B = { BEQ=0 }

local prog, labels = {}, {}
local function emit32(w) prog[#prog+1] = w end
local function mark(lbl) labels[lbl] = #prog end
local function idx_pc(idx, base) return base + (idx-1)*4 end
local function patchB(at_idx, src_pc, dst_pc, rs1, rs2, f3) prog[at_idx] = B(OPC_BRANCH, f3, rs1, rs2, dst_pc - src_pc) end
local function patchJ(at_idx, src_pc, dst_pc, rd) prog[at_idx] = J(OPC_JAL, rd, dst_pc - src_pc) end

----------------------------------------------------------------------
-- Programa: "Hi\n" y luego eco hasta '\n' (sólo cuando read() > 0)
----------------------------------------------------------------------
local ENTRY = 0x80000000
local MSG   = 0x80000100
local BUF   = 0x80000200

-- write(1, MSG, 3)
emit32(I(OPC_OPIMM,10,F3I.ADDI,0,1))          -- a0=1
emit32(U(OPC_LUI,   11,0x80000))              -- a1=0x80000000
emit32(I(OPC_OPIMM,11,F3I.ADDI,11,0x100))     -- a1=MSG
emit32(I(OPC_OPIMM,12,F3I.ADDI,0,3))          -- a2=3
emit32(I(OPC_OPIMM,17,F3I.ADDI,0,64))         -- a7=write
emit32(OPC_SYS)                               -- ecall

mark("LOOP")
-- a0=0; a1=BUF; a2=1; a7=read; ecall
emit32(I(OPC_OPIMM,10,F3I.ADDI,0,0))
emit32(U(OPC_LUI,   11,0x80000))
emit32(I(OPC_OPIMM,11,F3I.ADDI,11,0x200))
emit32(I(OPC_OPIMM,12,F3I.ADDI,0,1))
emit32(I(OPC_OPIMM,17,F3I.ADDI,0,63))
emit32(OPC_SYS)

-- if (a0==0) goto LOOP  (no escribir si no hay dato)
local beq_retry = #prog + 1; emit32(0)        -- BEQ a0,x0,LOOP  (parcheo luego)

-- cargar byte y si es '\n' -> EXIT
emit32(I(OPC_LOAD,5,F3L.LB,11,0))             -- t0 = LB 0(a1)
emit32(I(OPC_OPIMM,6,F3I.ADDI,0,10))          -- t1 = 10
local beq_exit = #prog + 1; emit32(0)         -- BEQ t0,t1,EXIT

-- write(1, BUF, 1)
emit32(I(OPC_OPIMM,10,F3I.ADDI,0,1))
emit32(I(OPC_OPIMM,12,F3I.ADDI,0,1))
emit32(I(OPC_OPIMM,17,F3I.ADDI,0,64))
emit32(OPC_SYS)
local j_loop = #prog + 1; emit32(0)           -- J LOOP

mark("EXIT")
emit32(I(OPC_OPIMM,17,F3I.ADDI,0,93))         -- exit(0)
emit32(I(OPC_OPIMM,10,F3I.ADDI,0,0))
emit32(OPC_SYS)

-- Parcheos
local function pc_of(i) return idx_pc(i, ENTRY) end
patchB(beq_retry, pc_of(beq_retry), pc_of(labels.LOOP + 1), 10, 0, F3B.BEQ)  -- a0==x0 -> LOOP
patchB(beq_exit,  pc_of(beq_exit ), pc_of(labels.EXIT + 1),  5,  6, F3B.BEQ) -- t0==10 -> EXIT
patchJ(j_loop,    pc_of(j_loop   ), pc_of(labels.LOOP + 1),  0)

----------------------------------------------------------------------
-- Cargar en memoria
----------------------------------------------------------------------
local mem = {}
do
	local pc = ENTRY
	for i = 1, #prog do w32(mem, pc, prog[i]); pc += 4 end
end
for i, c in ipairs{string.byte("Hi\n",1,-1)} do w8(mem, MSG + (i-1), c) end

----------------------------------------------------------------------
-- Crear CPU y ejecutar
----------------------------------------------------------------------
local cpu = Core.new{ pc = ENTRY, mem = mem, reg = { [2]=0x81000000 }, platform = platform }
print("[EchoDemo] Escribe en el cliente; termina con Enter.")
cpu:run(400000)
print("[EchoDemo] done")

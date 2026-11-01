-- ServerScriptService/RunElfDemo — ELF32 + SBI tabulado (no bloqueante)
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local RV = RS:WaitForChild("RiscV")

local Core   = require(RV:WaitForChild("core"))
local UARTM  = require(RV:WaitForChild("devices"):WaitForChild("uart16550"))
local ELF32  = require(RV:WaitForChild("elf32"))
local SBI    = require(RV:WaitForChild("sbi_min"))

-- ===== salida GUI =====
local OutRE = RS:FindFirstChild("RoEmu_Out") or Instance.new("RemoteEvent")
OutRE.Name = "RoEmu_Out"; OutRE.Parent = RS
local OutRF = RS:FindFirstChild("RoEmu_OutGet") or Instance.new("RemoteFunction")
OutRF.Name = "RoEmu_OutGet"; OutRF.Parent = RS

local out_buf, out_hist = "", ""
local function out_flush()
	if #out_buf>0 then
		OutRE:FireAllClients(out_buf)
		out_hist ..= out_buf
		if #out_hist > 200000 then out_hist = out_hist:sub(#out_hist-200000+1) end
		out_buf = ""
	end
end
OutRF.OnServerInvoke = function() return out_hist end
local function out_char(n)
	local c = (typeof(n)=="number") and string.char(n%256)
		or (type(n)=="string" and n:sub(1,1) or "?")
	out_buf ..= c
	if c=="\n" or #out_buf>=512 then out_flush() end
end
local function puts(s) for i=1,#s do out_char(s:byte(i)) end end

puts("[RunElfDemo] boot (ELF32 + SBI table)\n")

-- ===== core/ram/uart =====
local cpu = Core.new()
cpu:reset(0x80000000)
local ram = cpu:map_ram(0x80000000, 256*1024)

local uart = UARTM.new({
	writeChar = function(ch) out_char(ch) end
})
cpu:map_mmio(0x10000000, 0x100, uart)

-- Entrada de usuario → RX (por si el binario la usa)
local InRE = RS:FindFirstChild("RoEmu_Input") or Instance.new("RemoteEvent")
InRE.Name = "RoEmu_Input"; InRE.Parent = RS
InRE.OnServerEvent:Connect(function(_, line)
	if type(line)=="string" then uart:rx_line(line) end
end)

-- ===== SBI por tabla =====
SBI.attach(cpu, {
	[1] = function(a0) uart:write32(0, a0 or 0) end,   -- console_putchar
	[2] = function(a0) -- set_timer stub (nada por ahora) end
	end,
	[3] = function()  -- console_getchar (no bloqueante)
		local b = uart.read_byte_nonblock and uart:read_byte_nonblock() or nil
		return b and (b%256) or 0xFFFFFFFF
	end,
	[8] = function() cpu.halted = true end,            -- shutdown
})

-- ===== helpers LE =====
local band, rshift = bit32.band, bit32.rshift
local function le16(n) return string.char(band(n,0xFF), band(rshift(n,8),0xFF)) end
local function le32(n)
	return string.char(
		band(n,0xFF),
		band(rshift(n,8),0xFF),
		band(rshift(n,16),0xFF),
		band(rshift(n,24),0xFF)
	)
end

-- ===== código RV32I: "Hi\n" vía ECALL a7=1 + bucle =====
local code_words = {
	0x00100893,            -- addi a7, x0, 1
	0x04800513, 0x00000073,-- addi a0, x0, 'H' ; ecall
	0x06900513, 0x00000073,-- addi a0, x0, 'i' ; ecall
	0x00A00513, 0x00000073,-- addi a0, x0, '\n' ; ecall
	0x0000006F,            -- jal x0, 0
}
local function words_to_le_bytes(t)
	local s = table.create(#t)
	for i,w in ipairs(t) do s[i] = le32(w) end
	return table.concat(s)
end
local code = words_to_le_bytes(code_words)

-- ===== construir ELF32 (1 PT_LOAD) =====
local EH_SIZE, PH_SIZE = 52, 32
local PH_OFF, CODE_OFF = EH_SIZE, EH_SIZE + PH_SIZE
local ENTRY, VADDR = 0x80000000, 0x80000000
local ident = string.char(0x7F,0x45,0x4C,0x46, 1,1,1,0, 0,0,0,0,0,0,0,0)
local eh = table.concat({
	ident, le16(2), le16(243), le32(1),
	le32(ENTRY), le32(PH_OFF), le32(0), le32(0),
	le16(EH_SIZE), le16(PH_SIZE), le16(1),
	le16(40), le16(0), le16(0)
})
local ph = table.concat({
	le32(1), le32(CODE_OFF), le32(VADDR), le32(VADDR),
	le32(#code), le32(#code), le32(5), le32(4)
})
local elf_blob = eh .. ph .. code
puts(("[RunElfDemo] ELF bytes=%d\n"):format(#elf_blob))

-- ===== cargar en RAM y arrancar =====
local entry = ELF32.load(elf_blob, ram)
cpu.pc = entry

-- ===== ejecutar por Heartbeat (no bloqueante) =====
local STEPS_PER_FRAME, frames_left, running = 4000, 120, true
local hb
hb = RunService.Heartbeat:Connect(function()
	if not running then return end
	for _=1, STEPS_PER_FRAME do
		cpu:step()
		if cpu.halted then running=false; break end
	end
	frames_left -= 1
	if frames_left <= 0 or not running then
		if hb then hb:Disconnect() end
		puts("[RunElfDemo] done\n")
		out_flush()
	end
end)

out_flush()

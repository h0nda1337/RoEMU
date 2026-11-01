-- ServerScriptService/RunSbiEchoDemo  —  demo SBI eco (no bloqueante, sólo RoEmu_Out)
local RunService = game:GetService("RunService")
local RS         = game:GetService("ReplicatedStorage")
local RV         = RS:WaitForChild("RiscV")

local Core   = require(RV:WaitForChild("core"))
local UARTM  = require(RV:WaitForChild("devices"):WaitForChild("uart16550"))

-- CLINT opcional
local function requireClintOptional()
	local m = RV:FindFirstChild("clint"); if m then return require(m) end
	local d = RV:FindFirstChild("devices"); if d and d:FindFirstChild("clint") then return require(d.clint) end
	return nil
end
local CLINTM = requireClintOptional()

-- ===== Salida GUI con historial (RoEmu_Out / RoEmu_OutGet) =====
local OutRE = RS:FindFirstChild("RoEmu_Out") or Instance.new("RemoteEvent")
OutRE.Name = "RoEmu_Out"; OutRE.Parent = RS

local OutRF = RS:FindFirstChild("RoEmu_OutGet") or Instance.new("RemoteFunction")
OutRF.Name = "RoEmu_OutGet"; OutRF.Parent = RS

local out_buf, out_hist = "", ""
local function out_flush()
	if #out_buf > 0 then
		OutRE:FireAllClients(out_buf)
		out_hist ..= out_buf
		if #out_hist > 200000 then
			out_hist = string.sub(out_hist, #out_hist - 200000 + 1)
		end
		out_buf = ""
	end
end
OutRF.OnServerInvoke = function() return out_hist end
local function out_write_char(ch)
	local c = (typeof(ch) == "number") and string.char(ch % 256)
		or ((typeof(ch) == "string") and ch:sub(1,1) or "?")
	out_buf ..= c
	if c == "\n" or #out_buf >= 512 then out_flush() end
end
local function puts_str(s)
	for i = 1, #s do out_write_char(s:sub(i,i)) end
end

-- ===== Core + dispositivos =====
puts_str("[SBI Echo] boot\n")

local cpu = Core.new()
cpu:reset(0x80000000)
local ram = cpu:map_ram(0x80000000, 128*1024)

local uart = UARTM.new({
	writeChar = function(ch)
		local c = (typeof(ch)=="number") and string.char(ch%256)
			or ((typeof(ch)=="string") and ch:sub(1,1) or "?")
		out_write_char(c)
	end
})
cpu:map_mmio(0x10000000, 0x100, uart)

local clint = nil
if CLINTM then
	clint = CLINTM.new()
	cpu:map_mmio(0x02000000, 0x10000, clint)
	if clint.bind_core then clint:bind_core(cpu) end
	-- Habilita MIE + MTIE (no estorba si no usas timer todavía)
	cpu.csrs[0x300] = bit32.bor(cpu.csrs[0x300] or 0, 0x8)               -- MSTATUS.MIE
	cpu.csrs[0x304] = bit32.bor(cpu.csrs[0x304] or 0, bit32.lshift(1,7)) -- MIE.MTIE
end

-- Trap vector -> MRET
local function put32(t, w)
	t[#t+1] = bit32.band(w,0xFF)
	t[#t+1] = bit32.band(bit32.rshift(w,8),0xFF)
	t[#t+1] = bit32.band(bit32.rshift(w,16),0xFF)
	t[#t+1] = bit32.band(bit32.rshift(w,24),0xFF)
end
local TRAP = {}; put32(TRAP, 0x30200073)
cpu:map_rom(0x00000000, TRAP); cpu.csrs.mtvec = 0

-- Programa en RAM: ECALL ; JAL x0, -4 (bucle)
local PROG = {}; put32(PROG, 0x00000073); put32(PROG, 0xFFDFF06F)
for i=1,#PROG do ram.bytes[i] = PROG[i] end

-- ===== SBI mínimo =====
-- a7=1: console_putchar(a0)
-- a7=2: set_timer(delta)     (si hay CLINT)
-- a7=3: console_getchar() -> a0 (no bloqueante; -1 si vacío)
-- a7=8: shutdown()
cpu.on_sbi = function(a7, a0, core, _cpu)
	if a7 == 1 then
		uart:write32(0, a0 or 0)
		return true
	elseif a7 == 2 then
		if clint and clint.set_mtimecmp_delta then
			clint:set_mtimecmp_delta(tonumber(a0) or 5000)
		end
		return true
	elseif a7 == 3 then
		local b = uart.read_byte_nonblock and uart:read_byte_nonblock() or nil
		if b == nil then _cpu.regs[10] = 0xFFFFFFFF else _cpu.regs[10] = b % 256 end
		return true
	elseif a7 == 8 then
		_cpu.halted = true
		return true
	end
	return false
end

-- Entrada del usuario → FIFO RX
local InRE = RS:FindFirstChild("RoEmu_Input") or Instance.new("RemoteEvent")
InRE.Name = "RoEmu_Input"; InRE.Parent = RS
InRE.OnServerEvent:Connect(function(player, line)
	if type(line) == "string" then
		uart:rx_line(line)
	end
end)

-- Mensaje de bienvenida
puts_str("SBI Echo listo. Teclea y verás eco. Escribe 'exit' para apagar.\n> ")

-- ===== Bucle no bloqueante por Heartbeat =====
local CSR_MIP, MIP_MTIP = 0x344, bit32.lshift(1,7)
local DELTA = 5000
cpu.regs[17] = 0; cpu.regs[10] = 0
local buf = ""
local running = true
local STEPS_PER_FRAME = 2000  -- ajusta velocidad de emulación

local hbConn
hbConn = RunService.Heartbeat:Connect(function()
	if not running then return end

	for _=1, STEPS_PER_FRAME do
		-- getchar
		cpu.regs[17] = 3; cpu:step(); cpu:step()
		local ch = cpu.regs[10] or 0xFFFFFFFF
		if ch ~= 0xFFFFFFFF then
			-- eco
			cpu.regs[17] = 1; cpu.regs[10] = ch; cpu:step(); cpu:step()
			-- comando 'exit'
			if ch == 10 or ch == 13 then
				if buf == "exit" then
					puts_str("\nApagando...\n")
					cpu.regs[17] = 8; cpu.regs[10] = 0; cpu:step(); cpu:step()
					running = false
					break
				end
				buf = ""
				puts_str("> ")
			else
				buf ..= string.char(ch)
			end
		end

		-- paso normal (timer/otros)
		cpu:step()

		-- MTIP (si usas CLINT)
		if bit32.band(cpu.csrs[CSR_MIP] or 0, MIP_MTIP) ~= 0 then
			if clint and clint.set_mtimecmp_delta then clint:set_mtimecmp_delta(DELTA) end
			cpu.csrs[CSR_MIP] = bit32.band(cpu.csrs[CSR_MIP], bit32.bnot(MIP_MTIP))
		end

		if cpu.halted then running = false; break end
	end

	if not running then
		if hbConn then hbConn:Disconnect() end
		out_flush()
		puts_str("[SBI Echo] done\n")
		out_flush()
	end
end)

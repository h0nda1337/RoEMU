-- ReplicatedStorage/RiscV/devices/uart16550.lua
-- UART 16550 minimo pero mas compatible con acceso "word-spaced" estilo virt/QEMU.
-- Objetivos:
--   - THR/RBR en reg 0
--   - LSR visible correctamente
--   - read32(off) devuelve el registro en el byte bajo, NO empaqueta 4 registros
--   - soporta offsets byte-spaced (0x05) y word-spaced (0x14 -> reg 5)
--   - API util:
--       UART.new({ writeChar = function(byte) ... end })
--       :rx_line("texto")
--       :host_rx_line("texto")
--       :read_byte_nonblock()
--       :read8(off), :write8(off, val), :read32(off), :write32(off, val)
--       :setIrqSink(fn), :set_irq_callback(fn)

local band   = bit32.band
local bor    = bit32.bor
local lshift = bit32.lshift

local UART = {}
UART.__index = UART

local function new_fifo(cap)
	return {
		q = table.create(cap or 1024, 0),
		r = 1,
		w = 1,
		size = 0,
		cap = cap or 1024,
	}
end

local function fifo_clear(f)
	f.r = 1
	f.w = 1
	f.size = 0
end

local function fifo_push(f, byte)
	if f.size >= f.cap then
		return false
	end
	f.q[f.w] = band(byte or 0, 0xFF)
	f.w = (f.w % f.cap) + 1
	f.size += 1
	return true
end

local function fifo_pop(f)
	if f.size <= 0 then
		return nil
	end
	local v = f.q[f.r]
	f.r = (f.r % f.cap) + 1
	f.size -= 1
	return v
end

local function fifo_peek(f)
	if f.size <= 0 then
		return nil
	end
	return f.q[f.r]
end

local function to_u8(x)
	return band(tonumber(x) or 0, 0xFF)
end

local function decode_reg(off)
	off = band(tonumber(off) or 0, 0xFF)

	-- Compatibilidad:
	--   byte-spaced: 0x00,0x01,0x02,... -> mismos registros
	--   word-spaced: 0x00,0x04,0x08,... -> reg = off / 4
	--
	-- Ejemplo:
	--   LSR puede llegar como 0x05 (byte-spaced) o 0x14 (word-spaced)
	-- QEMU virt usa registros byte-spaced (reg-shift = 0). Conservamos el
	-- formato word-spaced solo fuera del rango byte directo para demos viejas.
	if off <= 7 then return off end
	if off % 4 == 0 then return off // 4 end
	return off
end

local function dlab_enabled(self)
	return band(self.lcr, 0x80) ~= 0
end

local function rx_data_ready(self)
	return self._rx.size > 0
end

local function irq_pending_rx(self)
	return (band(self.ier, 0x01) ~= 0) and rx_data_ready(self)
end

local function irq_pending_tx(self)
	-- La transmisión es inmediata en RoEMU, por lo que THR siempre vuelve a
	-- quedar vacío. Linux habilita IER.THRI mientras su cola de salida tenga
	-- bytes y lo deshabilita cuando termina de vaciarla.
	return band(self.ier, 0x02) ~= 0
end

local function update_irq(self)
	local pending = irq_pending_rx(self) or irq_pending_tx(self)

	if self._irqSink then
		pcall(self._irqSink, pending)
	end

	if self._irqCallback then
		pcall(self._irqCallback, pending)
	end
end

function UART.new(cfg)
	local self = setmetatable({}, UART)

	self._rx = new_fifo(4096)

	self.writeChar = function(_) end
	if type(cfg) == "table" and type(cfg.writeChar) == "function" then
		self.writeChar = cfg.writeChar
	end

	-- Registros basicos
	self.ier = 0x00
	self.fcr = 0x00
	self.lcr = 0x03 -- 8N1
	self.mcr = 0x00
	self.scr = 0x00

	-- Divisor latch (stub)
	self.dll = 0x01
	self.dlm = 0x00

	self._irqSink = nil
	self._irqCallback = nil

	return self
end

function UART:setIrqSink(fn)
	if type(fn) == "function" then
		self._irqSink = fn
	else
		self._irqSink = nil
	end
	update_irq(self)
end

function UART:set_irq_callback(fn)
	if type(fn) == "function" then
		self._irqCallback = fn
	else
		self._irqCallback = nil
	end
	update_irq(self)
end

function UART:rx_line(s)
	if typeof(s) ~= "string" then
		return
	end

	for i = 1, #s do
		fifo_push(self._rx, string.byte(s, i))
	end

	update_irq(self)
end

function UART:host_rx_line(s)
	self:rx_line(s)
end

function UART:read_byte_nonblock()
	local b = fifo_pop(self._rx)
	update_irq(self)
	return b
end

function UART:read8(off)
	local reg = decode_reg(off)

	-- reg 0: RBR / DLL
	if reg == 0x00 then
		if dlab_enabled(self) then
			return self.dll
		end

		local b = fifo_pop(self._rx)
		update_irq(self)
		return b or 0
	end

	-- reg 1: IER / DLM
	if reg == 0x01 then
		if dlab_enabled(self) then
			return self.dlm
		end
		return self.ier
	end

	-- reg 2: IIR (read) / FCR (write)
	if reg == 0x02 then
		-- bit0 = 1 => no interrupt pending
		-- 0x04 => received data available
		if irq_pending_rx(self) then
			return 0x04
		end
		-- 0x02 => THR vacío; permite que el driver 8250 continúe
		-- transmitiendo más allá del primer bloque de su FIFO.
		if irq_pending_tx(self) then
			return 0x02
		end
		return 0x01
	end

	-- reg 3: LCR
	if reg == 0x03 then
		return self.lcr
	end

	-- reg 4: MCR
	if reg == 0x04 then
		return self.mcr
	end

	-- reg 5: LSR
	if reg == 0x05 then
		-- bit0 DR   : data ready
		-- bit5 THRE : transmitter holding register empty
		-- bit6 TEMT : transmitter empty
		local dr = rx_data_ready(self) and 0x01 or 0x00
		return bor(dr, 0x20, 0x40)
	end

	-- reg 6: MSR (stub)
	if reg == 0x06 then
		return 0x00
	end

	-- reg 7: SCR
	if reg == 0x07 then
		return self.scr
	end

	return 0
end

function UART:write8(off, val)
	local reg = decode_reg(off)
	local byte = to_u8(val)

	-- reg 0: THR / DLL
	if reg == 0x00 then
		if dlab_enabled(self) then
			self.dll = byte
			return
		end

		self.writeChar(byte)
		return
	end

	-- reg 1: IER / DLM
	if reg == 0x01 then
		if dlab_enabled(self) then
			self.dlm = byte
			return
		end

		self.ier = band(byte, 0x0F)
		update_irq(self)
		return
	end

	-- reg 2: FCR
	if reg == 0x02 then
		self.fcr = byte

		-- bit1: clear RX FIFO
		if band(byte, 0x02) ~= 0 then
			fifo_clear(self._rx)
		end

		update_irq(self)
		return
	end

	-- reg 3: LCR
	if reg == 0x03 then
		self.lcr = byte
		return
	end

	-- reg 4: MCR
	if reg == 0x04 then
		self.mcr = byte
		return
	end

	-- reg 7: SCR
	if reg == 0x07 then
		self.scr = byte
		return
	end

	-- otros: ignorados
end

function UART:read32(off)
	-- Importante:
	-- devolver SOLO el registro en el byte bajo.
	-- No empaquetar 4 registros consecutivos.
	return self:read8(off)
end

function UART:write32(off, val)
	-- Igual: solo consumimos el byte bajo.
	self:write8(off, band(val or 0, 0xFF))
end

return {
	new = UART.new,
}

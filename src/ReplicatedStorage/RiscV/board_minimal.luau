-- ReplicatedStorage/RiscV/board_minimal.lua
local bit = bit32
local RS = game:GetService("ReplicatedStorage")
local Uart = require(RS.RiscV.devices.uart16550)

local Board = {}
Board.__index = Board

local UART_BASE = 0x10000000
local UART_SIZE = 0x08

local function in_range(addr, base, size)
	return (addr >= base) and (addr < base + size)
end

function Board.new(monitor)
	local self = setmetatable({}, Board)
	self.mon = monitor
	self.uart = Uart.new(monitor)

	-- Si más adelante conectas PLIC:
	self.uart:set_irq_callback(function(pending)
		if pending and self.mon then
			self.mon:print("[Board] IRQ UART pendiente")
		end
	end)

	return self
end

-- MMIO 8-bit
function Board:mmio_read8(addr)
	if in_range(addr, UART_BASE, UART_SIZE) then
		local off = addr - UART_BASE
		return self.uart:read8(off)
	end
	return 0
end

function Board:mmio_write8(addr, value)
	if in_range(addr, UART_BASE, UART_SIZE) then
		local off = addr - UART_BASE
		self.uart:write8(off, bit.band(value, 0xFF))
	end
end

-- Host -> RX
function Board:host_rx_line(s)
	self.uart:host_rx_line(s)
end

return Board

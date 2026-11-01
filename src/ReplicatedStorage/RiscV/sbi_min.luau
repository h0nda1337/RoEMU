-- RiscV/sbi_min — pequeño “router” de llamadas SBI por tabla
-- Uso:
--   local SBI = require(RS.RiscV.sbi_min)
--   SBI.attach(cpu, {
--     [1] = function(a0) uart:write32(0, a0 or 0) end,    -- console_putchar
--     [2] = function(a0) if clint then clint:set_mtimecmp_delta(tonumber(a0) or 5000) end end,
--     [3] = function()  -- console_getchar (no bloqueante)
--            local b = uart.read_byte_nonblock and uart:read_byte_nonblock() or nil
--            return (b and (b%256) or 0xFFFFFFFF)
--          end,
--     [8] = function() cpu.halted = true end,
--   })

local M = {}

function M.attach(cpu, tbl)
	assert(type(cpu)=="table" and type(tbl)=="table", "SBI.attach: args inválidos")
	cpu.on_sbi = function(a7, a0, core, _cpu)
		local fn = tbl[a7]
		if not fn then return false end
		local ret = fn(a0, core, _cpu)
		-- Convención: si la función devuelve un número, lo colocamos en a0 (x10)
		if type(ret)=="number" then _cpu.regs[10] = ret end
		return true
	end
end

return M

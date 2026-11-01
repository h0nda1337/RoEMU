-- ReplicatedStorage/RiscV/platform
local Platform = {}
Platform.__index = Platform

function Platform.new(onUart)
	return setmetatable({
		onUart = onUart,
		stdinBuf = {},  -- cola de bytes para read()
	}, Platform)
end

function Platform:uart_write(b)
	if self.onUart then self.onUart(b) end
end

-- Inserta texto a stdin (útil en demos/tests)
function Platform:stdin_feed(text)
	for i = 1, #text do
		table.insert(self.stdinBuf, string.byte(text, i))
	end
end

-- Copia hasta n bytes desde stdinBuf a memoria de la CPU en 'ptr'
function Platform:stdin_read(cpu, ptr, n)
	local mem = cpu.mem
	local k = 0
	while k < (n or 0) and #self.stdinBuf > 0 do
		local byte = table.remove(self.stdinBuf, 1)
		mem[ptr + k] = byte
		k = k + 1
	end
	return k
end

return Platform

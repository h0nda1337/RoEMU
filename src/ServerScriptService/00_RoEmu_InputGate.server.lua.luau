--!strict
-- 00_RoEmu_InputGate.server.lua
-- Entrada desde cliente -> cola de bytes en server.
-- Bootstrap (u otro) consume RoEmu.InputQueue para meterlo a UART.

task.wait()

_G.RoEmu = _G.RoEmu or {}
local RoEmu = _G.RoEmu :: any
local Log = RoEmu.Log or function(...) end
local ch = RoEmu.Channel

assert(ch and ch.In, "RoEmu.Channel.In no existe")

RoEmu.InputQueue = RoEmu.InputQueue or {} :: {number}
local InputQueue = RoEmu.InputQueue :: {number}

local MAX_PAYLOAD = 4096 -- evita spam

local function pushBytesFromString(s: string)
	local n = #s
	if n > MAX_PAYLOAD then
		s = string.sub(s, 1, MAX_PAYLOAD)
		n = #s
	end
	for i = 1, n do
		InputQueue[#InputQueue + 1] = string.byte(s, i)
	end
end

ch.In.OnServerEvent:Connect(function(plr: Player, kind: any, payload: any)
	-- Gate básico: solo aceptamos si está attached
	if not (RoEmu.Attached and RoEmu.Attached[plr.UserId]) then
		return
	end

	if kind == "bytes" and typeof(payload) == "string" then
		pushBytesFromString(payload)
		return
	end

	if kind == "text" and typeof(payload) == "string" then
		-- normaliza a bytes + newline
		pushBytesFromString(payload .. "\n")
		return
	end

	-- si llega algo raro, lo ignoramos
	Log("WARN", "InputGate payload inválido de", plr.Name, "kind=", kind, "type=", typeof(payload))
end)

Log("INFO", "InputGate listo")

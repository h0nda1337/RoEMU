--!strict
-- 00_RoEmu_RemoteGate.server.lua
-- Handshake único. Evita “doble attach” y valida entradas.

task.wait()

_G.RoEmu = _G.RoEmu or {}
local RoEmu = _G.RoEmu :: any
local Log = RoEmu.Log or function(...) end

local ch = RoEmu.Channel
assert(ch and ch.Rpc, "RoEmu.Channel.Rpc no existe (00_RoEmu_Channel no corrió)")

local function isAttached(plr: Player): boolean
	return RoEmu.Attached and RoEmu.Attached[plr.UserId] == true
end

local function setAttached(plr: Player, v: boolean)
	RoEmu.Attached = RoEmu.Attached or {}
	RoEmu.Attached[plr.UserId] = v
end

local function getCoreAPI()
	local sharedTable = rawget(_G, "shared")
	if type(sharedTable) ~= "table" then
		return nil
	end
	local api = rawget(sharedTable, "RoEmu_CoreAPI")
	if type(api) ~= "table" then
		return nil
	end
	return api
end

local function callCore(api, methodName: string, ...)
	local method = api and api[methodName]
	if type(method) ~= "function" then
		return false, "backend-api-unavailable"
	end
	local packed = table.pack(pcall(method, api, ...))
	if not packed[1] then
		Log("WARN", "Backend RPC fallo:", methodName, tostring(packed[2]))
		return false, "backend-internal-error"
	end
	return table.unpack(packed, 2, packed.n)
end

local function dispatch(plr: Player, op: string, a: any, b: any)
	if typeof(op) ~= "string" then
		return false, "bad-op"
	end

	if op == "ping" then
		return true, "pong"
	end

	if op == "attach" then
		if isAttached(plr) then
			return true, "already-attached"
		end
		setAttached(plr, true)
		Log("INFO", "Cliente attached:", plr.Name, plr.UserId)
		return true, "attached"
	end

	if op == "detach" then
		if not isAttached(plr) then
			return true, "already-detached"
		end
		setAttached(plr, false)
		Log("INFO", "Cliente detached:", plr.Name, plr.UserId)
		return true, "detached"
	end

	-- Contrato estable para un selector de arquitectura futuro. La GUI actual
	-- no usa estas operaciones, por lo que su comportamiento no cambia.
	if op == "backend-contract" then
		local api = getCoreAPI()
		if not api or type(api.GetBackendContract) ~= "function" then
			return false, "backend-api-unavailable"
		end
		local contract = callCore(api, "GetBackendContract")
		if contract == false then return false, "backend-internal-error" end
		return true, contract
	end

	if op == "backend-list" then
		local api = getCoreAPI()
		if not api or type(api.ListArchitectures) ~= "function" then
			return false, "backend-api-unavailable"
		end
		local architectures = callCore(api, "ListArchitectures")
		if architectures == false then return false, "backend-internal-error" end
		return true, architectures
	end

	if op == "backend-status" then
		local api = getCoreAPI()
		if not api or type(api.GetArchitectureStatus) ~= "function" then
			return false, "backend-api-unavailable"
		end
		local status = callCore(api, "GetArchitectureStatus", a)
		if status == false then return false, "backend-internal-error" end
		return true, status
	end

	if op == "backend-select" then
		if not isAttached(plr) then
			return false, "not-attached"
		end
		if typeof(a) ~= "string" then
			return false, "bad-architecture"
		end
		local api = getCoreAPI()
		if not api or type(api.SelectArchitecture) ~= "function" then
			return false, "backend-api-unavailable"
		end
		local options = b
		if type(b) == "table" then
			options = table.clone(b)
			-- Nunca permitimos que un cliente remoto habilite ejecucion Linux
			-- incompleta; esa opcion queda reservada a codigo de servidor.
			options.allowIncompleteExecution = nil
		end
		return callCore(api, "SelectArchitecture", a, options)
	end

	if op == "backend-control" then
		if not isAttached(plr) then
			return false, "not-attached"
		end
		if typeof(a) ~= "string" then
			return false, "bad-action"
		end
		local api = getCoreAPI()
		if not api then
			return false, "backend-api-unavailable"
		end
		local action = string.lower(a)
		if action == "start" and type(api.StartX86) == "function" then
			return callCore(api, "StartX86")
		end
		if action == "stop" and type(api.StopX86) == "function" then
			return callCore(api, "StopX86")
		end
		return false, "bad-action"
	end

	return false, "unknown-op"
end

-- La misma funcion queda publicada solo en servidor para pruebas y para que
-- otros scripts internos no tengan que simular trafico de red.
RoEmu.RemoteGateDispatch = dispatch
ch.Rpc.OnServerInvoke = dispatch

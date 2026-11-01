--!strict
-- 00_RoEmu_CoreCompat.server.lua
-- Compat layer + publicación en _G.shared.RoEmu_CoreAPI (lo que tus Run*.server.lua esperan).

task.wait()

_G.RoEmu = _G.RoEmu or {}
local RoEmu = _G.RoEmu :: any
local Log = RoEmu.Log or function(...) end

RoEmu.CoreCompat = {}
local CoreCompat = RoEmu.CoreCompat

-- Helper: intenta llamar un método si existe.
local function tryCall(obj: any, methodName: string, ...: any): (boolean, any)
	if obj and typeof(obj[methodName]) == "function" then
		local ok, res = pcall(obj[methodName], obj, ...)
		return ok, res
	end
	return false, nil
end

-- Instala trap handler con firma: (cpu, cause, tval, ...)
function CoreCompat.InstallTrap(core: any, handler: (any, any, any, any?) -> ())
	local ok = false
	ok = ok or select(1, tryCall(core, "setTrapHandler", handler))
	ok = ok or select(1, tryCall(core, "SetTrapHandler", handler))
	ok = ok or select(1, tryCall(core, "onTrap", handler))
	ok = ok or select(1, tryCall(core, "OnTrap", handler))

	if not ok then
		core.__roemu_trap = handler
		Log("WARN", "No encontré método de trap en core; guardé core.__roemu_trap")
	end
end

function CoreCompat.Step(core: any, cycles: number)
	local ok = false
	ok = ok or select(1, tryCall(core, "step", cycles))
	ok = ok or select(1, tryCall(core, "Step", cycles))
	ok = ok or select(1, tryCall(core, "runCycles", cycles))
	ok = ok or select(1, tryCall(core, "RunCycles", cycles))
	ok = ok or select(1, tryCall(core, "tick", cycles))
	ok = ok or select(1, tryCall(core, "Tick", cycles))
	return ok
end

function CoreCompat.RaiseInterrupt(core: any, irq: number)
	local ok = false
	ok = ok or select(1, tryCall(core, "raiseIRQ", irq))
	ok = ok or select(1, tryCall(core, "RaiseIRQ", irq))
	ok = ok or select(1, tryCall(core, "interrupt", irq))
	ok = ok or select(1, tryCall(core, "Interrupt", irq))
	return ok
end

-- =========================================================
-- Publicación legacy: _G.shared.RoEmu_CoreAPI
-- =========================================================
_G.shared = _G.shared or {}
local shared = _G.shared :: any

shared.RoEmu_CoreAPI = shared.RoEmu_CoreAPI or {}
local API = shared.RoEmu_CoreAPI :: any

API.Version = API.Version or "1.0"
API.CoreCompat = CoreCompat
API.Log = RoEmu.Log
API.core = API.core or _G.RoEmuCore -- se refresca en CoreExport también

function API.GetCore()
	return _G.RoEmuCore
end

function API.IsCoreReady()
	return _G.RoEmuCore ~= nil
end

-- Wrappers tolerantes a llamadas con ":" o "."
--  - Dot:   API.Step(core, cycles)
--  - Colon: API:Step(core, cycles)
local function unwrapSelf(selfOrCore: any, maybeCore: any, maybeArg: any)
	if selfOrCore == API then
		return maybeCore, maybeArg
	end
	return selfOrCore, maybeCore
end

function API.Step(selfOrCore: any, maybeCore: any, maybeCycles: any)
	local core, cycles = unwrapSelf(selfOrCore, maybeCore, maybeCycles)
	if core == nil then return false end
	return CoreCompat.Step(core, tonumber(cycles) or 0)
end

function API.InstallTrap(selfOrCore: any, maybeCore: any, maybeHandler: any)
	local core, handler = unwrapSelf(selfOrCore, maybeCore, maybeHandler)
	if core == nil or typeof(handler) ~= "function" then return false end
	CoreCompat.InstallTrap(core, handler)
	return true
end

function API.RaiseInterrupt(selfOrCore: any, maybeCore: any, maybeIrq: any)
	local core, irq = unwrapSelf(selfOrCore, maybeCore, maybeIrq)
	if core == nil then return false end
	return CoreCompat.RaiseInterrupt(core, tonumber(irq) or 0)
end

-- Alias por si tus scripts usan otro nombre
API.RaiseIRQ = API.RaiseInterrupt
API.InstallTrapHandler = API.InstallTrap

Log("INFO", "CoreCompat listo y publicado en _G.shared.RoEmu_CoreAPI")

-- ServerScriptService/RoEmu_Bootstrap.server.lua
local TAG = "[RoEmu_Bootstrap]"
local TIMEOUT = 15

local function log(fmt, ...)
	print(string.format("%s %s", TAG, string.format(fmt, ...)))
end
local function warnf(fmt, ...)
	warn(string.format("%s[WARN] %s", TAG, string.format(fmt, ...)))
end

local function waitFor(getter, timeoutSec)
	local deadline = os.clock() + timeoutSec
	while os.clock() < deadline do
		local v = getter()
		if v ~= nil then return v end
		task.wait(0.1)
	end
	return nil
end

local function listKeys(t, limit)
	limit = limit or 80
	local keys = {}
	for k, v in pairs(t) do
		table.insert(keys, string.format("%s:%s", tostring(k), typeof(v)))
	end
	table.sort(keys)
	if #keys > limit then
		local cut = {}
		for i = 1, limit do cut[i] = keys[i] end
		return table.concat(cut, ", ") .. string.format(" ... (+%d)", #keys - limit)
	end
	return table.concat(keys, ", ")
end

local function pcallTrace(fn, ...)
	local ok, res = pcall(fn, ...)
	if ok then return true, res end
	return false, tostring(res) .. "\n" .. debug.traceback()
end

-- ====== START ======
log("inicio")

_G.shared = _G.shared or {}
_G.shared.RoEmu_State = _G.shared.RoEmu_State or {}
local state = _G.shared.RoEmu_State

if state.BootstrapRan then
	log("ya corrí antes; salgo (BootstrapRan=true)")
	return
end
state.BootstrapRan = true

local core = waitFor(function()
	return _G.shared and _G.shared.RoEmu_CoreAPI
end, TIMEOUT)

if not core then
	warnf("RoEmu_CoreAPI no apareció en %ds; no hago nada.", TIMEOUT)
	return
end

log("CoreAPI typeof=%s", typeof(core))
if typeof(core) == "table" then
	log("CoreAPI keys: %s", listKeys(core, 120))
end

-- Si tus otros scripts ya ejecutaron, esto evita repetir.
_G.shared.RoEmu_Firmware = _G.shared.RoEmu_Firmware or {}
local fw = _G.shared.RoEmu_Firmware

local haveCaribe = (type(fw.CaribeELF) == "string" and #fw.CaribeELF > 0) and (type(fw.VirtDTB) == "string" and #fw.VirtDTB > 0)
local haveSBI    = (type(fw.OpenSBI_FW_DYNAMIC) == "string" and #fw.OpenSBI_FW_DYNAMIC > 0) and (type(fw.VirtDTB) == "string" and #fw.VirtDTB > 0)

log("Firmware present? Caribe=%s OpenSBI=%s (DTB=%s)",
	tostring(type(fw.CaribeELF)=="string" and #fw.CaribeELF or 0),
	tostring(type(fw.OpenSBI_FW_DYNAMIC)=="string" and #fw.OpenSBI_FW_DYNAMIC or 0),
	tostring(type(fw.VirtDTB)=="string" and #fw.VirtDTB or 0)
)

-- Helper: intenta llamar método de core si existe, probando con y sin self.
local function callCoreMethod(methodName, a, b)
	if typeof(core) ~= "table" then
		return false, "CoreAPI no es table"
	end
	local fn = core[methodName]
	if type(fn) ~= "function" then
		return false, methodName .. " no existe o no es function"
	end

	-- 1) sin self
	local ok1, e1 = pcallTrace(fn, a, b)
	if ok1 then return true, "ok(no-self)" end

	-- 2) con self
	local ok2, e2 = pcallTrace(fn, core, a, b)
	if ok2 then return true, "ok(with-self)" end

	return false, string.format("Falló %s:\n- no-self:\n%s\n- with-self:\n%s", methodName, tostring(e1), tostring(e2))
end

-- IMPORTANTE:
-- Tu error anterior “attempt to call a nil value” suele ser por llamar un método que NO existe.
-- Aquí NO llamamos nada que no exista.
-- Si quieres que Bootstrap también dispare el boot (además de tus Run*.server.lua), activa estas banderas:
local AUTO_RUN_CARIBE = false
local AUTO_RUN_OPENSBI = false

if AUTO_RUN_CARIBE and haveCaribe and not state.CaribeRan then
	log("AUTO_RUN_CARIBE: intentando RunCaribeBootX...")
	local ok, msg = callCoreMethod("RunCaribeBootX", fw.CaribeELF, fw.VirtDTB)
	if ok then
		state.CaribeRan = true
		log("RunCaribeBootX OK (%s)", msg)
	else
		warnf("RunCaribeBootX NO: %s", msg)
	end
else
	log("Caribe auto-run skip (AUTO=%s have=%s ran=%s)", tostring(AUTO_RUN_CARIBE), tostring(haveCaribe), tostring(state.CaribeRan))
end

if AUTO_RUN_OPENSBI and haveSBI and not state.OpenSBIRan then
	log("AUTO_RUN_OPENSBI: intentando RunOpenSBI...")
	local ok, msg = callCoreMethod("RunOpenSBI", fw.OpenSBI_FW_DYNAMIC, fw.VirtDTB)
	if ok then
		state.OpenSBIRan = true
		log("RunOpenSBI OK (%s)", msg)
	else
		warnf("RunOpenSBI NO: %s", msg)
	end
else
	log("OpenSBI auto-run skip (AUTO=%s have=%s ran=%s)", tostring(AUTO_RUN_OPENSBI), tostring(haveSBI), tostring(state.OpenSBIRan))
end

log("fin OK")

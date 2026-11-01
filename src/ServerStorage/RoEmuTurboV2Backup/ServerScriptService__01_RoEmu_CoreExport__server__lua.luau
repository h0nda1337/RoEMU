--!strict
-- 01_RoEmu_CoreExport.server.lua
-- Exporta el core en _G.RoEmuCore y también en _G.shared (legacy).

task.wait()

local ReplicatedStorage = game:GetService("ReplicatedStorage")

_G.RoEmu = _G.RoEmu or {}
local RoEmu = _G.RoEmu :: any
local Log = RoEmu.Log or function(...) end

-- ========= CONFIG =========
local CORE_PATH = ReplicatedStorage:WaitForChild("RiscV"):WaitForChild("core") :: ModuleScript
-- ==========================

local function CreateCore()
	local coreMod = require(CORE_PATH)

	if typeof(coreMod) == "function" then
		return coreMod()
	end

	if typeof(coreMod) == "table" and typeof((coreMod :: any).new) == "function" then
		return (coreMod :: any).new()
	end

	if typeof(coreMod) == "table" then
		return coreMod
	end

	error("core module no soportado: " .. typeof(coreMod))
end

if _G.RoEmuCore ~= nil then
	Log("WARN", "RoEmuCore ya existía; no lo recreo")
	-- Aun así: asegúrate de publicarlo en shared
	_G.shared = _G.shared or {}
	(_G.shared :: any).RoEmuCore = _G.RoEmuCore
	if (_G.shared :: any).RoEmu_CoreAPI then
		((_G.shared :: any).RoEmu_CoreAPI :: any).core = _G.RoEmuCore
	end
	return
end

local ok, core = pcall(CreateCore)
if not ok then
	Log("ERROR", "No pude crear RoEmuCore:", core)
	return
end

_G.RoEmuCore = core

-- Publicación legacy
_G.shared = _G.shared or {}
local shared = _G.shared :: any
shared.RoEmuCore = core
if shared.RoEmu_CoreAPI then
	(shared.RoEmu_CoreAPI :: any).core = core
end

Log("INFO", "RoEmuCore exportado (y publicado en _G.shared)")

--!strict
-- RoEmu_OutInit.server.lua
-- Este script solía duplicar remotes/canales. Ahora NO inicializa nada.
-- Déjalo si quieres por compatibilidad, pero no hace trabajo.

task.wait()
_G.RoEmu = _G.RoEmu or {}
local RoEmu = _G.RoEmu :: any
local Log = RoEmu.Log or function(...) end

Log("INFO", "OutInit en modo NO-OP (usa 00_RoEmu_Channel como única init)")

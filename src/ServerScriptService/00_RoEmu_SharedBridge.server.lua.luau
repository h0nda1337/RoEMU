--!strict
-- 00_RoEmu_SharedBridge.server.lua
-- Garantiza la tabla _G.shared (patrón viejo) para compatibilidad.

_G.shared = _G.shared or {}

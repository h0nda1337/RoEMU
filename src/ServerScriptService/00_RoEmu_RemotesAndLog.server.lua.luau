-- ServerScriptService/00_RoEmu_RemotesAndLog.server.lua

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- === Shared seguro (evita asignaciones inválidas) ===
local function getShared()
	local s = rawget(_G, "shared")
	if type(s) ~= "table" then
		s = {}
		rawset(_G, "shared", s)
	end
	return s
end

local Shared = getShared()
Shared.RoEmu = Shared.RoEmu or {}

-- === Crea/Reusa ReplicatedStorage.RoEmu ===
local roemuFolder = ReplicatedStorage:FindFirstChild("RoEmu")
if not roemuFolder then
	roemuFolder = Instance.new("Folder")
	roemuFolder.Name = "RoEmu"
	roemuFolder.Parent = ReplicatedStorage
end

local function ensureChild(className: string, name: string)
	local obj = roemuFolder:FindFirstChild(name)
	if obj and obj.ClassName ~= className then
		obj:Destroy()
		obj = nil
	end
	if not obj then
		obj = Instance.new(className)
		obj.Name = name
		obj.Parent = roemuFolder
	end
	return obj
end

local AttachRF = ensureChild("RemoteFunction", "Attach")
local LogRE    = ensureChild("RemoteEvent", "Log")

-- === Logger (server + opcional clientes) ===
local function logInfo(msg: string)
	local line = ("[RoEmu][INFO] %s"):format(msg)
	print(line)
	-- Si quieres reflejar a clientes:
	-- LogRE:FireAllClients("INFO", msg)
end

local function logErr(msg: string)
	local line = ("[RoEmu][ERR] %s"):format(msg)
	warn(line)
	-- LogRE:FireAllClients("ERR", msg)
end

-- Exponer utilidades
Shared.RoEmu.Folder = roemuFolder
Shared.RoEmu.Remotes = Shared.RoEmu.Remotes or {}
Shared.RoEmu.Remotes.Attach = AttachRF
Shared.RoEmu.Remotes.Log = LogRE
Shared.RoEmu.LogInfo = logInfo
Shared.RoEmu.LogErr = logErr

-- === Handshake Attach (evita rebindeos) ===
if not Shared.RoEmu.__AttachBound then
	Shared.RoEmu.__AttachBound = true

	AttachRF.OnServerInvoke = function(player, payload)
		Shared.RoEmu.AttachedPlayers = Shared.RoEmu.AttachedPlayers or {}
		Shared.RoEmu.AttachedPlayers[player] = true

		logInfo(("Cliente attached: %s %d"):format(player.Name, player.UserId))
		return true
	end
end

logInfo("Remotes&Log listos")

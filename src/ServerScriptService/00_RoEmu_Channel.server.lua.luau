--!strict
-- 00_RoEmu_Channel.server.lua
-- Única fuente de verdad para Remotes. Idempotente (no duplica si ya existen).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local REMOTES_FOLDER_NAME = "RoEmu_Remotes"

local function getOrCreateFolder(parent: Instance, name: string): Folder
	local f = parent:FindFirstChild(name)
	if f and f:IsA("Folder") then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = name
	nf.Parent = parent
	return nf
end

local function getOrCreateRemoteEvent(parent: Instance, name: string): RemoteEvent
	local r = parent:FindFirstChild(name)
	if r and r:IsA("RemoteEvent") then
		return r
	end
	local nr = Instance.new("RemoteEvent")
	nr.Name = name
	nr.Parent = parent
	return nr
end

local function getOrCreateRemoteFunction(parent: Instance, name: string): RemoteFunction
	local r = parent:FindFirstChild(name)
	if r and r:IsA("RemoteFunction") then
		return r
	end
	local nr = Instance.new("RemoteFunction")
	nr.Name = name
	nr.Parent = parent
	return nr
end

-- Global state container
_G.RoEmu = _G.RoEmu or {}
local RoEmu = _G.RoEmu :: any

RoEmu.Channel = RoEmu.Channel or {}
local Channel = RoEmu.Channel

-- Create/Reuse remotes folder (idempotent)
local remotes = getOrCreateFolder(ReplicatedStorage, REMOTES_FOLDER_NAME)
remotes:SetAttribute("__roemu_inited", true)

-- Remotes (nombres estables)
Channel.Folder = remotes
Channel.Log = getOrCreateRemoteEvent(remotes, "Log")         -- server -> client (y opcional client -> server)
Channel.Out = getOrCreateRemoteEvent(remotes, "Out")         -- server -> client (bytes/strings)
Channel.In = getOrCreateRemoteEvent(remotes, "In")           -- client -> server (input)
Channel.Rpc = getOrCreateRemoteFunction(remotes, "Rpc")      -- handshake/attach

-- Simple routing helpers
function Channel:FireLogAll(level: string, msg: string)
	self.Log:FireAllClients(level, msg)
end

function Channel:FireOutAll(payload: string)
	self.Out:FireAllClients(payload)
end

function Channel:FireOutPlayer(plr: Player, payload: string)
	self.Out:FireClient(plr, payload)
end

-- Track attach state (used by RemoteGate/InputGate)
RoEmu.Attached = RoEmu.Attached or {} :: {[number]: boolean} -- by UserId

Players.PlayerRemoving:Connect(function(plr)
	RoEmu.Attached[plr.UserId] = nil
end)

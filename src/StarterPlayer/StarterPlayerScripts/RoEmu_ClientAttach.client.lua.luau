-- StarterPlayerScripts/RoEmu_ClientAttach.client.lua

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function log(msg: string)
	print(("[RoEmu] %s"):format(msg))
end

local roemuFolder = ReplicatedStorage:WaitForChild("RoEmu", 15)
if not roemuFolder then
	warn("[RoEmu][ERR] ReplicatedStorage.RoEmu no apareció (timeout).")
	return
end

local attachRF = roemuFolder:WaitForChild("Attach", 15)
if not attachRF then
	warn("[RoEmu][ERR] ReplicatedStorage.RoEmu.Attach no apareció (timeout).")
	return
end

local ok, res = pcall(function()
	return attachRF:InvokeServer({
		client = "RoEmu_ClientAttach",
		version = 1,
	})
end)

if not ok then
	warn("[RoEmu][ERR] attach InvokeServer falló: " .. tostring(res))
	return
end

log(("attach: %s attached"):format(tostring(res)))

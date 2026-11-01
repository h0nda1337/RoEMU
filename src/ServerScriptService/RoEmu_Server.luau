-- ServerScriptService/RoEmu_Server  (bootstrap sin board)
local RS = game:GetService("ReplicatedStorage")
local RV = RS:WaitForChild("RiscV")

-- (opcional) detectar monitor para log
local ok, monitor = pcall(function()
	return RV:WaitForChild("RoEmu_Monitor", 2)
end)
if ok and monitor then
	print(("[RoEmu_Server] Monitor encontrado en: %s"):format(monitor:GetFullName()))
end

-- Remotos compartidos por todos los demos
local function ensureRemote(name, class)
	local obj = RS:FindFirstChild(name)
	if not obj then
		obj = Instance.new(class)
		obj.Name = name
		obj.Parent = RS
	end
	return obj
end

ensureRemote("RoEmu_Out", "RemoteEvent")
ensureRemote("RoEmu_OutGet", "RemoteFunction")
ensureRemote("RoEmu_Input", "RemoteEvent")

print("[INFO] [RoEmu_Server] Monitor OK.")

-- ServerScriptService/RunOpenSBI.server.lua
local TAG = "RunOpenSBI"

local function ts()
	return string.format("%.3f", os.clock())
end

local function log(msg)
	print(string.format("%s -- [%s] %s", ts(), TAG, msg))
end

local function fatal(msg)
	error(string.format("[%s][FATAL] %s", TAG, msg), 0)
end

local function waitChild(parent, name, timeout)
	local obj = parent:WaitForChild(name, timeout)
	if not obj then
		fatal(("WaitForChild(%s) timeout en %s"):format(name, parent:GetFullName()))
	end
	return obj
end

local function findFirmwareNode(fwFolder, wantedName)
	local n = fwFolder:FindFirstChild(wantedName)
	if n then return n end
	if wantedName:sub(1, 7) == "Return_" then
		local alt = wantedName:sub(8)
		n = fwFolder:FindFirstChild(alt)
		if n then return n end
	end
	return nil
end

local function getCore(timeout)
	timeout = timeout or 10
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		local shared = rawget(_G, "shared")
		if shared and type(shared) == "table" then
			local core = rawget(shared, "RoEmu_CoreAPI")
			if type(core) == "table" then
				return core
			end
		end
		task.wait(0.05)
	end
	return nil
end

local function ensureFwTable()
	_G.shared = _G.shared or {}
	_G.shared.RoEmu_Firmware = _G.shared.RoEmu_Firmware or {}
	return _G.shared.RoEmu_Firmware
end

local function main()
	log("inicio")

	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerStorage = game:GetService("ServerStorage")

	local RiscV = waitChild(ReplicatedStorage, "RiscV", 30)
	local fwFolder = waitChild(RiscV, "firmware", 30)

	local BlobDecoder
	do
		local libFolder = waitChild(ServerStorage, "Lib", 30)
		local mod = waitChild(libFolder, "BlobDecoder", 30)
		local ok, ret = pcall(require, mod)
		if not ok then
			fatal(("require(ServerStorage.Lib.BlobDecoder) falló: %s"):format(tostring(ret)))
		end
		BlobDecoder = ret
	end

	local sbiNode = findFirmwareNode(fwFolder, "Return_OpenSBI_FW_DYNAMIC_BIN")
	local dtbNode = findFirmwareNode(fwFolder, "Return_QEMUvirt_DTB")
	if not sbiNode then fatal("No encontré Return_OpenSBI_FW_DYNAMIC_BIN (ni alterno sin Return_)") end
	if not dtbNode then fatal("No encontré Return_QEMUvirt_DTB (ni alterno sin Return_)") end

	log("OpenSBI node: " .. sbiNode:GetFullName() .. " (" .. sbiNode.ClassName .. ")")
	log("DTB    node: " .. dtbNode:GetFullName() .. " (" .. dtbNode.ClassName .. ")")

	local fwBin, fwChunks = BlobDecoder.decode(sbiNode)
	local dtb, dtbChunks  = BlobDecoder.decode(dtbNode)

	log(("decode FW:  %d bytes | chunks=%d | from=%s"):format(#fwBin, fwChunks, sbiNode:GetFullName()))
	log(("decode DTB: %d bytes | chunks=%d | from=%s"):format(#dtb, dtbChunks, dtbNode:GetFullName()))
	log("FW  head: " .. BlobDecoder.head(fwBin, 16))
	log("DTB head: " .. BlobDecoder.head(dtb, 16))

	if #fwBin == 0 then
		fatal("FW es 0 bytes (Return_OpenSBI_FW_DYNAMIC_BIN no está devolviendo datos o decode falló)")
	end
	if #dtb == 0 then
		fatal("DTB es 0 bytes (Return_QEMUvirt_DTB no está devolviendo datos o decode falló)")
	end

	local fw = ensureFwTable()
	fw.OpenSBI_FW_DYNAMIC = fwBin
	fw.VirtDTB = dtb
	log("publicado en _G.shared.RoEmu_Firmware.{OpenSBI_FW_DYNAMIC,VirtDTB}")

	local core = getCore(10)
	if not core then
		log("CoreAPI no disponible (aún). Skip core.RunOpenSBI.")
		return
	end

	if type(core.RunOpenSBI) == "function" then
		log("invocando core.RunOpenSBI(...)")
		local ok, err = pcall(function()
			core.RunOpenSBI(script, fwBin, dtb)
		end)
		if ok then
			log("core.RunOpenSBI(self,fw,dtb) OK")
		else
			fatal("core.RunOpenSBI falló: " .. tostring(err))
		end
	else
		log("CoreAPI no tiene RunOpenSBI(). (keys cambiaron?)")
	end
end

local ok, err = pcall(main)
if not ok then
	warn(string.format("%s -- [%s][TOP] %s", ts(), TAG, tostring(err)))
end
-- ServerScriptService/RunCaribeBootX.server.lua
local TAG = "RunCaribeBootX"

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
	-- primero exacto, luego alterno sin "Return_"
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

	local caribeNode = findFirmwareNode(fwFolder, "Return_Caribe_ELF")
	local dtbNode    = findFirmwareNode(fwFolder, "Return_QEMUvirt_DTB")
	if not caribeNode then fatal("No encontré Return_Caribe_ELF (ni alterno sin Return_)") end
	if not dtbNode then fatal("No encontré Return_QEMUvirt_DTB (ni alterno sin Return_)") end

	log("Caribe node: " .. caribeNode:GetFullName() .. " (" .. caribeNode.ClassName .. ")")
	log("DTB   node: " .. dtbNode:GetFullName() .. " (" .. dtbNode.ClassName .. ")")

	local elf, elfChunks = BlobDecoder.decode(caribeNode)
	local dtb, dtbChunks = BlobDecoder.decode(dtbNode)

	log(("decode ELF: %d bytes | chunks=%d | from=%s"):format(#elf, elfChunks, caribeNode:GetFullName()))
	log(("decode DTB: %d bytes | chunks=%d | from=%s"):format(#dtb, dtbChunks, dtbNode:GetFullName()))
	log("ELF head: " .. BlobDecoder.head(elf, 16))
	log("DTB head: " .. BlobDecoder.head(dtb, 16))

	if #elf == 0 then
		fatal("ELF es 0 bytes (Return_Caribe_ELF no está devolviendo datos o decode falló)")
	end
	if #dtb == 0 then
		fatal("DTB es 0 bytes (Return_QEMUvirt_DTB no está devolviendo datos o decode falló)")
	end

	local fw = ensureFwTable()
	fw.CaribeELF = elf
	fw.VirtDTB = dtb
	log("publicado en _G.shared.RoEmu_Firmware.{CaribeELF,VirtDTB}")

	local core = getCore(10)
	if not core then
		log("CoreAPI no disponible (aún). Skip core.RunCaribeBootX.")
		return
	end

	-- Llamada “dura” con pcall + traceback
	if type(core.RunCaribeBootX) == "function" then
		log("invocando core.RunCaribeBootX(...)")
		local ok, err = pcall(function()
			core.RunCaribeBootX(script, elf, dtb)
		end)
		if ok then
			log("core.RunCaribeBootX(self,elf,dtb) OK")
		else
			fatal("core.RunCaribeBootX falló: " .. tostring(err))
		end
	else
		log("CoreAPI no tiene RunCaribeBootX(). (keys cambiaron?)")
	end
end

local ok, err = pcall(main)
if not ok then
	warn(string.format("%s -- [%s][TOP] %s", ts(), TAG, tostring(err)))
end
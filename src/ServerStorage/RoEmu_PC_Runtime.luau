--!native
--!optimize 2
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Machine = require(script.Parent.RoEmu_PC_Machine)
local DiskLoader = require(script.Parent.RoEmu_PC_DiskLoader)
local FrameStream = require(script.Parent.RoEmu_PC_FrameStream)
local Runtime = {}
local active
local paused = false

function Runtime.Pause()
	paused = true
end

function Runtime.Resume()
	if active then active.pitLastHostTime = active.hostClock();active.clockMinimum=0 end
	paused = false
end

local function channel()
	local shared = rawget(_G, "RoEmu")
	return shared and shared.Channel
end

function Runtime.Start(options)
	if active then return false, "pc-already-created" end
	options=options or {}
	local disk = DiskLoader.new(243279276, function(index)
		return script.Parent:WaitForChild(string.format("RoEmu_Win95_Disk%04d", index)).Value
	end, true)
	local pending = {}
	local systemROM=script.Parent:FindFirstChild("RoEmu_PC_SystemFirmware")
	local videoROM=script.Parent:FindFirstChild("RoEmu_PC_VideoFirmware")
	local machine = Machine.new(disk, {
		ramSize = 16 * 1024 * 1024,
		realtimeClock = true,
		systemFirmware=options.systemFirmware or (systemROM and systemROM.Value),
		videoFirmware=options.videoFirmware or (videoROM and videoROM.Value),
		onOutput = function(value) pending[#pending + 1] = value end,
	})
	machine.cpu.options.maxRepIterationsPerStep = 1024
	active = machine
	local video = Instance.new("RemoteEvent")
	video.Name = "RoEmu_PCVideo"
	video.Parent = ReplicatedStorage
	local frameRequests = {}
	local inputRates={}
	video.OnServerEvent:Connect(function(player, operation,a,b,c)
		if operation=="key" or operation=="mouse" or operation=="pointer" then
			local now=os.clock()
			local rate=inputRates[player]
			if not rate or now-rate.start>=1 then rate={start=now,count=0};inputRates[player]=rate end
			if rate.count>=240 then return end
			if operation=="key" then
				if type(a)~="number" or a%1~=0 or a<1 or a>0x7F or type(b)~="boolean" or type(c)~="boolean" then return end
			elseif operation=="mouse" then
				if type(a)~="number" or type(b)~="number" or type(c)~="number" or a~=a or b~=b or c%1~=0 or c<0 or c>7 or math.abs(a)>255 or math.abs(b)>255 then return end
			else
				if type(a)~="number" or type(b)~="number" or type(c)~="number" or a%1~=0 or b%1~=0 or a<0 or b<0 or a>65535 or b>65535 or c%1~=0 or c<0 or c>7 then return end
			end
			rate.count+=1
			_G.RoEmu.InputQueue=_G.RoEmu.InputQueue or {}
			table.insert(_G.RoEmu.InputQueue,{operation,a,b,c})
			return
		end
		if operation ~= "frame" or os.clock() - (frameRequests[player] or -math.huge) < 1 then return end
		frameRequests[player] = os.clock()
		local pixels, palette, width, height, format = machine.vga:snapshot()
		if pixels then video:FireClient(player, pixels, palette, width, height, format) end
	end)
	_G.RoEmu = _G.RoEmu or {}
	_G.RoEmu.ActiveArchitecture = "i386"
	_G.RoEmu.PCMachine = machine
	_G.RoEmu.PCStatus = { phase = "executing-mbr", architecture = "i386", windowsDesktopObserved = false }
	local output = channel()
	if output then output:FireOutAll("\n[RoEMU PC] Arranque real de Windows 95: disco -> MBR -> IO.SYS\n") end
	local lastStatus = 0
	local lastVideo,previousGeneration,showingVideo=0,nil,false
	local frames=FrameStream.new()
	local connection
	connection = RunService.Heartbeat:Connect(function(deltaTime)
		if paused then return end
		local deadline = os.clock() + math.clamp(deltaTime*0.75,0.004,0.016)
		local result
		local ok, failure = pcall(function()
			local input = _G.RoEmu.InputQueue
			if type(input) == "table" then
				for i=1,#input do
					local byte = input[i]
					if type(byte)=="table" then
						if byte[1]=="key" then machine:queueKey(byte[2],byte[3],byte[4])
						elseif byte[1]=="mouse" then machine:queueMouse(byte[2],byte[3],byte[4])
						elseif byte[1]=="pointer" then machine:queuePointer(byte[2],byte[3],byte[4]) end
					else machine:queueTextByte(byte) end
				end
				table.clear(input)
			end
			result = machine:runSlice(deadline)
		end)
		if #pending > 0 then
			local value = table.concat(pending)
			table.clear(pending)
			local ch = channel()
			if ch then ch:FireOutAll(value) end
		end
		local faulted=not ok or (result and result.kind~="ok" and result.kind~="halted")
		if os.clock() - lastStatus >= 0.5 or faulted then
			lastStatus = os.clock()
			local status = machine:getStatus()
			status.windowsDesktopObserved = false
			status.phase = machine.waitingKeyboard and "waiting-keyboard" or result and result.kind == "halted" and "waiting-interrupt" or "executing"
			status.architecture = "i386"
			status.videoMode = machine.videoMode
			_G.RoEmu.PCStatus = status
		end
		if os.clock()-lastVideo>=1/12 and previousGeneration~=machine.vga.generation then
			lastVideo=os.clock();previousGeneration=machine.vga.generation
			local pixels,palette,width,height,format=machine.vga:snapshot()
			if pixels then
				local payload,rectangle=frames:encode(pixels,palette,width,height,format)
				if payload then video:FireAllClients(payload,palette,width,height,format,rectangle);showingVideo=true end
			elseif showingVideo then video:FireAllClients(false);showingVideo=false;frames:reset() end
		end
		if faulted then
			connection:Disconnect()
			_G.RoEmu.PCStatus.phase = "faulted"
			local reason = not ok and tostring(failure) or tostring(result.detail or result.message or result.kind)
			_G.RoEmu.PCStatus.error = reason
			local ch = channel()
			if ch then ch:FireOutAll("\n[RoEMU PC] Detenido: " .. reason .. "\n") end
			warn("[RoEMU PC] " .. reason)
		end
	end)
	return true, _G.RoEmu.PCStatus
end

return Runtime

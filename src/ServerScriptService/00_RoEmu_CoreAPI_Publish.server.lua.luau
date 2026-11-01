-- ServerScriptService/00_RoEmu_CoreAPI_Publish.server.lua

-- Publica: _G.shared.RoEmu_CoreAPI
-- Incluye wrappers para RunOpenSBI / RunCaribeBootX y almacenamiento mínimo de blobs.

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

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

_G.RoEmu = _G.RoEmu or {}
local Runtime = _G.RoEmu
Runtime.ActiveArchitecture = Runtime.ActiveArchitecture or "riscv32"

local function logInfo(msg: string)
	print(("[RoEmu][CoreAPI] [INFO] %s"):format(msg))
end

local function logErr(msg: string)
	warn(("[RoEmu][CoreAPI] [ERR] %s"):format(msg))
end

-- CoreAPI: compatible y tolerante (si no existe Core real, guarda blobs)
local CoreAPI = {}
CoreAPI.Version = 3
CoreAPI.ContractRevision = 4
CoreAPI.State = {
	blobs = {}, -- name -> string|buffer
	activeArchitecture = Runtime.ActiveArchitecture,
	x86Available = false,
	x86Machine = nil,
	x86Running = false,
	x86SchedulerGeneration = 0,
}

local function bytesLen(x)
	if type(x) == "string" then
		return #x
	end
	if typeof(x) == "buffer" then
		return buffer.len(x)
	end
	return 0
end

function CoreAPI:SetBlob(name: string, blob)
	self.State.blobs[name] = blob
end

function CoreAPI:GetBlob(name: string)
	return self.State.blobs[name]
end

-- Intenta llamar a un core real si lo publicaste en otro script
function CoreAPI:_tryCore(methodName: string, ...)
	local core = rawget(Shared, "RoEmuCore") or (Shared.RoEmu and Shared.RoEmu.Core)
	if core and type(core) == "table" then
		local fn = core[methodName]
		if type(fn) == "function" then
			local ok, res = pcall(fn, core, ...)
			if ok then
				return true, res
			end
			logErr(("Core.%s falló: %s"):format(methodName, tostring(res)))
		end
	end
	return false, nil
end

-- === Wrappers usados por tus runners ===
function CoreAPI:BootOpenSBI(fwBytes, dtbBytes)
	Runtime.ActiveArchitecture = "riscv32"
	self.State.activeArchitecture = "riscv32"
	self.State.x86Running = false
	self:SetBlob("opensbi_fw", fwBytes or "")
	self:SetBlob("dtb", dtbBytes or "")

	-- Si existe core real con método compatible, lo intenta
	self:_tryCore("BootOpenSBI", fwBytes, dtbBytes)
	return true
end

function CoreAPI:BootCaribeBootX(elfBytes, dtbBytes)
	Runtime.ActiveArchitecture = "riscv32"
	self.State.activeArchitecture = "riscv32"
	self.State.x86Running = false
	self:SetBlob("caribe_elf", elfBytes or "")
	self:SetBlob("dtb", dtbBytes or "")

	self:_tryCore("BootCaribeBootX", elfBytes, dtbBytes)
	return true
end

-- === Registro headless de arquitecturas ===
-- i386 vive en modulos separados dentro de ServerStorage. No se publica en
-- _G.RoEmuCore porque los parches OpenSBI/Sv32 observan exclusivamente ese
-- nombre y deben continuar trabajando solo con RISC-V.
local X86Platform = nil
do
	local module = ServerStorage:FindFirstChild("RoEmu_i386_Platform")
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" and type(result.new) == "function" then
			X86Platform = result
			CoreAPI.State.x86Available = true
		else
			logErr("No se pudo cargar el backend i386: " .. tostring(result))
		end
	end
end

local function normalizeArchitecture(name)
	name = string.lower(tostring(name or ""))
	if name == "riscv" or name == "rv32" or name == "rv32imac" then
		return "riscv32"
	end
	if name == "x86" or name == "x86-32" or name == "80386" then
		return "i386"
	end
	return name
end

local function copyOptions(source)
	local result = {}
	for key, value in pairs(type(source) == "table" and source or {}) do
		result[key] = value
	end
	return result
end

local function deepCopy(source, seen)
	if type(source) ~= "table" then return source end
	seen = seen or {}
	if seen[source] then return seen[source] end
	local result = {}
	seen[source] = result
	for key, value in pairs(source) do
		result[deepCopy(key, seen)] = deepCopy(value, seen)
	end
	return result
end

local function compactCaribeStatus()
	local runtimeStatus = type(Runtime.CaribeOSStatus) == "table"
		and deepCopy(Runtime.CaribeOSStatus) or {}
	runtimeStatus.schema = runtimeStatus.schema or 1
	runtimeStatus.id = "caribeos-rv32"
	runtimeStatus.architecture = "rv32imacsu"
	runtimeStatus.bootChain = "OpenSBI -> CaribeBootX -> XNU-CaribeOS -> GNU Bash"
	runtimeStatus.phase = runtimeStatus.phase or "waiting-core"
	runtimeStatus.xnuBased = true
	runtimeStatus.darwinLineage = true
	runtimeStatus.macOS = false
	runtimeStatus.macOSCompatible = false
	runtimeStatus.compatibilityNote = runtimeStatus.compatibilityNote
		or "XNU/Darwin RV32 experimental; no ejecuta binarios ni interfaces de macOS"
	return runtimeStatus
end

local function compactX86Status(machine)
	if machine == nil then
		return {
			created = false,
			phase = "not-created",
			running = false,
			halted = false,
		}
	end
	local status = machine:getStatus()
	local phase
	if status.lastException ~= nil then
		phase = "faulted"
	elseif CoreAPI.State.x86Running == true then
		phase = "executing"
	elseif status.halted then
		phase = "halted"
	elseif status.loader ~= nil then
		phase = "prepared"
	elseif status.lastRun ~= nil then
		phase = "stopped"
	else
		phase = "created"
	end
	local guest = nil
	if status.loader ~= nil then
		guest = {
			kind = status.loader.guestKind or status.loader.format,
			executionSupported = status.loader.executionComplete ~= false,
			bootObserved = status.loader.bootObserved == true,
			userspaceObserved = status.loader.userspaceObserved == true,
		}
	end
	return {
		created = true,
		phase = phase,
		runningMeaning = "scheduler-executing-instructions",
		backendVersion = status.version,
		running = CoreAPI.State.x86Running == true,
		halted = status.halted,
		eip = status.eip,
		eflags = status.eflags,
		instructions = status.instructions,
		cycles = status.cycles,
		ramBytes = status.ramBytes,
		rxPending = status.rxPending,
		exitCode = status.exitCode,
		loader = status.loader,
		guest = guest,
		lastRun = status.lastRun,
		lastException = status.lastException,
	}
end

local function clearSharedInput()
	local runtime = rawget(_G, "RoEmu")
	local queue = type(runtime) == "table" and runtime.InputQueue or nil
	if type(queue) ~= "table" then return 0 end
	local removed = #queue
	table.clear(queue)
	return removed
end

local function dynamicChannel()
	local runtime = rawget(_G, "RoEmu")
	if type(runtime) ~= "table" then return nil end
	return runtime.Channel
end

local function flushX86Output(machine)
	local serialText = machine:drainOutput("serial")
	if serialText ~= "" then
		local channel = dynamicChannel()
		if channel and type(channel.FireOutAll) == "function" then
			channel:FireOutAll(serialText)
		end
	end
	local debugText = machine:drainOutput("debug")
	if debugText ~= "" then
		print("[RoEmu][i386][debug-e9] " .. string.gsub(debugText, "\r?\n$", ""))
	end
end

local function pumpSharedInput(machine)
	local runtime = rawget(_G, "RoEmu")
	local queue = type(runtime) == "table" and runtime.InputQueue or nil
	if type(queue) ~= "table" or #queue == 0 then return end
	local bytes = table.create(#queue)
	for index = 1, #queue do
		bytes[index] = queue[index]
		queue[index] = nil
	end
	machine:feedInput(bytes)
end

local function startX86Scheduler(options)
	local state = CoreAPI.State
	local machine = state.x86Machine
	if machine == nil then return false, "x86-machine-not-created" end
	if machine.cpu.halted then return false, "x86-machine-halted" end
	if machine.lastLoader and machine.lastLoader.executionComplete == false
		and not (type(options) == "table" and options.allowIncompleteExecution == true) then
		return false, "x86-loader-execution-incomplete"
	end
	if Runtime.ActiveArchitecture ~= "i386" then clearSharedInput() end
	Runtime.ActiveArchitecture = "i386"
	state.activeArchitecture = "i386"
	state.x86SchedulerGeneration += 1
	local generation = state.x86SchedulerGeneration
	state.x86Running = true

	task.spawn(function()
		while state.x86Running and state.x86Machine == machine
			and state.x86SchedulerGeneration == generation do
			if Runtime.ActiveArchitecture == "i386" then
				pumpSharedInput(machine)
				local result = machine:runSlice(250000, 0.012)
				flushX86Output(machine)
				if result.kind ~= "limit" and result.kind ~= "timeslice" then
					state.x86Running = false
					if result.kind ~= "halted" then
						logErr("i386 se detuvo: " .. tostring(result.kind))
					end
					break
				end
			end
			RunService.Heartbeat:Wait()
		end
		flushX86Output(machine)
	end)
	return true, compactX86Status(machine)
end

function CoreAPI:ListArchitectures()
	return {
		{
			id = "riscv32",
			label = "RISC-V RV32IMACSU / CaribeOS",
			available = true,
			default = true,
			active = Runtime.ActiveArchitecture == "riscv32",
			boot = "OpenSBI -> CaribeBootX -> XNU-CaribeOS -> GNU Bash",
			maturity = "experimental-guest",
			backendMaturity = "stable",
			guestMaturity = "experimental",
			guest = "caribeos-rv32",
			xnuBased = true,
			macOS = false,
			macOSCompatible = false,
			headless = false,
		},
		{
			id = "i386",
			label = "Intel 80386 (32-bit)",
			available = self.State.x86Available,
			default = false,
			active = Runtime.ActiveArchitecture == "i386",
			boot = "flat / ELF32; Linux bzImage direct32 loader only",
			maturity = "experimental",
			headless = true,
			backendVersion = X86Platform and X86Platform.VERSION or nil,
			linuxBootComplete = false,
		},
	}
end

function CoreAPI:GetRV32Capabilities()
	local status = compactCaribeStatus()
	return {
		schema = 1,
		architecture = "rv32imacsu",
		available = true,
		default = true,
		ramBytes = 128 * 1024 * 1024,
		mmu = "Sv32",
		privilegeModes = { "M", "S", "U" },
		boot = "OpenSBI -> CaribeBootX -> XNU-CaribeOS -> GNU Bash",
		guest = "caribeos-rv32",
		bootProfile = "process-gate-11",
		interactive = true,
		prompt = "bash-5.3$ ",
		xnuBased = true,
		darwinLineage = true,
		macOS = false,
		macOSCompatible = false,
		macOSCapabilityPhase = "xnu-darwin-rv32-foundation",
		storage = {
			kind = "virtio-blk",
			format = "HFS+",
			readOnly = true,
			logicalBytes = 67108864,
		},
		status = status,
		apiVersion = self.Version,
		contractRevision = self.ContractRevision,
	}
end

function CoreAPI:GetCaribeOSCapabilities()
	return self:GetRV32Capabilities()
end

function CoreAPI:GetX86Capabilities()
	local capabilities = X86Platform and deepCopy(X86Platform.CAPABILITIES) or {
		schema = 1,
		architecture = "i386",
		maturity = "experimental",
		headless = true,
	}
	capabilities.available = self.State.x86Available
	capabilities.backendVersion = X86Platform and X86Platform.VERSION or nil
	capabilities.apiVersion = self.Version
	return capabilities
end

-- Contrato serializable para que una GUI futura no tenga que conocer detalles
-- internos del emulador ni buscar ModuleScripts por nombre.
function CoreAPI:GetBackendContract()
	return {
		schema = 1,
		apiVersion = self.Version,
		contractRevision = self.ContractRevision,
		defaultArchitecture = "riscv32",
		activeArchitecture = Runtime.ActiveArchitecture,
		architectures = self:ListArchitectures(),
		riscv32 = self:GetRV32Capabilities(),
		caribeOS = self:GetCaribeOSCapabilities(),
		x86 = self:GetX86Capabilities(),
		client = {
			remoteFolder = "ReplicatedStorage/RoEmu_Remotes",
			rpc = "Rpc",
			output = "Out",
			input = "In",
			inputCall = { kind = "bytes", payloadType = "string", maxBytes = 4096 },
			outputPayload = "legacy-string",
			rpcOperations = {
				"attach",
				"detach",
				"backend-contract",
				"backend-list",
				"backend-status",
				"backend-select",
				"backend-control",
			},
			rpcDetails = {
				backendSelect = { op = "backend-select", arg1 = "architecture", arg2 = "options" },
				backendControl = { op = "backend-control", target = "i386", arg1 = "start-or-stop" },
			},
		},
		serverMethods = {
			"GetBackendContract",
			"ListArchitectures",
			"GetArchitectureStatus",
			"GetRV32Capabilities",
			"GetCaribeOSCapabilities",
			"SelectArchitecture",
			"CreateX86",
			"BootX86Flat",
			"BootX86ELF",
			"PrepareX86LinuxBzImage",
			"BootX86Linux",
			"StartX86",
			"StopX86",
			"FeedX86Input",
			"RunX86SelfTest",
			"RunX86Diagnostics",
		},
		compatibility = {
			existingGuiChanged = false,
			riscv32RemainsDefault = true,
			opensbiPathPreserved = true,
			previousLinuxGuestReplaced = true,
			xnuDarwinFoundationStarted = true,
			macOS = false,
			macOSCompatible = false,
		},
	}
end

function CoreAPI:GetArchitectureStatus(name)
	local selected = normalizeArchitecture(name)
	if selected == "" then selected = Runtime.ActiveArchitecture end
	if selected == "i386" then
		local status = compactX86Status(self.State.x86Machine)
		status.id = "i386"
		status.available = self.State.x86Available
		status.active = Runtime.ActiveArchitecture == "i386"
		return status
	end
	if selected == "riscv32" then
		local core = rawget(Shared, "RoEmuCore")
		local cpu = type(core) == "table" and core.cpu or nil
		local guest = compactCaribeStatus()
		return {
			id = "riscv32",
			available = true,
			active = Runtime.ActiveArchitecture == "riscv32",
			created = core ~= nil,
			running = cpu ~= nil and cpu.halted ~= true,
			halted = cpu ~= nil and cpu.halted == true,
			pc = cpu and cpu.pc or nil,
			instructions = cpu and cpu.instret or nil,
			guest = guest,
			phase = guest.phase,
			bootComplete = guest.bootComplete == true,
		}
	end
	return { id = selected, available = false, active = false, error = "unknown-architecture" }
end

function CoreAPI:CreateX86(options)
	if not self.State.x86Available or X86Platform == nil then
		return false, "i386-backend-unavailable"
	end
	local machineOptions = copyOptions(options)
	local requestedRAM = tonumber(machineOptions.ramSize) or (64 * 1024 * 1024)
	machineOptions.ramSize = math.clamp(math.floor(requestedRAM), 2 * 1024 * 1024, 128 * 1024 * 1024)
	local ok, machineOrError = pcall(X86Platform.new, machineOptions)
	if not ok then
		return false, tostring(machineOrError)
	end
	self.State.x86SchedulerGeneration += 1
	self.State.x86Running = false
	self.State.x86Machine = machineOrError
	Shared.RoEmu_i386 = machineOrError
	return true, machineOrError
end

function CoreAPI:GetX86Machine()
	return self.State.x86Machine
end

function CoreAPI:SelectArchitecture(name, options)
	local selected = normalizeArchitecture(name)
	if selected == "riscv32" then
		self.State.x86SchedulerGeneration += 1
		self.State.x86Running = false
		if Runtime.ActiveArchitecture ~= "riscv32" then clearSharedInput() end
		Runtime.ActiveArchitecture = "riscv32"
		self.State.activeArchitecture = "riscv32"
		return true, self:GetArchitectureStatus("riscv32")
	end
	if selected ~= "i386" then
		return false, "unknown-architecture"
	end
	if not self.State.x86Available then
		return false, "i386-backend-unavailable"
	end
	if self.State.x86Machine == nil then
		local created, machineOrError = self:CreateX86(options)
		if not created then return false, machineOrError end
	end
	if type(options) == "table" and options.start == true
		and self.State.x86Machine.lastLoader ~= nil then
		return startX86Scheduler(options)
	end
	if Runtime.ActiveArchitecture ~= "i386" then clearSharedInput() end
	Runtime.ActiveArchitecture = "i386"
	self.State.activeArchitecture = "i386"
	return true, self:GetArchitectureStatus("i386")
end

function CoreAPI:StartX86(options)
	if self.State.x86Machine == nil then
		return false, "x86-machine-not-created"
	end
	return startX86Scheduler(options)
end

function CoreAPI:StopX86()
	self.State.x86SchedulerGeneration += 1
	self.State.x86Running = false
	if self.State.x86Machine then self.State.x86Machine:stop() end
	return true, self:GetArchitectureStatus("i386")
end

function CoreAPI:FeedX86Input(data)
	if self.State.x86Machine == nil then return false, "x86-machine-not-created" end
	return true, self.State.x86Machine:feedInput(data)
end

local function prepareX86Machine(api, options)
	local created, machineOrError = api:CreateX86(type(options) == "table" and options.machine or options)
	if not created then return nil, machineOrError end
	return machineOrError, nil
end

function CoreAPI:BootX86Flat(image, options)
	options = type(options) == "table" and options or {}
	local machine, failure = prepareX86Machine(self, options)
	if not machine then return false, failure end
	local ok, loader = pcall(machine.loadFlat, machine, image, options.loadAddress, options.entry)
	if not ok then return false, tostring(loader) end
	if options.autoStart == false then return true, loader end
	local started, status = startX86Scheduler(options)
	return started, status, loader
end

function CoreAPI:BootX86ELF(image, options)
	options = type(options) == "table" and options or {}
	local machine, failure = prepareX86Machine(self, options)
	if not machine then return false, failure end
	local ok, loader = pcall(machine.loadELF32, machine, image)
	if not ok then return false, tostring(loader) end
	if options.autoStart == false then return true, loader end
	local started, status = startX86Scheduler(options)
	return started, status, loader
end

function CoreAPI:BootX86Linux(bzImage, options)
	options = type(options) == "table" and options or {}
	local machine, failure = prepareX86Machine(self, options)
	if not machine then return false, failure end
	local ok, loader = pcall(machine.prepareLinuxBzImage, machine, bzImage, options)
	if not ok then return false, tostring(loader) end
	-- El cargador deja boot_params y el punto de entrada listos, pero el CPU no
	-- tiene paginacion ni el conjunto completo de dispositivos de un PC Linux.
	-- Por eso preparar es seguro y arrancar requiere una opcion explicita.
	if options.autoStart ~= true then return true, loader end
	if options.allowIncompleteExecution ~= true then
		return false, "x86-linux-execution-incomplete", loader
	end
	local started, status = startX86Scheduler(options)
	return started, status, loader
end

function CoreAPI:PrepareX86LinuxBzImage(bzImage, options)
	local prepareOptions = copyOptions(options)
	prepareOptions.autoStart = false
	prepareOptions.allowIncompleteExecution = nil
	return self:BootX86Linux(bzImage, prepareOptions)
end

function CoreAPI:RunX86SelfTest()
	if not self.State.x86Available or X86Platform == nil then
		return false, "i386-backend-unavailable"
	end
	local machine = X86Platform.new({ ramSize = 2 * 1024 * 1024 })
	local ok, report = machine:selfTest()
	return ok, report
end

function CoreAPI:RunX86Diagnostics()
	if not self.State.x86Available or X86Platform == nil then
		return false, "i386-backend-unavailable"
	end
	local machine = X86Platform.new({ ramSize = 2 * 1024 * 1024 })
	local ok, report = machine:runDiagnostic()
	return ok, report
end

function CoreAPI:BootArchitecture(name, image, options)
	local selected = normalizeArchitecture(name)
	if selected == "i386" then
		local format = type(options) == "table" and string.lower(tostring(options.format or "flat")) or "flat"
		if format == "elf" or format == "elf32" then return self:BootX86ELF(image, options) end
		if format == "linux" or format == "bzimage" then return self:BootX86Linux(image, options) end
		return self:BootX86Flat(image, options)
	end
	return false, "use BootOpenSBI for riscv32"
end

-- Alias por compatibilidad
CoreAPI.RunOpenSBI = CoreAPI.BootOpenSBI
CoreAPI.RunCaribeBootX = CoreAPI.BootCaribeBootX

-- Publicar SIEMPRE (para que los runners no fallen)
Shared.RoEmu_CoreAPI = CoreAPI
logInfo(("Publicado _G.shared.RoEmu_CoreAPI v%d (CoreCompat listo)."):format(CoreAPI.Version))

-- Opcional: marca listo
Shared.RoEmu = Shared.RoEmu or {}
Shared.RoEmu.CoreAPIReady = true
Runtime.BackendAPI = CoreAPI

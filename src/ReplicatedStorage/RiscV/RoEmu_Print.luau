-- ReplicatedStorage/RiscV/RoEmu_Print
-- Con RemoteEvent (stream) + RemoteFunction (snapshot) para clientes que se conectan tarde.

local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local IS_SERVER = RunService:IsServer()
local IS_CLIENT = RunService:IsClient()

-- RemoteEvent: stream de texto
local RE = RS:FindFirstChild("RoEmu_PrintRE")
if not RE and IS_SERVER then
	RE = Instance.new("RemoteEvent")
	RE.Name = "RoEmu_PrintRE"
	RE.Parent = RS
end

-- RemoteFunction: snapshot del buffer actual
local RF = RS:FindFirstChild("RoEmu_PrintGet")
if not RF and IS_SERVER then
	RF = Instance.new("RemoteFunction")
	RF.Name = "RoEmu_PrintGet"
	RF.Parent = RS
	RF.OnServerInvoke = function()
		return table.concat(M._buffer)
	end
end

local M = {
	_buffer = {},
	_monitor = nil,
	_maxBuffer = 8192,
	_newline = "\n",
	_mirror = false,
	_mirror_linebuf = "",
}

function M.attach(monitorInstance)
	M._monitor = monitorInstance
	if monitorInstance and (monitorInstance:IsA("TextLabel") or monitorInstance:IsA("TextBox")) then
		monitorInstance.Text = table.concat(M._buffer)
	end
	return true
end

function M.mirrorToOutput(enable) M._mirror = not not enable end

function M.clear()
	table.clear(M._buffer)
	if M._monitor and (M._monitor:IsA("TextLabel") or M._monitor:IsA("TextBox")) then
		M._monitor.Text = ""
	end
end

local function _write(str)
	str = tostring(str or "")
	table.insert(M._buffer, str)

	-- recorte
	local txt = table.concat(M._buffer)
	if #txt > M._maxBuffer then
		txt = string.sub(txt, #txt - M._maxBuffer + 1)
		M._buffer = { txt }
	end

	-- pinta local (si hay monitor en este contexto)
	if M._monitor and (M._monitor:IsA("TextLabel") or M._monitor:IsA("TextBox")) then
		M._monitor.Text = txt
	end

	-- espejo a consola de Roblox por líneas
	if M._mirror then
		M._mirror_linebuf ..= str
		while true do
			local p = string.find(M._mirror_linebuf, "\n", 1, true)
			if not p then break end
			print(string.sub(M._mirror_linebuf, 1, p-1))
			M._mirror_linebuf = string.sub(M._mirror_linebuf, p+1)
		end
	end

	-- stream hacia clientes
	if IS_SERVER and RE then
		RE:FireAllClients(str)
	end
end

function M.raw(str) _write(str) end
function M.println(str) _write(tostring(str) .. M._newline) end
function M.printf(fmt, ...) _write(string.format(fmt, ...)) end
function M.info(str)  M.println("[INFO] "..tostring(str)) end
function M.warn(str)  M.println("[WARN] "..tostring(str)) end
function M.error(str) M.println("[ERR ] "..tostring(str)) end

return M

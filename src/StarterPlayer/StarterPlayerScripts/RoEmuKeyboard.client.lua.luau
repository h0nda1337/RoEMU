-- StarterPlayerScripts/RoEmuKeyboard.client.lua
-- Cliente: captura teclado y manda chars a RemoteEvent RoEmu_Input

local RunService = game:GetService("RunService")
if not RunService:IsClient() then
	warn("[RoEmuKeyboard] Este script es CLIENTE. Muévelo a StarterPlayerScripts como LocalScript.")
	return
end

local UIS = game:GetService("UserInputService")
local RS  = game:GetService("ReplicatedStorage")

local RE = RS:WaitForChild("RoEmu_Input")

local capture = true

local function isShiftDown()
	return UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift)
end

local function keyToChar(input)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return nil end
	local kc = input.KeyCode

	if kc == Enum.KeyCode.Return then return "\n" end
	if kc == Enum.KeyCode.Tab then return "\t" end
	if kc == Enum.KeyCode.Space then return " " end
	if kc == Enum.KeyCode.Backspace then return "\b" end

	-- Letras A..Z
	if kc.Value >= Enum.KeyCode.A.Value and kc.Value <= Enum.KeyCode.Z.Value then
		local ch = string.char(("A"):byte() + (kc.Value - Enum.KeyCode.A.Value))
		return isShiftDown() and ch or string.lower(ch)
	end

	-- Dígitos 0..9 (sin shift)
	if kc.Value >= Enum.KeyCode.Zero.Value and kc.Value <= Enum.KeyCode.Nine.Value then
		return string.char(("0"):byte() + (kc.Value - Enum.KeyCode.Zero.Value))
	end

	-- Símbolos (ojo: BackSlash con S mayúscula)
	local map = {
		[Enum.KeyCode.Period] = ".",
		[Enum.KeyCode.Comma] = ",",
		[Enum.KeyCode.Slash] = "/",
		[Enum.KeyCode.Semicolon] = ";",
		[Enum.KeyCode.Quote] = "'",
		[Enum.KeyCode.Minus] = "-",
		[Enum.KeyCode.Equals] = "=",
		[Enum.KeyCode.LeftBracket] = "[",
		[Enum.KeyCode.RightBracket] = "]",
		[Enum.KeyCode.BackSlash] = "\\",
	}

	return map[kc]
end

UIS.InputBegan:Connect(function(input, gp)
	if gp or not capture then return end
	local ch = keyToChar(input)
	if ch then
		RE:FireServer(ch)
	end
end)

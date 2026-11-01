-- LocalScript example. Place it under a ScreenGui or StarterPlayerScripts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PixelText = require(ReplicatedStorage.PerfectDOSVGA437.PixelText)

local screenGui = script.Parent

local panel = Instance.new("Frame")
panel.Name = "DOSPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromOffset(620, 240)
panel.BackgroundColor3 = Color3.fromRGB(8, 12, 20)
panel.BorderSizePixel = 0
panel.Parent = screenGui

local text = PixelText.new(panel, {
	Name = "DOSMessage",
	Position = UDim2.fromOffset(20, 20),
	Size = UDim2.new(1, -40, 1, -40),
	Text = "PERFECT DOS VGA 437\n\n¡HOLA, ÁNGELO! Ñ Ü áéíóú\n╔════════════════════╗\n║  TEXTO EN ROBLOX   ║\n╚════════════════════╝  ♥ ☺",
	Scale = 2,
	Color = Color3.fromRGB(120, 255, 170),
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
})

-- Examples:
-- text:SetText("Texto actualizado")
-- text:Set({Color = Color3.new(1, 1, 0), Scale = 3})

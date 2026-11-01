-- ServerScriptService/RunUartBoard
-- Orquestador mínimo que conecta la entrada del cliente con el “board”.
-- NO usa uart:on_tx (ya no existe). El TX lo imprime el propio UART/board.

local RS = game:GetService("ReplicatedStorage")
local BoardModule = require(RS.RiscV.board_minimal)  -- tu módulo de placa mínima

-- (Opcional) remoto para enviar TX a clientes si tu board lo soporta
local OutRE = RS:FindFirstChild("RoEmu_Out")

print("[RunUartBoard] boot")

-- Crea el board (si tu board admite pasarle un RemoteEvent para TX, pásalo)
local board = nil
local ok, err = pcall(function()
	-- Si tu Board.new admite (monitor, outRemote), pásale OutRE, si no, solo construye.
	board = BoardModule.new(nil, OutRE)
end)
if not ok then
	warn("[RunUartBoard] no se pudo crear el board:", err)
	return
end

-- Recibe líneas desde el cliente (ConsoleBridge) y las inyecta a la VM
local InRE = RS:WaitForChild("RoEmu_Input")
InRE.OnServerEvent:Connect(function(player, line)
	if typeof(line) == "string" then
		if board.host_rx_line then
			board:host_rx_line(line) -- tu board ya lo tiene implementado
		elseif board.uart and board.uart.rx_line then
			board.uart:rx_line(line)
		else
			warn("[RunUartBoard] no hay método para RX line en el board.")
		end
	end
end)

print("[RunUartBoard] listo")

-- ReplicatedStorage/RoEmu_Monitor  (ModuleScript)

local M = {}

local sink = function(_) end

function M.init(opts)
	if opts and typeof(opts.print) == "function" then
		sink = opts.print
	end
	sink("[RoEmu] Monitor listo.")
end

function M.clear() sink("__CLEAR__") end
function M.print(s) sink(tostring(s)) end
function M.printf(fmt, ...) sink(string.format(fmt, ...)) end

function M.onLine(player, line)
	line = tostring(line or "")
	if line == "clear" or line == "cls" then
		return M.clear()
	end
	if line == "" then
		return M.print("[UART] \\n")
	end
	M.printf("[UART] %s", line)
end

return M

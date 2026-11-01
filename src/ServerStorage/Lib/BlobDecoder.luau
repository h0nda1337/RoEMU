-- ServerStorage/Lib/BlobDecoder.lua
-- Decoder robusto: Base64 puro Luau + soporta ModuleScript o Folder(Part###)
-- Estructuras soportadas:
--   return { chunks = { {b64=[[...]]}, {b64=[[...]]}, {zeros=N}, ... } }
--   return { chunks_b64 = { [[...]], [[...]], ... } }
--   return { chunks = { [[...]], [[...]], ... } }  (por si acaso)

local BlobDecoder = {}

local TAG = "BlobDecoder"

local function ts()
	return string.format("%.3f", os.clock())
end

local function log(level, msg)
	print(string.format("%s -- [%s][%s] %s", ts(), TAG, level, msg))
end

local function isWhitespaceByte(b)
	return b == 9 or b == 10 or b == 13 or b == 32
end

-- Base64 decode puro Luau (sin HttpService)
do
	local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local inv = table.create(256, -1)
	for i = 1, #alphabet do
		inv[alphabet:byte(i)] = i - 1
	end
	inv[string.byte("=")] = -2

	function BlobDecoder.b64decode(b64)
		if type(b64) ~= "string" then
			error("b64decode: esperaba string, recibí " .. typeof(b64))
		end

		local out = table.create(math.floor(#b64 * 3 / 4))
		local quartet = table.create(4)
		local qi = 0

		for i = 1, #b64 do
			local c = b64:byte(i)
			if not isWhitespaceByte(c) then
				local v = inv[c]
				if v == nil then
					error("b64decode: byte fuera de rango: " .. tostring(c))
				end
				if v == -1 then
					error("b64decode: caracter inválido en base64: " .. string.char(c))
				end

				qi += 1
				quartet[qi] = v

				if qi == 4 then
					qi = 0
					local a, b, c2, d = quartet[1], quartet[2], quartet[3], quartet[4]

					-- '=' padding
					if c2 == -2 then
						-- solo 1 byte
						local byte1 = (a << 2) | (b >> 4)
						out[#out + 1] = string.char(byte1 & 0xFF)
					elseif d == -2 then
						-- 2 bytes
						local byte1 = (a << 2) | (b >> 4)
						local byte2 = ((b & 0x0F) << 4) | (c2 >> 2)
						out[#out + 1] = string.char(byte1 & 0xFF, byte2 & 0xFF)
					else
						-- 3 bytes
						local byte1 = (a << 2) | (b >> 4)
						local byte2 = ((b & 0x0F) << 4) | (c2 >> 2)
						local byte3 = ((c2 & 0x03) << 6) | d
						out[#out + 1] = string.char(byte1 & 0xFF, byte2 & 0xFF, byte3 & 0xFF)
					end
				end
			end
		end

		-- si quedaron chars sueltos, es base64 corrupto (debería venir múltiplo de 4)
		if qi ~= 0 then
			error("b64decode: base64 truncado (no múltiplo de 4). qi=" .. tostring(qi))
		end

		return table.concat(out)
	end
end

local function hexdumpHead(bin, n)
	n = n or 16
	local t = {}
	for i = 1, n do
		local b = bin:byte(i)
		if not b then break end
		t[#t + 1] = string.format("%02X", b)
	end
	return table.concat(t, " ")
end

local function normalizeChunksTable(ret)
	-- Devuelve lista de "entries" donde cada entry es:
	--   { kind="b64", s="..." } o { kind="zeros", n=123 }
	local entries = {}

	if type(ret) ~= "table" then
		return entries
	end

	local raw = ret.chunks_b64 or ret.chunks
	if type(raw) ~= "table" then
		return entries
	end

	for _, item in ipairs(raw) do
		if type(item) == "string" then
			entries[#entries + 1] = { kind = "b64", s = item }
		elseif type(item) == "table" then
			if item.b64 ~= nil then
				entries[#entries + 1] = { kind = "b64", s = item.b64 }
			elseif item.zeros ~= nil then
				entries[#entries + 1] = { kind = "zeros", n = tonumber(item.zeros) or 0 }
			end
		end
	end

	return entries
end

local function requireStrict(mod)
	local ok, ret = pcall(require, mod)
	if not ok then
		error(string.format("require(%s) falló: %s", mod:GetFullName(), tostring(ret)))
	end
	return ret
end

local function decodeReturnTable(ret)
	local entries = normalizeChunksTable(ret)
	if #entries == 0 then
		return "", 0
	end

	local out = table.create(#entries)
	local chunksCount = 0

	for _, e in ipairs(entries) do
		if e.kind == "b64" then
			chunksCount += 1
			out[#out + 1] = BlobDecoder.b64decode(e.s)
		elseif e.kind == "zeros" then
			local n = e.n or 0
			if n > 0 then
				out[#out + 1] = string.rep("\0", n)
			end
		end
	end

	return table.concat(out), chunksCount
end

function BlobDecoder.decode(node)
	-- node puede ser ModuleScript o Folder con Part### (ModuleScripts)
	if not node then
		error("decode: node=nil")
	end

	if node:IsA("ModuleScript") then
		local ret = requireStrict(node)
		local bin, chunks = decodeReturnTable(ret)
		return bin, chunks
	end

	if node:IsA("Folder") then
		local parts = {}
		for _, ch in ipairs(node:GetChildren()) do
			if ch:IsA("ModuleScript") then
				parts[#parts + 1] = ch
			end
		end

		table.sort(parts, function(a, b)
			return a.Name < b.Name
		end)

		local out = table.create(#parts)
		local totalChunks = 0

		for _, part in ipairs(parts) do
			local ret = requireStrict(part)
			local bin, chunks = decodeReturnTable(ret)
			totalChunks += chunks
			out[#out + 1] = bin
		end

		return table.concat(out), totalChunks
	end

	error("decode: node no es ModuleScript ni Folder: " .. node.ClassName)
end

function BlobDecoder.head(bin, n)
	return hexdumpHead(bin, n or 16)
end

function BlobDecoder._log(level, msg)
	log(level, msg)
end

return BlobDecoder
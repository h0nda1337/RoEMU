-- ChunkDecoder.lua (ModuleScript)
-- Soporta:
--  A) return { chunks_b64 = { [[...]], [[...]] } }          (legacy)
--  B) return { chunks = { {b64=[[...]]}, {zeros=1234} } }  (nuevo)

local HttpService = game:GetService("HttpService")

local ChunkDecoder = {}

-- Intentar decoder nativo (rápido)
local function tryHttpBase64Decode(b64)
	local ok, out = pcall(function()
		return HttpService:Base64Decode(b64)
	end)
	if ok and type(out) == "string" then
		return out
	end
	return nil
end

-- Fallback Base64 (por si HttpService falla en tu entorno)
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64inv = {}
for i = 1, #b64chars do
	b64inv[string.byte(b64chars, i)] = i - 1
end

local function base64DecodeFallback(data)
	-- limpia whitespace (por si acaso)
	data = string.gsub(data, "%s+", "")

	local out = table.create(math.floor(#data * 0.75))
	local outN = 0

	local i = 1
	while i <= #data do
		local c1 = string.byte(data, i);     i += 1
		local c2 = string.byte(data, i);     i += 1
		local c3 = string.byte(data, i);     i += 1
		local c4 = string.byte(data, i);     i += 1

		if not c1 or not c2 then break end

		local v1 = b64inv[c1]
		local v2 = b64inv[c2]
		local v3 = (c3 == 61) and nil or b64inv[c3] -- '='
		local v4 = (c4 == 61) and nil or b64inv[c4]

		if v1 == nil or v2 == nil then break end

		local b1 = (v1 << 2) | (v2 >> 4)
		outN += 1
		out[outN] = string.char(b1)

		if v3 ~= nil then
			local b2 = ((v2 & 0x0F) << 4) | (v3 >> 2)
			outN += 1
			out[outN] = string.char(b2)

			if v4 ~= nil then
				local b3 = ((v3 & 0x03) << 6) | v4
				outN += 1
				out[outN] = string.char(b3)
			end
		end
	end

	return table.concat(out, "", 1, outN)
end

local function base64Decode(b64)
	local s = tryHttpBase64Decode(b64)
	if s ~= nil then
		return s
	end
	return base64DecodeFallback(b64)
end

local function getChunkList(blob)
	-- Caso A: legacy
	if type(blob) == "table" and type(blob.chunks_b64) == "table" then
		return "legacy", blob.chunks_b64
	end
	-- Caso B: nuevo
	if type(blob) == "table" and type(blob.chunks) == "table" then
		return "new", blob.chunks
	end
	-- Caso C: si alguien retorna directamente un array { [[b64]], [[b64]] }
	if type(blob) == "table" then
		local isArray = (blob[1] ~= nil)
		if isArray and type(blob[1]) == "string" then
			return "legacy_array", blob
		end
	end
	error("Blob inválido: se esperaba {chunks_b64={...}} o {chunks={...}}")
end

function ChunkDecoder.decodeToString(blob)
	local kind, list = getChunkList(blob)

	local parts = table.create(#list + 1)
	local n = 0

	if kind == "new" then
		for _, ch in ipairs(list) do
			if ch.b64 then
				n += 1
				parts[n] = base64Decode(ch.b64)
			elseif ch.zeros then
				n += 1
				parts[n] = string.rep("\0", ch.zeros)
			else
				error("Chunk desconocido: se esperaba {b64=...} o {zeros=N}")
			end
		end
	else
		for _, b64 in ipairs(list) do
			n += 1
			parts[n] = base64Decode(b64)
		end
	end

	return table.concat(parts, "", 1, n)
end

function ChunkDecoder.decodeToBuffer(blob)
	-- Si buffer no existe en tu runtime, regresa string
	if type(buffer) ~= "table" or type(buffer.create) ~= "function" then
		return ChunkDecoder.decodeToString(blob)
	end

	local kind, list = getChunkList(blob)

	-- 1) tamaño total (aprox exacto)
	local total = 0
	local function decodedLenOfB64(b64)
		b64 = string.gsub(b64, "%s+", "")
		local len = #b64
		local pad = 0
		if len >= 2 and string.sub(b64, -2) == "==" then pad = 2
		elseif len >= 1 and string.sub(b64, -1) == "=" then pad = 1 end
		return math.floor(len * 3 / 4) - pad
	end

	if kind == "new" then
		for _, ch in ipairs(list) do
			if ch.b64 then
				total += decodedLenOfB64(ch.b64)
			elseif ch.zeros then
				total += ch.zeros
			end
		end
	else
		for _, b64 in ipairs(list) do
			total += decodedLenOfB64(b64)
		end
	end

	local out = buffer.create(total) -- por defecto viene en cero
	local off = 0

	-- 2) copia
	if kind == "new" then
		for _, ch in ipairs(list) do
			if ch.b64 then
				local s = base64Decode(ch.b64)
				local tmp = buffer.fromstring(s)
				buffer.copy(out, off, tmp, 0, buffer.len(tmp))
				off += buffer.len(tmp)
			elseif ch.zeros then
				-- ya son ceros; solo avanza
				off += ch.zeros
			end
		end
	else
		for _, b64 in ipairs(list) do
			local s = base64Decode(b64)
			local tmp = buffer.fromstring(s)
			buffer.copy(out, off, tmp, 0, buffer.len(tmp))
			off += buffer.len(tmp)
		end
	end

	return out
end

return ChunkDecoder

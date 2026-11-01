print("[linuxNext] boot")

task.spawn(function()
	local bit = bit32
	local RS = game:GetService("ReplicatedStorage")

	local CHUNK_FOLDER_NAME = "Return_Linux_RV32_Min_Initramfs_Image_chunks"
	local CHUNK_COUNT = 59
	local EXPECTED_BYTES = 2644992
	local LOAD_ADDR = 0x80400000
	local DTB_ADDR = 0x80200000
	local FWINFO = 0x80202000
	local ROOT_NEXT_ARG1 = 0x80043150
	local ROOT_NEXT_ADDR = 0x80043154
	local ROOT_NEXT_MODE = 0x80043158

	local loaded = setmetatable({}, { __mode = "k" })
	local seenLinux = setmetatable({}, { __mode = "k" })
	local imageBytes

	local b64 = {}
	do
		local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
		for i = 1, #alphabet do
			b64[alphabet:byte(i)] = i - 1
		end
	end

	local function hx(n)
		return ("0x%08X"):format(bit.band(tonumber(n) or 0, 0xFFFFFFFF))
	end

	local function w32(c, a, v)
		pcall(function()
			c:write32(a, bit.band(tonumber(v) or 0, 0xFFFFFFFF))
		end)
	end

	local function r32(c, a)
		local ok, v = pcall(function() return c:read32(a) end)
		return ok and bit.band(tonumber(v) or 0, 0xFFFFFFFF) or 0
	end

	local function reg(cpu, i)
		if not cpu then return 0 end
		if cpu.regs then return tonumber(cpu.regs[i]) or 0 end
		if cpu.x then return tonumber(cpu.x[i + 1]) or 0 end
		return 0
	end

	local function fireRemoteString(s)
		if not s or s == "" then return end

		local append = RS:FindFirstChild("RoEmu_OutAppend")
		if append and append:IsA("BindableEvent") then
			local ok = pcall(function() append:Fire(s) end)
			if ok then return end
		end

		local remotes = RS:FindFirstChild("RoEmu_Remotes")
		local chanOut = remotes and remotes:FindFirstChild("Out")
		if chanOut and chanOut:IsA("RemoteEvent") then
			local ok = pcall(function() chanOut:FireAllClients(s) end)
			if ok then return end
		end

		local out = RS:FindFirstChild("RoEmu_Out")
		if out and out:IsA("RemoteEvent") then
			pcall(function() out:FireAllClients(s) end)
		end
	end

	local function decodeBase64(s)
		local out = {}
		local tmp = {}
		local oi, ti = 1, 1
		local buf, bits = 0, 0

		for i = 1, #s do
			local c = s:byte(i)
			if c == 61 then break end -- "="
			local v = b64[c]
			if v then
				buf = buf * 64 + v
				bits += 6
				if bits >= 8 then
					bits -= 8
					local div = 2 ^ bits
					local byte = math.floor(buf / div) % 256
					buf = buf % div
					tmp[ti] = string.char(byte)
					ti += 1
					if ti > 4096 then
						out[oi] = table.concat(tmp)
						oi += 1
						ti = 1
						tmp = {}
					end
				end
			end
		end

		if ti > 1 then
			out[oi] = table.concat(tmp)
		end
		return table.concat(out)
	end

	local function findChunkFolder()
		local rv = RS:WaitForChild("RiscV", 30)
		local fw = rv and rv:WaitForChild("firmware", 30)
		return fw and fw:WaitForChild(CHUNK_FOLDER_NAME, 30)
	end

	local function decodeImage()
		local folder = findChunkFolder()
		if not folder then
			error("no encontre " .. CHUNK_FOLDER_NAME)
		end

		local decoded = {}
		for i = 1, CHUNK_COUNT do
			local name = ("chunk%03d"):format(i)
			local node = folder:WaitForChild(name, 30)
			if not node then
				error("falta " .. name)
			end

			local ok, chunk = pcall(require, node)
			if not ok or type(chunk) ~= "string" then
				error(("require(%s) fallo: %s"):format(name, tostring(chunk)))
			end
			decoded[i] = decodeBase64(chunk)
			if i == 1 or i == CHUNK_COUNT or i % 8 == 0 then
				print(("[linuxNext] decode chunk %03d/%03d"):format(i, CHUNK_COUNT))
				task.wait()
			end
		end

		imageBytes = table.concat(decoded)
		if #imageBytes ~= EXPECTED_BYTES then
			warn(("[linuxNext] size inesperado: %d bytes, esperado %d"):format(#imageBytes, EXPECTED_BYTES))
		end
		print(("[linuxNext] Linux Image decodificado: %d bytes, load=%s")
			:format(#imageBytes, hx(LOAD_ADDR)))
		fireRemoteString(("\n[RoEmu] Linux Image listo: %d KB @ %s\n")
			:format(math.floor((#imageBytes + 1023) / 1024), hx(LOAD_ADDR)))
	end

	local function patchNext(c)
		w32(c, FWINFO + 0x00, 0x4942534F)
		w32(c, FWINFO + 0x04, 2)
		w32(c, FWINFO + 0x08, LOAD_ADDR)
		w32(c, FWINFO + 0x0C, 1)
		w32(c, FWINFO + 0x10, 0)
		w32(c, FWINFO + 0x14, 0)

		w32(c, ROOT_NEXT_ARG1, DTB_ADDR)
		w32(c, ROOT_NEXT_ADDR, LOAD_ADDR)
		w32(c, ROOT_NEXT_MODE, 1)
	end

	local function loadImage(c, bytes)
		local started = os.clock()
		local n = #bytes
		local addr = LOAD_ADDR
		local nextLog = 512 * 1024

		for i = 1, n, 4 do
			local b1, b2, b3, b4 = bytes:byte(i, i + 3)
			local word = bit.bor(
				b1 or 0,
				bit.lshift(b2 or 0, 8),
				bit.lshift(b3 or 0, 16),
				bit.lshift(b4 or 0, 24)
			)
			w32(c, addr, word)
			addr += 4

			if i >= nextLog then
				print(("[linuxNext] cargado %d/%d KB"):format(
					math.floor(i / 1024),
					math.floor((n + 1023) / 1024)))
				nextLog += 512 * 1024
			end
			if bit.band(i, 0x3FFFF) == 1 then
				task.wait()
				patchNext(c)
			end
		end

		patchNext(c)
		print(("[linuxNext] Image cargado @%s..%s en %.2fs first=%s")
			:format(hx(LOAD_ADDR), hx(LOAD_ADDR + n - 1), os.clock() - started, hx(r32(c, LOAD_ADDR))))
		fireRemoteString(("[RoEmu] Linux cargado @ %s; OpenSBI saltara ahi.\n"):format(hx(LOAD_ADDR)))
	end

	local ok, err = pcall(decodeImage)
	if not ok then
		warn("[linuxNext] decode fallo: " .. tostring(err))
		fireRemoteString("\n[RoEmu] ERROR cargando Linux Image; revisa Output.\n")
		return
	end

	while task.wait(0.02) do
		local c = rawget(_G, "RoEmuCore")
		if type(c) == "table" and type(c.read32) == "function" and type(c.write32) == "function" then
			patchNext(c)

			if not loaded[c] and imageBytes then
				loaded[c] = true
				loadImage(c, imageBytes)
			end

			local cpu = c.cpu
			local pc = cpu and bit.band(tonumber(cpu.pc) or 0, 0xFFFFFFFF) or 0
			if not seenLinux[c] and pc >= LOAD_ADDR and pc < LOAD_ADDR + 0x00100000 then
				seenLinux[c] = true
				print(("[linuxNext] Linux ejecutando pc=%s a0/hart=%s a1/dtb=%s")
					:format(hx(pc), hx(reg(cpu, 10)), hx(reg(cpu, 11))))
				fireRemoteString(("[RoEmu] Linux arranco: pc=%s hart=%s dtb=%s\n")
					:format(hx(pc), hx(reg(cpu, 10)), hx(reg(cpu, 11))))
			end
		end
	end
end)

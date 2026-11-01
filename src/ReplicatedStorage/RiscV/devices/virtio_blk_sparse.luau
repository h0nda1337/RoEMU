--!native
--!optimize 2
-- Legacy virtio-mmio block device backed by a read-only sparse LZ4 image.
-- The guest-visible contract matches QEMU virt's virtio-blk-device.

local bit = bit32
local band, bor, bnot = bit.band, bit.bor, bit.bnot

local VIRTIO_MAGIC = 0x74726976
local VIRTIO_VERSION_LEGACY = 1
local VIRTIO_ID_BLOCK = 2
local VIRTIO_VENDOR_QEMU = 0x554D4551
local VIRTIO_BLK_T_IN = 0
local VIRTIO_BLK_S_OK = 0
local VIRTIO_BLK_S_IOERR = 1
local VIRTQ_DESC_F_NEXT = 1
local VIRTQ_DESC_F_WRITE = 2

local PACK_HEADER_BYTES = 24
local PACK_RECORD_BYTES = 16

local SparseDisk = {}
SparseDisk.__index = SparseDisk

local function readStringU32(data, index)
	local b0, b1, b2, b3 = data:byte(index, index + 3)
	assert(b3 ~= nil, "CaribeOS sparse pack truncado")
	return b0 + b1 * 0x100 + b2 * 0x10000 + b3 * 0x1000000
end

local function lz4Length(data, position, limit, initial)
	local length = initial
	if initial ~= 15 then return length, position end
	while true do
		assert(position < limit, "LZ4 truncado leyendo longitud")
		local byte = data:byte(position)
		position += 1
		length += byte
		if byte ~= 255 then return length, position end
	end
end

local function decompressLZ4Block(data, startPosition, compressedBytes, rawBytes)
	local output = buffer.create(rawBytes)
	local position = startPosition
	local limit = startPosition + compressedBytes
	local outputPosition = 0

	while position < limit do
		local token = data:byte(position)
		position += 1

		local literalBytes
		literalBytes, position = lz4Length(data, position, limit, bit.rshift(token, 4))
		assert(position + literalBytes <= limit, "LZ4 literales fuera del bloque")
		assert(outputPosition + literalBytes <= rawBytes, "LZ4 literales fuera de salida")
		if literalBytes > 0 then
			buffer.writestring(
				output,
				outputPosition,
				data:sub(position, position + literalBytes - 1)
			)
			position += literalBytes
			outputPosition += literalBytes
		end

		if position >= limit then break end
		assert(position + 1 < limit, "LZ4 offset truncado")
		local matchOffset = data:byte(position) + data:byte(position + 1) * 0x100
		position += 2
		assert(matchOffset > 0 and matchOffset <= outputPosition, "LZ4 offset invalido")

		local matchBytes
		matchBytes, position = lz4Length(data, position, limit, band(token, 0x0F))
		matchBytes += 4
		assert(outputPosition + matchBytes <= rawBytes, "LZ4 match fuera de salida")

		local sourcePosition = outputPosition - matchOffset
		if matchOffset >= matchBytes then
			buffer.copy(output, outputPosition, output, sourcePosition, matchBytes)
		else
			-- LZ4 permite matches solapados (por ejemplo para grandes corridas de cero).
			for index = 0, matchBytes - 1 do
				buffer.writeu8(
					output,
					outputPosition + index,
					buffer.readu8(output, sourcePosition + index)
				)
			end
		end
		outputPosition += matchBytes
	end

	assert(outputPosition == rawBytes, ("LZ4 produjo %d bytes; esperaba %d"):format(
		outputPosition,
		rawBytes
	))
	return output
end

function SparseDisk.new(pack)
	local provider
	if type(pack) == "table" then
		provider = pack
		local header = provider.readRange(0, PACK_HEADER_BYTES)
		local count = readStringU32(header, 17)
		pack = provider.readRange(0, PACK_HEADER_BYTES + count * PACK_RECORD_BYTES)
	end
	assert(type(pack) == "string" and #pack >= PACK_HEADER_BYTES, "sparse pack invalido")
	assert(pack:sub(1, 4) == "CBSP", "magic CBSP invalido")
	local version = readStringU32(pack, 5)
	assert(version == 1, "version CBSP no soportada: " .. tostring(version))

	local logicalBytes = readStringU32(pack, 9)
	local segmentBytes = readStringU32(pack, 13)
	local recordCount = readStringU32(pack, 17)
	assert(logicalBytes > 0 and logicalBytes % 512 == 0, "tamano CBSP invalido")
	assert(segmentBytes >= 4096 and segmentBytes % 512 == 0, "segmento CBSP invalido")
	assert(PACK_HEADER_BYTES + recordCount * PACK_RECORD_BYTES <= #pack, "tabla CBSP truncada")

	local records = {}
	local tablePosition = PACK_HEADER_BYTES + 1
	local payloadPosition = tablePosition + recordCount * PACK_RECORD_BYTES
	for _ = 1, recordCount do
		local segment = readStringU32(pack, tablePosition)
		local offset = readStringU32(pack, tablePosition + 4)
		local compressedBytes = readStringU32(pack, tablePosition + 8)
		local rawBytes = readStringU32(pack, tablePosition + 12)
		assert(rawBytes > 0 and rawBytes <= segmentBytes, "registro CBSP raw invalido")
		assert(payloadPosition + offset + compressedBytes - 1 <= (provider and provider.length or #pack), "registro CBSP fuera del payload")
		records[segment] = {
			position = payloadPosition + offset,
			compressedBytes = compressedBytes,
			rawBytes = rawBytes,
		}
		tablePosition += PACK_RECORD_BYTES
	end

	return setmetatable({
		pack = pack,
		provider = provider,
		cacheOrder = {},
		logicalBytes = logicalBytes,
		segmentBytes = segmentBytes,
		records = records,
		cache = {},
		decodedSegments = 0,
		readRequests = 0,
		readBytes = 0,
	}, SparseDisk)
end

function SparseDisk:_segment(index)
	local cached = self.cache[index]
	if cached then return cached end
	local record = self.records[index]
	if not record then return nil end
	local data = self.provider and self.provider.readRange(record.position - 1, record.compressedBytes) or self.pack
	local decoded = decompressLZ4Block(
		data,
		self.provider and 1 or record.position,
		record.compressedBytes,
		record.rawBytes
	)
	self.cache[index] = decoded
	if self.provider then
		self.cacheOrder[#self.cacheOrder + 1] = index
		if #self.cacheOrder > 64 then self.cache[table.remove(self.cacheOrder, 1)] = nil end
	end
	self.decodedSegments += 1
	return decoded
end

function SparseDisk:readInto(target, targetOffset, diskOffset, byteCount)
	if diskOffset < 0 or byteCount < 0 or diskOffset + byteCount > self.logicalBytes then
		return false
	end
	buffer.fill(target, targetOffset, 0, byteCount)
	local remaining = byteCount
	local destination = targetOffset
	local source = diskOffset
	while remaining > 0 do
		local segmentIndex = math.floor(source / self.segmentBytes)
		local withinSegment = source % self.segmentBytes
		local take = math.min(remaining, self.segmentBytes - withinSegment)
		local decoded = self:_segment(segmentIndex)
		if decoded then
			local available = math.min(take, buffer.len(decoded) - withinSegment)
			if available > 0 then
				buffer.copy(target, destination, decoded, withinSegment, available)
			end
		end
		destination += take
		source += take
		remaining -= take
	end
	self.readRequests += 1
	self.readBytes += byteCount
	return true
end

local Device = {}
Device.__index = Device

local function alignUp(value, alignment)
	return math.floor((value + alignment - 1) / alignment) * alignment
end

function Device.new(core, sparsePack)
	assert(type(core) == "table" and core.__main_ram and core.__main_ram.buffer, "core RAM no disponible")
	local self = setmetatable({
		core = core,
		ram = core.__main_ram,
		disk = SparseDisk.new(sparsePack),
		deviceFeaturesSelector = 0,
		driverFeaturesSelector = 0,
		driverFeatures = 0,
		guestPageSize = 4096,
		queueSelector = 0,
		queueNum = 0,
		queueAlign = 4096,
		queuePfn = 0,
		status = 0,
		interruptStatus = 0,
		lastAvailIndex = 0,
		irqSink = nil,
		completedRequests = 0,
		failedRequests = 0,
	}, Device)
	return self
end

function Device:_ramOffset(address, byteCount)
	local offset = address - self.ram.lo
	if offset < 0 or offset + byteCount > self.ram.size then return nil end
	return offset
end

function Device:_read8(address)
	local offset = self:_ramOffset(address, 1)
	assert(offset, ("virtio RAM read8 fuera de rango @0x%08X"):format(address))
	return buffer.readu8(self.ram.buffer, offset)
end

function Device:_read16(address)
	local offset = self:_ramOffset(address, 2)
	assert(offset, ("virtio RAM read16 fuera de rango @0x%08X"):format(address))
	return buffer.readu16(self.ram.buffer, offset)
end

function Device:_read32(address)
	local offset = self:_ramOffset(address, 4)
	assert(offset, ("virtio RAM read32 fuera de rango @0x%08X"):format(address))
	return buffer.readu32(self.ram.buffer, offset)
end

function Device:_write8(address, value)
	local offset = self:_ramOffset(address, 1)
	assert(offset, ("virtio RAM write8 fuera de rango @0x%08X"):format(address))
	buffer.writeu8(self.ram.buffer, offset, value)
end

function Device:_write16(address, value)
	local offset = self:_ramOffset(address, 2)
	assert(offset, ("virtio RAM write16 fuera de rango @0x%08X"):format(address))
	buffer.writeu16(self.ram.buffer, offset, value)
end

function Device:_write32(address, value)
	local offset = self:_ramOffset(address, 4)
	assert(offset, ("virtio RAM write32 fuera de rango @0x%08X"):format(address))
	buffer.writeu32(self.ram.buffer, offset, value)
end

function Device:_setInterrupt(value)
	self.interruptStatus = band(value, 0xFFFFFFFF)
	if self.irqSink then
		self.irqSink(self.interruptStatus ~= 0)
	end
end

function Device:setIrqSink(callback)
	self.irqSink = type(callback) == "function" and callback or nil
	self:_setInterrupt(self.interruptStatus)
end

function Device:_descriptor(base, index)
	local address = base + index * 16
	return {
		address = self:_read32(address),
		addressHigh = self:_read32(address + 4),
		length = self:_read32(address + 8),
		flags = self:_read16(address + 12),
		next = self:_read16(address + 14),
	}
end

function Device:_completeHead(descriptorBase, usedBase, head, usedIndex)
	local statusCode = VIRTIO_BLK_S_IOERR
	local transferred = 0
	local ok, reason = pcall(function()
		local header = self:_descriptor(descriptorBase, head)
		assert(header.addressHigh == 0 and band(header.flags, VIRTQ_DESC_F_NEXT) ~= 0, "cabecera virtio invalida")
		local data = self:_descriptor(descriptorBase, header.next)
		assert(data.addressHigh == 0 and band(data.flags, VIRTQ_DESC_F_NEXT) ~= 0, "descriptor de datos invalido")
		local statusDescriptor = self:_descriptor(descriptorBase, data.next)
		assert(statusDescriptor.addressHigh == 0 and statusDescriptor.length >= 1, "descriptor de estado invalido")

		local requestType = self:_read32(header.address)
		local sectorLow = self:_read32(header.address + 8)
		local sectorHigh = self:_read32(header.address + 12)
		assert(requestType == VIRTIO_BLK_T_IN, "solo se permiten lecturas virtio-blk")
		assert(sectorHigh == 0, "LBA virtio fuera de RV32")
		assert(band(data.flags, VIRTQ_DESC_F_WRITE) ~= 0, "buffer de lectura no es writable")

		local destinationOffset = self:_ramOffset(data.address, data.length)
		assert(destinationOffset, "buffer virtio fuera de RAM")
		assert(self.disk:readInto(
			self.ram.buffer,
			destinationOffset,
			sectorLow * 512,
			data.length
		), "lectura fuera del disco HFS+")
		self:_write8(statusDescriptor.address, VIRTIO_BLK_S_OK)
		statusCode = VIRTIO_BLK_S_OK
		transferred = data.length + 1
	end)

	if not ok then
		self.failedRequests += 1
		warn("[RoEmu][CaribeOS][virtio-blk] " .. tostring(reason))
	else
		self.completedRequests += 1
	end

	local usedSlot = usedBase + 4 + (usedIndex % math.max(self.queueNum, 1)) * 8
	self:_write32(usedSlot, head)
	self:_write32(usedSlot + 4, transferred)
	self:_write16(usedBase + 2, (usedIndex + 1) % 0x10000)
	return statusCode == VIRTIO_BLK_S_OK
end

function Device:_notify(queueIndex)
	if queueIndex ~= 0 or self.queueSelector ~= 0 then return end
	if self.queuePfn == 0 or self.queueNum < 3 then return end
	local descriptorBase = self.queuePfn * self.guestPageSize
	local availableBase = descriptorBase + 16 * self.queueNum
	local usedBase = alignUp(availableBase + 4 + 2 * self.queueNum + 2, self.queueAlign)
	local availableIndex = self:_read16(availableBase + 2)
	local usedIndex = self:_read16(usedBase + 2)

	while self.lastAvailIndex ~= availableIndex do
		local slot = self.lastAvailIndex % self.queueNum
		local head = self:_read16(availableBase + 4 + slot * 2)
		self:_completeHead(descriptorBase, usedBase, head, usedIndex)
		self.lastAvailIndex = (self.lastAvailIndex + 1) % 0x10000
		usedIndex = (usedIndex + 1) % 0x10000
	end
	self:_setInterrupt(bor(self.interruptStatus, 1))
end

function Device:read32(offset)
	if offset == 0x000 then return VIRTIO_MAGIC end
	if offset == 0x004 then return VIRTIO_VERSION_LEGACY end
	if offset == 0x008 then return VIRTIO_ID_BLOCK end
	if offset == 0x00C then return VIRTIO_VENDOR_QEMU end
	if offset == 0x010 then return 0 end
	if offset == 0x014 then return self.deviceFeaturesSelector end
	if offset == 0x020 then return self.driverFeatures end
	if offset == 0x024 then return self.driverFeaturesSelector end
	if offset == 0x028 then return self.guestPageSize end
	if offset == 0x030 then return self.queueSelector end
	if offset == 0x034 then return self.queueSelector == 0 and 1024 or 0 end
	if offset == 0x038 then return self.queueNum end
	if offset == 0x03C then return self.queueAlign end
	if offset == 0x040 then return self.queuePfn end
	if offset == 0x060 then return self.interruptStatus end
	if offset == 0x070 then return self.status end
	if offset == 0x100 then return math.floor(self.disk.logicalBytes / 512) end
	if offset == 0x104 then return 0 end
	return 0
end

function Device:write32(offset, value)
	value = band(tonumber(value) or 0, 0xFFFFFFFF)
	if offset == 0x014 then self.deviceFeaturesSelector = value
	elseif offset == 0x020 then self.driverFeatures = value
	elseif offset == 0x024 then self.driverFeaturesSelector = value
	elseif offset == 0x028 then self.guestPageSize = value ~= 0 and value or 4096
	elseif offset == 0x030 then self.queueSelector = value
	elseif offset == 0x038 then self.queueNum = math.clamp(value, 0, 1024)
	elseif offset == 0x03C then self.queueAlign = value ~= 0 and value or 4096
	elseif offset == 0x040 then
		self.queuePfn = value
		self.lastAvailIndex = 0
	elseif offset == 0x050 then self:_notify(value)
	elseif offset == 0x064 then self:_setInterrupt(band(self.interruptStatus, bnot(value)))
	elseif offset == 0x070 then
		self.status = value
		if value == 0 then
			self.driverFeatures = 0
			self.queueSelector = 0
			self.queueNum = 0
			self.queueAlign = 4096
			self.queuePfn = 0
			self.lastAvailIndex = 0
			self:_setInterrupt(0)
		end
	end
end

function Device:getStatus()
	return {
		logicalBytes = self.disk.logicalBytes,
		capacitySectors = math.floor(self.disk.logicalBytes / 512),
		readOnly = true,
		queuePfn = self.queuePfn,
		queueNum = self.queueNum,
		completedRequests = self.completedRequests,
		failedRequests = self.failedRequests,
		readRequests = self.disk.readRequests,
		readBytes = self.disk.readBytes,
		decodedSegments = self.disk.decodedSegments,
	}
end

return {
	VERSION = 1,
	new = Device.new,
	SparseDisk = SparseDisk,
}

--!native
--!optimize 2
-- Primary ATA PIO master. Guest writes remain in the in-memory sector overlay.
local band, bor, rshift, lshift = bit32.band, bit32.bor, bit32.rshift, bit32.lshift
local ATA = {}
ATA.__index = ATA
function ATA.new(disk, overlay, interrupt)
	return setmetatable({ disk = disk, overlay = overlay, interrupt = interrupt, regs = {},
		status = 0x50, error = 1, control = 0, cursor = 0, buffer = buffer.create(512),
		heads = 16, sectors = 63, multiple = 1 }, ATA)
end
function ATA:irq()
	if band(self.control, 2) == 0 then self.interrupt() end
end
function ATA:fail(code)
	self.error, self.status, self.operation = code or 4, 0x51, nil
	self:irq()
end
function ATA:address()
	local r = self.regs
	if band(r[6] or 0, 0x40) ~= 0 then
		return (r[3] or 0) + (r[4] or 0) * 256 + (r[5] or 0) * 65536 + band(r[6] or 0, 15) * 16777216
	end
	return (((r[4] or 0) + (r[5] or 0) * 256) * self.heads + band(r[6] or 0, 15)) * self.sectors + (r[3] or 1) - 1
end
function ATA:updateTaskFile(sectors)
	self.lba += sectors
	self.remaining -= sectors
	local r = self.regs
	r[2] = band(self.remaining, 255)
	if band(r[6] or 0, 0x40) ~= 0 then
		r[3], r[4], r[5] = band(self.lba, 255), band(rshift(self.lba, 8), 255), band(rshift(self.lba, 16), 255)
		r[6] = bor(band(r[6], 0xF0), band(rshift(self.lba, 24), 15))
	else
		local track = math.floor(self.lba / self.sectors)
		local cylinder = math.floor(track / self.heads)
		r[3], r[4], r[5] = self.lba % self.sectors + 1, band(cylinder, 255), band(rshift(cylinder, 8), 255)
		r[6] = bor(band(r[6] or 0, 0xF0), track % self.heads)
	end
end
function ATA:identify()
	local b = buffer.create(512)
	for word, value in pairs({ [0] = 0x40, [1] = 914, [3] = self.heads, [6] = self.sectors,
		[47] = 0x8010, [49] = 0x0200, [51] = 0x0200, [53] = 1, [54] = 914,
		[55] = self.heads, [56] = self.sectors, [59] = 0x100 + self.multiple }) do buffer.writeu16(b, word * 2, value) end
	buffer.writeu32(b, 57 * 2, 914 * self.heads * self.sectors)
	buffer.writeu32(b, 60 * 2, self.disk.logicalBytes / 512)
	local function text(word, length, value)
		value = value .. string.rep(" ", length)
		for offset = 0, length - 1, 2 do
			buffer.writeu8(b, word * 2 + offset, value:byte(offset + 2))
			buffer.writeu8(b, word * 2 + offset + 1, value:byte(offset + 1))
		end
	end
	text(10, 20, "ROEMU-LOCAL-0001"); text(23, 8, "1.0"); text(27, 40, "RoEMU local ATA PIO disk")
	self.buffer, self.cursor, self.operation, self.status = b, 0, "identify", 0x58
	self:irq()
end
function ATA:command(value)
	if band(self.regs[6] or 0, 0x10) ~= 0 then self.status = 0; return end
	self.error = 0
	if value == 0xEC then self:identify(); return end
	if value == 0x20 or value == 0x21 or value == 0xC4 or value == 0x30 or value == 0x31 or value == 0xC5 then
		self.lba, self.remaining = self:address(), self.regs[2] or 1
		if self.remaining == 0 then self.remaining = 256 end
		if self.lba < 0 or (self.lba + self.remaining) * 512 > self.disk.logicalBytes then self:fail(0x10); return end
		self.blockSectors = (value == 0xC4 or value == 0xC5) and self.multiple or 1
		self.cursor, self.buffer = 0, buffer.create(self.remaining * 512)
		self.operation = (value == 0x20 or value == 0x21 or value == 0xC4) and "read" or "write"
		self.status = 0x58
		if self.operation == "read" then
			if not self.disk:readInto(self.buffer, 0, self.lba * 512, buffer.len(self.buffer)) then self:fail(0x10); return end
			for sector = 0, self.remaining - 1 do if self.overlay[self.lba + sector] then buffer.copy(self.buffer, sector * 512, self.overlay[self.lba + sector]) end end
			self:irq()
		end
	elseif value == 0xC6 then
		local count = self.regs[2] or 0
		if count < 1 or count > 16 or band(count, count - 1) ~= 0 then self:fail(); return end
		self.multiple, self.status = count, 0x50; self:irq()
	elseif value == 0x91 then
		local sectors, heads = self.regs[2] or 0, band(self.regs[6] or 0, 15) + 1
		if sectors < 1 or sectors > 63 then self:fail(); return end
		self.sectors, self.heads, self.status = sectors, heads, 0x50; self:irq()
	elseif value == 0x90 then self.error, self.status = 1, 0x50; self:irq()
	elseif value == 0x40 or value == 0x41 then
		local count = self.regs[2] or 1; if count == 0 then count = 256 end
		if self:address() < 0 or (self:address() + count) * 512 > self.disk.logicalBytes then self:fail(0x10); return end
		self.status = 0x50; self:irq()
	elseif value == 0xEF then
		local feature, mode = self.regs[1] or 0, self.regs[2] or 0
		if feature ~= 2 and feature ~= 0x82 and not (feature == 3 and mode <= 0x0C) then self:fail(); return end
		self.status = 0x50; self:irq()
	elseif value == 0xE7 or value == 0xEA or (value >= 0x70 and value <= 0x7F) then
		self.status = 0x50; self:irq()
	else self:fail() end
end
function ATA:finishBlock()
	local total = buffer.len(self.buffer)
	local blockBytes = self.blockSectors * 512
	if self.cursor % blockBytes ~= 0 and self.cursor < total then return end
	local completed = math.min(self.blockSectors, self.remaining)
	local writing = self.operation == "write"
	if writing then
		for sector = 0, completed - 1 do
			local b = buffer.create(512)
			buffer.copy(b, 0, self.buffer, self.cursor - completed * 512 + sector * 512, 512)
			self.overlay[self.lba + sector] = b
		end
	end
	self:updateTaskFile(completed)
	if self.cursor >= total then self.status, self.operation = 0x50, nil else self.status = 0x58 end
	if writing or self.operation == "read" then self:irq() end
end
function ATA:readPort(port, width)
	if port == 0x1F7 or port == 0x3F6 then return band(self.regs[6] or 0, 0x10) ~= 0 and 0 or self.status end
	if port == 0x1F1 then return self.error end
	if port ~= 0x1F0 then return self.regs[port - 0x1F0] or 0 end
	if self.operation ~= "read" and self.operation ~= "identify" then return width == 8 and 255 or width == 16 and 65535 or 0xFFFFFFFF end
	local value = 0
	for i = 0, width / 8 - 1 do
		if self.cursor < buffer.len(self.buffer) then value += buffer.readu8(self.buffer, self.cursor) * 2 ^ (i * 8); self.cursor += 1 end
	end
	if self.operation == "identify" then if self.cursor >= 512 then self.status, self.operation = 0x50, nil end
	else self:finishBlock() end
	return value
end
function ATA:writePort(port, width, value)
	if port == 0x3F6 then
		local reset = band(self.control, 4) ~= 0
		self.control = value
		if band(value, 4) ~= 0 then self.status = 0x80
		elseif reset then self.status, self.error, self.operation = 0x50, 1, nil; self.regs[2], self.regs[3], self.regs[4], self.regs[5] = 1, 1, 0, 0 end
	elseif port == 0x1F7 then self:command(value)
	elseif port == 0x1F0 then
		if self.operation ~= "write" then return end
		for i = 0, width / 8 - 1 do
			if self.cursor < buffer.len(self.buffer) then buffer.writeu8(self.buffer, self.cursor, band(rshift(value, i * 8), 255)); self.cursor += 1 end
		end
		self:finishBlock()
	else self.regs[port - 0x1F0] = band(value, 255); if port == 0x1F6 then self.status = band(value, 0x10) ~= 0 and 0 or 0x50 end end
end
return ATA

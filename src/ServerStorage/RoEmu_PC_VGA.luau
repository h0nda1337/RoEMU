--!native
--!optimize 2
-- VGA registers, four memory planes and guest-programmed palette. No host image.
local band, bor, bxor, bnot, rshift, lshift = bit32.band, bit32.bor, bit32.bxor, bit32.bnot, bit32.rshift, bit32.lshift
local VGA = {}
VGA.__index = VGA
function VGA.new()
	local self = setmetatable({ memory = buffer.create(262144), palette = buffer.create(768),
		seq = {}, gc = {}, crtc = {}, attr = {}, latch = {}, seqIndex = 0, gcIndex = 0,
		crtcIndex = 0, attrIndex = 0, attrData = false, dacWrite = 0, dacRead = 0, pelMask = 255, misc = 0x67 }, VGA)
	self.linearMemory = buffer.create(8 * 1024 * 1024)
	self.linearBase = 0xE0000000
	self.linearEnabled = true
	self.vbeIndex = 0
	self.vbe = { [0] = 0xB0C5, [1] = 640, [2] = 480, [3] = 8, [4] = 0, [5] = 0, [6] = 640, [8] = 0, [9] = 0 }
	self.vbeModes = {}
	for _, entry in ipairs({ {0x101,640,480,8}, {0x103,800,600,8}, {0x105,1024,768,8},
		{0x110,640,480,15}, {0x111,640,480,16}, {0x112,640,480,24},
		{0x113,800,600,15}, {0x114,800,600,16}, {0x115,800,600,24},
		{0x116,1024,768,15}, {0x117,1024,768,16}, {0x118,1024,768,24},
		{0x140,640,480,32}, {0x143,800,600,32}, {0x144,1024,768,32} }) do
		self.vbeModes[entry[1]] = { width = entry[2], height = entry[3], bpp = entry[4] }
	end
	self:setMode(3)
	return self
end
function VGA:setMode(mode)
	self.generation = (self.generation or 0) + 1
	self.dirtyAll=true
	if self.vbe then self.vbe[4] = 0 end
	self.mode = mode
	local color256 = mode == 0x13
	local graphics = mode >= 0x0D and mode <= 0x13
	self.seq = { [0] = 3, [1] = 1, [2] = 15, [3] = 0, [4] = color256 and 14 or 6 }
	self.gc = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = color256 and 0x40 or 0,
		[6] = graphics and 5 or 14, [7] = 15, [8] = 255 }
	local width = (mode == 0x0D or mode == 0x13) and 320 or 640
	local height = (mode == 0x0D or mode == 0x0E or mode == 0x13) and 200 or mode == 0x10 and 350 or 480
	local rawHeight = height == 200 and 400 or height
	self.crtc = { [1] = (color256 and width * 2 or width) / 8 - 1, [7] = bor(band(rshift(rawHeight - 1, 7), 2), band(rshift(rawHeight - 1, 3), 0x40)),
		[9] = height == 200 and 0x41 or 0x40, [0x0C] = 0, [0x0D] = 0, [0x12] = band(rawHeight - 1, 255),
		[0x13] = color256 and width / 8 or width / 16, [0x17] = 0xE3 }
	self.attr = { [0x10] = color256 and 0x41 or 1, [0x12] = 15, [0x13] = 0, [0x14] = 0 }
	for index = 0, 15 do
		local ega = index == 6 and 20 or index >= 8 and index + 48 or index
		self.attr[index] = ega
	end
	for index = 0, 63 do
		buffer.writeu8(self.palette, index * 3, (band(index, 4) ~= 0 and 42 or 0) + (band(index, 32) ~= 0 and 21 or 0))
		buffer.writeu8(self.palette, index * 3 + 1, (band(index, 2) ~= 0 and 42 or 0) + (band(index, 16) ~= 0 and 21 or 0))
		buffer.writeu8(self.palette, index * 3 + 2, (band(index, 1) ~= 0 and 42 or 0) + (band(index, 8) ~= 0 and 21 or 0))
	end
	buffer.fill(self.memory, 0, 0)
end
function VGA:vbeEnabled() return band(self.vbe[4], 1) ~= 0 end
function VGA:isGraphics() return self:vbeEnabled() or band(self.gc[6] or 0, 1) ~= 0 end
function VGA:linearOffset(address)
	if not self.linearEnabled then return nil end
	local offset = address - self.linearBase
	if offset >= 0 and offset < buffer.len(self.linearMemory) then return offset end
	return nil
end
function VGA:writeVBE(index, value)
	if index == 0 then if value >= 0xB0C0 and value <= 0xB0C5 then self.vbe[0] = value end
	elseif index == 1 or index == 6 then if value > 0 and value <= 1024 then self.vbe[index] = value end
	elseif index == 2 then if value > 0 and value <= 768 then self.vbe[index] = value end
	elseif index == 3 then if value == 8 or value == 15 or value == 16 or value == 24 or value == 32 then self.vbe[3] = value end
	elseif index == 4 then
		local previous = self.vbe[4]; self.vbe[4] = value
		if band(value, 1) ~= 0 and band(previous, 1) == 0 then
			self.vbe[6], self.vbe[8], self.vbe[9] = self.vbe[1], 0, 0
			if band(value, 0x80) == 0 then buffer.fill(self.linearMemory, 0, 0) end
		end
	elseif index == 5 then self.vbe[5] = band(value, 127)
	elseif index == 8 or index == 9 then self.vbe[index] = value end
	self.generation += 1
end
function VGA:readVBE(index)
	if band(self.vbe[4], 2) ~= 0 then
		if index == 1 then return 1024 elseif index == 2 then return 768 elseif index == 3 then return 32 end
	end
	if index == 7 then return math.floor(buffer.len(self.linearMemory) / (math.max(1, self.vbe[6]) * math.ceil(self.vbe[3] / 8))) end
	if index == 0xA then return buffer.len(self.linearMemory) / 65536 end
	return self.vbe[index] or 0
end
function VGA:aperture(address)
	local map = band(rshift(self.gc[6] or 0, 2), 3)
	local base = map < 2 and 0xA0000 or map == 2 and 0xB0000 or 0xB8000
	local size = map == 0 and 0x20000 or map == 1 and 0x10000 or 0x8000
	if address < base or address >= base + size then return nil end
	return address - base
end
function VGA:readMemory(address)
	if self:vbeEnabled() and address >= 0xA0000 and address < 0xB0000 then return buffer.readu8(self.linearMemory, self.vbe[5] * 65536 + address - 0xA0000) end
	local offset = self:aperture(address)
	if offset == nil then return 255 end
	local plane = self.gc[4] or 0
	if band(self.seq[4] or 0, 8) ~= 0 then plane = band(offset, 3); offset = rshift(offset, 2) end
	offset = band(offset, 0xFFFF)
	for index = 0, 3 do self.latch[index] = buffer.readu8(self.memory, index * 65536 + offset) end
	if band(self.gc[5] or 0, 8) == 0 then return self.latch[plane] end
	local mismatch = 0
	for index = 0, 3 do
		if band(self.gc[7] or 0, lshift(1, index)) ~= 0 then
			mismatch = bor(mismatch, bxor(self.latch[index], band(self.gc[2] or 0, lshift(1, index)) ~= 0 and 255 or 0))
		end
	end
	return band(bnot(mismatch), 255)
end
function VGA:writeMemory(address, value)
	if self:vbeEnabled() and address >= 0xA0000 and address < 0xB0000 then
		buffer.writeu8(self.linearMemory, self.vbe[5] * 65536 + address - 0xA0000, value); self.generation += 1; return
	end
	local offset = self:aperture(address)
	if offset == nil then return end
	self.generation += 1
	local planes = self.seq[2] or 0
	if band(self.seq[4] or 0, 8) ~= 0 then planes = band(planes, lshift(1, band(offset, 3))); offset = rshift(offset, 2) end
	offset = band(offset, 0xFFFF)
	local mode, rotate = band(self.gc[5] or 0, 3), band(self.gc[3] or 0, 7)
	self.dirtyMin=math.min(self.dirtyMin or 65535,offset)
	self.dirtyMax=math.max(self.dirtyMax or 0,offset)
	local rotated = band(bor(rshift(value, rotate), lshift(value, 8 - rotate)), 255)
	local mask = self.gc[8] or 255
	if mode == 3 then mask = band(mask, rotated) end
	for plane = 0, 3 do
		local planeBit = lshift(1, plane)
		if band(planes, planeBit) ~= 0 then
			local latched = self.latch[plane] or 0
			local data = rotated
			if mode == 1 then data = latched
			else
				if mode == 2 then data = band(value, planeBit) ~= 0 and 255 or 0
				elseif mode == 3 or band(self.gc[1] or 0, planeBit) ~= 0 then data = band(self.gc[0] or 0, planeBit) ~= 0 and 255 or 0 end
				local operation = band(rshift(self.gc[3] or 0, 3), 3)
				if operation == 1 then data = band(data, latched) elseif operation == 2 then data = bor(data, latched) elseif operation == 3 then data = bxor(data, latched) end
				data = bor(band(data, mask), band(latched, band(bnot(mask), 255)))
			end
			buffer.writeu8(self.memory, plane * 65536 + offset, data)
		end
	end
end
function VGA:readPort(port)
	if port == 0x3C4 then return self.seqIndex elseif port == 0x3C5 then return self.seq[self.seqIndex] or 0
	elseif port == 0x3CE then return self.gcIndex elseif port == 0x3CF then return self.gc[self.gcIndex] or 0
	elseif port == 0x3D4 or port == 0x3B4 then return self.crtcIndex
	elseif port == 0x3D5 or port == 0x3B5 then return self.crtc[self.crtcIndex] or 0
	elseif port == 0x3C0 then return self.attrIndex elseif port == 0x3C1 then return self.attr[band(self.attrIndex, 31)] or 0
	elseif port == 0x3C6 then return self.pelMask elseif port == 0x3C7 then return 3 elseif port == 0x3C8 then return math.floor(self.dacWrite / 3)
	elseif port == 0x3C9 then local result = buffer.readu8(self.palette, self.dacRead % 768); self.dacRead = (self.dacRead + 1) % 768; return result
	elseif port == 0x3CC then return self.misc
	elseif port == 0x3DA or port == 0x3BA then self.attrData = false; self.retrace = not self.retrace; return self.retrace and 9 or 0 end
	return nil
end
function VGA:writePort(port, value)
	local redraw=false
	if port==0x3D5 or port==0x3B5 then redraw=self.crtc[self.crtcIndex]~=value
	elseif port==0x3C0 and self.attrData then redraw=self.attr[band(self.attrIndex,31)]~=value
	elseif port==0x3CF and self.gcIndex==5 then redraw=band(self.gc[5] or 0,0x40)~=band(value,0x40)
	elseif port==0x3CF and self.gcIndex==6 then redraw=band(self.gc[6] or 0,1)~=band(value,1)
	elseif port==0x3C6 then redraw=self.pelMask~=value end
	if redraw then self.dirtyAll=true;self.generation+=1 end
	if port==0x3C9 and buffer.readu8(self.palette,self.dacWrite%768)~=band(value,63) then self.generation+=1 end
	if port == 0x3C4 then self.seqIndex = band(value, 7) elseif port == 0x3C5 then self.seq[self.seqIndex] = value
	elseif port == 0x3CE then self.gcIndex = band(value, 15) elseif port == 0x3CF then self.gc[self.gcIndex] = value
	elseif port == 0x3D4 or port == 0x3B4 then self.crtcIndex = band(value, 31)
	elseif port == 0x3D5 or port == 0x3B5 then self.crtc[self.crtcIndex] = value
	elseif port == 0x3C0 then
		if self.attrData then self.attr[band(self.attrIndex, 31)] = value else self.attrIndex = value end
		self.attrData = not self.attrData
	elseif port == 0x3C2 then self.misc = value elseif port == 0x3C6 then self.pelMask = value
	elseif port == 0x3C7 then self.dacRead = value * 3 elseif port == 0x3C8 then self.dacWrite = value * 3
	elseif port == 0x3C9 then buffer.writeu8(self.palette, self.dacWrite % 768, band(value, 63)); self.dacWrite = (self.dacWrite + 1) % 768 end
end
function VGA:snapshot()
	if not self:isGraphics() then return nil end
	if self.cachedGeneration == self.generation then return self.cachedPixels, self.palette, self.cachedWidth, self.cachedHeight, self.cachedFormat end
	if self:vbeEnabled() then
		local width, height, bpp = self.vbe[1], self.vbe[2], self.vbe[3]
		local bytes = math.ceil(bpp / 8)
		local stride = self.vbe[6] * bytes
		local start = self.vbe[9] * stride + self.vbe[8] * bytes
		if width < 1 or height < 1 or start + (height - 1) * stride + width * bytes > buffer.len(self.linearMemory) then return nil end
		local format = bpp == 8 and "indexed8" or "rgba8"
		local pixels = buffer.create(width * height * (bpp == 8 and 1 or 4))
		for y = 0, height - 1 do
			if bpp == 8 then buffer.copy(pixels, y * width, self.linearMemory, start + y * stride, width)
			else
				for x = 0, width - 1 do
					local offset, target = start + y * stride + x * bytes, (y * width + x) * 4
					local r, g, b
					if bpp == 15 or bpp == 16 then
						local value = buffer.readu16(self.linearMemory, offset)
						local greenBits = bpp == 16 and 6 or 5
						r = math.floor(band(rshift(value, greenBits + 5), 31) * 255 / 31)
						g = math.floor(band(rshift(value, 5), 2 ^ greenBits - 1) * 255 / (2 ^ greenBits - 1))
						b = math.floor(band(value, 31) * 255 / 31)
					else b, g, r = buffer.readu8(self.linearMemory, offset), buffer.readu8(self.linearMemory, offset + 1), buffer.readu8(self.linearMemory, offset + 2) end
					buffer.writeu8(pixels, target, r); buffer.writeu8(pixels, target + 1, g); buffer.writeu8(pixels, target + 2, b); buffer.writeu8(pixels, target + 3, 255)
				end
			end
		end
		self.cachedGeneration, self.cachedPixels, self.cachedWidth, self.cachedHeight, self.cachedFormat = self.generation, pixels, width, height, format
		return pixels, self.palette, width, height, format
	end
	local color256 = band(self.gc[5] or 0, 0x40) ~= 0
	local width = ((self.crtc[1] or 79) + 1) * (color256 and 4 or 8)
	local overflow = self.crtc[7] or 0
	local height = (self.crtc[0x12] or 0) + band(overflow, 2) * 128 + band(overflow, 64) * 8 + 1
	local scan = self.crtc[9] or 0
	height = math.floor(height / ((band(scan, 31) + 1) * (band(scan, 128) ~= 0 and 2 or 1)))
	if width < 1 or width > 800 or height < 1 or height > 600 then return nil end
	local reuse=not self.dirtyAll and self.cachedPixels and self.cachedWidth==width and self.cachedHeight==height and self.cachedFormat=="indexed8"
	local output = reuse and self.cachedPixels or buffer.create(width * height)
	local stride = (self.crtc[0x13] or 40) * 2
	local start = (self.crtc[0x0C] or 0) * 256 + (self.crtc[0x0D] or 0)
	local firstRow,lastRow=0,height-1
	if reuse and not self.dirtyMin then firstRow,lastRow=0,-1
	elseif reuse and stride>0 and start+height*stride<=65536 then
		firstRow=math.clamp(math.floor((self.dirtyMin-start)/stride),0,height)
		lastRow=math.clamp(math.floor((self.dirtyMax-start)/stride),-1,height-1)
	end
	local colors={}
	for index=0,15 do
		local mapped=self.attr[band(index,self.attr[0x12] or 15)] or band(index,self.attr[0x12] or 15)
		if band(self.attr[0x10] or 0,128)~=0 then mapped=bor(band(mapped,15),lshift(band(self.attr[0x14] or 0,3),4)) end
		colors[index]=band(bor(band(mapped,63),lshift(band(self.attr[0x14] or 0,12),4)),self.pelMask)
	end
	for y = firstRow, lastRow do
		if not color256 and width%8==0 then
			-- Fetch each plane byte once for its eight pixels.
			for x=0,width-1,8 do
				local address=band(start+y*stride+x/8,65535)
				local p0,p1,p2,p3=buffer.readu8(self.memory,address),buffer.readu8(self.memory,65536+address),buffer.readu8(self.memory,131072+address),buffer.readu8(self.memory,196608+address)
				for bit=0,7 do
					local shift=7-bit
					local index=band(rshift(p0,shift),1)+band(rshift(p1,shift),1)*2+band(rshift(p2,shift),1)*4+band(rshift(p3,shift),1)*8
					buffer.writeu8(output,y*width+x+bit,colors[index])
				end
			end
			continue
		end
		for x = 0, width - 1 do
			local index
			if color256 then index = buffer.readu8(self.memory, (x % 4) * 65536 + band(start + y * stride + math.floor(x / 4), 0xFFFF))
			else
				local address, shift = band(start + y * stride + math.floor(x / 8), 0xFFFF), 7 - x % 8
				index = 0
				for plane = 0, 3 do index += band(rshift(buffer.readu8(self.memory, plane * 65536 + address), shift), 1) * 2 ^ plane end
				index = band(index, self.attr[0x12] or 15)
				local mapped = self.attr[index] or index
				if band(self.attr[0x10] or 0, 128) ~= 0 then mapped = bor(band(mapped, 15), lshift(band(self.attr[0x14] or 0, 3), 4)) end
				index = bor(band(mapped, 63), lshift(band(self.attr[0x14] or 0, 12), 4))
			end
			buffer.writeu8(output, y * width + x, band(index, self.pelMask))
		end
	end
	self.dirtyAll,self.dirtyMin,self.dirtyMax=false,nil,nil
	self.cachedGeneration, self.cachedPixels, self.cachedWidth, self.cachedHeight, self.cachedFormat = self.generation, output, width, height, "indexed8"
	return output, self.palette, width, height, "indexed8"
end
return VGA

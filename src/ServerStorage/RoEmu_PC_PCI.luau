--!native
--!optimize 2
local band, bor, rshift = bit32.band, bit32.bor, bit32.rshift
local PCI = {}
PCI.__index = PCI
function PCI.new(vga, videoFirmware)
	local self = setmetatable({ vga = vga, address = 0, config = {}, barProbe = false,
		rom = videoFirmware and buffer.fromstring(videoFirmware) or nil,
		romBase=0,romEnabled=false,romProbe=false,romSize=65536 }, PCI)
	local host, video, isa, ide = buffer.create(256), buffer.create(256), buffer.create(256), buffer.create(256)
	buffer.writeu32(host, 0, 0x12378086); buffer.writeu32(host, 8, 0x06000002)
	buffer.writeu32(isa, 0, 0x70008086); buffer.writeu16(isa, 4, 7)
	buffer.writeu32(isa, 8, 0x06010000); buffer.writeu8(isa, 0x0E, 0x80)
	for offset=0x60,0x63 do buffer.writeu8(isa,offset,0x80) end
	buffer.writeu32(ide, 0, 0x70108086); buffer.writeu16(ide, 4, 1)
	-- PIIX-compatible primary IDE in fixed legacy PIO mode. Bus mastering
	-- is not advertised until a DMA engine is implemented.
	buffer.writeu32(ide, 8, 0x01010000); buffer.writeu16(ide, 0x40, 0x8000)
	buffer.writeu32(video, 0, 0x11111234); buffer.writeu16(video, 4, 3)
	buffer.writeu32(video, 8, 0x03000000); buffer.writeu32(video, 0x10, vga.linearBase + 8)
	buffer.writeu32(video, 0x2C, 0x11001AF4)
	self.config[0], self.config[8], self.config[9], self.config[0x90] = host, isa, ide, video
	return self
end
function PCI:readConfig(devfn, offset, width)
	local b = self.config[devfn]
	if not b or offset < 0 or offset + width / 8 > 256 then return width == 8 and 255 or width == 16 and 65535 or 0xFFFFFFFF end
	if devfn == 0x90 and offset >= 0x10 and offset + width / 8 <= 0x14 and self.barProbe then
		return band(rshift(0xFF800008, (offset - 0x10) * 8), width == 8 and 255 or width == 16 and 65535 or 0xFFFFFFFF)
	end
	if devfn==0x90 and offset>=0x30 and offset+width/8<=0x34 and self.romProbe and self.rom then
		return band(rshift(0xFFFF0001,(offset-0x30)*8),width==8 and 255 or width==16 and 65535 or 0xFFFFFFFF)
	end
	if width == 8 then return buffer.readu8(b, offset) elseif width == 16 then return buffer.readu16(b, offset) else return buffer.readu32(b, offset) end
end
function PCI:writeConfig(devfn, offset, width, value)
	local b = self.config[devfn]
	if not b or offset < 4 or offset + width / 8 > 256 then return end
	if devfn==0x90 and offset==0x30 and width==32 and self.rom then
		self.romProbe=value==0xFFFFFFFF
		if not self.romProbe then
			self.romBase,self.romEnabled=band(value,0xFFFF0000),band(value,1)~=0
			buffer.writeu32(b,offset,self.romBase+(self.romEnabled and 1 or 0))
		end
		return
	end
	if offset >= 0x10 and offset < 0x28 then
		if devfn == 0x90 and offset == 0x10 and width == 32 then
			self.barProbe = value == 0xFFFFFFFF
			if not self.barProbe then
				self.vga.linearBase = band(value, 0xFF800000)
				buffer.writeu32(b, offset, self.vga.linearBase + 8)
			end
		end
		return
	end
	if offset == 4 then
		buffer.writeu16(b, 4, band(value, 7))
		if devfn == 0x90 then self.vga.linearEnabled = band(value, 2) ~= 0 end
	elseif offset == 0x0C or offset == 0x0D or offset == 0x3C then buffer.writeu8(b, offset, band(value, 255)) end
	if (devfn==8 and offset>=0x60 and offset+width/8<=0x64) or (devfn==9 and offset>=0x40 and offset+width/8<=0x44) then
		if width==8 then buffer.writeu8(b,offset,value) elseif width==16 then buffer.writeu16(b,offset,value) else buffer.writeu32(b,offset,value) end
	end
end
function PCI:readROM(address,width)
	if not self.rom or not self.romEnabled or address<self.romBase or address+width/8>self.romBase+self.romSize then return nil end
	local value=0
	for i=0,width/8-1 do
		local offset=address-self.romBase+i
		value+= (offset<buffer.len(self.rom) and buffer.readu8(self.rom,offset) or 255)*2^(8*i)
	end
	return value
end
function PCI:readPort(port, width)
	if port >= 0xCF8 and port <= 0xCFB then return band(rshift(self.address, (port - 0xCF8) * 8), width == 8 and 255 or width == 16 and 65535 or 0xFFFFFFFF) end
	if band(self.address, 0x80000000) == 0 or band(self.address, 0x00FF0000) ~= 0 then return width == 8 and 255 or width == 16 and 65535 or 0xFFFFFFFF end
	return self:readConfig(band(rshift(self.address, 8), 255), band(self.address, 0xFC) + port - 0xCFC, width)
end
function PCI:writePort(port, width, value)
	if port == 0xCF8 and width == 32 then self.address = value
	elseif port >= 0xCFC and port <= 0xCFF and band(self.address, 0x80000000) ~= 0 and band(self.address, 0x00FF0000) == 0 then
		self:writeConfig(band(rshift(self.address, 8), 255), band(self.address, 0xFC) + port - 0xCFC, width, value)
	end
end
return PCI

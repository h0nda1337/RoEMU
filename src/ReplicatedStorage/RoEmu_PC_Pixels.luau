--!native
--!optimize 2
-- Reusable VGA indexed-color -> RGBA conversion for the framebuffer client.
local Pixels={}
Pixels.__index=Pixels
function Pixels.new()
	return setmetatable({lookup=buffer.create(1024)},Pixels)
end
function Pixels:convert(indexed,palette)
	local colors=buffer.tostring(palette)
	if colors~=self.palette then
		for i=0,255 do
			local r=math.round(buffer.readu8(palette,i*3)*255/63)
			local g=math.round(buffer.readu8(palette,i*3+1)*255/63)
			local b=math.round(buffer.readu8(palette,i*3+2)*255/63)
			buffer.writeu32(self.lookup,i*4,r+g*256+b*65536+4278190080)
		end
		self.palette=colors
	end
	local count=buffer.len(indexed)
	if not self.rgba or buffer.len(self.rgba)~=count*4 then self.rgba=buffer.create(count*4) end
	for i=0,count-1 do buffer.writeu32(self.rgba,i*4,buffer.readu32(self.lookup,buffer.readu8(indexed,i)*4)) end
	return self.rgba
end
return Pixels

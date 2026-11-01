--!native
--!optimize 2
-- Keep a private previous frame: VGA snapshots can reuse mutable buffers.
local Stream={}
Stream.__index=Stream
function Stream.new() return setmetatable({},Stream) end
function Stream:reset() self.previous=nil;self.palette=nil end
function Stream:encode(pixels,palette,width,height,format)
	local colors=buffer.tostring(palette)
	local length=buffer.len(pixels)
	local full=not self.previous or self.width~=width or self.height~=height or self.format~=format or self.palette~=colors
	if full then
		self.previous=buffer.create(length);buffer.copy(self.previous,0,pixels)
		self.width,self.height,self.format,self.palette=width,height,format,colors
		return pixels,nil
	end
	local first,last=0,length
	while first+4<=last and buffer.readu32(pixels,first)==buffer.readu32(self.previous,first) do first+=4 end
	while first<last and buffer.readu8(pixels,first)==buffer.readu8(self.previous,first) do first+=1 end
	if first==last then return nil end
	while last-4>=first and buffer.readu32(pixels,last-4)==buffer.readu32(self.previous,last-4) do last-=4 end
	while last>first and buffer.readu8(pixels,last-1)==buffer.readu8(self.previous,last-1) do last-=1 end
	local stride=width*(format=="rgba8" and 4 or 1)
	local y=math.floor(first/stride)
	local rows=math.ceil(last/stride)-y
	local offset,count=y*stride,rows*stride
	buffer.copy(self.previous,offset,pixels,offset,count)
	if rows==height then return pixels,nil end
	local patch=buffer.create(count);buffer.copy(patch,0,pixels,offset,count)
	return patch,{y=y,rows=rows}
end
return Stream

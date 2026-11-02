--!native
--!optimize 2
-- Bounded PSF 1.01 metadata reader. No firmware or filesystem access.
local SFO={VERSION="0.1.0"}
local function failure(code,message) return false,{code=code,message=message} end
function SFO.Read(data)
	if type(data)=="string" then
		if #data>1048576 then return failure("sfo-size","PARAM.SFO exceeds the 1 MiB metadata limit") end
		data=buffer.fromstring(data)
	end
	if typeof(data)~="buffer" then return failure("sfo-data","PARAM.SFO must be a buffer or byte string") end
	local size=buffer.len(data)
	if size<20 or size>1048576 then return failure("sfo-size","PARAM.SFO header is truncated or exceeds the metadata limit") end
	if buffer.readstring(data,0,4)~="\0PSF" or buffer.readu32(data,4)~=0x101 then return failure("sfo-header","Expected PSF version 1.01") end
	local keyStart,dataStart,count=buffer.readu32(data,8),buffer.readu32(data,12),buffer.readu32(data,16)
	if count>4096 or keyStart<20+count*16 or dataStart<keyStart or dataStart>size then return failure("sfo-tables","Invalid PSF index/key/data table bounds") end
	local keys=buffer.readstring(data,keyStart,dataStart-keyStart)
	local entries,values={},{}
	for i=0,count-1 do
		local at=20+i*16
		local keyOffset,format=buffer.readu16(data,at),buffer.readu16(data,at+2)
		local length,maximum,offset=buffer.readu32(data,at+4),buffer.readu32(data,at+8),buffer.readu32(data,at+12)
		local last=string.find(keys,"\0",keyOffset+1,true)
		if not last or last==keyOffset+1 then return failure("sfo-key","PSF key is empty or lacks a terminator in the key table") end
		local key=string.sub(keys,keyOffset+1,last-1)
		if entries[key] then return failure("sfo-duplicate","Duplicate PSF key") end
		if length>maximum or dataStart+offset+maximum>size then return failure("sfo-value","PSF value exceeds its declared/file bounds") end
		local value
		if format==0x0404 then
			if length~=4 or maximum~=4 then return failure("sfo-integer","PSF integers must occupy four bytes") end
			value=buffer.readu32(data,dataStart+offset)
		elseif format==0x0204 or format==0x0004 then
			value=buffer.readstring(data,dataStart+offset,length)
			if format==0x0204 then
				local terminator=string.find(value,"\0",1,true)
				if terminator then value=string.sub(value,1,terminator-1) end
			end
		else return failure("sfo-format","Unsupported PSF value format") end
		entries[key]={format=format,maxBytes=maximum,value=value};values[key]=value
	end
	return true,{version=0x101,entries=entries,values=values}
end
return SFO

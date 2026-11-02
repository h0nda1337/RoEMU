--!native
--!optimize 2
-- Static ELF64 big-endian loader, independently implemented from the ELF ABI.
-- PS3 PPU uses an 8-byte pair of 32-bit entry/TOC addresses, not ELFv1's
-- three 64-bit descriptor fields. This loader does not implement an OS.
local ELF={}
local band=bit32.band
local function be16(data,at) return buffer.readu8(data,at)*256+buffer.readu8(data,at+1) end
local function be32(data,at)
	return buffer.readu8(data,at)*16777216+buffer.readu8(data,at+1)*65536+buffer.readu8(data,at+2)*256+buffer.readu8(data,at+3)
end
local function low64(data,at)
	if be32(data,at)~=0 then return nil end
	return be32(data,at+4)
end
local function failure(code,message) return false,{code=code,message=message} end
local function contains(segment,address,bytes)
	return address>=segment.address and address+bytes<=segment.address+segment.memoryBytes
end
local function alignUp(value,alignment) return math.ceil(value/alignment)*alignment end
function ELF.Load(cpu,data,options)
	options=options or {}
	if type(options)~="table" then return failure("elf-options","Loader options must be a table") end
	if type(data)=="string" then data=buffer.fromstring(data) end
	if typeof(data)~="buffer" then return failure("elf-data","ELF input must be a buffer or byte string") end
	local size,ramBytes=buffer.len(data),buffer.len(cpu.ram)
	if size>=4 and be32(data,0)==0x53434500 then return failure("self-unsupported","SELF containers are not implemented; provide an unencrypted ELF") end
	if size<64 then return failure("elf-truncated","ELF64 header is truncated") end
	if be32(data,0)~=0x7F454C46 then return failure("elf-magic","Input is not ELF") end
	if buffer.readu8(data,4)~=2 or buffer.readu8(data,5)~=2 then return failure("elf-format","Only ELF64 big endian is implemented") end
	if buffer.readu8(data,6)~=1 or be32(data,20)~=1 or be16(data,52)~=64 then return failure("elf-version","Unsupported ELF header version or size") end
	if be16(data,18)~=21 then return failure("elf-machine","ELF must target PowerPC64 (EM_PPC64)") end
	if be16(data,16)~=2 then return failure("elf-type","Only static ET_EXEC ELF is implemented") end
	local osabi=buffer.readu8(data,7)
	if osabi~=0 and osabi~=0x66 then return failure("elf-osabi","Unsupported ELF OS ABI") end
	local entry,phoff=low64(data,24),low64(data,32)
	if entry==nil or phoff==nil then return failure("elf-address-width","ELF offsets/entry exceed the flat RAM address window") end
	local count=be16(data,56)
	if be16(data,54)~=56 or count<1 or count>64 or phoff<64 or phoff+count*56>size then return failure("elf-program-headers","Invalid or truncated program header table") end
	local abi=band(be32(data,48),3)
	local mode=options.entryMode
	if not mode then
		if osabi==0x66 then mode="ps3-ppu" elseif abi==1 then mode="elfv1" elseif abi==2 then mode="direct"
		else return failure("elf-entry-mode","Unspecified PPC64 ABI: choose direct, elfv1 or ps3-ppu entryMode") end
	end
	if mode~="direct" and mode~="elfv1" and mode~="ps3-ppu" then return failure("elf-entry-mode","Unsupported entry mode") end
	if (osabi==0x66 and mode~="ps3-ppu") or (abi==1 and mode=="direct") or (abi==2 and mode=="elfv1") then return failure("elf-entry-mode","Entry mode conflicts with the declared ELF ABI") end
	local segments,tls={},nil
	for i=0,count-1 do
		local at=phoff+i*56
		local kind=be32(data,at)
		if kind==2 or kind==3 then return failure("elf-runtime-required","Dynamic linking and interpreters are not implemented") end
		if kind==7 then
			if options.tlsMode~="static" and options.tlsMode~="guest" then return failure("elf-runtime-required","TLS requires an explicit process initialization mode") end
			if tls then return failure("elf-tls","Multiple TLS templates are not implemented") end
			local offset,address,fileBytes,memoryBytes,alignment=low64(data,at+8),low64(data,at+16),low64(data,at+32),low64(data,at+40),low64(data,at+48)
			if offset==nil or address==nil or fileBytes==nil or memoryBytes==nil or alignment==nil then return failure("elf-address-width","TLS field exceeds the flat RAM window") end
			if fileBytes>memoryBytes or offset+fileBytes>size or address+memoryBytes>ramBytes then return failure("elf-tls","Invalid TLS template bounds") end
			if alignment>1 and (band(alignment,alignment-1)~=0 or address%alignment~=offset%alignment) then return failure("elf-tls","Invalid TLS template alignment") end
			tls={offset=offset,address=address,fileBytes=fileBytes,memoryBytes=memoryBytes,alignment=math.max(alignment,1),mode=options.tlsMode}
		end
		if kind==1 then
			local offset,address,fileBytes,memoryBytes,align=low64(data,at+8),low64(data,at+16),low64(data,at+32),low64(data,at+40),low64(data,at+48)
			if offset==nil or address==nil or fileBytes==nil or memoryBytes==nil or align==nil then return failure("elf-address-width","A LOAD field exceeds the flat RAM window") end
			if fileBytes>memoryBytes or offset+fileBytes>size or address+memoryBytes>ramBytes then return failure("elf-segment-bounds","LOAD segment exceeds file/RAM bounds") end
			if memoryBytes>0 and align>1 and (band(align,align-1)~=0 or address%align~=offset%align) then return failure("elf-segment-alignment","Invalid LOAD alignment") end
			local segment={address=address,offset=offset,fileBytes=fileBytes,memoryBytes=memoryBytes,flags=be32(data,at+4)}
			if memoryBytes>0 then
				for _,previous in ipairs(segments) do
					if address<previous.address+previous.memoryBytes and previous.address<address+memoryBytes then return failure("elf-segment-overlap","Overlapping LOAD memory ranges are not implemented") end
				end
				segments[#segments+1]=segment
			end
		end
	end
	if #segments==0 then return failure("elf-no-load","ELF has no nonempty LOAD segments") end
	if tls then
		local found=false
		for _,s in ipairs(segments) do
			if contains(s,tls.address,tls.memoryBytes) and tls.address+tls.fileBytes<=s.address+s.fileBytes
				and s.offset+tls.address-s.address==tls.offset and band(s.flags,4)~=0 then found=true;break end
		end
		if not found then return failure("elf-tls","TLS template must belong to a readable LOAD segment") end
	end
	local function source(address,bytes)
		for _,s in ipairs(segments) do
			if contains(s,address,bytes) and band(s.flags,4)~=0 and address+bytes<=s.address+s.fileBytes then return s.offset+address-s.address end
		end
		return nil
	end
	local code,toc,environment=entry,0,0
	if mode~="direct" then
		local width=mode=="elfv1" and 24 or 8
		if entry%(mode=="elfv1" and 8 or 4)~=0 then return failure("elf-descriptor","Entry descriptor is misaligned") end
		local at=source(entry,width)
		if not at then return failure("elf-descriptor","Entry descriptor is outside readable, file-backed LOAD data") end
		if mode=="elfv1" then code,toc,environment=low64(data,at),low64(data,at+8),low64(data,at+16)
		else code,toc=be32(data,at),be32(data,at+4) end
		if code==nil or toc==nil or environment==nil then return failure("elf-address-width","Descriptor contains addresses outside the flat RAM window") end
	end
	if code%4~=0 then return failure("elf-entry-alignment","Entry instruction address is misaligned") end
	local executable=false
	for _,s in ipairs(segments) do if contains(s,code,4) and band(s.flags,1)~=0 and code+4<=s.address+s.fileBytes then executable=true;break end end
	if not executable then return failure("elf-entry-range","Entry is outside file-backed executable LOAD data") end
	local stackTop=options.stackTop or ramBytes
	local stackBytes=options.stackBytes or 65536
	if type(stackTop)~="number" or type(stackBytes)~="number" or stackTop%16~=0 or stackBytes%16~=0
		or stackBytes<256 or stackTop>ramBytes or stackTop-stackBytes<0 then return failure("elf-stack","Invalid standalone stack range") end
	local bottom=stackTop-stackBytes
	for _,s in ipairs(segments) do if bottom<s.address+s.memoryBytes and s.address<stackTop then return failure("elf-stack-overlap","Standalone stack overlaps LOAD memory") end end
	local stackReserved=options.stackReservedBytes or 0
	if type(stackReserved)~="number" or stackReserved%16~=0 or stackReserved<0 or stackReserved+0x70>stackBytes then return failure("elf-stack","Invalid process argument reservation") end
	if tls and tls.mode=="static" then
		local alignment=math.max(tls.alignment,16)
		local prefix=alignUp(0x30,alignment)
		local residue=tls.address%tls.alignment
		local bytes=alignUp(prefix+residue+tls.memoryBytes,alignment)
		local allocation=options.tlsAddress or math.floor((bottom-bytes)/alignment)*alignment
		if type(allocation)~="number" or allocation%alignment~=0 or allocation<0 or allocation+bytes>ramBytes then return failure("elf-tls-allocation","Invalid static TLS allocation") end
		if allocation<stackTop and bottom<allocation+bytes then return failure("elf-tls-overlap","TLS allocation overlaps stack") end
		for _,s in ipairs(segments) do if allocation<s.address+s.memoryBytes and s.address<allocation+bytes then return failure("elf-tls-overlap","TLS allocation overlaps LOAD memory") end end
		tls.allocation,tls.allocationBytes=allocation,bytes
		tls.blockBase,tls.dataAddress=allocation+prefix,allocation+prefix+residue
		tls.threadPointer=tls.blockBase+0x7000
		if tls.threadPointer>0xFFFFFFFF then return failure("elf-tls-allocation","TLS thread pointer exceeds the address window") end
	end
	local returnAddress=options.returnAddress or 0
	if type(returnAddress)~="number" or returnAddress%4~=0 or returnAddress<0 or returnAddress+4>ramBytes then return failure("elf-return-address","Invalid standalone return address") end
	for _,s in ipairs(segments) do if returnAddress<s.address+s.memoryBytes and s.address<returnAddress+4 then return failure("elf-return-overlap","Standalone return address overlaps LOAD memory") end end
	if tls and tls.allocation and returnAddress<tls.allocation+tls.allocationBytes and tls.allocation<returnAddress+4 then return failure("elf-return-overlap","Standalone return address overlaps static TLS") end
	-- Commit only after validating every segment, descriptor and stack field.
	-- A caller may load from a view of the same RAM that is being populated.
	if data==cpu.ram then data=buffer.fromstring(buffer.tostring(data)) end
	for _,s in ipairs(segments) do
		buffer.copy(cpu.ram,s.address,data,s.offset,s.fileBytes)
		if s.memoryBytes>s.fileBytes then buffer.fill(cpu.ram,s.address+s.fileBytes,0,s.memoryBytes-s.fileBytes) end
	end
	buffer.fill(cpu.ram,bottom,0,stackBytes)
	if tls and tls.allocation then
		buffer.fill(cpu.ram,tls.allocation,0,tls.allocationBytes)
		buffer.copy(cpu.ram,tls.dataAddress,data,tls.offset,tls.fileBytes)
	end
	for index=0,31 do cpu:setRegister(index,0,0);cpu:setFloatingRegister(index,0,0) end
	cpu.fpscr=0
	cpu:setRegister(1,0,stackTop-stackReserved-0x70);cpu:setRegister(2,0,toc);cpu:setRegister(11,0,environment)
	if tls and tls.threadPointer then cpu:setRegister(13,0,tls.threadPointer) end
	if mode=="direct" then cpu:setRegister(12,0,code) end
	cpu.pcHi,cpu.pcLo=0,code;cpu.lrHi,cpu.lrLo=0,returnAddress
	cpu.ctrHi,cpu.ctrLo,cpu.cr,cpu.xer,cpu.instructions=0,0,0,0,0
	local report={format="ELF64-BE-PPC64",osabi=osabi,entryMode=mode,descriptorAddress=mode~="direct" and entry or nil,
		entry=code,toc=toc,environment=environment,segments=segments,stackTop=stackTop,stackBytes=stackBytes,
		returnAddress=returnAddress,tls=tls,stackReservedBytes=stackReserved,standaloneOnly=true,ps3BootSupported=false}
	cpu.loadedImage=report
	cpu.process=nil
	cpu.readTimeBase=nil;cpu.timeBaseHi,cpu.timeBaseLo=0,0
	cpu.reservation=nil
	return true,report
end
return ELF

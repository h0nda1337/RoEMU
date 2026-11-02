return function(Platform,SFO,image)
	local checks=0
	local function check(value,why) assert(value,why);checks+=1 end
	local function make(entries)
		local keys,payload,index="","",{}
		for _,entry in ipairs(entries) do
			local key,format,value,maximum=entry[1],entry[2],entry[3],entry[4]
			local raw=value
			if format==0x0404 then local n=buffer.create(4);buffer.writeu32(n,0,value);raw=buffer.tostring(n)
			elseif format==0x0204 then raw=value.."\0" end
			maximum=maximum or #raw
			index[#index+1]={#keys,format,#raw,maximum,#payload}
			keys..=key.."\0";payload..=raw..string.rep("\0",maximum-#raw)
		end
		local keyStart=20+#entries*16
		local dataStart=math.ceil((keyStart+#keys)/4)*4
		local b=buffer.create(dataStart+#payload)
		buffer.writestring(b,0,"\0PSF");buffer.writeu32(b,4,0x101);buffer.writeu32(b,8,keyStart);buffer.writeu32(b,12,dataStart);buffer.writeu32(b,16,#entries)
		for i,item in ipairs(index) do
			local at=20+(i-1)*16
			buffer.writeu16(b,at,item[1]);buffer.writeu16(b,at+2,item[2])
			for j=3,5 do buffer.writeu32(b,at+(j-2)*4,item[j]) end
		end
		buffer.writestring(b,keyStart,keys);buffer.writestring(b,dataStart,payload)
		return b
	end
	local sfo=make({{"TITLE_ID",0x0204,"ROEM00001",16},{"CATEGORY",0x0204,"HG",4},{"ATTRIBUTE",0x0404,0xFEDCBA98},{"OWN_BINARY",0x0004,"\0ab\0z"},{"EMPTY",0x0004,""}})
	local ok,parsed=SFO.Read(sfo)
	check(ok and parsed.values.TITLE_ID=="ROEM00001" and parsed.values.CATEGORY=="HG","PSF strings")
	check(parsed.values.ATTRIBUTE==0xFEDCBA98 and parsed.entries.ATTRIBUTE.format==0x0404,"little endian integer")
	check(parsed.values.OWN_BINARY=="\0ab\0z" and parsed.values.EMPTY=="","binary values preserve NULs")
	check(SFO.Read(buffer.tostring(sfo)),"byte-string input")
	local function bad(data,code)
		local success,valid,report=pcall(SFO.Read,data)
		check(success and not valid and (not code or report.code==code),"safe rejection "..tostring(code))
	end
	bad(nil,"sfo-data");bad({},"sfo-data");bad(true,"sfo-data");bad(buffer.create(1048577),"sfo-size")
	for n=0,buffer.len(sfo)-1 do bad(buffer.readstring(sfo,0,n)) end
	local function changed(offset,value,width)
		local b=buffer.fromstring(buffer.tostring(sfo))
		if width==2 then buffer.writeu16(b,offset,value) else buffer.writeu32(b,offset,value) end
		return b
	end
	for _,item in ipairs({{0,0,4,"sfo-header"},{4,0x100,4,"sfo-header"},{8,20,4,"sfo-tables"},
		{12,0xFFFFFFFF,4,"sfo-tables"},{16,4097,4,"sfo-tables"},{20,65535,2,"sfo-key"},
		{22,0x7777,2,"sfo-format"},{24,17,4,"sfo-value"},{28,0xFFFFFFFF,4,"sfo-value"},
		{32,0xFFFFFFFF,4,"sfo-value"},{36,0,2,"sfo-duplicate"},{20+2*16+4,3,4,"sfo-integer"}}) do bad(changed(item[1],item[2],item[3]),item[4]) end
	local keyEnd=changed(12,20+5*16+5,4);bad(keyEnd,"sfo-key")
	local c=Platform.new({ramBytes=1048576})
	buffer.fill(c.ram,0,0xA5)
	ok=Platform.LoadProcess(c,image,{argv={"/app_home/metadata.elf","T"},paramSFO=sfo})
	check(ok and c.process.titleId=="ROEM00001" and c.process.paramSFO.values.ATTRIBUTE==0xFEDCBA98,"process metadata")
	buffer.fill(sfo,0,0,buffer.len(sfo))
	check(c.process.titleId=="ROEM00001" and c.process.paramSFO.values.OWN_BINARY=="\0ab\0z","metadata is detached from caller buffer")
	local result=Platform.RunProcess(c,5000)
	check(result.kind=="process-exited" and result.exitStatus==42 and Platform.ProcessConsole(c)=="ROEMU_PPU_SFO_OK\n","compiled own C with metadata")
	local no=Platform.new({ramBytes=1048576});check(Platform.LoadProcess(no,image),"load without SFO")
	result=Platform.RunProcess(no,5000)
	check(result.kind=="process-exited" and result.exitStatus==42 and Platform.ProcessConsole(no)=="ROEMU_PPU_SFO_OK\n","compiled own C missing SFO")
	local valid=make({{"TITLE_ID",0x0204,"ROEM00001-extra",32}})
	c=Platform.new({ramBytes=1048576});check(Platform.LoadProcess(c,image,{paramSFO=valid,trace=true}),"syscall test image")
	local function put(at,value) for j=3,0,-1 do buffer.writeu8(c.ram,at+j,value%256);value=math.floor(value/256) end end
	local out=0xF0000
	local function call(high,address,expected)
		c.pcHi,c.pcLo=0,0x10000;put(0x10000,0x44000002)
		c:setRegister(3,high,address);c:setRegister(4,0,0);c:setRegister(11,0,30)
		local r=Platform.RunProcess(c,1);local h,l=c:getRegister(3)
		check(r.kind=="budget" and l==expected and h==(expected>=0x80000000 and 0xFFFFFFFF or 0),"paramsfo result/sign extension")
	end
	buffer.fill(c.ram,out-1,0xA5,66);call(0,out,0)
	check(buffer.readstring(c.ram,out,64)=="\0ROEM00001"..string.rep("\0",54),"64-byte paramsfo layout/truncation")
	check(buffer.readu8(c.ram,out-1)==0xA5 and buffer.readu8(c.ram,out+64)==0xA5,"output guards and ignored r4")
	for _,ptr in ipairs({{1,out},{0,0},{0,0x10000},{0,0xEFFFF},{0,0xFFFFF}}) do
		local before=buffer.readstring(c.ram,out,64);call(ptr[1],ptr[2],0x8001000D)
		check(buffer.readstring(c.ram,out,64)==before,"failed paramsfo does not alter output")
	end
	c:setFloatingRegister(31,0x7FF01234,0x56789ABC);c.fpscr=0x80000000
	local snapshot=buffer.tostring(c.ram);local previous,loaded,pc=c.process,c.loadedImage,c.pcLo
	for _,data in ipairs({true,"\0PSF",changed(28,0xFFFFFFFF,4),make({{"TITLE_ID",0x0404,42}})}) do
		local success,accepted=pcall(Platform.LoadProcess,c,image,{paramSFO=data})
		local h,l=c:getFloatingRegister(31)
		check(success and not accepted and c.process==previous and c.loadedImage==loaded and c.pcLo==pc and buffer.tostring(c.ram)==snapshot and h==0x7FF01234 and l==0x56789ABC and c.fpscr==0x80000000,"invalid metadata leaves existing process/FPR/RAM intact")
	end
	for _,data in ipairs({make({}),make({{"CATEGORY",0x0204,"HG"}}),make({{"TITLE_ID",0x0204,""}})}) do
		check(Platform.LoadProcess(c,image,{paramSFO=data}),"metadata without title ID")
		buffer.fill(c.ram,out,0xA5,64);call(1,0xFFFFFFFF,0x80010006)
		check(buffer.readstring(c.ram,out,64)==string.rep("\xA5",64),"missing title ID returns ENOENT before dereference")
	end
	check(not Platform.Status().bootSupported,"metadata does not claim console boot")
	return {checks=checks,compiledSFOProcess=true,missingMetadata=true,exitStatus=42,ps3BootSupported=false}
end

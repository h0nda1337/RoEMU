-- Own LLVM-built diagnostic from examples/powerpc/bringup.c; no firmware.
return function(Platform,image)
	local checks,rejected=0,0
	local function check(value,message) assert(value,message);checks+=1 end
	local function be32(data,at)
		return buffer.readu8(data,at)*16777216+buffer.readu8(data,at+1)*65536+buffer.readu8(data,at+2)*256+buffer.readu8(data,at+3)
	end
	local function put(data,at,value,bytes)
		for i=bytes-1,0,-1 do buffer.writeu8(data,at+i,value%256);value=math.floor(value/256) end
	end
	local function clone(data) return buffer.fromstring(buffer.tostring(data)) end
	for _,mode in ipairs({"ps3-ppu","elfv1","direct"}) do
		local data=clone(image)
		if mode=="elfv1" then
			buffer.writeu8(data,7,0);put(data,48,1,4)
			put(data,0x1C0,0x10000,8);put(data,0x1C8,0x18050,8);put(data,0x1D0,0,8)
		elseif mode=="direct" then
			buffer.writeu8(data,7,0);put(data,48,2,4);put(data,24,0x10000,8)
		end
		local cpu=Platform.new({ramBytes=262144})
		buffer.fill(cpu.ram,0,0xA5)
		local ok,report=Platform.LoadELF(cpu,data)
		check(ok,tostring(report.code))
		check(report.entryMode==mode and report.entry==0x10000,"ELF entry selection")
		local high,low=cpu:getRegister(1);check(high==0 and low==262144-0x70,"aligned call frame")
		high,low=cpu:getRegister(2);check(high==0 and low==(mode=="direct" and 0 or 0x18050),"TOC descriptor")
		check(be32(cpu.ram,0x12028)==0 and be32(cpu.ram,0x1202C)==0,"BSS cleared")
		check(buffer.readu8(cpu.ram,0x30000)==0 and buffer.readu8(cpu.ram,0xFFFF)==0xA5,"stack and unmapped data")
		if mode=="direct" then
			high,low=cpu:getRegister(12);check(high==0 and low==0x10000,"ELFv2 function entry in r12")
			-- This program was compiled for a TOC descriptor. Supply its caller TOC
			-- explicitly to test direct dispatch without pretending ABI conversion.
			cpu:setRegister(2,0,0x18050)
		end
		local result=Platform.RunStandalone(cpu,1)
		check(result.kind=="budget" and result.instructions==1,"bounded continuation")
		result=Platform.RunStandalone(cpu,31)
		check(result.kind=="returned" and result.instructions==32,"actual guest execution")
		high,low=cpu:getRegister(3);check(high==0 and low==42,"C return value")
		check(be32(cpu.ram,0x12028)==0x01034566 and be32(cpu.ram,0x1202C)==0x89ABCDFB,"exact 64-bit checksum")
	end
	local cpu=Platform.new({ramBytes=262144,entry=0x44})
	buffer.fill(cpu.ram,0,0xA7)
	for i=0,31 do cpu:setRegister(i,0x12345678,i*97) end
	cpu.lrHi,cpu.lrLo,cpu.ctrHi,cpu.ctrLo,cpu.cr,cpu.xer,cpu.instructions=3,4,5,6,7,8,9
	local previous={sentinel=true};cpu.loadedImage=previous
	local snapshot=buffer.tostring(cpu.ram)
	local function atomic(data,options,code)
		local success,accepted,report=pcall(Platform.LoadELF,cpu,data,options)
		check(success,"malformed ELF raised a host exception")
		check(not accepted and (not code or report.code==code),"expected ELF rejection: "..tostring(report.code))
		check(buffer.tostring(cpu.ram)==snapshot,"rejected ELF modified RAM")
		check(cpu.pcHi==0 and cpu.pcLo==0x44 and cpu.lrHi==3 and cpu.lrLo==4 and cpu.ctrHi==5 and cpu.ctrLo==6
			and cpu.cr==7 and cpu.xer==8 and cpu.instructions==9 and cpu.loadedImage==previous,"rejected ELF modified CPU state")
		for i=0,31 do local h,l=cpu:getRegister(i);check(h==0x12345678 and l==i*97,"rejected ELF modified GPR") end
		rejected+=1
	end
	local function bad(at,value,bytes,code)
		local data=clone(image);put(data,at,value,bytes);atomic(data,nil,code)
	end
	atomic(nil,nil,"elf-data");atomic(image,true,"elf-options")
	atomic("SCE\0",nil,"self-unsupported")
	for length=0,63 do atomic(buffer.create(length),nil,"elf-truncated") end
	bad(0,0,4,"elf-magic");bad(4,1,1,"elf-format");bad(5,1,1,"elf-format")
	bad(6,2,1,"elf-version");bad(18,23,2,"elf-machine");bad(16,3,2,"elf-type")
	bad(7,3,1,"elf-osabi");bad(24,1,4,"elf-address-width")
	bad(54,55,2,"elf-program-headers");bad(56,0,2,"elf-program-headers");bad(56,65,2,"elf-program-headers")
	bad(64,2,4,"elf-runtime-required");bad(64,3,4,"elf-runtime-required");bad(64,7,4,"elf-runtime-required")
	bad(64+8,1,4,"elf-address-width");bad(64+32,0x10000,8,"elf-segment-bounds")
	bad(64+48,3,8,"elf-segment-alignment")
	bad(64+56+16,0x10000,8,"elf-segment-overlap")
	bad(64+4*56+16,262144,8,"elf-segment-bounds") -- invalid final BSS after valid segments
	bad(24,0x11004,8,"elf-entry-range") -- descriptor data, but points outside executable text
	bad(0x1C0,0x10001,4,"elf-entry-alignment")
	bad(0x1C0,0x12000,4,"elf-entry-range")
	atomic(image,{entryMode="bad"},"elf-entry-mode")
	atomic(image,{entryMode="direct"},"elf-entry-mode")
	atomic(image,{stackTop=0/0},"elf-stack");atomic(image,{stackBytes=math.huge},"elf-stack")
	atomic(image,{stackTop=0x20000,stackBytes=0x10000},"elf-stack-overlap")
	atomic(image,{returnAddress=0x10000},"elf-return-overlap")
	atomic(image,{returnAddress=-4},"elf-return-address")
	local partial=clone(image);put(partial,64+4*56+16,2,8);put(partial,64+4*56+40,1,8)
	atomic(partial,nil,"elf-return-overlap")
	local seed=0x13579BDF
	local function random(n) seed=bit32.bxor(seed,bit32.lshift(seed,13));seed=bit32.bxor(seed,bit32.rshift(seed,17));seed=bit32.bxor(seed,bit32.lshift(seed,5));return seed%n end
	for _=1,1000 do
		local data=clone(image)
		-- Force one invalid header while corrupting arbitrary program/payload bytes.
		for _=1,1+random(8) do buffer.writeu8(data,random(buffer.len(data)),random(256)) end
		if rejected%3==0 then
			buffer.writeu8(data,4,1)
		elseif rejected%3==1 then
			put(data,64+4*56,7,4)
		else
			put(data,64+4*56,1,4);put(data,64+4*56+40,0xFFFFFFFF,8)
		end
		atomic(data)
	end
	local empty=clone(image)
	put(empty,64+4*56+16,0,8);put(empty,64+4*56+40,0,8);put(empty,64+4*56+48,65536,8)
	local emptyCPU=Platform.new({ramBytes=262144})
	check(Platform.LoadELF(emptyCPU,empty),"empty LOAD has no memory alignment requirement")
	check(Platform.RunStandalone(emptyCPU,32).kind=="returned","empty LOAD execution")
	-- Same input and destination buffer must not corrupt later source sections.
	local shared=Platform.new({ramBytes=262144})
	buffer.copy(shared.ram,0,image)
	local loaded=Platform.LoadELF(shared,shared.ram)
	check(loaded and Platform.RunStandalone(shared,32).kind=="returned","aliased source RAM")
	check(be32(shared.ram,0x12028)==0x01034566 and be32(shared.ram,0x1202C)==0x89ABCDFB,"aliased source checksum")
	return {checks=checks,rejected=rejected,compiledC=true,ps3BootSupported=false}
end

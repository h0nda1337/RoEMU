return function(Platform,cases)
	local checks=0
	local function check(value,why) assert(value,why);checks+=1 end
	local function unhex(hex)
		local b=buffer.create(#hex/2);for i=1,#hex,2 do buffer.writeu8(b,(i-1)/2,tonumber(hex:sub(i,i+1),16)) end;return b
	end
	local function put(b,at,w) for i=3,0,-1 do buffer.writeu8(b,at+i,w%256);w=math.floor(w/256) end end
	for _,v in ipairs(cases) do
		local c=Platform.new({ramBytes=65536,entry=0x1000})
		for i,p in ipairs(v.before) do c:setRegister(i-1,p[1],p[2]) end
		c:setFloatingRegister(3,v.initialF3[1],v.initialF3[2]);c.cr,c.xer=v.cr,v.xer
		buffer.copy(c.ram,v.dataAddress,unhex(v.data));put(c.ram,0x1000,v.word)
		check(c:step().kind=="ok" and c.pcLo==0x1004,"legal Cell cacheable access")
		for i,p in ipairs(v.after) do local h,l=c:getRegister(i-1);check(h==p[1] and l==p[2],"unaligned GPR/update/address calculation") end
		local h,l=c:getFloatingRegister(3);check(h==v.expectedF3[1] and l==v.expectedF3[2],"FP word-aligned raw bits")
		check(c.cr==v.expectedCR and c.xer==v.expectedXER,"unaligned access preserves CR/XER")
		check(buffer.readstring(c.ram,v.dataAddress,#v.data/2)==buffer.tostring(unhex(v.expectedMemory)),"unaligned big endian bytes and guards")
	end
	local c=Platform.new({ramBytes=65536})
	local function step(word)
		c.pcHi,c.pcLo=0,0x1000;put(c.ram,0x1000,word);return c:step()
	end
	local function x(xo) return 31*67108864+3*2097152+4*65536+5*2048+xo*2 end
	c:setFloatingRegister(3,0x7FF01234,0x56789ABC);c:setRegister(4,0,0x4101);c:setRegister(5,0,0)
	for _,word in ipairs({48*67108864+3*2097152+4*65536,49*67108864+3*2097152+4*65536,
		50*67108864+3*2097152+4*65536,51*67108864+3*2097152+4*65536,
		52*67108864+3*2097152+4*65536,53*67108864+3*2097152+4*65536,
		54*67108864+3*2097152+4*65536,55*67108864+3*2097152+4*65536,
		x(535),x(567),x(599),x(631),x(663),x(695),x(727),x(759)}) do
		local before=c.instructions;local data=buffer.readstring(c.ram,0x4100,16)
		check(step(word).kind=="memory_fault" and c.instructions==before and c.pcLo==0x1000,"FP byte misalignment remains a precise host fault")
		local h,l=c:getRegister(4);local fh,fl=c:getFloatingRegister(3)
		check(h==0 and l==0x4101 and fh==0x7FF01234 and fl==0x56789ABC and buffer.readstring(c.ram,0x4100,16)==data,"fault preserves base/FPR/RAM")
	end
	c:setRegister(4,0,0x4FFC)
	for _,word in ipairs({50*67108864+3*2097152+4*65536,54*67108864+3*2097152+4*65536,x(599),x(727)}) do
		local before=c.instructions;check(step(word).kind=="memory_fault" and c.instructions==before,"doubleword FP crossing configured data page faults")
	end
	local large=Platform.new({ramBytes=65536,dataPageBytes=65536,entry=0x1000})
	large:setRegister(4,0,0x4FFC);put(large.ram,0x4FFC,0x11223344);put(large.ram,0x5000,0x55667788)
	put(large.ram,0x1000,50*67108864+3*2097152+4*65536)
	check(large:step().kind=="ok","FP access obeys configured page size")
	local h,l=large:getFloatingRegister(3);check(h==0x11223344 and l==0x55667788,"word-aligned FP across a 4K marker within a larger page")
	for _,bad in ipairs({0,1,4095,4097,33554432,"4096",0/0}) do check(not pcall(Platform.new,{dataPageBytes=bad}),"invalid page quantum rejected") end
	for _,item in ipairs({{x(20),0x4101},{x(84),0x4104},{x(150)+1,0x4101},{x(214)+1,0x4104}}) do
		c:setRegister(4,0,item[2]);local before=c.instructions;local cr=c.cr
		check(step(item[1]).kind=="memory_fault" and c.instructions==before and c.cr==cr,"atomic reservations retain natural alignment")
	end
	c:setRegister(4,0,65532);buffer.fill(c.ram,65528,0xA5,8)
	local before=c.instructions;check(step(62*67108864+3*2097152+4*65536).kind=="memory_fault" and c.instructions==before and buffer.readstring(c.ram,65528,8)==string.rep("\xA5",8),"out-of-RAM unaligned store does not partially commit")
	c.pcHi,c.pcLo=0,0x1001;before=c.instructions;check(c:step().kind=="memory_fault" and c.instructions==before,"instruction fetch still requires four-byte alignment")
	return {checks=checks,vectors=#cases,cacheableIntegerUnaligned=true,cellFPAlignment=true,reservationAlignment=true,ps3BootSupported=false}
end

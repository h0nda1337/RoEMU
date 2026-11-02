return function(Platform,vectors,threads)
	local checks=0
	local function check(value,why) assert(value,why);checks+=1 end
	local function put(b,at,w) for i=3,0,-1 do buffer.writeu8(b,at+i,w%256);w=math.floor(w/256) end end
	local function get(b,at) return buffer.readu8(b,at)*16777216+buffer.readu8(b,at+1)*65536+buffer.readu8(b,at+2)*256+buffer.readu8(b,at+3) end
	local function x(xo,rt,ra,rb,rc) return 31*67108864+rt*2097152+ra*65536+rb*2048+xo*2+(rc or 0) end
	local c=Platform.new({ramBytes=65536})
	local function step(word)
		put(c.ram,0x1000,word);c.pcHi,c.pcLo=0,0x1000;return c:step()
	end
	for _,v in ipairs(vectors) do
		for i=0,31 do c:setRegister(i,0,0);c:setFloatingRegister(i,0,0) end
		c:setFloatingRegister(3,v.source[1],v.source[2]);c:setFloatingRegister(4,v.initialF4[1],v.initialF4[2]);c.fpscr,c.cr=v.fpscr,v.cr
		put(c.ram,0x4100,v.memory)
		check(step(v.word).kind=="ok","raw-bit vector executes")
		local h,l=c:getFloatingRegister(3);check(h==v.f3[1] and l==v.f3[2],"FPR3 IEEE bits including signaling NaN payload")
		h,l=c:getFloatingRegister(4);check(h==v.f4[1] and l==v.f4[2],"FPR4 sign/move result")
		check(c.cr==v.expectedCR and c.fpscr==v.fpscr and get(c.ram,0x4100)==v.expectedMemory,"memory/CR1 and unchanged FPSCR")
	end
	c:setRegister(5,0,0x4100);c:setRegister(6,0,0)
	put(c.ram,0x4100,0x7FF01234);put(c.ram,0x4104,0x56789ABC)
	check(step(x(631,5,5,6)).kind=="ok","lfdux same number in separate banks")
	local h,l=c:getFloatingRegister(5);local gh,gl=c:getRegister(5)
	check(h==0x7FF01234 and l==0x56789ABC and gh==0 and gl==0x4100,"raw double and updated GPR")
	c.reservation={granule=0x4100,address=0x4100,bytes=8,high=h,low=l}
	check(step(x(759,5,5,6)).kind=="ok" and c.reservation==nil,"floating store invalidates reservation")
	for _,xo in ipairs({246,278}) do
		c.reservation={granule=0x4100};c:setRegister(6,0xFFFFFFFF,0xFFFFFFFF)
		local cr,fpscr,token=c.cr,c.fpscr,c.reservation
		check(step(x(xo,0,0,6)).kind=="ok" and c.cr==cr and c.fpscr==fpscr and c.reservation==token,"prefetch does not dereference EA or consume reservation")
	end
	for _,word in ipairs({x(599,5,0,6),x(727,5,0,6)}) do
		local count,cr,fpscr,token=c.instructions,c.cr,c.fpscr,c.reservation
		local before=buffer.readstring(c.ram,0x4100,8)
		check(step(word).kind=="memory_fault" and c.instructions==count and c.cr==cr and c.fpscr==fpscr and c.reservation==token and buffer.readstring(c.ram,0x4100,8)==before,"FPR access fault has no architectural mutation")
	end
	for _,word in ipairs({x(278,0,0,6,1),x(599,5,0,6,1),51*67108864+5*2097152+0x4100,63*67108864+5*2097152+65536+72*2,0xFC00002A}) do
		local count=c.instructions;check(step(word).kind=="unsupported_instruction" and c.instructions==count and c.pcLo==0x1000,"reserved forms/arithmetic remain explicit stops")
	end
	-- The real compiled multi-thread fixture never uses FPRs. Inject different
	-- raw state per resident thread and check it survives actual yields/waits.
	c=Platform.new({ramBytes=2*1024*1024})
	c:setFloatingRegister(31,0x7FF01234,0x56789ABC);c.fpscr=0x80000000
	check(Platform.LoadProcess(c,threads,{quantum=1}),"compiled context-switch test")
	h,l=c:getFloatingRegister(31);check(h==0 and l==0 and c.fpscr==0,"ELF/process load resets FPR state")
	local seen,last,switches={},nil,0
	local function verifyResident()
		local id=c.process.cpuThreadId
		if not id or id==last then return end
		last=id;switches+=1
		for i=0,31 do
			local wantH,wantL=0,0
			if seen[id] then wantH=0x7FF00000+i;wantL=(id+i*7919)%4294967296 end
			local ah,al=c:getFloatingRegister(i)
			check(ah==wantH and al==wantL,"FPR isolation across real thread switches")
		end
		check(c.fpscr==(seen[id] and bit32.lshift(id%16,28) or 0),"FPSCR isolation/initialization")
		if not seen[id] then
			seen[id]=true
			for i=0,31 do c:setFloatingRegister(i,0x7FF00000+i,(id+i*7919)%4294967296) end
			c.fpscr=bit32.lshift(id%16,28)
		end
	end
	local result
	for _=1,100000 do
		verifyResident();result=Platform.RunProcess(c,1)
		if result.kind~="budget" then break end
	end
	check(result.kind=="process-exited" and result.exitStatus==42,"compiled thread program completes with isolated FPR state")
	local count=0;for _ in pairs(seen) do count+=1 end
	check(count==4 and switches>8,"four contexts actually observed")
	return {checks=checks,rawBitVectors=#vectors,threadSwitches=switches,threadContexts=count,completeFloatingPoint=false}
end

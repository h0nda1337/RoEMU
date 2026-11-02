return function(Platform,vectors,exceptions,program)
	local checks=0
	local function check(value,why) assert(value,why);checks+=1 end
	local function put(b,at,w) for i=3,0,-1 do buffer.writeu8(b,at+i,w%256);w=math.floor(w/256) end end
	local c=Platform.new({ramBytes=65536,entry=0x1000})
	local function vector(v)
		for i=0,31 do c:setRegister(i,0x12345678,i*7919);c:setFloatingRegister(i,0x76543210,i*104729) end
		for _,r in ipairs(v.initial) do c:setFloatingRegister(r[1],r[2],r[3]) end
		c.fpscr,c.cr,c.pcHi,c.pcLo=v.fpscr,v.cr,0,0x1000
		put(c.ram,0x1000,v.word)
		local result=c:step();check(result.kind=="ok" and c.pcLo==0x1004,"FP instruction executes")
		for _,r in ipairs(v.expected) do
			local h,l=c:getFloatingRegister(r[1]);check(h==r[2] and l==r[3],"FP result bits/reg "..r[1].." word "..string.format("%08X",v.word))
		end
		check(c.fpscr==v.expectedFPSCR and c.cr==v.expectedCR,"FP status/CR1 word "..string.format("%08X status %08X vs %08X CR %08X vs %08X input %08X%08X initial %08X",v.word,c.fpscr,v.expectedFPSCR,c.cr,v.expectedCR,v.initial[1][2],v.initial[1][3],v.fpscr))
		local h,l=c:getRegister(3);check(h==0x12345678 and l==3*7919,"FP instruction does not alter GPR bank")
	end
	for _,v in ipairs(vectors) do vector(v) end
	for _,v in ipairs(exceptions) do vector(v) end
	for _,word in ipairs({0xFC00069C,0xFC000018,0xFC000024,0xEC000024}) do
		c.pcHi,c.pcLo,c.fpscr=0,0x1000,4;put(c.ram,0x1000,word)
		local before=c.instructions;local h,l=c:getFloatingRegister(0);local cr=c.cr
		check(c:step().kind=="unsupported_fp_mode" and c.pcLo==0x1000 and c.instructions==before and c.fpscr==4 and c.cr==cr,"non-IEEE mode stops without mutation")
		local ah,al=c:getFloatingRegister(0);check(h==ah and l==al,"unsupported FP mode preserves destination")
	end
	for _,budget in ipairs({1,13,256}) do
		c=Platform.new({ramBytes=1048576})
		check(Platform.LoadProcess(c,program),"compiled own FP process")
		local result
		for _=1,1000 do result=Platform.RunProcess(c,budget);if result.kind~="budget" then break end end
		check(result.kind=="process-exited" and result.exitStatus==42,"compiled FP program real instruction path")
		check(Platform.ProcessConsole(c)=="ROEMU_PPU_FLOATING_OK\n","compiled FP console")
	end
	check(not Platform.Status().bootSupported,"FP subset is not console boot")
	return {checks=checks,computeVectors=#vectors,exceptionVectors=#exceptions,compiledFloatingProcess=true,exitStatus=42,completeFloatingPoint=false}
end

-- Pending waits must park the CPU; timeout completion reacquires ownership.
return function(Platform,image)
	local checks=0
	local function check(value,why) assert(value,why);checks+=1 end
	local function put(b,at,value) for j=3,0,-1 do buffer.writeu8(b,at+j,value%256);value=math.floor(value/256) end end
	local function get(b,at) return buffer.readu8(b,at)*16777216+buffer.readu8(b,at+1)*65536+buffer.readu8(b,at+2)*256+buffer.readu8(b,at+3) end
	for _,timeout in ipairs({0,37}) do
		local cpu=Platform.new({ramBytes=1048576})
		local ok=Platform.LoadProcess(cpu,image,{trace=true});check(ok,"load wait fixture")
		local base=0xF0000;local code=cpu.pcLo
		local function invoke(number,...)
			cpu.pcHi,cpu.pcLo=0,code;put(cpu.ram,code,0x44000002);put(cpu.ram,code+4,0x60000000)
			cpu.process.slice=0
			for register=3,10 do cpu:setRegister(register,0,0) end
			for i,value in ipairs({...}) do cpu:setRegister(i+2,0,value) end
			cpu:setRegister(11,0,number)
			local r=Platform.RunProcess(cpu,1);local h,l=cpu:getRegister(3);return r,h,l
		end
		buffer.fill(cpu.ram,base,0,64)
		for i,value in ipairs({1,0x10,0x200,0x2000}) do put(cpu.ram,base+(i-1)*4,value) end
		local r,h,l=invoke(100,base+128,base);check(r.kind=="budget" and l==0,"mutex create")
		local mutex=get(cpu.ram,base+128)
		put(cpu.ram,base+64,0x200)
		r,h,l=invoke(105,base+132,mutex,base+64);check(l==0,"condition create")
		local condition=get(cpu.ram,base+132)
		r,h,l=invoke(107,condition,timeout);check(h==0xFFFFFFFF and l==0x80010009,"non-owner cannot wait")
		invoke(102,mutex);invoke(102,mutex)
		local before=cpu.instructions
		r=invoke(107,condition,timeout)
		check(cpu.instructions==before+1 and cpu.pcLo==code+4,"accepted wait advances once")
		check(cpu.process.threads[cpu.process.threadId].state=="waiting" and cpu.process.mutexes[mutex].owner==0,"wait releases recursive mutex")
		local entry=cpu.process.trace[#cpu.process.trace];check(entry.pending==true,"wait trace remains pending")
		if timeout==0 then
			local clock=cpu.process.clockUS
			r=Platform.RunProcess(cpu,1000)
			check(r.kind=="process-waiting" and cpu.instructions==before+1 and cpu.process.clockUS==clock,"indefinite wait never busy polls or reports success")
			check(entry.pending and #cpu.process.conditions[condition].waiters==1,"waiter remains queued")
		else
			r=Platform.RunProcess(cpu,1);h,l=cpu:getRegister(3)
			check(r.kind=="budget" and h==0xFFFFFFFF and l==0x8001000B,"timeout result survives context restoration")
			check(cpu.process.mutexes[mutex].owner==cpu.process.threadId and cpu.process.mutexes[mutex].depth==2,"timeout returns with recursive ownership restored")
			check(not entry.pending and entry.result==0x8001000B and #cpu.process.conditions[condition].waiters==0,"completed wait trace reflects actual result")
		end
	end
	return {checks=checks,indefiniteWaitParks=true,timeoutReacquires=true}
end

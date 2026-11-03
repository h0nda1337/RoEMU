return function(Platform,image)
	local checks=0
	local function check(value,why) assert(value,why);checks+=1 end
	local function put(b,at,w) for j=3,0,-1 do buffer.writeu8(b,at+j,w%256);w=math.floor(w/256) end end
	local function get(b,at) return buffer.readu8(b,at)*16777216+buffer.readu8(b,at+1)*65536+buffer.readu8(b,at+2)*256+buffer.readu8(b,at+3) end
	local retired={}
	for _,priority in ipairs({false,true}) do
	for _,quantum in ipairs({1,2,7,17,256,4096}) do
		local c=Platform.new({ramBytes=4*1024*1024})
		check(Platform.LoadProcess(c,image,{argv=priority and {"/app_home/rwlocks.elf","P"} or {"/app_home/rwlocks.elf"},quantum=quantum,trace=true}),"load own C RW fixture")
		local result=Platform.RunProcess(c,100000)
		check(result.kind=="process-exited" and result.exitStatus==42,"compiled RW concurrency program")
		check(Platform.ProcessConsole(c)==(priority and "ROEMU_PPU_RWLOCK_PRIORITY_OK\n" or "ROEMU_PPU_RWLOCK_FIFO_OK\n"),"selected protocol verified by own C")
		check(c.process.rwlockCount==0 and c.process.mutexCount==0 and c.process.conditionCount==0,"all sync resources released")
		check(c.process.threadCount==1 and #c.process.threadRanges==0,"all children joined and stacks freed")
		local children=0;for _,thread in pairs(c.process.threads) do if not thread.main then children+=1;check(thread.reaped and thread.state=="exited","child actually completed") end end
		check(children==9,"nine actual worker threads")
		check(c.process.clockUS-c.instructions>200000,"timeouts advance idle clock instead of polling")
		retired[#retired+1]=c.instructions
	end
	end
	local c=Platform.new({ramBytes=1048576});check(Platform.LoadProcess(c,image,{trace=true,quantum=4096}),"syscall cases")
	local code=c.pcLo;local base=0xF0200;local main=c.process.threadId
	local function invoke(number,args)
		c.pcHi,c.pcLo=0,code;put(c.ram,code,0x44000002);put(c.ram,code+4,0x60000000);put(c.ram,code+8,0x48000000)
		for i=3,10 do c:setRegister(i,0,0) end
		for i,value in ipairs(args or {}) do if type(value)=="table" then c:setRegister(i+2,value[1],value[2]) else c:setRegister(i+2,0,value) end end
		c:setRegister(11,0,number);c.process.slice=0
		local result=Platform.RunProcess(c,1);local h,l=c:getRegister(3);return result,h,l
	end
	local function returns(number,args,expected)
		local result,h,l=invoke(number,args)
		check(result.kind=="budget" and l==expected and h==(expected>=0x80000000 and 0xFFFFFFFF or 0),"RW syscall result "..number)
	end
	local function attr(protocol,shared,key,flags)
		buffer.fill(c.ram,base,0,32);put(c.ram,base,protocol or 1);put(c.ram,base+4,shared or 0x200)
		put(c.ram,base+12,key or 0);put(c.ram,base+16,flags or 0)
	end
	attr(3);returns(120,{base+64,base},0x80010002)
	attr(1,0);returns(120,{base+64,base},0x80010002)
	attr(1,0x100);returns(120,{base+64,base},0x80010002)
	attr(1,0x100,1,0);returns(120,{base+64,base},0x80010002)
	attr(1,0x100,1,1)
	local before=c.instructions;local result=invoke(120,{base+64,base})
	check(result.kind=="unsupported_rwlock_ipc" and c.instructions==before and c.process.rwlockCount==0,"IPC stops explicitly before mutation")
	attr()
	for _,args in ipairs({{0,base},{base+64,0},{{1,base+64},base},{base+64,{1,base}},{base+64,0xFFFF0},{0x10000,base}}) do returns(120,args,0x8001000D) end
	buffer.writestring(c.ram,base+24,"r\0w-name")
	returns(120,{base+64,base},0);local id=get(c.ram,base+64)
	check(id==0x88000000 and c.process.rwlocks[id].name=="r\0w-name","opaque ID class and binary name")
	for n=121,127 do returns(n,{0},0x80010005) end
	returns(123,{id},0);returns(123,{id},0);check(c.process.rwlocks[id].readers==2,"recursive global reader count")
	returns(126,{id},0x8001000A);returns(127,{id},0x80010009);returns(121,{id},0x8001000A)
	returns(124,{id},0);returns(124,{id},0);returns(124,{id},0x80010009)
	returns(125,{id},0);returns(125,{id},0x80010008);returns(126,{id},0x80010008);returns(123,{id},0x8001000A)
	before=c.instructions;result=invoke(122,{id,{0x200000,0}})
	check(result.kind=="unsupported_timeout" and c.instructions==before and #c.process.rwlocks[id].readerWaiters==0,"huge blocking timeout is rejected without a waiter")
	returns(127,{id},0);returns(121,{id},0)
	-- HLE attributes are byte-readable; no extra host alignment restriction.
	attr();buffer.copy(c.ram,base+1,c.ram,base,32)
	returns(120,{base+65,base+1},0);id=get(c.ram,base+65);returns(121,{id},0)
	-- Real created/started PPU contexts queue at the actual syscall instruction.
	local function child(number,timeout,handle,priority)
		local at=code+0x200+(number==122 and 0 or 0x80)
		local function move(rt,rs) return 0x7C000378+rs*2097152+rt*65536+rs*2048 end
		local unlock=number==122 and 124 or 127
		local program={move(30,3),0x38800000+timeout,0x39600000+number,0x44000002,move(31,3),0x2C230000,0x40820010,
			move(3,30),0x39600000+unlock,0x44000002,move(3,31),0x39600029,0x44000002}
		for i,w in ipairs(program) do put(c.ram,at+(i-1)*4,w) end
		put(c.ram,base+96,at);put(c.ram,base+100,0);put(c.ram,base+104,base+96);put(c.ram,base+108,0)
		returns(52,{base+128,base+104,handle,0,priority or 1000,4096,1},0)
		local tid=get(c.ram,base+132);returns(53,{tid},0)
		for _=1,30 do
			Platform.RunProcess(c,1)
			if c.process.threads[tid].state=="waiting" then break end
		end
		check(c.process.threads[tid].state=="waiting","real child parked on RW syscall")
		Platform.RunProcess(c,1);check(c.process.threadId==main,"main restored after child parks")
		return tid
	end
	for _,protocol in ipairs({1,2}) do
		attr(protocol);returns(120,{base+64,base},0);id=get(c.ram,base+64)
		returns(125,{id},0)
		local reader=child(122,0,id,1000)
		local a=child(125,0,id,1000);local b=child(125,0,id,999)
		check(#c.process.rwlocks[id].readerWaiters==1 and #c.process.rwlocks[id].writerWaiters==2,"all actual waiters observed before release")
		returns(127,{id},0)
		check(c.process.rwlocks[id].writer==(protocol==1 and a or b),"writer preference and FIFO/priority choice before scheduling")
		for _=1,150 do Platform.RunProcess(c,1);if c.process.threads[reader].state=="exited" and c.process.threadId==main then break end end
		check(c.process.threads[a].exitLo==0 and c.process.threads[b].exitLo==0 and c.process.threads[reader].exitLo==0,"both writers and reader completed their real syscalls")
		check(c.process.rwlocks[id].writer==0 and c.process.rwlocks[id].readers==0,"child unlocks restored empty lock")
		returns(121,{id},0)
	end
	attr();returns(120,{base+64,base},0);id=get(c.ram,base+64);returns(122,{id},0)
	local writer=child(125,37,id,1000);local reader=child(122,0,id,1000)
	local waitingTrace=c.process.threads[writer].pendingTrace
	returns(141,{100},0)
	for _=1,200 do Platform.RunProcess(c,1);if c.process.threads[reader].state=="exited" and c.process.threadId==main then break end end
	check(c.process.threads[writer].exitLo==0x8001000B and c.process.threads[writer].exitHi==0xFFFFFFFF,"writer timeout survives save/restore")
	check(c.process.threads[reader].exitLo==0 and c.process.rwlocks[id].readers==1,"last writer timeout admits reader while main still holds read")
	check(waitingTrace.pending==false and waitingTrace.result==0x8001000B,"pending trace resolves to actual timeout")
	returns(124,{id},0);returns(121,{id},0)
	-- A self reader request under an exclusive lock can deadlock indefinitely.
	attr();returns(120,{base+64,base},0);id=get(c.ram,base+64);returns(125,{id},0)
	invoke(122,{id,0});local count,clock=c.instructions,c.process.clockUS
	result=Platform.RunProcess(c,10000)
	check(result.kind=="process-waiting" and c.instructions==count and c.process.clockUS==clock,"infinite RW wait parks without guest polling")
	check(c.process.rwlocks[id].writer==main and #c.process.rwlocks[id].readerWaiters==1,"parked request retains real ownership/queue")
	check(not Platform.Status().bootSupported,"RW services do not claim GameOS")
	return {checks=checks,quanta=6,protocolProfiles=2,compiledChildrenPerRun=9,retired=retired,writerPreference=true,indefiniteWaitParks=true,ps3BootSupported=false}
end

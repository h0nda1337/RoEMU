--!native
--!optimize 2
-- Single PPU user process foundation. Not LV2, console boot or GameOS.
-- Independent implementation of the observed PPU entry/syscall interfaces.
local ELF=script and require(script.Parent.RoEmu_PowerPC_ELF64) or require("./RoEmu_PowerPC_ELF64")
local Scheduler=script and require(script.Parent.RoEmu_PS3_Scheduler) or require("./RoEmu_PS3_Scheduler")
local Process={VERSION="0.2.0"}
local function failure(code,message) return false,{code=code,message=message} end
local function align16(value) return math.ceil(value/16)*16 end
local function put32(data,at,value)
	for i=3,0,-1 do buffer.writeu8(data,at+i,value%256);value=math.floor(value/256) end
end
local function putPointer(data,at,value) put32(data,at,0);put32(data,at+4,value) end
local function put64(data,at,high,low) put32(data,at,high);put32(data,at+4,low) end
local function get32(data,at)
	return buffer.readu8(data,at)*16777216+buffer.readu8(data,at+1)*65536+buffer.readu8(data,at+2)*256+buffer.readu8(data,at+3)
end
local function strings(value,default)
	if value==nil then value=default end
	if type(value)~="table" then return nil end
	local result,bytes={},0
	for key,item in pairs(value) do
		if type(key)~="number" or key%1~=0 or key<1 or key>256 or type(item)~="string" or string.find(item,"\0",1,true) then return nil end
		result[key]=item;bytes+=align16(#item+1)
		if bytes>131072 then return nil end
	end
	local count=0;for _ in pairs(result) do count+=1 end
	for i=1,count do if result[i]==nil then return nil end end
	return result,bytes
end
function Process.Load(cpu,data,options)
	options=options or {}
	if type(options)~="table" then return failure("ps3-options","Process options must be a table") end
	if type(data)=="string" then data=buffer.fromstring(data) end
	if typeof(data)~="buffer" or buffer.len(data)<64 or buffer.readu8(data,7)~=0x66 then return failure("ps3-elf","Expected an unencrypted ELF with PS3 LV2 OSABI") end
	local argv,argBytes=strings(options.argv,{"/app_home/program.elf"})
	local envp,envBytes=strings(options.envp,{})
	if not argv or not envp then return failure("ps3-arguments","Arguments/environment must be dense arrays of at most 256 NUL-free byte strings") end
	local threadId,pid=options.threadId or 0x1000000,options.pid or 1
	for _,value in ipairs({threadId,pid}) do
		if type(value)~="number" or value%1~=0 or value<1 or value>0xFFFFFFFF then return failure("ps3-identity","Thread/process ID must fit a positive 32-bit integer") end
	end
	local tlsMode=options.tlsMode or "static"
	if tlsMode~="static" and tlsMode~="guest" then return failure("ps3-tls-mode","Choose static TLS or guest initialization") end
	local priority,quantum=options.priority or 1001,options.quantum or 256
	if type(priority)~="number" or priority%1~=0 or priority<0 or priority>3071 or type(quantum)~="number" or quantum%1~=0 or quantum<1 or quantum>65536 then return failure("ps3-scheduler-options","Invalid PPU priority/instruction quantum") end
	local pointerBytes=align16((#argv+#envp+2)*8)
	local reserved=pointerBytes+argBytes+envBytes
	local ok,image=ELF.Load(cpu,data,{entryMode="ps3-ppu",stackTop=options.stackTop,stackBytes=options.stackBytes,
		returnAddress=options.returnAddress,stackReservedBytes=reserved,tlsMode=tlsMode,tlsAddress=options.tlsAddress})
	if not ok then return false,image end
	-- Everything below has been bounded before ELF's atomic commit.
	local address=image.stackTop-reserved
	local textAt=address+pointerBytes
	local function writeList(list,at)
		for _,item in ipairs(list) do
			putPointer(cpu.ram,at,textAt)
			buffer.writestring(cpu.ram,textAt,item)
			textAt+=align16(#item+1);at+=8
		end
		putPointer(cpu.ram,at,0)
	end
	local envAddress=address+(#argv+1)*8
	writeList(argv,address);writeList(envp,envAddress)
	for register,value in pairs({[3]=#argv,[4]=address,[5]=envAddress,[6]=#envp,[7]=threadId,
		[8]=image.tls and image.tls.address or 0,[9]=image.tls and image.tls.fileBytes or 0,
		[10]=image.tls and image.tls.memoryBytes or 0,[11]=image.descriptorAddress,[12]=0x100000}) do cpu:setRegister(register,0,value) end
	local state={kind="ps3-ppu-process",state="runnable",pid=pid,threadId=threadId,argv=argv,envp=envp,
		argvAddress=address,envpAddress=envAddress,tlsMode=tlsMode,tty={},ttyBytes=0,syscalls=0,
		mutexes={},nextMutex=0x85000000,mutexCount=0,inheritCount=0,conditions={},nextCondition=0x86000000,conditionCount=0,
		lightMutexes={},nextLightMutex=0x95000000,lightMutexCount=0,
		allocations={},trace=options.trace==true and {} or nil,bootSupported=false,importsLinked=false}
	cpu.process=state
	Scheduler.Init(cpu,state,priority,quantum)
	cpu.readTimeBase=function()
		local lower=(state.clockUS%4294967296)*80
		local high=bit32.band(math.floor(state.clockUS/4294967296)*80+math.floor(lower/4294967296),0xFFFFFFFF)
		return high,bit32.band(lower,0xFFFFFFFF)
	end
	image.standaloneOnly=false;image.processKind=state.kind
	return true,state
end
local function access(cpu,address,bytes,write)
	if address<0 or bytes<0 or address+bytes>buffer.len(cpu.ram) then return false end
	local image=cpu.loadedImage
	if address>=image.stackTop-image.stackBytes and address+bytes<=image.stackTop then return true end
	local tls=image.tls
	if tls and tls.allocation and address>=tls.allocation and address+bytes<=tls.allocation+tls.allocationBytes then return true end
	for _,s in ipairs(image.segments) do
		if address>=s.address and address+bytes<=s.address+s.memoryBytes and bit32.band(s.flags,write and 2 or 4)~=0 then return true end
	end
	for start,size in pairs(cpu.process.allocations) do if address>=start and address+bytes<=start+size then return true end end
	for _,range in ipairs(cpu.process.threadRanges) do if address>=range.address and address+bytes<=range.address+range.bytes then return true end end
	return false
end
local function allocation(cpu,bytes,alignment)
	local ranges={}
	local image=cpu.loadedImage
	for _,s in ipairs(image.segments) do ranges[#ranges+1]={s.address,s.address+s.memoryBytes} end
	ranges[#ranges+1]={image.stackTop-image.stackBytes,image.stackTop}
	ranges[#ranges+1]={image.returnAddress,image.returnAddress+4}
	local tls=image.tls
	if tls and tls.allocation then ranges[#ranges+1]={tls.allocation,tls.allocation+tls.allocationBytes} end
	for start,size in pairs(cpu.process.allocations) do ranges[#ranges+1]={start,start+size} end
	for _,range in ipairs(cpu.process.threadRanges) do ranges[#ranges+1]={range.address,range.address+range.bytes} end
	table.sort(ranges,function(a,b) return a[1]<b[1] end)
	local candidate=math.ceil(0x10000/alignment)*alignment
	for _,range in ipairs(ranges) do
		if candidate+bytes<=range[1] then return candidate end
		if candidate<range[2] then candidate=math.ceil(range[2]/alignment)*alignment end
	end
	if candidate+bytes<=buffer.len(cpu.ram) then return candidate end
	return nil
end
local function takeWaiter(state,queue,protocol,target)
	local index
	for i,waiter in ipairs(queue) do
		if (not target or waiter.thread==target) and (not index or protocol~=1 and Scheduler.Priority(state,state.threads[waiter.thread])<Scheduler.Priority(state,state.threads[queue[index].thread])) then index=i end
	end
	if index then return table.remove(queue,index) end
	return nil
end
local function grantMutex(state,mutex)
	if mutex.owner~=0 then return end
	Scheduler.UpdatePriorities(state)
	local waiter=takeWaiter(state,mutex.waiters,mutex.protocol)
	if waiter then
		mutex.owner,mutex.depth=waiter.thread,waiter.depth
		Scheduler.Wake(state.threads[waiter.thread],waiter.result or 0)
		state.readyChange=true
	end
end
local function transferCondition(state,condition,target)
	local mutex=state.mutexes[condition.mutex]
	local waiter=takeWaiter(state,condition.waiters,mutex.protocol,target)
	if waiter then
		local thread=state.threads[waiter.thread]
		thread.waiting={kind="mutex-reacquire",mutex=condition.mutex}
		mutex.waiters[#mutex.waiters+1]=waiter;grantMutex(state,mutex)
	end
	return waiter~=nil
end
local function deadline(cpu,register)
	local high,low=cpu:getRegister(register)
	if high==0 and low==0 then return true,nil end
	local value=high*4294967296+low
	if value>9007199254740991-cpu.process.clockUS then return false,nil end
	return true,cpu.process.clockUS+value
end
local function refreshWaits(state)
	if not state.nextDeadline or state.clockUS<state.nextDeadline then return end
	for _,thread in pairs(state.threads) do
		local wait=thread.waiting
		if wait and wait.deadline and wait.deadline<=state.clockUS then
			if wait.kind=="condition" then
				local condition=state.conditions[wait.condition]
				local waiter=takeWaiter(state,condition.waiters,1,thread.id)
				waiter.result=0x8001000B
				local mutex=state.mutexes[wait.mutex]
				thread.waiting={kind="mutex-reacquire",mutex=wait.mutex}
				mutex.waiters[#mutex.waiters+1]=waiter;grantMutex(state,mutex)
			elseif wait.kind=="mutex" then
				takeWaiter(state,state.mutexes[wait.mutex].waiters,1,thread.id)
				Scheduler.Wake(thread,0x8001000B)
				state.readyChange=true
			elseif wait.kind=="light-mutex" then
				takeWaiter(state,state.lightMutexes[wait.mutex].waiters,1,thread.id)
				Scheduler.Wake(thread,0x8001000B);state.readyChange=true
			elseif wait.kind=="sleep" then Scheduler.Wake(thread,0);state.readyChange=true
			end
		end
	end
	state.nextDeadline=nil
	for _,thread in pairs(state.threads) do
		local wait=thread.waiting
		if wait and wait.deadline and (not state.nextDeadline or wait.deadline<state.nextDeadline) then state.nextDeadline=wait.deadline end
	end
end
local function noteDeadline(state,due)
	if due and (not state.nextDeadline or due<state.nextDeadline) then state.nextDeadline=due end
end
local function schedule(cpu,rotate)
	local state=cpu.process
	refreshWaits(state)
	if Scheduler.Select(cpu,rotate) then return true end
	local nextTime
	for _,thread in pairs(state.threads) do
		local wait=thread.waiting
		if wait and wait.deadline and (not nextTime or wait.deadline<nextTime) then nextTime=wait.deadline end
	end
	if nextTime then state.clockUS=nextTime;state.nextDeadline=nextTime;refreshWaits(state);return Scheduler.Select(cpu,true) end
	return false
end
local function call(cpu,trap)
	local state=cpu.process
	local high,number=cpu:getRegister(11)
	local trace
	if state.trace then
		trace={number=number,pc=cpu.pcLo,args={}}
		for register=3,8 do local h,l=cpu:getRegister(register);trace.args[#trace.args+1]={h,l} end
	end
	local result=0
	if high~=0 then return {kind="unimplemented_syscall",numberHi=high,number=number,pc=cpu.pcLo} end
	if number==22 then
		local _,status=cpu:getRegister(3)
		state.exitStatus=status>=0x80000000 and status-4294967296 or status
		state.state="exited"
	elseif number==1 then
		result=state.pid
	elseif number==43 then state.rotate=true
	elseif number==52 then
		local outHi,out=cpu:getRegister(3);local paramHi,param=cpu:getRegister(4)
		local argHi,arg=cpu:getRegister(5);local secondHi,second=cpu:getRegister(6)
		local _,priority=cpu:getRegister(7);local stackHi,stackSize=cpu:getRegister(8)
		local flagHi,flags=cpu:getRegister(9);local nameHi,name=cpu:getRegister(10)
		if outHi~=0 or paramHi~=0 or out==0 or param==0 or out%8~=0 or param%4~=0 or not access(cpu,out,8,true) or not access(cpu,param,8,false) then result=0x8001000D
		elseif priority>3071 then result=0x80010002
		elseif flagHi==0 and flags==3 then result=0x80010009
		elseif flagHi~=0 or flags>1 then return {kind="unsupported_thread_flags",number=number,pc=cpu.pcLo}
		elseif stackHi~=0 or stackSize>buffer.len(cpu.ram)-4095 then result=0x80010004
		elseif state.threadCount>=256 then result=0x80010001
		else
			local descriptor=get32(cpu.ram,param);local tls=get32(cpu.ram,param+4)
			local validName=nameHi==0;local threadName=""
			if name~=0 then
				local chars={};validName=false
				for i=0,27 do
					if not access(cpu,name+i,1,false) then break end
					local char=buffer.readu8(cpu.ram,name+i)
					if char==0 then validName=nameHi==0;break end
					chars[#chars+1]=string.char(char)
				end
				threadName=table.concat(chars)
			end
			if descriptor==0 or descriptor%4~=0 or not access(cpu,descriptor,8,false) or not validName then result=0x8001000D
			else
				local entry,toc=get32(cpu.ram,descriptor),get32(cpu.ram,descriptor+4)
				local executable=false
				for _,s in ipairs(cpu.loadedImage.segments) do if entry>=s.address and entry+4<=s.address+s.fileBytes and bit32.band(s.flags,1)~=0 then executable=true;break end end
				stackSize=math.max(4096,math.ceil(stackSize/4096)*4096)
				local stack=allocation(cpu,stackSize,4096)
				if entry%4~=0 or not executable then result=0x8001000D
				elseif not stack then result=0x80010004
				else
					local id=state.nextThread;while state.threads[id] do id+=1 end
					state.nextThread=id+1;state.threadCount+=1
					local context={hi=table.create(32,0),lo=table.create(32,0),pcHi=0,pcLo=entry,lrHi=0,lrLo=cpu.loadedImage.returnAddress,ctrHi=0,ctrLo=0,cr=0,xer=0}
					context.lo[2],context.lo[3],context.lo[14]=stack+stackSize-0x70,toc,tls
					context.hi[4],context.lo[4],context.hi[5],context.lo[5]=argHi,arg,secondHi,second
					state.threads[id]={id=id,state="created",priority=priority,context=context,stackAddress=stack,stackBytes=stackSize,joinable=flags==1,name=threadName}
					state.threadOrder[#state.threadOrder+1]=id
					state.threadRanges[#state.threadRanges+1]={address=stack,bytes=stackSize,thread=id}
					buffer.fill(cpu.ram,stack,0,stackSize);putPointer(cpu.ram,out,id)
				end
			end
		end
	elseif number==53 then
		local high,id=cpu:getRegister(3);local thread=high==0 and state.threads[id] or nil
		if not thread or thread.reaped then result=0x80010005
		elseif thread.state~="created" then result=0x8001000A
		else thread.state="runnable";state.readyChange=true end
	elseif number==41 then
		local thread=Scheduler.Current(cpu)
		thread.exitHi,thread.exitLo=cpu:getRegister(3);thread.state="exited"
		if thread.joiner then
			local joiner=state.threads[thread.joiner]
			local reply=0
			if joiner.waiting.output~=0 then
				if access(cpu,joiner.waiting.output,8,true) then put64(cpu.ram,joiner.waiting.output,thread.exitHi,thread.exitLo) else reply=0x8001000D end
			end
			Scheduler.Wake(joiner,reply);state.readyChange=true;thread.reaped=true;state.threadCount-=1
		elseif not thread.joinable then thread.reaped=true;state.threadCount-=1
		end
		for i=#state.threadRanges,1,-1 do if state.threadRanges[i].thread==thread.id then table.remove(state.threadRanges,i) end end
	elseif number==44 then
		local high,id=cpu:getRegister(3);local outHi,out=cpu:getRegister(4)
		local target=high==0 and state.threads[id] or nil
		if id==state.threadId then result=0x80010008
		elseif not target or target.reaped then result=0x80010005
		elseif not target.joinable or target.joiner then result=0x80010002
		elseif outHi~=0 or (out~=0 and (out%8~=0 or not access(cpu,out,8,true))) then result=0x8001000D
		elseif target.state=="exited" then if out~=0 then put64(cpu.ram,out,target.exitHi,target.exitLo) end;target.reaped=true;state.threadCount-=1
		else
			target.joiner=state.threadId
			local thread=Scheduler.Current(cpu);thread.state="waiting";thread.waiting={kind="join",thread=id,output=out}
		end
	elseif number==45 then
		local high,id=cpu:getRegister(3);local target=high==0 and state.threads[id] or nil
		if not target or target.reaped then result=0x80010005
		elseif not target.joinable or target.joiner then result=0x80010002
		else target.joinable=false;if target.state=="exited" then target.reaped=true;state.threadCount-=1 end end
	elseif number==47 or number==48 then
		local high,id=cpu:getRegister(3);local h,value=cpu:getRegister(4)
		local thread=high==0 and state.threads[id] or nil
		if not thread or thread.reaped then result=0x80010005
		elseif number==47 then if value>3071 then result=0x80010002 else thread.priority=value;state.readyChange=true end
		elseif h~=0 or value%4~=0 or not access(cpu,value,4,true) then result=0x8001000D
		else put32(cpu.ram,value,thread.priority) end
	elseif number==49 then
		local high,out=cpu:getRegister(3);local thread=Scheduler.Current(cpu)
		if high~=0 or out%4~=0 or not access(cpu,out,8,true) then result=0x8001000D
		else put32(cpu.ram,out,thread.stackAddress);put32(cpu.ram,out+4,thread.stackBytes) end
	elseif number>=95 and number<=99 or number==117 then
		local high,id=cpu:getRegister(3)
		if number==95 then
			local protocolHi,protocol=cpu:getRegister(4);local controlHi,control=cpu:getRegister(5)
			local _,named=cpu:getRegister(6);local nameHi,nameLo=cpu:getRegister(7)
			if high~=0 or id==0 or id%4~=0 or not access(cpu,id,4,true) or controlHi~=0 then result=0x8001000D
			elseif protocolHi~=0 or (protocol~=1 and protocol~=2 and protocol~=4) then result=0x80010002
			elseif protocol==4 then return {kind="unsupported_light_mutex_protocol",number=number,pc=cpu.pcLo}
			elseif state.lightMutexCount>=4096 then result=0x80010001
			else
				local handle=state.nextLightMutex;state.nextLightMutex+=1;state.lightMutexCount+=1
				state.lightMutexes[handle]={protocol=protocol,control=control,signal=0,waiters={},nameHi=named>=0x80000000 and nameHi or 0,nameLo=named>=0x80000000 and nameLo or 0}
				put32(cpu.ram,id,handle)
			end
		else
			local mutex=high==0 and state.lightMutexes[id] or nil
			if not mutex then result=0x80010005
			elseif number==96 then
				if #mutex.waiters>0 then result=0x8001000A else state.lightMutexes[id]=nil;state.lightMutexCount-=1 end
			elseif number==98 or number==117 then
				local waiter=takeWaiter(state,mutex.waiters,mutex.protocol)
				if waiter then Scheduler.Wake(state.threads[waiter.thread],number==117 and 0x8001000A or 0);state.readyChange=true
				else mutex.signal=bit32.bor(mutex.signal,number==117 and 0x80000000 or 1) end
			elseif number==99 then
				if bit32.band(mutex.signal,1)==0 then result=0x8001000A else mutex.signal=0 end
			elseif mutex.signal~=0 then result=bit32.band(mutex.signal,1)==0 and 0x8001000A or 0;mutex.signal=0
			else
				local valid,due=deadline(cpu,4)
				if not valid then return {kind="unsupported_timeout",number=number,pc=cpu.pcLo} end
				local thread=Scheduler.Current(cpu);thread.state="waiting";thread.waiting={kind="light-mutex",mutex=id,deadline=due}
				mutex.waiters[#mutex.waiters+1]={thread=thread.id};noteDeadline(state,due)
			end
		end
	elseif number>=100 and number<=104 then
		local idHi,id=cpu:getRegister(3)
		if number==100 then
			local attrHi,attr=cpu:getRegister(4)
			if idHi~=0 or attrHi~=0 or id==0 or attr==0 or id%4~=0 or attr%8~=0 or not access(cpu,id,4,true) or not access(cpu,attr,40,false) then result=0x8001000D
			else
				local protocol,recursive,shared,adaptive=get32(cpu.ram,attr),get32(cpu.ram,attr+4),get32(cpu.ram,attr+8),get32(cpu.ram,attr+12)
				if protocol<1 or protocol>3 or (recursive~=0x10 and recursive~=0x20) or (shared~=0x100 and shared~=0x200) then result=0x80010002
				elseif shared~=0x200 or adaptive~=0x2000 then return {kind="unsupported_mutex_feature",number=number,pc=cpu.pcLo}
				elseif state.mutexCount>=4096 then result=0x80010001
				else
					local handle=state.nextMutex;state.nextMutex+=1;state.mutexCount+=1
					state.mutexes[handle]={owner=0,depth=0,recursive=recursive==0x10,protocol=protocol,conditionCount=0,waiters={},name=buffer.readstring(cpu.ram,attr+32,8)}
					if protocol==3 then state.inheritCount+=1 end
					put32(cpu.ram,id,handle)
				end
			end
		else
			local mutex=idHi==0 and state.mutexes[id] or nil
			if not mutex then result=0x80010005
			elseif number==101 then
				if mutex.owner~=0 then result=0x8001000A elseif mutex.conditionCount>0 then result=0x80010009
				else if mutex.protocol==3 then state.inheritCount-=1 end;state.mutexes[id]=nil;state.mutexCount-=1 end
			elseif number==104 then
				if mutex.owner~=state.threadId then result=0x80010009
				else mutex.depth-=1;if mutex.depth==0 then mutex.owner=0;grantMutex(state,mutex) end end
			elseif mutex.owner==0 then mutex.owner,mutex.depth=state.threadId,1
			elseif mutex.owner==state.threadId then
				if not mutex.recursive then result=0x80010008
				elseif mutex.depth==0x100000000 then result=0x80010011 else mutex.depth+=1 end
			elseif number==103 then result=0x8001000A
			else
				local valid,due=deadline(cpu,4)
				if not valid then return {kind="unsupported_timeout",number=number,pc=cpu.pcLo} end
				local thread=Scheduler.Current(cpu);thread.state="waiting";thread.waiting={kind="mutex",mutex=id,deadline=due}
				noteDeadline(state,due)
				mutex.waiters[#mutex.waiters+1]={thread=thread.id,depth=1}
			end
		end
	elseif number>=105 and number<=110 then
		local idHi,id=cpu:getRegister(3)
		if number==105 then
			local mHi,mutexId=cpu:getRegister(4);local attrHi,attr=cpu:getRegister(5)
			local mutex=mHi==0 and state.mutexes[mutexId] or nil
			if not mutex then result=0x80010005
			elseif idHi~=0 or attrHi~=0 or id==0 or attr==0 or id%4~=0 or attr%8~=0 or not access(cpu,id,4,true) or not access(cpu,attr,24,false) then result=0x8001000D
			else
				local shared=get32(cpu.ram,attr)
				if shared~=0x100 and shared~=0x200 then result=0x80010002
				elseif shared==0x100 and get32(cpu.ram,attr+8)==0 and get32(cpu.ram,attr+12)==0 then result=0x80010002
				elseif shared==0x100 then return {kind="unsupported_condition_ipc",number=number,pc=cpu.pcLo}
				elseif state.conditionCount>=4096 then result=0x80010001
				else
					local handle=state.nextCondition;state.nextCondition+=1;state.conditionCount+=1;mutex.conditionCount+=1
					state.conditions[handle]={mutex=mutexId,waiters={},name=buffer.readstring(cpu.ram,attr+16,8)}
					put32(cpu.ram,id,handle)
				end
			end
		else
			local condition=idHi==0 and state.conditions[id] or nil
			if not condition then result=0x80010005
			elseif number==106 then
				if #condition.waiters>0 then result=0x8001000A
				else state.mutexes[condition.mutex].conditionCount-=1;state.conditions[id]=nil;state.conditionCount-=1 end
			elseif number==107 then
				local mutex=state.mutexes[condition.mutex]
				if mutex.owner~=state.threadId then result=0x80010009
				else
					local valid,due=deadline(cpu,4)
					if not valid then return {kind="unsupported_timeout",number=number,pc=cpu.pcLo} end
					local thread=Scheduler.Current(cpu)
					condition.waiters[#condition.waiters+1]={thread=thread.id,depth=mutex.depth}
					thread.state="waiting";thread.waiting={kind="condition",condition=id,mutex=condition.mutex,deadline=due}
					noteDeadline(state,due)
					mutex.owner,mutex.depth=0,0;grantMutex(state,mutex)
				end
			elseif number==110 then
				local high,target=cpu:getRegister(4)
				if high~=0 or not state.threads[target] or state.threads[target].reaped then result=0x80010005
				elseif not transferCondition(state,condition,target) then result=0x80010009 end
			elseif number==108 then transferCondition(state,condition)
			else while transferCondition(state,condition) do end end
		end
	elseif number==147 then result=80000000
	elseif number==141 or number==142 then
		local valid,due
		if number==141 then valid,due=deadline(cpu,3)
		else
			local high,seconds=cpu:getRegister(3)
			valid=high==0 and seconds*1000000<=9007199254740991-state.clockUS
			due=valid and seconds>0 and state.clockUS+seconds*1000000 or nil
		end
		if not valid then return {kind="unsupported_timeout",number=number,pc=cpu.pcLo} end
		if due then local thread=Scheduler.Current(cpu);thread.state="waiting";thread.waiting={kind="sleep",deadline=due};noteDeadline(state,due)
		else state.rotate=true end
	elseif number==348 then
		local sizeHi,size=cpu:getRegister(3);local flagsHi,flags=cpu:getRegister(4);local outHi,out=cpu:getRegister(5)
		local alignment=(flags==0 or flags==0x400) and 0x100000 or (flags==0x200 and 0x10000 or 0)
		if sizeHi~=0 then result=0x80010004
		elseif size==0 then result=0x80010010
		elseif flagsHi~=0 or alignment==0 then result=0x80010002
		elseif size%alignment~=0 then result=0x80010010
		elseif outHi~=0 or out==0 or out%4~=0 or not access(cpu,out,4,true) then result=0x8001000D
		else
			local address=allocation(cpu,size,alignment)
			if not address then result=0x80010004
			else buffer.fill(cpu.ram,address,0,size);state.allocations[address]=size;put32(cpu.ram,out,address) end
		end
	elseif number==349 then
		local high,address=cpu:getRegister(3)
		if high~=0 or not state.allocations[address] then result=0x80010002 else state.allocations[address]=nil end
	elseif number==403 then
		local chHi,ch=cpu:getRegister(3);local bufHi,address=cpu:getRegister(4)
		local lenHi,length=cpu:getRegister(5);local outHi,written=cpu:getRegister(6)
		if chHi~=0 or ch>15 or lenHi~=0 or length>1048576 then result=0x80010002
		elseif (length>0 and (bufHi~=0 or not access(cpu,address,length,false))) or outHi~=0 or written%4~=0 or not access(cpu,written,4,true) then result=0x8001000D
		elseif state.ttyBytes+length>1048576 then return {kind="tty-buffer-full",number=number,pc=cpu.pcLo}
		else
			local text=length==0 and "" or buffer.readstring(cpu.ram,address,length)
			put32(cpu.ram,written,length)
			state.tty[#state.tty+1]={channel=ch,text=text};state.ttyBytes+=length
		end
	else return {kind="unimplemented_syscall",numberHi=high,number=number,pc=cpu.pcLo} end
	if state.state~="exited" and number~=41 then cpu:setRegister(3,result>=0x80000000 and 0xFFFFFFFF or 0,result) end
	cpu.pcHi,cpu.pcLo=trap.resumeHi,trap.resumeLo
	cpu.reservation=nil
	cpu.instructions+=1;state.syscalls+=1
	if trace then
		trace.result=result
		local current=Scheduler.Current(cpu)
		if current.state=="waiting" then trace.pending=true;current.pendingTrace=trace end
		if #state.trace>=32 then table.remove(state.trace,1) end
		state.trace[#state.trace+1]=trace
	end
	return {kind=state.state=="exited" and "process-exited" or "ok",exitStatus=state.exitStatus,instructions=cpu.instructions}
end
function Process.Run(cpu,budget)
	if not cpu.process or not cpu.loadedImage then return {kind="no-process"} end
	if type(budget)~="number" or budget%1~=0 or budget<1 or budget>1000000 then return {kind="bad-budget"} end
	if cpu.process.state=="exited" then return {kind="process-exited",exitStatus=cpu.process.exitStatus,instructions=cpu.instructions} end
	for _=1,budget do
		local state=cpu.process
		refreshWaits(state)
		local thread=Scheduler.Current(cpu)
		if state.readyChange or state.cpuThreadId==nil or not thread or thread.state~="runnable" or state.slice>=state.quantum or state.rotate then
			if not schedule(cpu,state.slice>=state.quantum or state.rotate==true) then return {kind="process-waiting",instructions=cpu.instructions,clockUS=state.clockUS} end
		end
		state.rotate=nil
		if cpu.pcHi==0 and cpu.pcLo==cpu.loadedImage.returnAddress then return {kind="unexpected-process-return",instructions=cpu.instructions} end
		local before=cpu.instructions
		local result=cpu:step()
		if result.kind=="system_call" then result=call(cpu,result) end
		local retired=cpu.instructions-before
		state.clockUS+=retired;state.slice+=retired
		if Scheduler.Current(cpu).state~="runnable" then Scheduler.Save(cpu);state.cpuThreadId=nil end
		if result.kind~="ok" then cpu.process.lastStop=result;return result end
	end
	return {kind="budget",pcHi=cpu.pcHi,pcLo=cpu.pcLo,instructions=cpu.instructions}
end
function Process.Console(cpu)
	local result={};if not cpu.process then return "" end
	for _,entry in ipairs(cpu.process.tty) do result[#result+1]=entry.text end
	return table.concat(result)
end
return Process

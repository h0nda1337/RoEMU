--!native
--!optimize 2
-- Single PPU user process foundation. Not LV2, console boot or GameOS.
-- Independent implementation of the observed PPU entry/syscall interfaces.
local ELF=script and require(script.Parent.RoEmu_PowerPC_ELF64) or require("./RoEmu_PowerPC_ELF64")
local Process={VERSION="0.1.0"}
local function failure(code,message) return false,{code=code,message=message} end
local function align16(value) return math.ceil(value/16)*16 end
local function put32(data,at,value)
	for i=3,0,-1 do buffer.writeu8(data,at+i,value%256);value=math.floor(value/256) end
end
local function putPointer(data,at,value) put32(data,at,0);put32(data,at+4,value) end
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
		mutexes={},nextMutex=0x85000000,mutexCount=0,allocations={},trace=options.trace==true and {} or nil,bootSupported=false,importsLinked=false}
	cpu.process=state
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
	table.sort(ranges,function(a,b) return a[1]<b[1] end)
	local candidate=math.ceil(0x10000/alignment)*alignment
	for _,range in ipairs(ranges) do
		if candidate+bytes<=range[1] then return candidate end
		if candidate<range[2] then candidate=math.ceil(range[2]/alignment)*alignment end
	end
	if candidate+bytes<=buffer.len(cpu.ram) then return candidate end
	return nil
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
					state.mutexes[handle]={owner=0,depth=0,recursive=recursive==0x10,protocol=protocol,name=buffer.readstring(cpu.ram,attr+32,8)}
					put32(cpu.ram,id,handle)
				end
			end
		else
			local mutex=idHi==0 and state.mutexes[id] or nil
			if not mutex then result=0x80010005
			elseif number==101 then
				if mutex.owner~=0 then result=0x8001000A else state.mutexes[id]=nil;state.mutexCount-=1 end
			elseif number==104 then
				if mutex.owner~=state.threadId then result=0x80010009
				else mutex.depth-=1;if mutex.depth==0 then mutex.owner=0 end end
			elseif mutex.owner==0 then mutex.owner,mutex.depth=state.threadId,1
			elseif mutex.owner==state.threadId then
				if not mutex.recursive then result=0x80010008
				elseif mutex.depth==0x100000000 then result=0x80010011 else mutex.depth+=1 end
			elseif number==103 then result=0x8001000A
			else return {kind="mutex-wait",number=number,mutex=id,pc=cpu.pcLo} end
		end
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
	if state.state~="exited" then cpu:setRegister(3,result>=0x80000000 and 0xFFFFFFFF or 0,result) end
	cpu.pcHi,cpu.pcLo=trap.resumeHi,trap.resumeLo
	cpu.instructions+=1;state.syscalls+=1
	if trace then
		trace.result=result
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
		if cpu.pcHi==0 and cpu.pcLo==cpu.loadedImage.returnAddress then return {kind="unexpected-process-return",instructions=cpu.instructions} end
		local result=cpu:step()
		if result.kind=="system_call" then result=call(cpu,result) end
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

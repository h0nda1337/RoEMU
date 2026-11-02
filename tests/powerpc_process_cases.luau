-- Own compiled process.c and explicit guest ABI/memory/state checks.
return function(Platform,image)
	local checks=0
	local function check(value,why) assert(value,why);checks+=1 end
	local function put(b,at,value,bytes)
		for i=bytes-1,0,-1 do buffer.writeu8(b,at+i,value%256);value=math.floor(value/256) end
	end
	local function get(b,at) return buffer.readu8(b,at)*16777216+buffer.readu8(b,at+1)*65536+buffer.readu8(b,at+2)*256+buffer.readu8(b,at+3) end
	local function new(options)
		local cpu=Platform.new({ramBytes=1024*1024})
		buffer.fill(cpu.ram,0,0xA7)
		local ok,state=Platform.LoadProcess(cpu,image,options or {argv={"/app_home/process.elf","abc"},envp={"ALPHA=42"}})
		check(ok,tostring(state.code));return cpu
	end
	local cpu=new()
	local tls=cpu.loadedImage.tls
	check(tls.fileBytes==8 and tls.memoryBytes==16 and tls.dataAddress~=tls.address,"private TLS copy")
	check(get(cpu.ram,tls.dataAddress)==0x00200000 and get(cpu.ram,tls.dataAddress+4)==1,"TLS initial image")
	check(get(cpu.ram,tls.dataAddress+8)==0 and get(cpu.ram,tls.allocation)==0,"TLS BSS/system area")
	check(cpu.pcLo==0x10000 and cpu.pcHi==0,"PPU entry descriptor")
	for i,value in pairs({[3]=2,[6]=1,[7]=0x1000000,[8]=0x20020,[9]=8,[10]=16,[11]=0x20000,[12]=0x100000,[13]=tls.threadPointer}) do
		local h,l=cpu:getRegister(i);check(h==0 and l==value,"process register r"..i)
	end
	local h,argv=cpu:getRegister(4);check(h==0 and get(cpu.ram,argv)==0 and get(cpu.ram,argv+20)==0,"argv64 terminator")
	local pointer=get(cpu.ram,argv+4);check(buffer.readstring(cpu.ram,pointer,21)=="/app_home/process.elf" and buffer.readu8(cpu.ram,pointer+21)==0,"argument bytes and terminator")
	local result=Platform.RunProcess(cpu,1);check(result.kind=="budget" and cpu.instructions==1,"process continuation budget")
	result=Platform.RunProcess(cpu,1000)
	check(result.kind=="process-exited" and result.exitStatus==42 and cpu.instructions==70,"actual C TLS/argument/syscall execution")
	check(Platform.ProcessConsole(cpu)=="ROEMU_PPU_TLS_ARGS_OK\n" and cpu.process.syscalls==2,"TTY and exit")
	check(get(cpu.ram,0x20020)==0x00200000 and get(cpu.ram,0x20024)==1,"TLS writes preserve template")
	check(Platform.RunStandalone(cpu,1).kind=="process-runner-required","process uses explicit syscall host")
	check(get(cpu.ram,0x20030)==0x00200000 and get(cpu.ram,0x20034)==42,"exact 64-bit observed value")
	local count=cpu.instructions;check(Platform.RunProcess(cpu,8).kind=="process-exited" and cpu.instructions==count,"terminal process is stable")
	local guest=new({tlsMode="guest"})
	h,pointer=guest:getRegister(13);check(h==0 and pointer==0 and guest.loadedImage.tls.allocation==nil,"self-initializing guest receives TLS metadata")
	local snapshot=buffer.tostring(guest.ram);local process=guest.process;local oldImage=guest.loadedImage;local pc=guest.pcLo
	local function rejected(data,options,code)
		local success,ok,report=pcall(Platform.LoadProcess,guest,data,options)
		check(success and not ok and report.code==code,"reject "..code)
		check(buffer.tostring(guest.ram)==snapshot and guest.process==process and guest.loadedImage==oldImage and guest.pcLo==pc,"atomic process rejection")
	end
	rejected(image,true,"ps3-options");rejected("SCE\0",nil,"ps3-elf")
	for _,options in ipairs({{argv={[1]="a",[3]="b",[5]="c"}},{argv={"a\0b"}},{envp={3}},{argv={string.rep("a",131073)}}}) do rejected(image,options,"ps3-arguments") end
	rejected(image,{threadId=0},"ps3-identity");rejected(image,{pid=0/0},"ps3-identity")
	rejected(image,{tlsMode="bad"},"ps3-tls-mode")
	rejected(image,{tlsAddress=0x20000},"elf-tls-overlap")
	rejected(image,{tlsAddress=0xF0000},"elf-tls-overlap")
	rejected(image,{tlsAddress=1},"elf-tls-allocation")
	rejected(image,{stackBytes=256,argv={string.rep("a",256)}},"elf-stack")
	for _,change in ipairs({{64+2*56+48,3,8,"elf-tls"},{64+2*56+16,0x40000,8,"elf-tls"},{64+2*56+32,17,8,"elf-tls"},{64+2*56+8,1,4,"elf-address-width"}}) do
		local data=buffer.fromstring(buffer.tostring(image));put(data,change[1],change[2],change[3]);rejected(data,nil,change[4])
	end
	local data=buffer.fromstring(buffer.tostring(image));put(data,56,4,2);buffer.copy(data,64+3*56,data,64+2*56,56);rejected(data,nil,"elf-tls")
	-- Nonzero TLS address residue preserves the compiler's TP-relative alignment.
	data=buffer.fromstring(buffer.tostring(image));put(data,64+2*56+8,804,8);put(data,64+2*56+16,0x20024,8);put(data,64+2*56+32,4,8);put(data,64+2*56+40,12,8)
	local residue=Platform.new({ramBytes=1048576});local ok=Platform.LoadProcess(residue,data)
	check(ok and residue.loadedImage.tls.dataAddress%8==4,"TLS residue alignment")
	check(get(residue.ram,residue.loadedImage.tls.dataAddress)==1,"TLS residue initializer")
	local c=new();local base=0xF0000
	local function syscall(number,args)
		c.pcHi,c.pcLo=0,0x10000;put(c.ram,0x10000,0x44000002,4)
		for i=3,10 do c:setRegister(i,0,0) end
		for i,value in ipairs(args or {}) do
			if type(value)=="table" then c:setRegister(i+2,value[1],value[2]) else c:setRegister(i+2,0,value) end
		end
		c:setRegister(11,0,number)
		local r=Platform.RunProcess(c,1);local hi,lo=c:getRegister(3);return r,hi,lo
	end
	local function returns(number,args,expected)
		local r,hi,lo=syscall(number,args)
		check(r.kind=="budget" and lo==expected and hi==(expected>=0x80000000 and 0xFFFFFFFF or 0),"syscall result/sign extension "..number)
	end
	returns(1,{},1)
	buffer.writestring(c.ram,base+0x100,"abc\0z")
	returns(403,{0,base+0x100,5,base+0x200},0)
	check(get(c.ram,base+0x200)==5 and Platform.ProcessConsole(c)=="abc\0z","binary TTY bytes and count")
	returns(403,{16,base+0x100,5,base+0x200},0x80010002)
	returns(403,{0,{1,base+0x100},5,base+0x200},0x8001000D)
	check(get(c.ram,base+0x200)==5 and c.process.ttyBytes==5,"failed write has no output side effects")
	returns(403,{0,{1,0xFFFFFFFF},0,base+0x200},0);check(get(c.ram,base+0x200)==0 and c.process.ttyBytes==5,"zero-byte TTY does not dereference source")
	local attr=base+0x300;buffer.fill(c.ram,attr,0,40)
	for i,value in ipairs({2,0x10,0x200,0x2000}) do put(c.ram,attr+(i-1)*4,value,4) end
	returns(100,{base+0x400,attr},0);local handle=get(c.ram,base+0x400)
	check(c.process.mutexCount==1 and handle==0x85000000,"mutex allocation")
	returns(102,{handle},0);returns(103,{handle},0)
	check(c.process.mutexes[handle].depth==2,"recursive owner depth")
	returns(101,{handle},0x8001000A);returns(104,{handle},0);returns(104,{handle},0);returns(104,{handle},0x80010009)
	returns(101,{handle},0);returns(103,{handle},0x80010005)
	put(c.ram,attr+4,0x20,4);returns(100,{base+0x400,attr},0);handle=get(c.ram,base+0x400)
	returns(102,{handle},0);returns(102,{handle},0x80010008);returns(104,{handle},0);returns(101,{handle},0)
	put(c.ram,attr+8,0x100,4)
	count=c.instructions;result=syscall(100,{base+0x400,attr});check(result.kind=="unsupported_mutex_feature" and c.instructions==count,"IPC stops explicitly")
	returns(348,{0x10000,0x200,base+0x500},0);local heap=get(c.ram,base+0x500)
	check(heap%65536==0 and heap~=0 and buffer.readstring(c.ram,heap,65536)==string.rep("\0",65536),"aligned zeroed real allocation")
	buffer.writestring(c.ram,heap+32,"heap")
	returns(403,{0,heap+32,4,heap+64},0);check(get(c.ram,heap+64)==4,"interior heap pointers")
	returns(349,{heap},0);returns(403,{0,heap+32,4,base+0x200},0x8001000D)
	returns(349,{heap},0x80010002);returns(348,{3,0x200,base+0x500},0x80010010)
	returns(348,{0x100000,0x400,base+0x500},0x80010004)
	returns(348,{0x10000,0x200,base+0x500},0);check(get(c.ram,base+0x500)==heap and get(c.ram,heap+32)==0,"freed allocation reuse and zeroing")
	count=c.instructions;local before=buffer.tostring(c.ram)
	result=syscall(999,{})
	check(result.kind=="unimplemented_syscall" and result.number==999 and c.pcLo==0x10000 and c.instructions==count,"unknown syscall stays at trap")
	check(buffer.tostring(c.ram)==before,"unknown syscall does not write RAM")
	local trap=c:step();check(trap.kind=="system_call" and c.pcLo==0x10000 and c.instructions==count,"CPU event alone does not acknowledge syscall")
	check(not Platform.Status().bootSupported,"process foundation does not claim GameOS")
	return {checks=checks,compiledTLSProcess=true,exitStatus=42,ps3BootSupported=false}
end

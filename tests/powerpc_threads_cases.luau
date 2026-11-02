-- Execute the owned C synchronization program under different interleavings.
return function(Platform,image)
	local checks=0
	local function check(value,message) assert(value,message);checks+=1 end
	local retired={}
	for _,inherit in ipairs({false,true}) do
	for _,quantum in ipairs({1,2,7,17,256,4096}) do
		local cpu=Platform.new({ramBytes=4*1024*1024})
		local ok,state=Platform.LoadProcess(cpu,image,{quantum=quantum,trace=true,argv=inherit and {"/app_home/threads.elf","I"} or {"/app_home/threads.elf"}})
		check(ok,tostring(state.code))
		local result=Platform.RunProcess(cpu,100000)
		check(result.kind=="process-exited" and result.exitStatus==42,"C synchronization result, quantum="..quantum.." kind="..result.kind)
		check(Platform.ProcessConsole(cpu)==(inherit and "ROEMU_PPU_THREADS_COND_INHERIT_OK\n" or "ROEMU_PPU_THREADS_COND_OK\n"),"C terminal output proves the selected priority profile")
		check(state.threadCount==1 and #state.threadRanges==0,"thread stacks and join resources released")
		check(state.mutexCount==0 and state.conditionCount==0 and state.lightMutexCount==0 and state.inheritCount==0,"synchronization objects destroyed")
		check(state.clockUS-cpu.instructions==2997,"three real virtual-time waits without guest busy polling")
		local exited=0
		for _,thread in pairs(state.threads) do
			check(thread.pendingTrace==nil and thread.waiting==nil,"completed thread has no pending syscall")
			if not thread.main then
				exited+=1;check(thread.state=="exited" and thread.reaped,"join consumed child")
				if thread.id==0x1000001 then check(thread.exitHi==0xFEDCBA98 and thread.exitLo==0x76543210,"exact 64-bit child result") end
			end
		end
		check(exited==3,"three real children ran")
		local timed=false
		for _,entry in ipairs(state.trace) do
			check(not entry.pending,"trace must distinguish pending and completed waits")
			if entry.number==97 and entry.result==0x8001000B then timed=true end
		end
		check(timed,"timeout return is recorded after wakeup")
		retired[#retired+1]=cpu.instructions
	end
	end
	check(not Platform.Status().bootSupported,"scheduler foundation is not GameOS boot")
	return {checks=checks,quanta=6,priorityProfiles=2,childrenPerRun=3,retired=retired,ps3BootSupported=false}
end

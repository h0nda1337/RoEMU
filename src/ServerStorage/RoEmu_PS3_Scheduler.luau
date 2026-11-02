--!native
--!optimize 2
-- Deterministic single-PPE context scheduling. Not Cell SMT or cycle accuracy.
local Scheduler={}
local fields={"pcHi","pcLo","lrHi","lrLo","ctrHi","ctrLo","cr","xer"}
function Scheduler.Capture(cpu)
	local context={hi=table.clone(cpu.hi),lo=table.clone(cpu.lo)}
	for _,field in ipairs(fields) do context[field]=cpu[field] end
	return context
end
function Scheduler.Restore(cpu,context)
	for i=1,32 do cpu.hi[i],cpu.lo[i]=context.hi[i],context.lo[i] end
	for _,field in ipairs(fields) do cpu[field]=context[field] end
end
function Scheduler.Init(cpu,state,priority,quantum)
	state.threads={[state.threadId]={id=state.threadId,state="runnable",priority=priority,context=Scheduler.Capture(cpu),main=true,joinable=false,
		stackAddress=cpu.loadedImage.stackTop-cpu.loadedImage.stackBytes,stackBytes=cpu.loadedImage.stackBytes}}
	state.threadOrder={state.threadId};state.nextThread=0x1000001
	if state.nextThread==state.threadId then state.nextThread+=1 end
	state.cursor,state.quantum,state.slice,state.clockUS=1,quantum,0,0
	state.cpuThreadId=state.threadId
	state.threadRanges={}
	state.threadCount=1
end
function Scheduler.Current(cpu) return cpu.process.threads[cpu.process.threadId] end
function Scheduler.Save(cpu)
	local thread=Scheduler.Current(cpu)
	if thread and cpu.process.cpuThreadId==thread.id then thread.context=Scheduler.Capture(cpu) end
end
function Scheduler.Wake(thread,result)
	if thread.pendingTrace then thread.pendingTrace.result=result;thread.pendingTrace.pending=false;thread.pendingTrace=nil end
	thread.state,thread.waiting="runnable",nil
	thread.context.hi[4]=result>=0x80000000 and 0xFFFFFFFF or 0
	thread.context.lo[4]=result
end
function Scheduler.Priority(state,thread)
	return state.inheritCount>0 and (thread.effectivePriority or thread.priority) or thread.priority
end
function Scheduler.UpdatePriorities(state)
	if state.inheritCount==0 then return end
	for _,thread in pairs(state.threads) do thread.effectivePriority=thread.priority end
	for _=1,state.threadCount do
		local changed=false
		for _,mutex in pairs(state.mutexes) do
			local owner=state.threads[mutex.owner]
			if mutex.protocol==3 and owner then
				for _,waiter in ipairs(mutex.waiters) do
					local priority=state.threads[waiter.thread].effectivePriority
					if priority<owner.effectivePriority then owner.effectivePriority=priority;changed=true end
				end
			end
		end
		if not changed then break end
	end
end
function Scheduler.Select(cpu,rotate)
	local state=cpu.process
	Scheduler.Save(cpu)
	Scheduler.UpdatePriorities(state)
	local current=Scheduler.Current(cpu)
	local selected,index
	for offset=1,#state.threadOrder do
		local at=(state.cursor+offset-1)%#state.threadOrder+1
		local thread=state.threads[state.threadOrder[at]]
		if thread and thread.state=="runnable" and (not selected or Scheduler.Priority(state,thread)<Scheduler.Priority(state,selected)) then selected,index=thread,at end
	end
	if not rotate and current and current.state=="runnable" and (not selected or Scheduler.Priority(state,current)<=Scheduler.Priority(state,selected)) then
		if state.cpuThreadId~=current.id then Scheduler.Restore(cpu,current.context);state.cpuThreadId=current.id end
		state.state="runnable";state.readyChange=nil;return true
	end
	if not selected then state.state="waiting";return false end
	if state.cpuThreadId~=selected.id then cpu.reservation=nil end
	state.cursor,state.threadId,state.slice,state.state=index,selected.id,0,"runnable"
	Scheduler.Restore(cpu,selected.context)
	state.cpuThreadId=selected.id;state.readyChange=nil
	return true
end
return Scheduler

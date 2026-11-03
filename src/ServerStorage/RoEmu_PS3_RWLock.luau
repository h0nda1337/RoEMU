--!native
--!optimize 2
-- Private LV2 read/write locks for the deterministic PPU process host.
-- Reader count is global, writer ownership is per thread; writers take priority.
local Scheduler=script and require(script.Parent.RoEmu_PS3_Scheduler) or require("./RoEmu_PS3_Scheduler")
local RW={VERSION="0.1.0"}
local function wake(state,waiter,result)
	Scheduler.Wake(state.threads[waiter.thread],result or 0);state.readyChange=true
end
local function choose(state,queue,protocol)
	local index=1
	if protocol==2 then
		Scheduler.UpdatePriorities(state)
		for i=2,#queue do
			if Scheduler.Priority(state,state.threads[queue[i].thread])<Scheduler.Priority(state,state.threads[queue[index].thread]) then index=i end
		end
	end
	return table.remove(queue,index)
end
local function grant(state,lock)
	if lock.writer~=0 then return end
	if #lock.writerWaiters>0 then
		if lock.readers==0 then
			local waiter=choose(state,lock.writerWaiters,lock.protocol)
			lock.writer=waiter.thread;wake(state,waiter)
		end
	else
		local readers=lock.readerWaiters;lock.readerWaiters={}
		lock.readers+=#readers
		for _,waiter in ipairs(readers) do wake(state,waiter) end
	end
end
function RW.Init(state) state.rwlocks={};state.rwlockCount=0;state.nextRWLock=0x88000000 end
function RW.Create(state,protocol,name)
	if state.rwlockCount>=4096 then return 0x80010001 end
	local id=state.nextRWLock;state.nextRWLock+=1;state.rwlockCount+=1
	state.rwlocks[id]={protocol=protocol,name=name,readers=0,writer=0,readerWaiters={},writerWaiters={}}
	return 0,id
end
function RW.Call(state,number,id,timeoutHi,timeoutLo)
	local lock=state.rwlocks[id]
	if not lock then return 0x80010005 end
	if number==121 then
		if lock.writer~=0 or lock.readers~=0 or #lock.readerWaiters>0 or #lock.writerWaiters>0 then return 0x8001000A end
		state.rwlocks[id]=nil;state.rwlockCount-=1;return 0
	elseif number==124 then
		if lock.readers==0 then return 0x80010009 end
		lock.readers-=1;grant(state,lock);return 0
	elseif number==127 then
		if lock.writer~=state.threadId then return 0x80010009 end
		lock.writer=0;grant(state,lock);return 0
	end
	local writing=number==125 or number==126
	if writing and lock.writer==state.threadId then return 0x80010008 end
	local available=lock.writer==0 and (writing and lock.readers==0 or not writing and #lock.writerWaiters==0 and #lock.readerWaiters==0)
	if available then
		if writing then lock.writer=state.threadId else lock.readers+=1 end
		return 0
	end
	if number==123 or number==126 then return 0x8001000A end
	local timeout=timeoutHi*4294967296+timeoutLo
	if timeout>9007199254740991-state.clockUS then return nil end
	local due=timeout~=0 and state.clockUS+timeout or nil
	local thread=state.threads[state.threadId]
	thread.state="waiting";thread.waiting={kind=writing and "rwlock-write" or "rwlock-read",rwlock=id,deadline=due}
	local queue=writing and lock.writerWaiters or lock.readerWaiters
	queue[#queue+1]={thread=thread.id}
	if due and (not state.nextDeadline or due<state.nextDeadline) then state.nextDeadline=due end
	return 0
end
function RW.Expire(state,thread)
	local wait=thread.waiting;local lock=state.rwlocks[wait.rwlock]
	local queue=wait.kind=="rwlock-write" and lock.writerWaiters or lock.readerWaiters
	for i,waiter in ipairs(queue) do if waiter.thread==thread.id then table.remove(queue,i);break end end
	wake(state,{thread=thread.id},0x8001000B)
	-- Removing the last waiting writer admits queued readers even while other
	-- readers still hold the lock. Waiting readers must not remain stranded.
	grant(state,lock)
end
return RW

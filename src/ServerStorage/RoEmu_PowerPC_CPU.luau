--!native
--!optimize 2
-- Experimental, flat-memory PowerPC64 subset. This is not a Cell/PS3.
-- Registers use two 32-bit halves; no 64-bit integer passes through a double.
local band,bor,bxor,bnot,lshift,rshift=bit32.band,bit32.bor,bit32.bxor,bit32.bnot,bit32.lshift,bit32.rshift
local CPU={}
CPU.__index=CPU
local U32=4294967296
local function add(ah,al,bh,bl)
	local low=al+bl
	return band(ah+bh+math.floor(low/U32),0xFFFFFFFF),band(low,0xFFFFFFFF)
end
local function addCarry(ah,al,bh,bl,carry)
	local low=al+bl+carry
	local high=ah+bh+math.floor(low/U32)
	return band(high,0xFFFFFFFF),band(low,0xFFFFFFFF),high>=U32
end
local arithmetic={ [266]=true,[10]=true,[138]=true,[234]=true,[202]=true,
	[40]=true,[8]=true,[136]=true,[232]=true,[200]=true,[104]=true }
local function divideUnsigned(ah,al,bh,bl)
	local qh,ql,rh,rl=0,0,0,0
	for bit=63,0,-1 do
		local carry=rshift(rh,31)
		rh=bor(lshift(rh,1),rshift(rl,31))
		rl=bor(lshift(rl,1),band(rshift(bit>=32 and ah or al,bit%32),1))
		if carry~=0 or rh>bh or (rh==bh and rl>=bl) then
			rh,rl=addCarry(rh,rl,bnot(bh),bnot(bl),1)
			if bit>=32 then qh=bor(qh,lshift(1,bit-32)) else ql=bor(ql,lshift(1,bit)) end
		end
	end
	return qh,ql
end
local function multiply(ah,al,bh,bl,signed)
	local a={band(al,65535),rshift(al,16),band(ah,65535),rshift(ah,16)}
	local b={band(bl,65535),rshift(bl,16),band(bh,65535),rshift(bh,16)}
	local parts=table.create(8,0)
	for i=1,4 do for j=1,4 do parts[i+j-1]+=a[i]*b[j] end end
	for i=1,7 do local carry=math.floor(parts[i]/65536);parts[i]%=65536;parts[i+1]+=carry end
	local high,low=band(parts[8]*65536+parts[7],0xFFFFFFFF),parts[6]*65536+parts[5]
	if signed then
		if ah>=0x80000000 then high,low=addCarry(high,low,bnot(bh),bnot(bl),1) end
		if bh>=0x80000000 then high,low=addCarry(high,low,bnot(ah),bnot(al),1) end
	end
	return parts[4]*65536+parts[3],parts[2]*65536+parts[1],high,low
end
local function signed16(value) return value>=32768 and value-65536 or value end
local function extend(value) return value<0 and 0xFFFFFFFF or 0,band(value,0xFFFFFFFF) end
local function shiftLeft(high,low,amount)
	if amount==0 then return high,low elseif amount>=64 then return 0,0
	elseif amount>=32 then return lshift(low,amount-32),0 end
	return bor(lshift(high,amount),rshift(low,32-amount)),lshift(low,amount)
end
local function shiftRight(high,low,amount)
	if amount==0 then return high,low elseif amount>=64 then return 0,0
	elseif amount>=32 then return 0,rshift(high,amount-32) end
	return rshift(high,amount),bor(rshift(low,amount),lshift(high,32-amount))
end
local function rotate(high,low,amount)
	if amount==0 then return high,low end
	local ah,al=shiftLeft(high,low,amount);local bh,bl=shiftRight(high,low,64-amount)
	return bor(ah,bh),bor(al,bl)
end
-- PowerPC numbers mask bits from the most significant end of the operand.
local function wordMask(first,last)
	if first<=last then return band(rshift(0xFFFFFFFF,first),lshift(0xFFFFFFFF,31-last)) end
	return bor(rshift(0xFFFFFFFF,first),lshift(0xFFFFFFFF,31-last))
end
local function wideMask(first,last)
	if first==last+1 then return 0xFFFFFFFF,0xFFFFFFFF end
	if first>last then
		local high,low=wideMask(last+1,first-1);return bnot(high),bnot(low)
	end
	local high,low=0,0
	if first<32 then high=wordMask(first,math.min(last,31)) end
	if last>=32 then low=wordMask(math.max(first,32)-32,last-32) end
	return high,low
end
local function readBE(data,address,bytes)
	local value=0
	for i=0,bytes-1 do value=value*256+buffer.readu8(data,address+i) end
	return value
end
local function writeBE(data,address,bytes,value)
	for i=bytes-1,0,-1 do buffer.writeu8(data,address+i,band(value,255));value=math.floor(value/256) end
end
local function singleToDouble(value)
	local sign,exponent,fraction=band(value,0x80000000),band(rshift(value,23),255),band(value,0x7FFFFF)
	if exponent==0 then
		if fraction==0 then return sign,0 end
		local shift=bit32.countlz(fraction)-8
		fraction=band(lshift(fraction,shift),0x7FFFFF);exponent=897-shift
	elseif exponent==255 then exponent=2047
	else exponent+=896 end
	return bor(sign,lshift(exponent,20),rshift(fraction,3)),lshift(fraction,29)
end
local function doubleToSingle(high,low)
	local exponent=band(rshift(high,20),2047)
	if exponent>896 then return bor(band(high,0xC0000000),lshift(band(high,0x07FFFFFF),3),rshift(low,29)) end
	local fraction=0
	if exponent>=874 then
		local _,shifted=shiftRight(bor(band(high,0xFFFFF),0x100000),low,926-exponent)
		fraction=shifted
	end
	return bor(band(high,0x80000000),fraction)
end
-- X-form memory operations: width, store, update, signed load, FPR bit transfer.
local indexedMemory={
	[21]={8},[53]={8,false,true},[23]={4},[55]={4,false,true},
	[87]={1},[119]={1,false,true},[279]={2},[311]={2,false,true},
	[343]={2,false,false,true},[375]={2,false,true,true},
	[341]={4,false,false,true},[373]={4,false,true,true},
	[149]={8,true},[181]={8,true,true},[151]={4,true},[183]={4,true,true},
	[215]={1,true},[247]={1,true,true},[407]={2,true},[439]={2,true,true},
	[599]={8,false,false,false,true},[631]={8,false,true,false,true},
	[727]={8,true,false,false,true},[759]={8,true,true,false,true},
	[535]={4,false,false,false,true},[567]={4,false,true,false,true},
	[663]={4,true,false,false,true},[695]={4,true,true,false,true},
}
function CPU.new(options)
	options=options or {}
	local self=setmetatable({ram=buffer.create(options.ramBytes or 1024*1024),
		hi=table.create(32,0),lo=table.create(32,0),pcHi=0,pcLo=options.entry or 0,
		fhi=table.create(32,0),flo=table.create(32,0),fpscr=0,
		lrHi=0,lrLo=0,ctrHi=0,ctrLo=0,cr=0,xer=0,instructions=0},CPU)
	return self
end
function CPU:getRegister(index) return self.hi[index+1],self.lo[index+1] end
function CPU:setRegister(index,high,low)
	assert(index>=0 and index<32 and index%1==0,"PowerPC GPR index")
	self.hi[index+1],self.lo[index+1]=band(high,0xFFFFFFFF),band(low,0xFFFFFFFF)
end
-- Raw IEEE-754 bits, including NaN payloads; no host numeric conversion.
function CPU:getFloatingRegister(index) return self.fhi[index+1],self.flo[index+1] end
function CPU:setFloatingRegister(index,high,low)
	assert(index>=0 and index<32 and index%1==0,"PowerPC FPR index")
	self.fhi[index+1],self.flo[index+1]=band(high,0xFFFFFFFF),band(low,0xFFFFFFFF)
end
function CPU:load(data,address)
	assert(typeof(data)=="buffer","flat PowerPC image must be a buffer")
	assert(address>=0 and address%4==0 and address+buffer.len(data)<=buffer.len(self.ram),"flat PowerPC image bounds/alignment")
	buffer.copy(self.ram,address,data)
	self.reservation=nil
end
function CPU:invalidateReservation(address,bytes)
	local reservation=self.reservation
	if reservation and address<reservation.granule+128 and reservation.granule<address+bytes then self.reservation=nil end
end
function CPU:setCR(field,less,greater,equal)
	local shift=28-field*4
	local value=(less and 8 or 0)+(greater and 4 or 0)+(equal and 2 or 0)+(band(self.xer,0x80000000)~=0 and 1 or 0)
	self.cr=bor(band(self.cr,bnot(lshift(15,shift))),lshift(value,shift))
end
function CPU:record(high,low)
	local zero=high==0 and low==0
	self:setCR(0,high>=0x80000000,not zero and high<0x80000000,zero)
end
function CPU:compare(field,ah,al,bh,bl,signed,wide)
	if not wide then
		ah,bh=0,0
		if signed then al=al>=0x80000000 and al-U32 or al;bl=bl>=0x80000000 and bl-U32 or bl end
	elseif signed then ah=ah>=0x80000000 and ah-U32 or ah;bh=bh>=0x80000000 and bh-U32 or bh end
	local less=ah<bh or (ah==bh and al<bl)
	local equal=ah==bh and al==bl
	self:setCR(field,less,not less and not equal,equal)
end
function CPU:branchCondition(bo,bi)
	local ctrOK=true
	if band(bo,4)==0 then
		self.ctrHi,self.ctrLo=add(self.ctrHi,self.ctrLo,0xFFFFFFFF,0xFFFFFFFF)
		ctrOK=((self.ctrHi~=0 or self.ctrLo~=0)~=(band(bo,2)~=0))
	end
	return ctrOK and (band(bo,16)~=0 or (band(rshift(self.cr,31-bi),1)==(band(bo,8)~=0 and 1 or 0)))
end
function CPU:step()
	local function fault(kind,detail,word)
		return {kind=kind,detail=detail,pcHi=self.pcHi,pcLo=self.pcLo,word=word,instructions=self.instructions}
	end
	if self.pcHi~=0 or self.pcLo%4~=0 or self.pcLo+4>buffer.len(self.ram) then return fault("memory_fault","instruction address outside aligned flat RAM") end
	local word=readBE(self.ram,self.pcLo,4)
	local op=rshift(word,26)
	local rt,ra,rb=band(rshift(word,21),31),band(rshift(word,16),31),band(rshift(word,11),31)
	local immediate=band(word,65535)
	local nextHi,nextLo=add(self.pcHi,self.pcLo,0,4)
	local function unsupported() return fault("unsupported_instruction","PowerPC instruction is outside the implemented integer subset",word) end
	if op==17 then
		if word~=0x44000002 then return unsupported() end
		-- User-mode trap event. The process host explicitly commits a supported
		-- call; architectural supervisor exception delivery is not implemented.
		local event=fault("system_call","PowerPC sc 0",word)
		event.resumeHi,event.resumeLo=nextHi,nextLo
		return event
	elseif op==7 then
		local ah,al=self:getRegister(ra);local bh,bl=extend(signed16(immediate))
		local high,low=multiply(ah,al,bh,bl,false);self:setRegister(rt,high,low)
	elseif op==8 or op==12 or op==13 then
		local ah,al=self:getRegister(ra);local bh,bl=extend(signed16(immediate))
		local high,low,carry
		if op==8 then high,low,carry=addCarry(bnot(ah),bnot(al),bh,bl,1)
		else high,low,carry=addCarry(ah,al,bh,bl,0) end
		self:setRegister(rt,high,low)
		self.xer=bor(band(self.xer,0xDFFFFFFF),carry and 0x20000000 or 0)
		if op==13 then self:record(high,low) end
	elseif op==14 or op==15 then
		local bh,bl=extend(signed16(immediate)*(op==15 and 65536 or 1))
		local ah,al=0,0;if ra~=0 then ah,al=self:getRegister(ra) end
		self:setRegister(rt,add(ah,al,bh,bl))
	elseif op>=24 and op<=29 then
		local high,low=self:getRegister(rt)
		local mask=(op%2==1) and lshift(immediate,16) or immediate
		if op<=25 then low=bor(low,mask) elseif op<=27 then low=bxor(low,mask) else high,low=0,band(low,mask) end
		self:setRegister(ra,high,low)
		if op>=28 then self:record(high,low) end
	elseif op==20 or op==21 or op==23 then
		local _,source=self:getRegister(rt)
		local amount=rb
		if op==23 then local _,value=self:getRegister(rb);amount=band(value,31) end
		local mh,ml=wideMask(32+band(rshift(word,6),31),32+band(rshift(word,1),31))
		local rotated=bit32.lrotate(source,amount)
		local high,low=band(rotated,mh),band(rotated,ml)
		if op==20 then local ah,al=self:getRegister(ra);high,low=bor(band(ah,bnot(mh)),high),bor(band(al,bnot(ml)),low) end
		self:setRegister(ra,high,low)
		if band(word,1)~=0 then self:record(high,low) end
	elseif op==30 then
		local high,low=self:getRegister(rt)
		local selector=band(rshift(word,2),7)
		local boundary=band(rshift(word,6),31)+band(word,32)
		local amount=rb+band(word,2)*16
		local mh,ml
		if selector<=3 then
			if selector==0 then mh,ml=wideMask(boundary,63)
			elseif selector==1 then mh,ml=wideMask(0,boundary)
			else mh,ml=wideMask(boundary,63-amount) end
		else
			local xo=band(rshift(word,1),15)
			if xo~=8 and xo~=9 then return unsupported() end
			local _,value=self:getRegister(rb);amount=band(value,63)
			if xo==8 then mh,ml=wideMask(boundary,63) else mh,ml=wideMask(0,boundary) end
		end
		high,low=rotate(high,low,amount);high,low=band(high,mh),band(low,ml)
		if selector==3 then local ah,al=self:getRegister(ra);high,low=bor(band(ah,bnot(mh)),high),bor(band(al,bnot(ml)),low) end
		self:setRegister(ra,high,low)
		if band(word,1)~=0 then self:record(high,low) end
	elseif op==10 or op==11 then
		local ah,al=self:getRegister(ra)
		local bh,bl=0,immediate
		if op==11 then bh,bl=extend(signed16(immediate)) end
		self:compare(band(rshift(word,23),7),ah,al,bh,bl,op==11,band(word,0x200000)~=0)
	elseif op==18 then
		local displacement=band(word,0x3FFFFFC)
		if displacement>=0x2000000 then displacement-=0x4000000 end
		local dh,dl=extend(displacement)
		local targetHi,targetLo=dh,dl
		if band(word,2)==0 then targetHi,targetLo=add(self.pcHi,self.pcLo,dh,dl) end
		if band(word,1)~=0 then self.lrHi,self.lrLo=nextHi,nextLo end
		nextHi,nextLo=targetHi,targetLo
	elseif op==16 or op==19 then
		local targetHi,targetLo
		local bo,bi=rt,ra
		local control=op==19 and band(rshift(word,1),1023) or -1
		if control==150 then
			if word~=0x4C00012C then return unsupported() end
			-- Instruction fetch and stores are already serialized in this core.
		elseif control==0 then
			local to,from=band(rshift(word,23),7),band(rshift(word,18),7)
			local shift=28-to*4
			self.cr=bor(band(self.cr,bnot(lshift(15,shift))),lshift(band(rshift(self.cr,28-from*4),15),shift))
		elseif control==257 or control==129 or control==289 or control==225 or control==33 or control==449 or control==417 or control==193 then
			local a,b=band(rshift(self.cr,31-ra),1),band(rshift(self.cr,31-rb),1)
			local value
			if control==257 then value=band(a,b) elseif control==129 then value=band(a,1-b)
			elseif control==289 then value=1-bxor(a,b) elseif control==225 then value=1-band(a,b)
			elseif control==33 then value=1-bor(a,b) elseif control==449 then value=bor(a,b)
			elseif control==417 then value=bor(a,1-b) else value=bxor(a,b) end
			self.cr=bor(band(self.cr,bnot(lshift(1,31-rt))),lshift(value,31-rt))
		else
		if op==16 then
			local dh,dl=extend(signed16(band(word,0xFFFC)))
			targetHi,targetLo=dh,dl
			if band(word,2)==0 then targetHi,targetLo=add(self.pcHi,self.pcLo,dh,dl) end
		else
			local xo=band(rshift(word,1),1023)
			if xo==16 then targetHi,targetLo=self.lrHi,band(self.lrLo,0xFFFFFFFC)
			elseif xo==528 and band(bo,4)~=0 then targetHi,targetLo=self.ctrHi,band(self.ctrLo,0xFFFFFFFC)
			else return unsupported() end
		end
		if band(word,1)~=0 then self.lrHi,self.lrLo=nextHi,nextLo end
		if self:branchCondition(bo,bi) then nextHi,nextLo=targetHi,targetLo end
		end
	elseif (op>=32 and op<=45) or (op>=48 and op<=55) or op==58 or op==62 then
		local floating=op>=48 and op<=55
		local storing=(op>=36 and op<=39) or op==44 or op==45 or op==62 or (op>=52 and op<=55)
		local bytes=op>=40 and 2 or 4
		if floating then bytes=band(op,2)==0 and 4 or 8 end
		if op==34 or op==35 or op==38 or op==39 then bytes=1 end
		local updating=op%2==1
		local displacement=signed16(immediate)
		if op==58 or op==62 then
			local ds=band(word,3)
			if ds>1 and not (op==58 and ds==2) then return unsupported() end
			bytes=ds==2 and 4 or 8;updating=ds==1;displacement=signed16(band(word,0xFFFC))
		end
		if updating and (ra==0 or (not storing and not floating and ra==rt)) then return unsupported() end
		local ah,al=0,0;if ra~=0 then ah,al=self:getRegister(ra) end
		local dh,dl=extend(displacement)
		local high,address=add(ah,al,dh,dl)
		if high~=0 or address%bytes~=0 or address+bytes>buffer.len(self.ram) then return fault("memory_fault","data address outside aligned flat RAM",word) end
		if storing then
			local vh,vl=self:getRegister(rt)
			if floating then vh,vl=self:getFloatingRegister(rt) end
			if floating and bytes==4 then vl=doubleToSingle(vh,vl) end
			self:invalidateReservation(address,bytes)
			if bytes==8 then writeBE(self.ram,address,4,vh);writeBE(self.ram,address+4,4,vl)
			else writeBE(self.ram,address,bytes,vl) end
		else
			local vh,vl=0,0
			if bytes==8 then vh,vl=readBE(self.ram,address,4),readBE(self.ram,address+4,4)
			else
				vl=readBE(self.ram,address,bytes)
				if op==42 or op==43 then vh,vl=extend(signed16(vl))
				elseif op==58 then vh,vl=extend(vl>=0x80000000 and vl-U32 or vl) end
			end
			if floating then
				if bytes==4 then vh,vl=singleToDouble(vl) end
				self:setFloatingRegister(rt,vh,vl)
			else self:setRegister(rt,vh,vl) end
		end
		if updating then self:setRegister(ra,high,address) end
	elseif op==31 then
		local xo=band(rshift(word,1),1023)
		local high,low
		local memory=indexedMemory[xo]
		if word==0x7C0004AC or word==0x7C2004AC or word==0x7C0006AC then
			-- sync/lwsync/eieio: all implemented memory/device effects are ordered.
		elseif xo==246 or xo==278 then
			if band(word,1)~=0 then return unsupported() end
			-- dcbt/dcbtst are prefetch hints, with no architectural data access.
			-- Flat uncached RAM needs no fill and must not fault on the hint EA.
		elseif xo==20 or xo==84 or xo==150 or xo==214 then
			local storing=xo==150 or xo==214
			local bytes=(xo==84 or xo==214) and 8 or 4
			if band(word,1)~=(storing and 1 or 0) then return unsupported() end
			local ah,al=0,0;if ra~=0 then ah,al=self:getRegister(ra) end
			local bh,bl=self:getRegister(rb);local addressHi,address=add(ah,al,bh,bl)
			if addressHi~=0 or address%bytes~=0 or address+bytes>buffer.len(self.ram) then return fault("memory_fault","reservation address outside aligned flat RAM",word) end
			local vh,vl=0,readBE(self.ram,address,4)
			if bytes==8 then vh,vl=vl,readBE(self.ram,address+4,4) end
			if storing then
				local reservation=self.reservation
				local success=reservation~=nil and reservation.address==address and reservation.bytes==bytes and reservation.high==vh and reservation.low==vl
				self.reservation=nil
				if success then
					local sh,sl=self:getRegister(rt)
					if bytes==8 then writeBE(self.ram,address,4,sh);writeBE(self.ram,address+4,4,sl) else writeBE(self.ram,address,4,sl) end
				end
				self:setCR(0,false,false,success)
			else
				self:setRegister(rt,vh,vl)
				self.reservation={address=address,bytes=bytes,granule=math.floor(address/128)*128,high=vh,low=vl}
			end
		elseif memory then
			local bytes,storing,updating,signed,floating=memory[1],memory[2],memory[3],memory[4],memory[5]
			if band(word,1)~=0 or (updating and (ra==0 or (not storing and not floating and ra==rt))) then return unsupported() end
			local ah,al=0,0;if ra~=0 then ah,al=self:getRegister(ra) end
			local bh,bl=self:getRegister(rb)
			local addressHi,address=add(ah,al,bh,bl)
			if addressHi~=0 or address%bytes~=0 or address+bytes>buffer.len(self.ram) then return fault("memory_fault","indexed address outside aligned flat RAM",word) end
			if storing then
				local vh,vl=self:getRegister(rt)
				if floating then vh,vl=self:getFloatingRegister(rt) end
				if floating and bytes==4 then vl=doubleToSingle(vh,vl) end
				self:invalidateReservation(address,bytes)
				if bytes==8 then writeBE(self.ram,address,4,vh);writeBE(self.ram,address+4,4,vl)
				else writeBE(self.ram,address,bytes,vl) end
			else
				local vh,vl=0,0
				if bytes==8 then vh,vl=readBE(self.ram,address,4),readBE(self.ram,address+4,4)
				else
					vl=readBE(self.ram,address,bytes)
					if signed then
						if bytes==2 then vh,vl=extend(signed16(vl)) else vh,vl=extend(vl>=0x80000000 and vl-U32 or vl) end
					end
				end
				if floating then
					if bytes==4 then vh,vl=singleToDouble(vl) end
					self:setFloatingRegister(rt,vh,vl)
				else self:setRegister(rt,vh,vl) end
			end
			if updating then self:setRegister(ra,addressHi,address) end
		elseif xo==19 or xo==144 then
			if band(word,1)~=0 then return unsupported() end
			local fields=band(rshift(word,12),255)
			local one=band(word,0x100000)~=0
			if one and (fields==0 or band(fields,fields-1)~=0) then return unsupported() end
			if xo==19 then
				if not one and fields~=0 then return unsupported() end
				low=self.cr
				if one then
					low=0
					for i=0,7 do if band(fields,lshift(1,7-i))~=0 then low=band(self.cr,lshift(15,28-i*4));break end end
				end
				self:setRegister(rt,0,low)
			else
				local _,value=self:getRegister(rt)
				for i=0,7 do
					if band(fields,lshift(1,7-i))~=0 then local mask=lshift(15,28-i*4);self.cr=bor(band(self.cr,bnot(mask)),band(value,mask)) end
				end
			end
		elseif arithmetic[band(xo,511)] then
			local operation=band(xo,511)
			local unary=operation==234 or operation==202 or operation==232 or operation==200 or operation==104
			if unary and rb~=0 then return unsupported() end
			local ah,al=self:getRegister(ra);local bh,bl=self:getRegister(rb)
			local subtract=operation==40 or operation==8 or operation==136 or operation==232 or operation==200 or operation==104
			local carryIn=(operation==138 or operation==234 or operation==202 or operation==136 or operation==232 or operation==200)
				and (band(self.xer,0x20000000)~=0 and 1 or 0) or (subtract and 1 or 0)
			if operation==234 or operation==232 then bh,bl=0xFFFFFFFF,0xFFFFFFFF
			elseif unary then bh,bl=0,0 end
			local signedA,signedB=ah>=0x80000000,bh>=0x80000000
			local carry
			if subtract then high,low,carry=addCarry(bnot(ah),bnot(al),bh,bl,carryIn)
			else high,low,carry=addCarry(ah,al,bh,bl,carryIn) end
			if operation~=266 and operation~=40 and operation~=104 then self.xer=bor(band(self.xer,0xDFFFFFFF),carry and 0x20000000 or 0) end
			if xo>=512 then
				local negative=high>=0x80000000
				local overflow=(subtract and signedA~=signedB and negative~=signedB) or (not subtract and signedA==signedB and negative~=signedA)
				self.xer=bor(band(self.xer,0xBFFFFFFF),overflow and 0xC0000000 or 0)
			end
			self:setRegister(rt,high,low)
			if band(word,1)~=0 then self:record(high,low) end
		elseif band(xo,511)==233 or band(xo,511)==235 or xo==9 or xo==73 or xo==11 or xo==75 then
			local operation=band(xo,511)
			local ah,al=self:getRegister(ra);local bh,bl=self:getRegister(rb)
			local wordMode=operation==235 or operation==11 or operation==75
			local signed=operation~=9 and operation~=11
			if wordMode then
				ah,bh=0,0
				if signed then ah,al=extend(al>=0x80000000 and al-U32 or al);bh,bl=extend(bl>=0x80000000 and bl-U32 or bl) end
			end
			local ph,pl,uh,ul=multiply(ah,al,bh,bl,signed)
			local overflow=false
			if operation==9 or operation==73 then high,low=uh,ul
			elseif operation==11 then high,low=0,ph
			elseif operation==75 then high,low=0,ph
			elseif operation==235 then
				high,low=ph,pl;overflow=ph~=(pl>=0x80000000 and 0xFFFFFFFF or 0)
			else high,low=ph,pl;local fill=ph>=0x80000000 and 0xFFFFFFFF or 0;overflow=uh~=fill or ul~=fill end
			if xo>=512 then self.xer=bor(band(self.xer,0xBFFFFFFF),overflow and 0xC0000000 or 0) end
			self:setRegister(rt,high,low)
			if band(word,1)~=0 then self:record(high,low) end
		elseif band(xo,511)==457 or band(xo,511)==489 or band(xo,511)==459 or band(xo,511)==491 then
			local operation=band(xo,511)
			local ah,al=self:getRegister(ra);local bh,bl=self:getRegister(rb)
			local wide=operation==457 or operation==489
			local signed=operation==489 or operation==491
			local overflow=false
			if wide then
				overflow=(bh==0 and bl==0) or (signed and ah==0x80000000 and al==0 and bh==0xFFFFFFFF and bl==0xFFFFFFFF)
				if overflow then high,low=0,0
				else
					local negativeA,negativeB=signed and ah>=0x80000000,signed and bh>=0x80000000
					if negativeA then ah,al=addCarry(bnot(ah),bnot(al),0,0,1) end
					if negativeB then bh,bl=addCarry(bnot(bh),bnot(bl),0,0,1) end
					high,low=divideUnsigned(ah,al,bh,bl)
					if negativeA~=negativeB then high,low=addCarry(bnot(high),bnot(low),0,0,1) end
				end
			else
				overflow=bl==0 or (signed and al==0x80000000 and bl==0xFFFFFFFF)
				if overflow then high,low=0,0
				else
					if signed then al=al>=0x80000000 and al-U32 or al;bl=bl>=0x80000000 and bl-U32 or bl end
					local value=math.floor(math.abs(al)/math.abs(bl))
					if (al<0)~=(bl<0) then value=-value end
					high,low=0,band(value,0xFFFFFFFF)
				end
			end
			if xo>=512 then self.xer=bor(band(self.xer,0xBFFFFFFF),overflow and 0xC0000000 or 0) end
			self:setRegister(rt,high,low)
			if band(word,1)~=0 then self:record(high,low) end
		elseif xo==26 or xo==58 then
			local sh,sl=self:getRegister(rt)
			low=xo==26 and bit32.countlz(sl) or (sh==0 and 32+bit32.countlz(sl) or bit32.countlz(sh))
			self:setRegister(ra,0,low)
			if band(word,1)~=0 then self:record(0,low) end
		elseif xo==954 or xo==922 or xo==986 then
			local _,value=self:getRegister(rt)
			if xo==954 then value=band(value,255);if value>=128 then value-=256 end
			elseif xo==922 then value=signed16(band(value,65535))
			elseif value>=0x80000000 then value-=U32 end
			high,low=extend(value);self:setRegister(ra,high,low)
			if band(word,1)~=0 then self:record(high,low) end
		elseif xo==28 or xo==444 or xo==316 or xo==124 then
			local ah,al=self:getRegister(rt);local bh,bl=self:getRegister(rb)
			if xo==28 then high,low=band(ah,bh),band(al,bl)
			elseif xo==444 then high,low=bor(ah,bh),bor(al,bl)
			elseif xo==316 then high,low=bxor(ah,bh),bxor(al,bl)
			else high,low=bnot(bor(ah,bh)),bnot(bor(al,bl)) end
			self:setRegister(ra,high,low)
		elseif xo==24 or xo==536 or xo==792 or xo==824 or xo==27 or xo==539 or xo==794 or band(xo,0x3FE)==826 then
			local ah,al=self:getRegister(rt)
			local wide=xo==27 or xo==539 or xo==794 or band(xo,0x3FE)==826
			local amount
			if xo==824 then amount=rb
			elseif band(xo,0x3FE)==826 then amount=rb+band(word,2)*16
			else local _,value=self:getRegister(rb);amount=band(value,wide and 127 or 63) end
			local arithmetic=xo==792 or xo==824 or xo==794 or band(xo,0x3FE)==826
			if not wide then ah=0;al=band(al,0xFFFFFFFF) end
			if xo==24 or xo==27 then high,low=shiftLeft(ah,al,amount)
			else high,low=shiftRight(ah,al,amount) end
			if not wide then high=0;if amount>=32 then low=0 end end
			if arithmetic then
				local negative=(wide and ah or al)>=0x80000000
				local lost
				if wide then
					local rh,rl=shiftLeft(high,low,amount);lost=rh~=ah or rl~=al
					if negative then
						if amount>=64 then high,low=0xFFFFFFFF,0xFFFFFFFF
						elseif amount>0 then local mh,ml=wideMask(0,amount-1);high,low=bor(high,mh),bor(low,ml) end
					end
				else
					lost=(amount>=32 and al~=0) or (amount<32 and lshift(low,amount)~=al)
					if negative then
						high=0xFFFFFFFF
						if amount>=32 then low=0xFFFFFFFF elseif amount>0 then low=bor(low,lshift(0xFFFFFFFF,32-amount)) end
					end
				end
				self.xer=bor(band(self.xer,0xDFFFFFFF),(negative and lost) and 0x20000000 or 0)
			end
			self:setRegister(ra,high,low)
			if band(word,1)~=0 then self:record(high,low) end
		elseif xo==0 or xo==32 then
			local ah,al=self:getRegister(ra);local bh,bl=self:getRegister(rb)
			self:compare(band(rshift(word,23),7),ah,al,bh,bl,xo==0,band(word,0x200000)~=0)
		elseif xo==371 or (xo==339 and (ra+rb*32==268 or ra+rb*32==269)) then
			if band(word,1)~=0 then return unsupported() end
			local tbr=ra+rb*32
			if tbr~=268 and tbr~=269 then return unsupported() end
			local high,low=self.timeBaseHi or 0,self.timeBaseLo or 0
			if self.readTimeBase then high,low=self.readTimeBase() end
			if tbr==268 then self:setRegister(rt,high,low) else self:setRegister(rt,0,high) end
		elseif xo==339 or xo==467 then
			if band(word,1)~=0 then return unsupported() end
			local spr=ra+rb*32
			if spr~=1 and spr~=8 and spr~=9 then return unsupported() end
			if xo==339 then
				if spr==1 then high,low=0,self.xer elseif spr==8 then high,low=self.lrHi,self.lrLo else high,low=self.ctrHi,self.ctrLo end
				self:setRegister(rt,high,low)
			else
				high,low=self:getRegister(rt)
				-- CA32/OV32 belong to ISA 3.0, outside this legacy integer profile.
				if spr==1 then self.xer=band(low,0xFFF3FFFF) elseif spr==8 then self.lrHi,self.lrLo=high,low else self.ctrHi,self.ctrLo=high,low end
			end
		else return unsupported() end
		if (xo==28 or xo==444 or xo==316 or xo==124) and band(word,1)~=0 then self:record(high,low) end
	elseif op==63 then
		local xo=band(rshift(word,1),1023)
		if ra~=0 or (xo~=40 and xo~=72 and xo~=136 and xo~=264) then return unsupported() end
		local high,low=self:getFloatingRegister(rb)
		if xo==40 then high=bxor(high,0x80000000)
		elseif xo==136 then high=bor(high,0x80000000)
		elseif xo==264 then high=band(high,0x7FFFFFFF) end
		self:setFloatingRegister(rt,high,low)
		if band(word,1)~=0 then self.cr=bor(band(self.cr,0xF0FFFFFF),lshift(rshift(self.fpscr,28),24)) end
	else return unsupported() end
	self.pcHi,self.pcLo=nextHi,nextLo
	self.instructions+=1
	return {kind="ok",pcHi=nextHi,pcLo=nextLo,instructions=self.instructions}
end
function CPU:run(budget)
	assert(type(budget)=="number" and budget%1==0 and budget>=1 and budget<=1000000,"PowerPC instruction budget")
	local result
	for _=1,budget do result=self:step();if result.kind~="ok" then return result end end
	return result
end
return CPU

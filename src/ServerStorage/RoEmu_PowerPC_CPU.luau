--!native
--!optimize 2
-- Experimental, flat-memory PowerPC64 integer subset. This is not a Cell/PS3.
-- Registers use two 32-bit halves; no 64-bit integer passes through a double.
local band,bor,bxor,bnot,lshift,rshift=bit32.band,bit32.bor,bit32.bxor,bit32.bnot,bit32.lshift,bit32.rshift
local CPU={}
CPU.__index=CPU
local U32=4294967296
local function add(ah,al,bh,bl)
	local low=al+bl
	return band(ah+bh+math.floor(low/U32),0xFFFFFFFF),band(low,0xFFFFFFFF)
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
function CPU.new(options)
	options=options or {}
	local self=setmetatable({ram=buffer.create(options.ramBytes or 1024*1024),
		hi=table.create(32,0),lo=table.create(32,0),pcHi=0,pcLo=options.entry or 0,
		lrHi=0,lrLo=0,ctrHi=0,ctrLo=0,cr=0,xer=0,instructions=0},CPU)
	return self
end
function CPU:getRegister(index) return self.hi[index+1],self.lo[index+1] end
function CPU:setRegister(index,high,low)
	assert(index>=0 and index<32 and index%1==0,"PowerPC GPR index")
	self.hi[index+1],self.lo[index+1]=band(high,0xFFFFFFFF),band(low,0xFFFFFFFF)
end
function CPU:load(data,address)
	assert(typeof(data)=="buffer","flat PowerPC image must be a buffer")
	assert(address>=0 and address%4==0 and address+buffer.len(data)<=buffer.len(self.ram),"flat PowerPC image bounds/alignment")
	buffer.copy(self.ram,address,data)
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
	if op==14 or op==15 then
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
	elseif (op>=32 and op<=45) or op==58 or op==62 then
		local storing=(op>=36 and op<=39) or op==44 or op==45 or op==62
		local bytes=op>=40 and 2 or 4
		if op==34 or op==35 or op==38 or op==39 then bytes=1 end
		local updating=op%2==1
		local displacement=signed16(immediate)
		if op==58 or op==62 then
			local ds=band(word,3)
			if ds>1 and not (op==58 and ds==2) then return unsupported() end
			bytes=ds==2 and 4 or 8;updating=ds==1;displacement=signed16(band(word,0xFFFC))
		end
		if updating and (ra==0 or (not storing and ra==rt)) then return unsupported() end
		local ah,al=0,0;if ra~=0 then ah,al=self:getRegister(ra) end
		local dh,dl=extend(displacement)
		local high,address=add(ah,al,dh,dl)
		if high~=0 or address%bytes~=0 or address+bytes>buffer.len(self.ram) then return fault("memory_fault","data address outside aligned flat RAM",word) end
		if storing then
			local vh,vl=self:getRegister(rt)
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
			self:setRegister(rt,vh,vl)
		end
		if updating then self:setRegister(ra,high,address) end
	elseif op==31 then
		local xo=band(rshift(word,1),1023)
		local high,low
		if xo==266 then
			local ah,al=self:getRegister(ra);local bh,bl=self:getRegister(rb)
			high,low=add(ah,al,bh,bl);self:setRegister(rt,high,low)
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
		if (xo==266 or xo==28 or xo==444 or xo==316 or xo==124) and band(word,1)~=0 then self:record(high,low) end
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

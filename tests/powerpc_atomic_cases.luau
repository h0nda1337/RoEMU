return function(Platform)
	local checks=0
	local function check(value,why) assert(value,why);checks+=1 end
	local function put(b,at,w) for j=0,3 do buffer.writeu8(b,at+j,bit32.band(bit32.rshift(w,(3-j)*8),255)) end end
	local function get(b,at) return buffer.readu8(b,at)*16777216+buffer.readu8(b,at+1)*65536+buffer.readu8(b,at+2)*256+buffer.readu8(b,at+3) end
	local function x(xo,rt,ra,rb,rc) return 31*67108864+rt*2097152+ra*65536+rb*2048+xo*2+(rc or 0) end
	local c=Platform.new({ramBytes=65536})
	local function step(word)
		put(c.ram,0x1000,word);c.pcHi,c.pcLo=0,0x1000;return c:step()
	end
	for _,width in ipairs({4,8}) do
		local load=x(width==4 and 20 or 84,3,0,4)
		local store=x(width==4 and 150 or 214,6,0,4,1)
		c.reservation=nil;c.cr,c.xer=0x4ABCDEF0,0x80000000;c:setRegister(4,0,0x300)
		put(c.ram,0x300,0x00200000);put(c.ram,0x304,1)
		check(step(load).kind=="ok","load reservation")
		local h,l=c:getRegister(3);check(h==(width==8 and 0x00200000 or 0) and l==(width==8 and 1 or 0x00200000),"exact reserved load")
		c:setRegister(6,0xFEDCBA98,0x76543210)
		check(step(store).kind=="ok" and bit32.rshift(c.cr,28)==3 and c.reservation==nil,"successful store consumes token and records EQ/SO")
		check(get(c.ram,0x300)==(width==8 and 0xFEDCBA98 or 0x76543210),"conditional store bytes")
		local before=buffer.tostring(c.ram)
		check(step(store).kind=="ok" and bit32.rshift(c.cr,28)==1,"repeated conditional store fails")
		check(buffer.tostring(c.ram)==before,"failed conditional store does not write")
		step(load);c:setRegister(4,0,0x308);check(step(store).kind=="ok" and bit32.rshift(c.cr,28)==1,"address mismatch")
		c:setRegister(4,0,0x300);step(load)
		check(step(36*67108864+6*2097152+4*65536).kind=="ok" and c.reservation==nil,"intervening guest store invalidates reservation")
		check(step(store).kind=="ok" and bit32.rshift(c.cr,28)==1,"modified granule cannot commit")
		step(load)
		step(36*67108864+6*2097152+4*65536+128)
		check(c.reservation~=nil and step(store).kind=="ok" and bit32.rshift(c.cr,28)==3,"other granule preserves reservation")
		step(load);c:setRegister(4,1,0x300)
		local count,cr=c.instructions,c.cr
		check(step(store).kind=="memory_fault" and c.instructions==count and c.cr==cr,"high address fault is atomic")
		c:setRegister(4,0,0x300)
	end
	c.reservation=nil;c.timeBaseHi,c.timeBaseLo=0x00200000,1
	check(step(x(371,7,12,8)).kind=="ok","mftb opcode")
	local h,l=c:getRegister(7);check(h==0x00200000 and l==1,"timebase beyond 2^53")
	check(step(x(339,7,12,8)).kind=="ok","mfspr TBL encoding")
	h,l=c:getRegister(7);check(h==0x00200000 and l==1,"TBL is full64")
	check(step(x(371,7,13,8)).kind=="ok","mftbu")
	h,l=c:getRegister(7);check(h==0 and l==0x00200000,"TBU upper32")
	for _,word in ipairs({0x7C0004AC,0x7C2004AC,0x7C0006AC,0x4C00012C}) do
		local cr,xer,ctrH,ctrL=c.cr,c.xer,c.ctrHi,c.ctrLo
		check(step(word).kind=="ok" and c.pcLo==0x1004 and c.cr==cr and c.xer==xer and c.ctrHi==ctrH and c.ctrLo==ctrL,"ordered-memory barrier")
	end
	return {checks=checks,exactTimebase=true,reservations=true}
end

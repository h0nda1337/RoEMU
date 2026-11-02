--!native
--!optimize 2
-- Exact IEEE bit operations for the implemented legacy PowerPC FP subset.
-- No signed 64-bit input is rounded by converting it to a host double first.
local FPU={VERSION="0.1.0"}
local band,bor,bnot,lshift,rshift=bit32.band,bit32.bor,bit32.bnot,bit32.lshift,bit32.rshift
local function exception(status,bits)
	if band(bnot(status),bits)~=0 then status=bor(status,0x80000000) end
	status=bor(status,bits)
	local invalid=band(status,0x01F80700)~=0
	status=bor(band(status,0x9FFFFFFF),invalid and 0x20000000 or 0)
	local enabled=(invalid and band(status,0x80)~=0) or (band(status,0x10000000)~=0 and band(status,0x40)~=0)
		or (band(status,0x08000000)~=0 and band(status,0x20)~=0) or (band(status,0x04000000)~=0 and band(status,0x10)~=0)
		or (band(status,0x02000000)~=0 and band(status,8)~=0)
	return bor(status,enabled and 0x40000000 or 0)
end
function FPU.FromSigned(high,low,fpscr)
	local negative=high>=0x80000000
	if negative then
		low=4294967295-low+1
		high=band(4294967295-high+math.floor(low/4294967296),0xFFFFFFFF);low=band(low,0xFFFFFFFF)
	end
	local sign=negative and 0x80000000 or 0
	local resultHi,resultLo,classification=0,0,2
	local inexact,increment=false,false
	if high~=0 or low~=0 then
		local exponent=high~=0 and 63-bit32.countlz(high) or 31-bit32.countlz(low)
		local shift=math.max(0,exponent-52)
		local mantissaHi,mantissaLo=high,low
		if shift>0 then
			local remainder=band(low,lshift(1,shift)-1)
			mantissaHi=rshift(high,shift);mantissaLo=bor(rshift(low,shift),lshift(high,32-shift))
			inexact=remainder~=0
			local mode=band(fpscr,3)
			local halfway=lshift(1,shift-1)
			increment=inexact and ((mode==2 and not negative) or (mode==3 and negative)
				or (mode==0 and (remainder>halfway or (remainder==halfway and band(mantissaLo,1)~=0))))
		elseif exponent<52 then
			local amount=52-exponent
			if amount>=32 then mantissaHi,mantissaLo=lshift(low,amount-32),0
			else mantissaHi,mantissaLo=bor(lshift(high,amount),rshift(low,32-amount)),lshift(low,amount) end
		end
		if increment then
			mantissaLo+=1;mantissaHi+=math.floor(mantissaLo/4294967296);mantissaLo=band(mantissaLo,0xFFFFFFFF)
			if mantissaHi==0x200000 then mantissaHi,mantissaLo=0x100000,0;exponent+=1 end
		end
		resultHi,resultLo=bor(sign,lshift(exponent+1023,20),band(mantissaHi,0xFFFFF)),mantissaLo
		classification=negative and 8 or 4
	end
	local status=bor(band(fpscr,0xFFF80FFF),lshift(classification,12),inexact and 0x20000 or 0,increment and 0x40000 or 0)
	status=exception(status,inexact and 0x02000000 or 0)
	return resultHi,resultLo,status
end
local function roundInteger(significand,shift,mode,negative)
	local retained,remainder=0,significand
	local halfway=math.huge
	if shift<54 then
		local quantum=2^shift
		retained=math.floor(significand/quantum);remainder=significand-retained*quantum;halfway=quantum/2
	end
	local inexact=remainder~=0
	local increment=inexact and ((mode==2 and not negative) or (mode==3 and negative)
		or (mode==0 and (remainder>halfway or (remainder==halfway and retained%2~=0))))
	return retained+(increment and 1 or 0),inexact,increment
end
local function resultStatus(fpscr,classification,inexact,increment,exceptions)
	local status=bor(band(fpscr,0xFFF80FFF),lshift(classification,12),inexact and 0x20000 or 0,increment and 0x40000 or 0)
	return exception(status,bor(exceptions or 0,inexact and 0x02000000 or 0))
end
function FPU.RoundSingle(high,low,fpscr)
	local negative=high>=0x80000000;local sign=band(high,0x80000000)
	local exponent=band(rshift(high,20),2047)
	local fractionHi=band(high,0xFFFFF)
	if exponent==2047 then
		if fractionHi==0 and low==0 then return high,low,resultStatus(fpscr,negative and 9 or 5,false,false),true end
		local signaling=band(high,0x80000)==0
		if signaling and band(fpscr,0x80)~=0 then
			return 0,0,exception(band(fpscr,0xFFF9FFFF),0x01000000),false
		end
		local payload=bor(lshift(fractionHi,3),rshift(low,29),0x400000)
		return bor(sign,0x7FF00000,rshift(payload,3)),lshift(payload,29),resultStatus(fpscr,0x11,false,false,signaling and 0x01000000 or 0),true
	end
	-- A binary64 significand is at most 2^53-1, exactly representable here.
	-- The full encoded operand is never converted to a scalar integer.
	local significand=fractionHi*4294967296+low
	if exponent==0 and significand==0 then return sign,0,resultStatus(fpscr,negative and 0x12 or 2,false,false),true end
	local e=exponent-1023
	if exponent==0 then
		local top=fractionHi~=0 and 63-bit32.countlz(fractionHi) or 31-bit32.countlz(low)
		local shift=52-top;significand*=2^shift;e=-1022-shift
	else significand+=4503599627370496 end
	local mode=band(fpscr,3)
	local tiny=e< -126
	local underflowEnabled=band(fpscr,0x20)~=0
	local shift=tiny and not underflowEnabled and 29+(-126-e) or 29
	local mantissa,inexact,increment=roundInteger(significand,shift,mode,negative)
	local exceptions=0
	if tiny then
		if underflowEnabled then e+=192;exceptions=0x08000000
		else
			e=-126
			if inexact then exceptions=0x08000000 end
		end
	end
	if mantissa>=16777216 then mantissa/=2;e+=1 end
	if e>127 and not tiny then
		exceptions=0x10000000
		if band(fpscr,0x40)~=0 then e-=192
		else
			local infinity=mode==0 or (mode==2 and not negative) or (mode==3 and negative)
			local rh,rl=bor(sign,0x47EFFFFF),0xE0000000 -- largest finite binary32 in double format
			if infinity then rh,rl=bor(sign,0x7FF00000),0 end
			return rh,rl,resultStatus(fpscr,infinity and (negative and 9 or 5) or (negative and 8 or 4),true,false,exceptions),true
		end
	end
	local classification=negative and 8 or 4
	if mantissa==0 then return sign,0,resultStatus(fpscr,negative and 0x12 or 2,inexact,increment,exceptions),true end
	if mantissa<8388608 then
		local shiftToNormal=bit32.countlz(mantissa)-8
		mantissa*=2^shiftToNormal;e-=shiftToNormal;classification=negative and 0x18 or 0x14
	end
	local fraction=mantissa-8388608
	return bor(sign,lshift(e+1023,20),rshift(fraction,3)),lshift(fraction,29),resultStatus(fpscr,classification,inexact,increment,exceptions),true
end
local function unpackFinite(high,low)
	local exponent=band(rshift(high,20),2047)
	local fraction=band(high,0xFFFFF)*4294967296+low
	if exponent~=0 then return fraction+4503599627370496,exponent-1023 end
	local top=band(high,0xFFFFF)~=0 and 63-bit32.countlz(band(high,0xFFFFF)) or 31-bit32.countlz(low)
	local shift=52-top
	return fraction*2^shift,-1022-shift
end
local function encodeFinite(negative,mantissa,precision,e)
	local sign=negative and 0x80000000 or 0
	if mantissa==0 then return sign,0 end
	local highPart=math.floor(mantissa/4294967296)
	local top=highPart~=0 and 63-bit32.countlz(highPart) or 31-bit32.countlz(mantissa)
	local shift=precision-1-top
	mantissa*=2^shift;e-=shift
	local fraction
	if e< -1022 then fraction=mantissa*2^(53-precision+e+1022);e=-1023
	else fraction=mantissa*2^(53-precision)-4503599627370496 end
	return bor(sign,lshift(e+1023,20),math.floor(fraction/4294967296)),fraction%4294967296
end
function FPU.Divide(ah,al,bh,bl,fpscr,single)
	local negative=(ah>=0x80000000)~=(bh>=0x80000000)
	local sign=negative and 0x80000000 or 0
	local ae,be=band(rshift(ah,20),2047),band(rshift(bh,20),2047)
	local af,bf=band(ah,0xFFFFF),band(bh,0xFFFFF)
	local az=ae==0 and af==0 and al==0;local bz=be==0 and bf==0 and bl==0
	local an=ae==2047 and (af~=0 or al~=0);local bn=be==2047 and (bf~=0 or bl~=0)
	local invalid=0
	if (an and band(ah,0x80000)==0) or (bn and band(bh,0x80000)==0) then invalid=0x01000000 end
	if not an and not bn then
		if ae==2047 and be==2047 then invalid=0x00400000
		elseif az and bz then invalid=0x00200000 end
	end
	if invalid~=0 and band(fpscr,0x80)~=0 then return 0,0,exception(band(fpscr,0xFFF9FFFF),invalid),false end
	if an or bn then
		local h,l=ah,al;if not an then h,l=bh,bl end
		h=bor(h,0x80000)
		if single then l=band(l,0xE0000000) end
		return h,l,resultStatus(fpscr,0x11,false,false,invalid),true
	end
	if invalid~=0 then return 0x7FF80000,0,resultStatus(fpscr,0x11,false,false,invalid),true end
	if ae==2047 then return bor(sign,0x7FF00000),0,resultStatus(fpscr,negative and 9 or 5,false,false),true end
	if be==2047 or az then return sign,0,resultStatus(fpscr,negative and 0x12 or 2,false,false),true end
	if bz then
		if band(fpscr,0x10)~=0 then return 0,0,exception(band(fpscr,0xFFF9FFFF),0x04000000),false end
		return bor(sign,0x7FF00000),0,resultStatus(fpscr,negative and 9 or 5,false,false,0x04000000),true
	end
	local numerator,aExponent=unpackFinite(ah,al)
	local denominator,bExponent=unpackFinite(bh,bl)
	local e=aExponent-bExponent
	if numerator<denominator then numerator*=2;e-=1 end
	local remainder=numerator-denominator
	local precision=single and 24 or 53
	local minimum,maximum=single and -126 or -1022,single and 127 or 1023
	local tiny=e<minimum;local underflowEnabled=band(fpscr,0x20)~=0
	local retainedBits=precision-((tiny and not underflowEnabled) and minimum-e or 0)
	local mantissa=0
	local inexact,increment
	local mode=band(fpscr,3)
	if retainedBits>0 then
		mantissa=1
		for _=2,retainedBits do
			remainder*=2;mantissa*=2
			if remainder>=denominator then remainder-=denominator;mantissa+=1 end
		end
		inexact=remainder~=0
		local twice=remainder*2
		increment=inexact and ((mode==2 and not negative) or (mode==3 and negative)
			or (mode==0 and (twice>denominator or (twice==denominator and mantissa%2~=0))))
	else
		inexact=true
		increment=(mode==2 and not negative) or (mode==3 and negative) or (mode==0 and retainedBits==0 and remainder~=0)
	end
	if increment then mantissa+=1 end
	local exceptions=0
	if tiny then
		if underflowEnabled then e+=single and 192 or 1536;exceptions=0x08000000
		else e=minimum;if inexact then exceptions=0x08000000 end end
	end
	if mantissa==2^precision then mantissa/=2;e+=1 end
	if e>maximum and not tiny then
		exceptions=0x10000000
		if band(fpscr,0x40)~=0 then e-=single and 192 or 1536
		else
			local infinity=mode==0 or (mode==2 and not negative) or (mode==3 and negative)
			local h,l
			if infinity then h,l=bor(sign,0x7FF00000),0
			elseif single then h,l=bor(sign,0x47EFFFFF),0xE0000000
			else h,l=bor(sign,0x7FEFFFFF),0xFFFFFFFF end
			return h,l,resultStatus(fpscr,infinity and (negative and 9 or 5) or (negative and 8 or 4),true,false,exceptions),true
		end
	end
	local classification=negative and 8 or 4
	if mantissa==0 then classification=negative and 0x12 or 2
	elseif mantissa<2^(precision-1) then classification=negative and 0x18 or 0x14 end
	local h,l=encodeFinite(negative,mantissa,precision,e)
	return h,l,resultStatus(fpscr,classification,inexact,increment,exceptions),true
end
return FPU

--!strict
-- Sv32 (bytes) con hojas L1 (4MB) y L0 (4KB). Permisos R/W/X simplificados.
local bit = bit32
local function u32(x) x = x % 0x100000000; return x end
local function fld(x, lo, hi)
	local width = hi - lo + 1
	local mask  = bit.lshift(bit.lshift(1, width) - 1, lo)
	return bit.rshift(bit.band(x, mask), lo)
end

local MMU = {}
function MMU.sv32_translate(read8, read32, satp, va, isWrite, isExec)
	local mode = bit.band(satp, 0xF)
	if mode ~= 1 then return u32(va), nil end
	local vpn0 = bit.rshift(bit.band(va, 0x000FF000), 12)
	local vpn1 = bit.rshift(bit.band(va, 0x3FF00000), 20)
	local off  = bit.band(va, 0xFFF)
	local root = bit.rshift(satp, 12)

	local function pte_addr(ppn, idx) return u32(bit.lshift(ppn,12) + idx*4) end
	local function rd32(a) return read32(a) end

	local pte1 = rd32(pte_addr(root, vpn1))
	if bit.band(pte1,1)==0 then return nil, "PTE1 not present" end
	local R = bit.band(pte1,2)~=0; local W=bit.band(pte1,4)~=0; local X=bit.band(pte1,8)~=0
	if R or X then
		if isWrite and not W then return nil, "L1 write-protect" end
		if isExec and not X then return nil, "L1 exec-protect" end
		local pa = u32(bit.lshift(fld(pte1,10,31),12) + bit.lshift(vpn0,12) + off)
		return pa, nil
	end
	-- descend L0
	local nextppn = fld(pte1,10,31)
	local pte0 = rd32(pte_addr(nextppn, vpn0))
	if bit.band(pte0,1)==0 then return nil, "PTE0 not present" end
	local R0 = bit.band(pte0,2)~=0; local W0=bit.band(pte0,4)~=0; local X0=bit.band(pte0,8)~=0
	if not (R0 or X0) then return nil, "PTE0 invalid leaf" end
	if isWrite and not W0 then return nil, "L0 write-protect" end
	if isExec and not X0 then return nil, "L0 exec-protect" end
	local pa = u32(bit.lshift(fld(pte0,10,31),12) + off)
	return pa, nil
end
return MMU

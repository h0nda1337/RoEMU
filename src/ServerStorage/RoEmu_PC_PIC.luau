--!native
--!optimize 2
local band, bor, bnot, lshift = bit32.band, bit32.bor, bit32.bnot, bit32.lshift
local PIC = {}
PIC.__index = PIC
local function chip(base, mask)
	return { base = base, mask = mask, irr = 0, isr = 0, priority = 0, init = 0, readISR = false, autoEOI = false }
end
local function priority(ch, mask)
	if mask == 0 then return 8 end
	for rank = 0, 7 do if band(mask, lshift(1, (rank + ch.priority) % 8)) ~= 0 then return rank end end
	return 8
end
local function pending(ch, extra)
	local rank = priority(ch, band(bor(ch.irr, extra or 0), bnot(ch.mask)))
	local inService = ch.specialMask and band(ch.isr, bnot(ch.mask)) or ch.isr
	if rank < priority(ch, inService) then return (rank + ch.priority) % 8 end
	return nil
end
local function acknowledge(ch, irq)
	ch.irr = band(ch.irr, bnot(lshift(1, irq)))
	if ch.autoEOI then
		if ch.rotateAuto then ch.priority = (irq + 1) % 8 end
	else ch.isr = bor(ch.isr, lshift(1, irq)) end
end
function PIC.new() return setmetatable({ master = chip(8, 0), slave = chip(0x70, 255) }, PIC) end
function PIC:raise(irq)
	local ch = irq < 8 and self.master or self.slave
	ch.irr = bor(ch.irr, lshift(1, irq % 8))
end
function PIC:nextVector()
	if self.master.irr == 0 and self.slave.irr == 0 then return nil end
	local slaveIRQ = pending(self.slave)
	if slaveIRQ then self:raise(2) end
	local irq = pending(self.master)
	if irq == nil then return nil end
	acknowledge(self.master, irq)
	if irq == 2 then
		if slaveIRQ then acknowledge(self.slave, slaveIRQ) end
		return self.slave.base + (slaveIRQ or 7)
	end
	return self.master.base + irq
end
function PIC:hasPending()
	return pending(self.master, pending(self.slave) and 4 or 0) ~= nil
end
function PIC:read(port)
	local ch = port < 0xA0 and self.master or self.slave
	if port % 2 == 1 then return ch.mask end
	if ch.poll then
		ch.poll = false
		local irq = pending(ch)
		if irq == nil then return 0 end
		acknowledge(ch, irq); return 0x80 + irq
	end
	return ch.readISR and ch.isr or ch.irr
end
function PIC:write(port, value)
	local ch = port < 0xA0 and self.master or self.slave
	if port % 2 == 1 then
		if ch.init == 1 then ch.base = band(value, 0xF8); ch.init = ch.single and (ch.need4 and 3 or 0) or 2
		elseif ch.init == 2 then ch.init = ch.need4 and 3 or 0
		elseif ch.init == 3 then ch.autoEOI = band(value, 2) ~= 0; ch.init = 0
		else ch.mask = value end
	elseif band(value, 0x10) ~= 0 then
		ch.init, ch.irr, ch.isr, ch.mask, ch.priority = 1, 0, 0, 0, 0
		ch.need4, ch.single, ch.autoEOI = band(value, 1) ~= 0, band(value, 2) ~= 0, false
	elseif band(value, 8) ~= 0 then
		if band(value, 2) ~= 0 then ch.readISR = band(value, 1) ~= 0 end
		if band(value, 4) ~= 0 then ch.poll = true end
		if band(value, 0x40) ~= 0 then ch.specialMask = band(value, 0x20) ~= 0 end
	else
		local command, irq = math.floor(value / 32), band(value, 7)
		if command == 0 or command == 4 then ch.rotateAuto = command == 4
		elseif command == 6 then ch.priority = (irq + 1) % 8
		elseif command == 1 or command == 3 or command == 5 or command == 7 then
			if command == 1 or command == 5 then
				local rank = priority(ch, ch.isr)
				if rank == 8 then return end
				irq = (rank + ch.priority) % 8
			end
			ch.isr = band(ch.isr, bnot(lshift(1, irq)))
			if command >= 5 then ch.priority = (irq + 1) % 8 end
		end
	end
end
return PIC

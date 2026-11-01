--!native
--!optimize 2
-- Headless byte-addressable memory helpers for the x86 backend.
-- The CPU only needs read8/write8 callbacks; this module is optional.

local bit = bit32
local band = bit.band

local Memory = {}

local function u32(value)
	return band(tonumber(value) or 0, 0xFFFFFFFF)
end

local RAM = {}
RAM.__index = RAM

function RAM.new(base, size, options)
	options = options or {}
	base = u32(base or 0)
	size = math.floor(tonumber(size) or 0)
	assert(size > 0, "RAM size must be positive")

	local self = setmetatable({}, RAM)
	self.base = base
	self.size = size
	self.limit = base + size - 1
	self.readOnly = options.readOnly == true
	self.defaultByte = band(options.defaultByte or 0, 0xFF)

	-- Roblox provides buffers and they are substantially faster for dense RAM.
	-- The sparse-table fallback keeps fixtures usable in a plain Luau runtime.
	if buffer ~= nil and buffer.create ~= nil and size <= 0x7FFFFFFF then
		self.buffer = buffer.create(size)
		if self.defaultByte ~= 0 and buffer.fill ~= nil then
			buffer.fill(self.buffer, 0, self.defaultByte, size)
		end
	else
		self.bytes = {}
	end
	return self
end

function RAM:contains(address)
	address = u32(address)
	return address >= self.base and address <= self.limit
end

function RAM:read8(address)
	address = u32(address)
	local offset = address - self.base
	if offset < 0 or offset >= self.size then
		return nil, "unmapped"
	end
	if self.buffer ~= nil then
		return buffer.readu8(self.buffer, offset)
	end
	local value = self.bytes[offset + 1]
	if value == nil then
		return self.defaultByte
	end
	return value
end

function RAM:write8(address, value)
	address = u32(address)
	local offset = address - self.base
	if offset < 0 or offset >= self.size then
		return false, "unmapped"
	end
	if self.readOnly then
		return false, "read-only"
	end
	value = band(value or 0, 0xFF)
	if self.buffer ~= nil then
		buffer.writeu8(self.buffer, offset, value)
	else
		self.bytes[offset + 1] = value
	end
	return true
end

function RAM:load(address, data)
	address = u32(address)
	if type(data) == "string" then
		for index = 1, #data do
			local ok, reason = self:write8(address + index - 1, string.byte(data, index))
			if not ok then
				return false, reason
			end
		end
		return true
	end

	for index, value in ipairs(data) do
		local ok, reason = self:write8(address + index - 1, value)
		if not ok then
			return false, reason
		end
	end
	return true
end

function RAM:dump(address, size)
	local result = {}
	for index = 0, size - 1 do
		local value, reason = self:read8(address + index)
		if value == nil then
			return nil, reason
		end
		result[index + 1] = value
	end
	return result
end

function RAM:callbacks()
	return {
		read8 = function(address)
			return self:read8(address)
		end,
		write8 = function(address, value)
			return self:write8(address, value)
		end,
	}
end

Memory.RAM = RAM

local Bus = {}
Bus.__index = Bus

function Bus.new()
	return setmetatable({ regions = {} }, Bus)
end

function Bus:map(base, size, handlers, name)
	base = u32(base)
	size = math.floor(tonumber(size) or 0)
	assert(size > 0, "mapped region size must be positive")
	assert(type(handlers) == "table", "mapped region handlers must be a table")
	local region = {
		base = base,
		limit = base + size - 1,
		size = size,
		name = name or handlers.name or "region",
		read8 = handlers.read8,
		write8 = handlers.write8,
	}
	table.insert(self.regions, region)
	return region
end

function Bus:mapRAM(ram, name)
	return self:map(ram.base, ram.size, {
		read8 = function(address)
			return ram:read8(address)
		end,
		write8 = function(address, value)
			return ram:write8(address, value)
		end,
	}, name or "ram")
end

function Bus:find(address)
	address = u32(address)
	-- Later mappings override earlier mappings, which is useful for MMIO windows.
	for index = #self.regions, 1, -1 do
		local region = self.regions[index]
		if address >= region.base and address <= region.limit then
			return region
		end
	end
	return nil
end

function Bus:read8(address, cpu, access)
	local region = self:find(address)
	if region == nil or region.read8 == nil then
		return nil, "unmapped"
	end
	return region.read8(u32(address), cpu, access, region)
end

function Bus:write8(address, value, cpu, access)
	local region = self:find(address)
	if region == nil or region.write8 == nil then
		return false, "unmapped"
	end
	return region.write8(u32(address), band(value or 0, 0xFF), cpu, access, region)
end

function Bus:callbacks()
	return {
		read8 = function(address, cpu, access)
			return self:read8(address, cpu, access)
		end,
		write8 = function(address, value, cpu, access)
			return self:write8(address, value, cpu, access)
		end,
	}
end

Memory.Bus = Bus

return Memory

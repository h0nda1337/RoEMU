--!optimize 2
local Sparse = script and require(game:GetService("ReplicatedStorage").RiscV.devices.virtio_blk_sparse)
	or require("./sparse_disk")
local Loader = {}

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local lookup = {}
for i = 1, #alphabet do lookup[alphabet:byte(i)] = i - 1 end
local function decode(text)
	local length = #text / 4 * 3
	if text:sub(-1) == "=" then length -= 1 end
	if text:sub(-2, -2) == "=" then length -= 1 end
	local out = buffer.create(length)
	local cursor = 0
	for i = 1, #text, 4 do
		local a, b, c, d = text:byte(i, i + 3)
		local n = lookup[a] * 262144 + lookup[b] * 4096 + (lookup[c] or 0) * 64 + (lookup[d] or 0)
		buffer.writeu8(out, cursor, bit32.rshift(n, 16)); cursor += 1
		if cursor < length then buffer.writeu8(out, cursor, bit32.rshift(n, 8)); cursor += 1 end
		if cursor < length then buffer.writeu8(out, cursor, n); cursor += 1 end
	end
	return buffer.tostring(out)
end

function Loader.new(packBytes, getPart, rawParts)
	local cache, order = {}, {}
	local provider = { length = packBytes }
	provider.readRange = function(offset, count)
		assert(offset >= 0 and count >= 0 and offset + count <= packBytes, "disk pack range")
		local output = {}
		while count > 0 do
			local part = math.floor(offset / 84000) + 1
			local within = offset % 84000
			local value = cache[part]
			if not value then
				value = rawParts and getPart(part) or decode(getPart(part))
				cache[part] = value
				order[#order + 1] = part
				if #order > 64 then cache[table.remove(order, 1)] = nil end
			end
			local take = math.min(count, #value - within)
			assert(take > 0, "truncated disk pack")
			output[#output + 1] = value:sub(within + 1, within + take)
			offset += take
			count -= take
		end
		return table.concat(output)
	end
	return Sparse.SparseDisk.new(provider)
end

return Loader

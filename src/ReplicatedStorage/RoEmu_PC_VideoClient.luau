--!optimize 2
-- Runtime VGA framebuffer; all pixels come from guest VRAM and its DAC palette.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetService = game:GetService("AssetService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local Pixels = require(script.Parent.RoEmu_PC_Pixels)
local Video = {}

function Video.Mount()
	local gui = Instance.new("ScreenGui")
	gui.Name = "RoEmuPCVideo"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 2000
	gui.Enabled = false
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	local background = Instance.new("Frame")
	background.Size = UDim2.fromScale(1, 1)
	background.BackgroundColor3 = Color3.new(0, 0, 0)
	background.BorderSizePixel = 0
	background.Active = true
	background.Parent = gui
	local surface = Instance.new("ImageLabel")
	surface.AnchorPoint = Vector2.new(0.5, 0.5)
	surface.Position = UDim2.fromScale(0.5, 0.5)
	surface.Size = UDim2.fromScale(1, 1)
	surface.BackgroundTransparency = 1
	surface.ResampleMode = Enum.ResamplerMode.Pixelated
	surface.Parent = background
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 4 / 3
	aspect.DominantAxis = Enum.DominantAxis.Width
	aspect.Parent = surface
	local function fitSurface()
		local size = background.AbsoluteSize
		local width = math.min(size.X, size.Y * 4 / 3)
		surface.Size = UDim2.fromOffset(width, width * 3 / 4)
	end
	background:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitSurface)
	fitSurface()
	local editable, imageWidth, imageHeight
	local converter=Pixels.new()
	local hasFrame,lastFormat,fallbackPixels=false,nil,nil
	local spans = {}
	local function fallback(pixels, palette, width, height, format)
		local used = 0
		local scale = math.max(2, math.ceil(width / 128), math.ceil(height / 100))
		local function pixel(offset) return format == "rgba8" and buffer.readu32(pixels, offset * 4) or buffer.readu8(pixels, offset) end
		for y = 0, height - 1, scale do
			local x = 0
			while x < width do
				local index = pixel(y * width + x)
				local finish = math.min(width, x + scale)
				while finish < width and pixel(y * width + finish) == index do finish = math.min(width, finish + scale) end
				used += 1
				if used > 16000 then break end
				local span = spans[used]
				if not span then span = Instance.new("Frame"); span.BorderSizePixel = 0; span.Parent = surface; spans[used] = span end
				span.Position = UDim2.fromScale(x / width, y / height)
				span.Size = UDim2.fromScale((finish - x) / width, math.min(scale, height - y) / height)
				if format == "rgba8" then
					span.BackgroundColor3 = Color3.fromRGB(bit32.band(index, 255), bit32.band(bit32.rshift(index, 8), 255), bit32.band(bit32.rshift(index, 16), 255))
				else span.BackgroundColor3 = Color3.fromRGB(buffer.readu8(palette, index * 3) * 255 / 63,
					buffer.readu8(palette, index * 3 + 1) * 255 / 63, buffer.readu8(palette, index * 3 + 2) * 255 / 63) end
				span.Visible = true
				x = finish
			end
		end
		for index = used + 1, #spans do spans[index].Visible = false end
	end
	local event = ReplicatedStorage:FindFirstChild("RoEmu_PCVideo")
	while not event do
		local child = ReplicatedStorage.ChildAdded:Wait()
		if child.Name == "RoEmu_PCVideo" then event = child end
	end
	local specialKeys={LeftControl={0x1D,false},RightControl={0x1D,true},LeftAlt={0x38,false},RightAlt={0x38,true},
		LeftSuper={0x5B,true},RightSuper={0x5C,true},LeftMeta={0x5B,true},RightMeta={0x5C,true},
		Up={0x48,true},Down={0x50,true},Left={0x4B,true},Right={0x4D,true},Home={0x47,true},End={0x4F,true},
		PageUp={0x49,true},PageDown={0x51,true},Insert={0x52,true},F11={0x57,false},F12={0x58,false}}
	for i=1,10 do specialKeys["F"..i]={0x3A+i,false} end
	local held={}
	local mouseButtons,lastMouse=0,0
	local pointerX,pointerY,pointerPending=32768,32768,false
	local buttonBits={ [Enum.UserInputType.MouseButton1]=1,[Enum.UserInputType.MouseButton2]=2,[Enum.UserInputType.MouseButton3]=4 }
	local function acceptsInput()
		return gui.Enabled and not GuiService.MenuIsOpen and UserInputService:GetFocusedTextBox()==nil
	end
	local function inside(position)
		local origin,size=surface.AbsolutePosition,surface.AbsoluteSize
		return position.X>=origin.X and position.Y>=origin.Y and position.X<origin.X+size.X and position.Y<origin.Y+size.Y
	end
	local function locatePointer(position)
		local origin,size=surface.AbsolutePosition,surface.AbsoluteSize
		pointerX=math.clamp(math.round((position.X-origin.X)/math.max(1,size.X-1)*65535),0,65535)
		pointerY=math.clamp(math.round((position.Y-origin.Y)/math.max(1,size.Y-1)*65535),0,65535)
		pointerPending=true
	end
	local function sendMouse()
		event:FireServer("pointer",pointerX,pointerY,mouseButtons)
		pointerPending=false
		lastMouse=os.clock()
	end
	UserInputService.InputBegan:Connect(function(input)
		if not acceptsInput() then return end
		local key=specialKeys[input.KeyCode.Name]
		if key then held[input.KeyCode.Name]=key;event:FireServer("key",key[1],true,key[2]) end
		local button=buttonBits[input.UserInputType]
		local position=UserInputService:GetMouseLocation()
		if button and inside(position) then locatePointer(position);mouseButtons=bit32.bor(mouseButtons,button);sendMouse() end
	end)
	UserInputService.InputEnded:Connect(function(input)
		local key=held[input.KeyCode.Name]
		if key then held[input.KeyCode.Name]=nil;event:FireServer("key",key[1],false,key[2]) end
		local button=buttonBits[input.UserInputType]
		if button and bit32.band(mouseButtons,button)~=0 then locatePointer(UserInputService:GetMouseLocation());mouseButtons=bit32.band(mouseButtons,bit32.bnot(button));sendMouse() end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not acceptsInput() or input.UserInputType~=Enum.UserInputType.MouseMovement or not imageWidth then return end
		-- Position works with Roblox's free pointer; Delta can be zero unless
		-- pointer lock is active. IgnoreGuiInset gives the same screen origin.
		local position=UserInputService:GetMouseLocation()
		if inside(position) or mouseButtons~=0 then locatePointer(position) end
	end)
	RunService.RenderStepped:Connect(function()
		if pointerPending and acceptsInput() and os.clock()-lastMouse>=1/60 then sendMouse() end
	end)
	UserInputService.WindowFocusReleased:Connect(function()
		for _,key in pairs(held) do event:FireServer("key",key[1],false,key[2]) end
		table.clear(held)
		if mouseButtons~=0 then mouseButtons=0;sendMouse() end
	end)
	event.OnClientEvent:Connect(function(pixels, palette, width, height, format, rectangle)
		if pixels == false then gui.Enabled = false;hasFrame=false;return end
		if type(width) ~= "number" or type(height) ~= "number" or width % 1 ~= 0 or height % 1 ~= 0 or width < 1 or width > 1024 or height < 1 or height > 768 then return end
		format = format or "indexed8"
		if format ~= "indexed8" and format ~= "rgba8" then return end
		local y,rows=0,height
		if rectangle~=nil then
			if type(rectangle)~="table" or type(rectangle.y)~="number" or type(rectangle.rows)~="number" then return end
			y,rows=rectangle.y,rectangle.rows
			if y%1~=0 or rows%1~=0 or y<0 or rows<1 or y+rows>height then return end
			if not hasFrame or imageWidth~=width or imageHeight~=height or lastFormat~=format then event:FireServer("frame");return end
		end
		if typeof(pixels) ~= "buffer" or buffer.len(pixels) ~= width * rows * (format == "rgba8" and 4 or 1) or typeof(palette) ~= "buffer" or buffer.len(palette) ~= 768 then return end
		if imageWidth ~= width or imageHeight ~= height then
			if editable then editable:Destroy(); editable = nil end
			local ok, result = pcall(function() return AssetService:CreateEditableImage({ Size = Vector2.new(width, height) }) end)
			if ok and result then editable = result; surface.ImageContent = Content.fromObject(editable) end
			imageWidth, imageHeight = width, height
			-- Standard VGA timings display non-square guest pixels on a 4:3 CRT.
			aspect.AspectRatio = 4 / 3
		end
		gui.Enabled = true
		hasFrame,lastFormat=true,format
		if editable then
			if format == "rgba8" then editable:WritePixelsBuffer(Vector2.new(0,y), Vector2.new(width,rows), pixels); return end
			local rgba = converter:convert(pixels,palette)
			editable:WritePixelsBuffer(Vector2.new(0,y), Vector2.new(width,rows), rgba)
		else
			local stride=width*(format=="rgba8" and 4 or 1)
			if not fallbackPixels or buffer.len(fallbackPixels)~=stride*height then fallbackPixels=buffer.create(stride*height) end
			buffer.copy(fallbackPixels,y*stride,pixels)
			fallback(fallbackPixels, palette, width, height, format)
		end
	end)
	event:FireServer("frame")
end

return Video

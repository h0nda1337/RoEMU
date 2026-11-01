-- PixelText: sprite-atlas text renderer for Roblox UI.

local FontData = require(script.Parent.FontData)

local PixelText = {}
PixelText.__index = PixelText

local DEFAULT_COLOR = Color3.new(1, 1, 1)

local function normalizeImage(value: any): string
	if type(value) == "number" then
		return "rbxassetid://" .. tostring(value)
	end
	if type(value) == "string" then
		return value
	end
	return FontData.AtlasImage
end

local function horizontalOffset(alignment: Enum.TextXAlignment, totalWidth: number, lineWidth: number): number
	if alignment == Enum.TextXAlignment.Center then
		return (totalWidth - lineWidth) * 0.5
	elseif alignment == Enum.TextXAlignment.Right then
		return totalWidth - lineWidth
	end
	return 0
end

local function verticalOffset(alignment: Enum.TextYAlignment, totalHeight: number, contentHeight: number): number
	if alignment == Enum.TextYAlignment.Center then
		return (totalHeight - contentHeight) * 0.5
	elseif alignment == Enum.TextYAlignment.Bottom then
		return totalHeight - contentHeight
	end
	return 0
end

function PixelText.new(parent: GuiObject, options: {[string]: any}?)
	assert(parent and parent:IsA("GuiObject"), "PixelText.new expects a GuiObject parent")
	options = options or {}

	local self = setmetatable({}, PixelText)
	self.Parent = parent
	self.Text = options.Text or ""
	self.Scale = options.Scale or 1
	self.Color = options.Color or DEFAULT_COLOR
	self.Transparency = options.Transparency or 0
	self.TextWrapped = options.TextWrapped == true
	self.MaxWidth = options.MaxWidth
	self.TextXAlignment = options.TextXAlignment or Enum.TextXAlignment.Left
	self.TextYAlignment = options.TextYAlignment or Enum.TextYAlignment.Top
	self.LetterSpacing = options.LetterSpacing or 0
	self.LineSpacing = options.LineSpacing or 0
	self.TabSize = math.max(1, options.TabSize or 4)
	self.ZIndex = options.ZIndex or 1
	self.Image = normalizeImage(options.Image)
	self.Visible = options.Visible ~= false
	self._destroyed = false
	self._glyphs = {}
	self._renderQueued = false

	local root = Instance.new("Frame")
	root.Name = options.Name or "PixelText"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Position = options.Position or UDim2.fromScale(0, 0)
	root.Size = options.Size or UDim2.fromScale(1, 1)
	root.AnchorPoint = options.AnchorPoint or Vector2.zero
	root.ClipsDescendants = options.ClipsDescendants == true
	root.Visible = self.Visible
	root.ZIndex = self.ZIndex
	root.Parent = parent
	self.Root = root

	self._sizeConnection = root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_queueRender()
	end)

	self:Render()
	task.defer(function()
		if not self._destroyed then
			self:Render()
		end
	end)

	return self
end

function PixelText:_queueRender()
	if self._destroyed or self._renderQueued then
		return
	end
	self._renderQueued = true
	task.defer(function()
		self._renderQueued = false
		if not self._destroyed then
			self:Render()
		end
	end)
end

function PixelText:_acquireGlyph(): ImageLabel
	local index = self._activeGlyphCount + 1
	self._activeGlyphCount = index

	local glyph = self._glyphs[index]
	if glyph == nil then
		glyph = Instance.new("ImageLabel")
		glyph.Name = "Glyph"
		glyph.BackgroundTransparency = 1
		glyph.BorderSizePixel = 0
		glyph.ScaleType = Enum.ScaleType.Stretch
		glyph.ResampleMode = Enum.ResamplerMode.Pixelated
		glyph.Parent = self.Root
		self._glyphs[index] = glyph
	end

	glyph.Visible = true
	return glyph
end

function PixelText:_hideUnusedGlyphs()
	for index = self._activeGlyphCount + 1, #self._glyphs do
		self._glyphs[index].Visible = false
	end
end

function PixelText:_layoutLines(wrapWidth: number)
	local lines = {}
	local scale = math.max(0.01, self.Scale)
	local cellAdvance = (FontData.Advance + self.LetterSpacing) * scale
	local shouldWrap = self.TextWrapped and wrapWidth > 0

	local line = {glyphs = {}, width = 0, columns = 0}

	local function pushLine()
		table.insert(lines, line)
		line = {glyphs = {}, width = 0, columns = 0}
	end

	for _, codepoint in utf8.codes(self.Text) do
		if codepoint == 0x0D then
			continue
		elseif codepoint == 0x0A then
			pushLine()
		elseif codepoint == 0x09 then
			local spaces = self.TabSize - (line.columns % self.TabSize)
			local advance = spaces * cellAdvance
			if shouldWrap and line.width > 0 and line.width + advance > wrapWidth then
				pushLine()
				spaces = self.TabSize
				advance = spaces * cellAdvance
			end
			line.width += advance
			line.columns += spaces
		else
			if shouldWrap and line.width > 0 and line.width + cellAdvance > wrapWidth then
				pushLine()
			end

			local renderedCodepoint = codepoint
			if FontData.GlyphIndex[renderedCodepoint] == nil then
				renderedCodepoint = FontData.FallbackCodepoint
			end

			if renderedCodepoint ~= 0x20 and renderedCodepoint ~= 0x00A0 then
				table.insert(line.glyphs, {
					codepoint = renderedCodepoint,
					x = line.width,
				})
			end

			line.width += cellAdvance
			line.columns += 1
		end
	end

	pushLine()
	return lines
end

function PixelText:Render()
	if self._destroyed then
		return
	end

	local scale = math.max(0.01, self.Scale)
	local rootSize = self.Root.AbsoluteSize
	local alignmentWidth = rootSize.X
	local wrapWidth = alignmentWidth
	if type(self.MaxWidth) == "number" and self.MaxWidth > 0 then
		wrapWidth = math.min(wrapWidth, self.MaxWidth)
	end

	local lines = self:_layoutLines(wrapWidth)
	local lineHeight = (FontData.LineHeight * scale) + self.LineSpacing
	local contentHeight = 0
	if #lines > 0 then
		contentHeight = (#lines * FontData.LineHeight * scale) + ((#lines - 1) * self.LineSpacing)
	end

	local startY = verticalOffset(self.TextYAlignment, rootSize.Y, contentHeight)
	local image = normalizeImage(self.Image)
	self._activeGlyphCount = 0

	for lineIndex, line in ipairs(lines) do
		local startX = horizontalOffset(self.TextXAlignment, alignmentWidth, line.width)
		local y = startY + ((lineIndex - 1) * lineHeight)

		for _, item in ipairs(line.glyphs) do
			local glyph = self:_acquireGlyph()
			local rectOffset, rectSize = FontData.GetRect(item.codepoint)

			glyph.Image = image
			glyph.ImageRectOffset = rectOffset
			glyph.ImageRectSize = rectSize
			glyph.ImageColor3 = self.Color
			glyph.ImageTransparency = self.Transparency
			glyph.ZIndex = self.ZIndex
			glyph.Size = UDim2.fromOffset(
				math.round(FontData.GlyphSize.X * scale),
				math.round(FontData.GlyphSize.Y * scale)
			)
			glyph.Position = UDim2.fromOffset(
				math.round(startX + item.x),
				math.round(y)
			)
		end
	end

	self.Root.Visible = self.Visible
	self:_hideUnusedGlyphs()
end

function PixelText:SetText(text: string)
	self.Text = text
	self:Render()
end

function PixelText:Set(properties: {[string]: any})
	for key, value in pairs(properties) do
		if key == "Image" then
			self.Image = normalizeImage(value)
		elseif key == "Position" or key == "Size" or key == "AnchorPoint" or key == "ClipsDescendants" then
			self.Root[key] = value
		elseif self[key] ~= nil then
			self[key] = value
		else
			warn(("PixelText: unknown property %q"):format(tostring(key)))
		end
	end
	self.Root.ZIndex = self.ZIndex
	self.Root.Visible = self.Visible
	self:Render()
end

function PixelText:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	if self._sizeConnection then
		self._sizeConnection:Disconnect()
	end
	self.Root:Destroy()
	table.clear(self._glyphs)
end

return PixelText

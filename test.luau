
-- Simple regression and performance test for luau_qoi.

--!strict
--!native

local QOI = require('@self/QOI')
local SampleID = Content.fromAssetId(126128421498657)

local Asset = game:GetService 'AssetService'
local Foreimage = Asset:CreateEditableImageAsync(SampleID)
local ForeimageID = Content.fromObject(Foreimage)

local ForeimageData: QOI.ImageData = {
	Width = Foreimage.Size.X,
	Height = Foreimage.Size.Y,
	Channels = 4,
	Colorspace = 0,
	Data = Foreimage:ReadPixelsBuffer(Vector2.zero, Foreimage.Size)
} 

local function CorrectnessTest(): ()
	local QOIFile = QOI.encode( ForeimageData )
	local PXBFile = QOI.decode( QOIFile )
	local Afterimage = QOI.read( PXBFile )
	local AfterimageID = Content.fromObject(Afterimage)

	print('working?')
	-- Render outputs
	local New = Instance.new

	local GUI = Instance.new 'ScreenGui'
	local Client = (game:GetService 'Players').LocalPlayer :: Player

	local function RenderImage(content: Content, size: Vector2): (ImageLabel)
		local IMG_SIZE = UDim2.fromScale(0.75, 0.75)

		local label = New 'ImageLabel'
		label.ImageContent = content
		label.BorderSizePixel = 0
		label.Size = IMG_SIZE
		label.Name = '$image'

		local ratio = New 'UIAspectRatioConstraint'
		ratio.AspectRatio = size.X / size.Y
		ratio.Parent = label
		ratio.Name = '$aspect-ratio'

		label.Parent = GUI
		return label
	end

	RenderImage(ForeimageID, Foreimage.Size).Name = '@foreimage'
	RenderImage(AfterimageID, Afterimage.Size).Name = '@afterimage'

	local list = New 'UIListLayout'
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.FillDirection = Enum.FillDirection.Horizontal
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0.05)
	list.Parent = GUI

	GUI.ResetOnSpawn = false
	GUI.IgnoreGuiInset = true
	GUI.Parent = Client.PlayerGui
end

local function Benchmark<P...>(amount: number, func: (P...) -> (any), ...: P...): ()
	local WAIT_AMOUNT = 1/15 -- 4 frames worth
	local accum, n = 0, 0
	local begin, finish = 0, 0
	local clock = os.clock

	for i = 1, amount do
		begin = clock()
		func(...)
		finish = clock()
		accum += finish - begin
		n += 1
		task.wait(WAIT_AMOUNT) --> to prevent execution time exhaustion
	end

	local funcname = debug.info(func, 'n')
	local avg = (accum / n) * 1000
	warn(`{funcname}() took {avg} ms on average.`)
end

CorrectnessTest()
task.wait()

local OriginalSize = buffer.len(ForeimageData.Data)
warn(`Sample image size: {Foreimage.Size}`)
warn(`Sample image data size before encoding: {OriginalSize}`)

Benchmark(40, QOI.encode, ForeimageData)
-- As of August 29, 2025, the results of the benchmark relative to the
-- `ForeimageData` is that the `encode()` function takes ~44 ms on average.
-- Compare this to the previous benchmark (https://devforum.roblox.com/t/2921027)
-- I've done against an image of the same size (1024 by 1024) and speculatively,
-- of the same spacial complexity, this is about a 14x improvement!

local EncodedForeimageData = QOI.encode(ForeimageData)
local CompressedSize = buffer.len(EncodedForeimageData)
warn(`Sample image data size after encoding: {CompressedSize}`)
warn(`Compression percentage: {100 - (CompressedSize / OriginalSize * 100)}% less`)
task.wait()

Benchmark(40, QOI.decode, EncodedForeimageData)
-- As of August 29, 2025, the results of the benchmark relative to the
-- `EncodedForeimageData` is that the `decode()` function takes ~40 ms on average.
-- Compare this to the previous benchmark (https://devforum.roblox.com/t/2921027)
-- I've done against an image of the same size (1024 by 1024) and speculatively,
-- of the same spacial complexity, this is about a 7x improvement!

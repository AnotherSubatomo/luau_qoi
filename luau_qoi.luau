
--[=[
	Copyright (c) 2024, AnotherSubatomo
	SPDX-License-Identifier: MIT
	
	QOI en-/decoder in Luau for Roblox
	A derivative of Dominic Szablewski's work
	
	NOTE:
	 -  EditableImages by default are RGBA (4-channeled),
		rendering the header's channel field useless.
	
	 -  EditableImages format pixels as an Float32Array[4]
	 	(because the values are normals) but we have to turn
	 	them into Uint8Array[4] (actual RGBA values).
]=]

--!strict
--!optimize 2
--!native

local buffer_readu8 = buffer.readu8
local buffer_writeu8 = buffer.writeu8
local talloc = table.create
local tclone = table.clone
local push = table.insert

export type Pixel = { number } -- [1:4] number array
export type QOIHeader = {
	Signature: 'qoif',
	Width: number,
	Height: number,
	Channels: number,
	Colorspace: number
}
export type ImageData = {
	Width: number,
	Height: number,
	Channels: number?,
	Colorspace: number?,
	Data: buffer
}

local QOI_OP_RUN   = 0b11000000;
local QOI_OP_INDEX = 0b00000000;
local QOI_OP_DIFF  = 0b01000000;
local QOI_OP_LUMA  = 0b10000000;
local QOI_OP_RGB   = 0b11111110;
local QOI_OP_RGBA  = 0b11111111;

local QOI_MASK192  = 0b11000000;
local QOI_MASK63   = 0b00111111;

local MAX_DIM_SIZE = 4096
local HEADER_SIZE = 14
local END_MARKER = {0, 0, 0, 0, 0, 0, 0, 1}

local function PixelDiff(pixel: Pixel, previous_pixel: Pixel)
	return {
		pixel[1] - previous_pixel[1],		-- @r
		pixel[2] - previous_pixel[2],		-- @g
		pixel[3] - previous_pixel[3],		-- @b
		pixel[4] - previous_pixel[4]		-- @a
	}
end

local function PixelEq(pixel: Pixel, previous_pixel: Pixel)
	return
		previous_pixel and
		pixel[1] == previous_pixel[1] and	-- @r
		pixel[2] == previous_pixel[2] and	-- @g
		pixel[3] == previous_pixel[3] and	-- @b
		pixel[4] == previous_pixel[4] and	-- @a
		true or false
end

local function HashPixel(pixel: Pixel): (number)
	return ( pixel[1] * 3 + pixel[2] * 5 + pixel[3] * 7 + pixel[4] * 11 ) % 64;
end

function QOI_GET_HEADER(file: buffer): QOIHeader
	local signature = buffer.readstring(file, 0, 4)
	assert( signature == 'qoif' , 'QOI_HEADER: Invalid file signature.' )

	return {
		Signature = signature,
		Width = buffer.readu32(file, 4),
		Height = buffer.readu32(file, 8),
		Channels = buffer_readu8(file, 12),
		Colorspace = buffer_readu8(file, 13)
	}
end

function QOI_ENCODE(image: ImageData): (buffer)
	local height = image.Height
	local width = image.Width
	local pixels = image.Data
	local img_data_size = height * width * 4
	local img_end_offset = img_data_size - 4

	assert( height > 1 and height < MAX_DIM_SIZE , 'QOI_ENCODING: Invalid height.' )
	assert( width > 1 and width < MAX_DIM_SIZE , 'QOI_ENCODING: Invalid width.' )

	local seen_pixels = talloc(64); -- @[0..62] >> #62
	local bytes = talloc(img_data_size); -- should be good heuristics
	local run = 0;

	local cur_px = talloc(4, 0);
	local prev_px = talloc(4, 0); prev_px[4] = 255;

	-- Compress image data.
	for px_pos = 0, img_data_size - 1, 4 do
		-- Update the content of the 'current pixel'.
		cur_px[1] = buffer_readu8(pixels, px_pos)
		cur_px[2] = buffer_readu8(pixels, px_pos+1)
		cur_px[3] = buffer_readu8(pixels, px_pos+2)
		cur_px[4] = buffer_readu8(pixels, px_pos+3)

		-- QOI_OP_RUN
		if PixelEq(cur_px, prev_px) then
			run += 1;
			if run == 62 or px_pos == img_end_offset then
				push(bytes, QOI_OP_RUN + (run - 1))	-- bias by -1
				run = 0;
			end
		else
			if run > 0 then
				push(bytes, QOI_OP_RUN + (run - 1)) -- bias by -1
				run = 0;
			end
			-- QOI_OP_INDEX
			local hash = HashPixel(cur_px)
			local cache_idx = hash + 1 -- add by 1 because this is Lua(u).

			if PixelEq(cur_px, seen_pixels[cache_idx]) then
				push(bytes, QOI_OP_INDEX + hash)
			else
				seen_pixels[cache_idx] = tclone(cur_px)

				-- QOI_OP_DIFF & QOI_OP_LUMA & QOI_OP_RGB
				local diff = PixelDiff(cur_px, prev_px)
				local dr_dg = diff[1] - diff[2]
				local db_dg = diff[3] - diff[2]
				local endian = 0

				-- (if the alpha of both pixels were the same)
				if diff[4] == 0 then
					if (diff[1] >= -2 and diff[1] <= 1) and
						(diff[2] >= -2 and diff[2] <= 1) and
						(diff[3] >= -2 and diff[3] <= 1) then
						for c = 1, 3 do endian += bit32.lshift(diff[c] + 2, (3 - c) * 2) end -- bias by 2
						push(bytes, QOI_OP_DIFF + endian)
					elseif (diff[2] >= -32 and diff[2] <= 31) and
						(dr_dg >= -8 and dr_dg <= 7) and
						(db_dg >= -8 and db_dg <= 7) then
						push(bytes, QOI_OP_LUMA + (diff[2] + 32))             -- bias by 32
						push(bytes, bit32.lshift(dr_dg + 8, 4) + (db_dg + 8)) -- bias by 8
					else
						push(bytes, 254)
						for c = 1, 3 do push(bytes, cur_px[c]) end
					end
				else
					-- QOI_OP_RGBA
					push(bytes, 255)
					for c = 1, 4 do push(bytes, cur_px[c]) end
				end
			end
		end

		prev_px, cur_px = cur_px, prev_px;
	end

	-- Mark the end of the QOI file.
	table.move(END_MARKER, 1, #END_MARKER, #bytes + 1, bytes)

	-- Hooray! We are officially done encoding, time to buffer it!
	local file = buffer.create(#bytes + HEADER_SIZE)
	local offset = HEADER_SIZE;

	-- We write the header.
	local channels = image.Channels or 4
	local colorspace = image.Colorspace or 0
	buffer.writestring(file, 0, 'qoif')  -- @char >> signature 'qoif'
	buffer.writeu32(file, 4, width)      -- @uint32
	buffer.writeu32(file, 8, height)     -- @uint32
	buffer_writeu8(file, 12, channels)   -- @uint8 >> 3 = RGB, 4 = RGBA
	buffer_writeu8(file, 13, colorspace) -- @uint8 >> 0 = sRGB w/ linear alpha

	-- We write the compressed data.
	for i = 1, #bytes do
		buffer_writeu8(file, offset, bytes[i])
		offset += 1
	end

	return file
end

function QOI_DECODE(file: buffer): (ImageData)
	local header = QOI_GET_HEADER(file);
	local pixel = talloc(4, 0); pixel[4] = 255;
	local pixels_size = header.Width * header.Height * header.Channels;
	local pixels = buffer.create(pixels_size);
	local file_size = buffer.len(file);

	local seen_pixels = talloc(64); -- @[0..62] >> #62
	local run = 0;
	local read_limit = file_size - #END_MARKER;
	local read_idx = HEADER_SIZE;
	local write_idx = 0;

	local function readu8(): (number)
		local byte = buffer_readu8(file, read_idx)
		read_idx += 1
		return byte
	end

	-- File size must not be lesser than the size of the header and end marker, combined.
	assert( file_size > HEADER_SIZE + #END_MARKER , 'QOI_DECODING: Bad QOI file (too small).' )

	while read_idx < read_limit do
		if run > 0 then
			run -= 1
		else
			local byte1 = readu8()

			if byte1 == QOI_OP_RGB then
				pixel[1] = readu8()
				pixel[2] = readu8()
				pixel[3] = readu8()

			elseif byte1 == QOI_OP_RGBA then
				pixel[1] = readu8()
				pixel[2] = readu8()
				pixel[3] = readu8()
				pixel[4] = readu8()

			elseif bit32.band(byte1, QOI_MASK192) == QOI_OP_INDEX then
				local cache_idx = byte1 + 1  -- add by 1 because this is Lua(u).
				pixel = seen_pixels[cache_idx]

			elseif bit32.band(byte1, QOI_MASK192) == QOI_OP_DIFF then
				pixel[1] += bit32.rshift(bit32.band(byte1, 0x30), 4) - 2
				pixel[2] += bit32.rshift(bit32.band(byte1, 0x0c), 2) - 2
				pixel[3] +=              bit32.band(byte1, 0x03)     - 2

			elseif bit32.band(byte1, QOI_MASK192) == QOI_OP_LUMA then
				local dg = bit32.band(byte1, QOI_MASK63) - 32
				local byte2 = readu8()
				pixel[2] += dg
				pixel[1] += dg + bit32.rshift(bit32.band(byte2, 0xf0), 4) - 8
				pixel[3] += dg +              bit32.band(byte2, 0x0f)     - 8

			elseif bit32.band(byte1, QOI_MASK192) == QOI_OP_RUN then
				run = bit32.band(byte1, QOI_MASK63);
			end

			local cache_idx = HashPixel(pixel) + 1 -- add by 1 because this is Lua(u).
			seen_pixels[cache_idx] = tclone(pixel);
		end

		-- Write the pixel
		local offset = 4 * write_idx
		write_idx += 1
		buffer_writeu8(pixels, offset, pixel[1])
		buffer_writeu8(pixels, offset + 1, pixel[2])
		buffer_writeu8(pixels, offset + 2, pixel[3])
		buffer_writeu8(pixels, offset + 3, pixel[4])
	end

	return {
		Signature = header.Signature,
		Width = header.Width,
		Height = header.Height,
		Channels = header.Channels,
		Colorspace = header.Colorspace,
		Data = pixels
	}
end

function READ_TO_IMAGE(imageData: ImageData): (EditableImage)
	assert(game or Vector2, "Cannot read into an editable image; you are in a non-Roblox environment.")
	assert(imageData.Channels == 4, "Cannot read into an editable image; channel amounts other than 4 are unsupported.")

	local AssetService = (game::DataModel):GetService 'AssetService'
	local image_size = Vector2.new(imageData.Width, imageData.Height)
	local image = AssetService:CreateEditableImage({ Size = image_size })
	image:WritePixelsBuffer(Vector2.zero, image_size, imageData.Data)
	return image
end

local VERSION = table.freeze { major = 2, minor = 0, isRelease = true }

return table.freeze {
	version = VERSION;
	getHeader = QOI_GET_HEADER;
	encode = QOI_ENCODE;
	decode = QOI_DECODE;
	read = READ_TO_IMAGE;
}

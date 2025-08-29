
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
local buffer_readu32 = buffer.readu32
local buffer_writeu32 = buffer.writeu32
local alloc = buffer.create
local lshift = bit32.lshift
local rshift = bit32.rshift
local band = bit32.band

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

local QOI_MAGIC      = 'qoif';
local HEADER_SIZE    = 14;
local QOI_PIXELS_MAX = 400000000;
local QOI_PADDING    = {0, 0, 0, 0, 0, 0, 0, 1};

local SIZEOF_U32 = 4; -- (bytes)
local CACHE_SIZE = 64;

local function cast_u32(n: number): (number)
	return math.clamp(math.round(n), 0, 0xffffffff)
end

local function hash_pixel(r: number, g: number, b: number, a: number): (number)
	return ( r * 3 + g * 5 + b * 7 + a * 11 ) % 64;
end

function QOI_GET_HEADER(file: buffer): (QOIHeader)
	assert( buffer.readstring(file, 0, 4) == QOI_MAGIC , 'QOI_HEADER: Invalid file signature.' )

	return {
		Signature = QOI_MAGIC::'qoif',       -- @char[4] ; "qoif"
		Width = buffer_readu32(file, 4),     -- @uint32  ; # of pixels on x-axis
		Height = buffer_readu32(file, 8),    -- @uint32  ; # of pixels on y-axis
		Channels = buffer_readu8(file, 12),  -- @uint8   ; 3 = RGB, 4 = RGBA
		Colorspace = buffer_readu8(file, 13) -- @uint8   ; 0 = sRGB w/ linear alpha, 1 = all channels linear
	}
end

function QOI_ENCODE(image: ImageData): (buffer)
	local height = cast_u32(image.Height)
	local width = cast_u32(image.Width)
	local channels = cast_u32(image.Channels or 4)
	local colorspace = cast_u32(image.Colorspace or 0)
	local pixels = image.Data
	local img_data_size = height * width * SIZEOF_U32
	local img_end_offset = img_data_size - SIZEOF_U32

	assert( height > 0                       , 'QOI_ENCODING: Invalid height.' )
	assert( width > 0                        , 'QOI_ENCODING: Invalid width.' )
	assert( channels == 3 or channels == 4   , 'QOI_ENCODING: `Channels` must be either 3 or 4.' )
	assert( colorspace <= 1                  , 'QOI_ENCODING: `Colorspace` must be either 0 or 1.' )
	assert( height < QOI_PIXELS_MAX // width , 'QOI_ENCODING: Image exceeds maximum pixel count.' )

	local seen_pixels = alloc(SIZEOF_U32 * CACHE_SIZE) -- @[0..62] >> #62
	local compressed = alloc(img_data_size) -- should be good heuristics
	local write_idx = 0;

	local run = 0;
	local cur_px = 0;           -- (0, 0, 0, 0)
	local prev_px = 0x000000ff; -- (0, 0, 0, 255)

	local prev_r, prev_g, prev_b, prev_a = 0, 0, 0, 255;
	local cur_r, cur_g, cur_b, cur_a = 0, 0, 0, 0;
	local diff_r, diff_g, diff_b, diff_a = 0, 0, 0, 0;
	local dr_dg, db_dg, endian = 0, 0, 0;

	-- Compress image data.
	for px_pos = 0, img_data_size - 1, 4 do
		-- Update the content of the 'current pixel'.
		cur_px = buffer_readu32(pixels, px_pos)
		cur_r = buffer_readu8(pixels, px_pos)
		cur_g = buffer_readu8(pixels, px_pos + 1)
		cur_b = buffer_readu8(pixels, px_pos + 2)
		cur_a = buffer_readu8(pixels, px_pos + 3)

		-- QOI_OP_RUN
		if cur_px == prev_px then
			run += 1;
			if run == 62 or px_pos == img_end_offset then
				buffer_writeu8(compressed, write_idx, QOI_OP_RUN + (run - 1)) -- bias by -1
				write_idx += 1;
				run = 0;
			end
		else
			if run > 0 then
				buffer_writeu8(compressed, write_idx, QOI_OP_RUN + (run - 1)) -- bias by -1
				write_idx += 1;
				run = 0;
			end
			-- QOI_OP_INDEX
			local hash = hash_pixel(cur_r, cur_g, cur_b, cur_a)

			if cur_px == buffer_readu32(seen_pixels, SIZEOF_U32 * hash) then
				buffer_writeu8(compressed, write_idx, QOI_OP_INDEX + hash)
				write_idx += 1;
			else
				buffer_writeu32(seen_pixels, SIZEOF_U32 * hash, cur_px)

				-- QOI_OP_DIFF & QOI_OP_LUMA & QOI_OP_RGB
				diff_r = cur_r - prev_r; 
				diff_g = cur_g - prev_g; 
				diff_b = cur_b - prev_b; 
				diff_a = cur_a - prev_a; 
				dr_dg = diff_r - diff_g;
				db_dg = diff_b - diff_g;
				endian = 0;

				-- (if the alpha of both pixels were the same)
				if diff_a == 0 then
					if (diff_r >= -2 and diff_r <= 1) and
						(diff_g >= -2 and diff_g <= 1) and
						(diff_b >= -2 and diff_b <= 1) then
						-- biases of 2
						endian += lshift(diff_r + 2, 4)
						endian += lshift(diff_g + 2, 2)
						endian +=        diff_b + 2
						
						buffer_writeu8(compressed, write_idx, QOI_OP_DIFF + endian)
						write_idx += 1
					elseif (diff_g >= -32 and diff_g <= 31) and
						(dr_dg >= -8 and dr_dg <= 7) and
						(db_dg >= -8 and db_dg <= 7) then
						buffer_writeu8(compressed, write_idx,     QOI_OP_LUMA + (diff_g + 32))        -- bias by 32
						buffer_writeu8(compressed, write_idx + 1, lshift(dr_dg + 8, 4) + (db_dg + 8)) -- bias by 8
						write_idx += 2
					else
						buffer_writeu8(compressed, write_idx,      254)
						buffer_writeu32(compressed, write_idx + 1, cur_px)
						write_idx += 4;
					end
				else
					-- QOI_OP_RGBA
					buffer_writeu8(compressed, write_idx,      255)
					buffer_writeu32(compressed, write_idx + 1, cur_px)
					write_idx += 5;
				end
			end
		end

		prev_px = cur_px;
		prev_r = cur_r;
		prev_g = cur_g;
		prev_b = cur_b;
		prev_a = cur_a;
	end

	-- Mark the end of the QOI file.
	for _, byte in QOI_PADDING do
		buffer_writeu8(compressed, write_idx, byte)
		write_idx += 1;
	end

	-- Hooray! We are officially done encoding, time to buffer it!
	local file = alloc(write_idx + HEADER_SIZE)

	-- We write the header.
	buffer.writestring(file, 0, QOI_MAGIC)
	buffer_writeu32(file, 4, width)
	buffer_writeu32(file, 8, height)
	buffer_writeu8(file, 12, channels)
	buffer_writeu8(file, 13, colorspace)

	-- We write the compressed data.
	buffer.copy(file, HEADER_SIZE, compressed, 0, write_idx)

	return file
end

function QOI_DECODE(file: buffer): (ImageData)
	local file_size = buffer.len(file)
	assert( file_size > HEADER_SIZE + #QOI_PADDING , 'QOI_DECODING: Bad QOI file (too small).' )

	local header = QOI_GET_HEADER(file)
	local raw_image_size = header.Width * header.Height * header.Channels;
	local raw_image = alloc(raw_image_size)

	local seen_pixels = alloc(SIZEOF_U32 * CACHE_SIZE) -- @[0..62] >> #62
	local read_limit = file_size - #QOI_PADDING;
	local read_idx = HEADER_SIZE;
	local write_idx = 0;

	local r, g, b, a = 0, 0, 0, 255;
	local run = 0;

	while read_idx < read_limit do
		if run > 0 then
			run -= 1;
		else
			local byte1 = buffer_readu8(file, read_idx); read_idx +=1;
			local op = band(byte1, QOI_MASK192)

			if byte1 == QOI_OP_RGB then
				r = buffer_readu8(file, read_idx)
				g = buffer_readu8(file, read_idx + 1)
				b = buffer_readu8(file, read_idx + 2)
				read_idx += 3;

			elseif byte1 == QOI_OP_RGBA then
				r = buffer_readu8(file, read_idx)
				g = buffer_readu8(file, read_idx + 1)
				b = buffer_readu8(file, read_idx + 2)
				a = buffer_readu8(file, read_idx + 3)
				read_idx += 4;

			elseif op == QOI_OP_INDEX then
				local cache_idx = SIZEOF_U32 * byte1
				r = buffer_readu8(seen_pixels, cache_idx)
				g = buffer_readu8(seen_pixels, cache_idx + 1)
				b = buffer_readu8(seen_pixels, cache_idx + 2)
				a = buffer_readu8(seen_pixels, cache_idx + 3)

			elseif op == QOI_OP_DIFF then
				r += rshift(band(byte1, 0x30), 4) - 2
				g += rshift(band(byte1, 0x0c), 2) - 2
				b +=        band(byte1, 0x03)     - 2

			elseif op == QOI_OP_LUMA then
				local dg = band(byte1, QOI_MASK63) - 32
				local byte2 = buffer_readu8(file, read_idx); read_idx +=1;
				g += dg
				r += dg + rshift(band(byte2, 0xf0), 4) - 8
				b += dg +        band(byte2, 0x0f)     - 8

			elseif op == QOI_OP_RUN then
				run = band(byte1, QOI_MASK63)
			end

			local cache_idx = SIZEOF_U32 * hash_pixel(r, g, b, a)
			buffer_writeu8(seen_pixels, cache_idx, r)
			buffer_writeu8(seen_pixels, cache_idx + 1, g)
			buffer_writeu8(seen_pixels, cache_idx + 2, b)
			buffer_writeu8(seen_pixels, cache_idx + 3, a)
		end

		-- Write the pixel
		buffer_writeu8(raw_image, write_idx, r)
		buffer_writeu8(raw_image, write_idx + 1, g)
		buffer_writeu8(raw_image, write_idx + 2, b)
		buffer_writeu8(raw_image, write_idx + 3, a)
		write_idx += 4
	end

	return {
		Signature = header.Signature,
		Width = header.Width,
		Height = header.Height,
		Channels = header.Channels,
		Colorspace = header.Colorspace,
		Data = raw_image
	}
end

function READ_TO_IMAGE(imageData: ImageData): (EditableImage)
	assert(game and Vector2, "Cannot read into an editable image; you are in a non-Roblox environment.")
	assert(imageData.Channels == 4, "Cannot read into an editable image; channel amounts other than 4 are unsupported.")

	local AssetService = (game::DataModel):GetService 'AssetService'
	local image_size = Vector2.new(imageData.Width, imageData.Height)
	local image = AssetService:CreateEditableImage({ Size = image_size })
	image:WritePixelsBuffer(Vector2.zero, image_size, imageData.Data)
	return image
end

local VERSION = table.freeze { major = 2, minor = 2, isRelease = true }

return table.freeze {
	version = VERSION;
	getHeader = QOI_GET_HEADER;
	encode = QOI_ENCODE;
	decode = QOI_DECODE;
	read = READ_TO_IMAGE;
}

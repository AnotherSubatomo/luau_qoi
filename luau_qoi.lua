
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

export type Pixel = { r: number, g: number, b: number, a: number }
export type QOIHeader = { Magic: 'qoif', Width: number, Height: number, Channels: number }

local QOI_OP = {
	RUN = 192 ,		-- @0b11000000
	INDEX = 0 ,		-- @0b00000000
	DIFF = 64 ,		-- @0b01000000
	LUMA = 128 ,	-- @0b10000000
	RGB = 254 ,		-- @0b11111110
	RGBA = 255 ,	-- @0b11111111

	MASK = 192	 	-- @0b11000000
}

local PX_SIZE = Vector2.one
local HEADER_SIZE = 14
local END_MARKER = {0, 0, 0, 0, 0, 0, 0, 1}

local function PixelDiff(
	pixel : Pixel ,
	previous_pixel : Pixel
)
	return {
		pixel[1] - previous_pixel[1],		-- @r
		pixel[2] - previous_pixel[2],		-- @g
		pixel[3] - previous_pixel[3],		-- @b
		pixel[4] - previous_pixel[4]		-- @a
	}
end

local function PixelEq(
	pixel : Pixel ,
	previous_pixel : Pixel
)
	return
		previous_pixel and
		pixel[1] == previous_pixel[1] and	-- @r
		pixel[2] == previous_pixel[2] and	-- @g
		pixel[3] == previous_pixel[3] and	-- @b
		pixel[4] == previous_pixel[4] and	-- @a
		true or false
end

local function HashPixel( pixel : Pixel )
	return ( pixel[1] * 3 + pixel[2] * 5 + pixel[3] * 7 + pixel[4] * 11 ) % 64;
end

-------------------------------------------------------------------------------------------

local QOI = {}

function QOI.getHeader(
	file : buffer
)
	return {
		Magic = buffer.readstring(file, 0, 4) ,
		Width = buffer.readu32(file, 4) ,
		Height = buffer.readu32(file, 8) ,
		Channels = buffer.readu8(file, 12) ,
		Colorspace = buffer.readu8(file, 13)
	}
end

function QOI.encode(
	image : EditableImage
)
	local seen_pixels = {}; -- @[0..62] >> #62
	local bytes = {};
	local previous_pixel = {0, 0, 0, 255};
	local run = 0

	local height = image.Size.Y
	local width = image.Size.X
	
	local pixels = image:ReadPixels(Vector2.zero, image.Size)
	local px_len = height * width * 4
	local px_end = px_len - 4
	
	assert( height > 1 and height < 4096 , 'QOI_ENCODING: Invalid height.')
	assert( width > 1 and width < 4096 , 'QOI_ENCODING: Invalid width.')

	for px_pos = 1, px_len, 4 do
		local pixel = { pixels[px_pos], pixels[px_pos+1],
						pixels[px_pos+2], pixels[px_pos+3] }
		for c = 1, 4 do pixel[c] = math.round(pixel[c]*255) end

		-- // QOI_OP.RUN
		if PixelEq( pixel, previous_pixel ) then
			run += 1;
			if run == 62 or px_pos == px_end then
				table.insert(bytes, QOI_OP.RUN + (run - 1))		-- bias by -1
				run = 0;
			end
		else
			if run > 0 then
				table.insert(bytes, QOI_OP.RUN + (run - 1))		-- bias by -1
				run = 0;
			end
			-- // QOI_OP.INDEX
			local hash = HashPixel(pixel)
			
			if PixelEq( pixel, seen_pixels[hash] ) then
				table.insert(bytes, QOI_OP.INDEX + hash)
			else
				seen_pixels[hash] = table.clone(pixel);
				
				-- // QOI_OP.DIFF & QOI_OP.LUMA & QOI_OP.RGB
				local diff = PixelDiff(pixel, previous_pixel)
				local dr_dg = diff[1] - diff[2]
				local db_dg = diff[3] - diff[2]
				local endian = 0;
				
				--@ If the alpha of both pixels were the same;
				if diff[4] == 0 then
					if (diff[1] >= -2 and diff[1] <= 1) and
						(diff[2] >= -2 and diff[2] <= 1) and
						(diff[3] >= -2 and diff[3] <= 1) then
						for c = 1, 3 do endian += bit32.lshift(diff[c]+2, (3-c)*2) end	-- bias by 2
						table.insert(bytes, QOI_OP.DIFF + endian)
					elseif (diff[2] >= -32 and diff[2] <= 31) and
						(dr_dg >= -8 and dr_dg <= 7) and
						(db_dg >= -8 and db_dg <= 7) then
						table.insert(bytes, QOI_OP.LUMA + (diff[2] + 32))				-- bias by 32
						table.insert(bytes, bit32.lshift(dr_dg+8, 4)+(db_dg+8))			-- bias by 8
					else
						table.insert(bytes, 254)
						for c = 1, 3 do table.insert(bytes, pixel[c]) end
					end
				else
					-- // QOI_OP.RGBA
					table.insert(bytes, 255)
					for c = 1, 4 do table.insert(bytes, pixel[c]) end
				end
			end
		end

		previous_pixel = table.clone(pixel);
	end

	-- /* Mark the end of the QOI file. */
	for m = 1, #END_MARKER do
		table.insert(bytes, END_MARKER[m])
	end

	-- /* Hooray! We are officially done encoding, time to buffer it! */
	local file = buffer.create(#bytes + HEADER_SIZE)
	local offset = HEADER_SIZE;
	
	-- // We write the header.
	buffer.writestring(file, 0, 'qoif')		-- @char >> signature 'qoif'
	buffer.writeu32(file, 4, width)			-- @uint32
	buffer.writeu32(file, 8, height)		-- @uint32
	buffer.writeu8(file, 12, 4)				-- @uint8 >> 3 = RGB, 4 = RGBA
	buffer.writeu8(file, 13, 0)				-- @uint8 >> 0 = sRGB w/ linear alpha
	
	-- // We write the compressed data.
	for i = 1, #bytes do
		buffer.writeu8(file, offset, bytes[i])
		offset += 1
	end
	
	return file
end



function QOI.decode( file : buffer )
	
	local header = QOI.getHeader(file)
	local pixel = {0, 0, 0, 255};
	local pixels_size = header.Width * header.Height * header.Channels;
	local pixels = buffer.create(pixels_size);
	
	local seen_pixels = {} -- @[0..62] >> #62
	local run = 0
	local read_index = HEADER_SIZE;
	local write_index = 0;

	local function WritePixel( pixel : Pixel )
		local offset = 4 * write_index
		write_index += 1
		buffer.writeu8(pixels, offset, pixel[1])
		buffer.writeu8(pixels, offset + 1, pixel[2])
		buffer.writeu8(pixels, offset + 2, pixel[3])
		buffer.writeu8(pixels, offset + 3, pixel[4])
	end
	
	local buffer = {
		readu8 = function(b : buffer) read_index += 1 return buffer.readu8(b,read_index-1) end,
		len = function(b : buffer) return buffer.len(b) end
	}

	assert( header.Magic == 'qoif' , 'QOI_DECODING: Invalid file signature.' )
	assert( buffer.len(file) > HEADER_SIZE + #END_MARKER , 'QOI_DECODING: Invalid QOI File.' )

	while read_index < buffer.len(file) - #END_MARKER do
		if run > 0 then
			run -= 1
		else
			local byte1 = buffer.readu8(file)
			
			if byte1 == QOI_OP.RGB then
				pixel[1] = buffer.readu8(file)
				pixel[2] = buffer.readu8(file)
				pixel[3] = buffer.readu8(file)
				
			elseif byte1 == QOI_OP.RGBA then
				pixel[1] = buffer.readu8(file)
				pixel[2] = buffer.readu8(file)
				pixel[3] = buffer.readu8(file)
				pixel[4] = buffer.readu8(file)

			elseif bit32.band(byte1, QOI_OP.MASK) == QOI_OP.INDEX then
				pixel = seen_pixels[byte1]

			elseif bit32.band(byte1, QOI_OP.MASK) == QOI_OP.DIFF then
				pixel[1] += bit32.rshift(bit32.band(byte1, 0x30), 4) - 2;
				pixel[2] += bit32.rshift(bit32.band(byte1, 0x0c), 2) - 2;
				pixel[3] += 			 bit32.band(byte1, 0x03)	 - 2;

			elseif bit32.band(byte1, QOI_OP.MASK) == QOI_OP.LUMA then
				local dg = bit32.band(byte1, 0x3f) - 32
				local byte2 = buffer.readu8(file)
				pixel[2] += dg
				pixel[1] += dg + bit32.rshift(bit32.band(byte2, 0xf0), 4) - 8
				pixel[3] += dg +			  bit32.band(byte2, 0x0f)	  - 8

			elseif bit32.band(byte1, QOI_OP.MASK) == QOI_OP.RUN then
				run = bit32.band(byte1, 0x3f);
			end
			
			seen_pixels[HashPixel(pixel)] = table.clone(pixel);
		end
		WritePixel(pixel)
	end
	
	-- /* On second thought, this assert is unreachable, but I'll keep it anyways :) */
	assert( buffer.len(pixels) <= pixels_size , 'QOI_DECODING: File exceeded expected size.' )

	return {
		Magic = header.Magic ,
		Width = header.Width ,
		Height = header.Height ,
		Channels = header.Channels ,
		colorspace = header.Colorspace ,
		Data = pixels
	}
end



function QOI.read(
	dfile : QOIHeader & Data ,
	image : EditableImage
)
	local read_index = 0;
	local pixelBuffer = dfile.Data;

	image:Resize(Vector2.new(dfile.Width, dfile.Height))
	
	for y = 0 , dfile.Height - 1 do
		for x = 0 , dfile.Width - 1 do
			local offset = read_index * 4
			local pixel = {
				buffer.readu8(pixelBuffer, offset)/255,
				buffer.readu8(pixelBuffer, offset + 1)/255,
				buffer.readu8(pixelBuffer, offset + 2)/255,
				buffer.readu8(pixelBuffer, offset + 3)/255
			}
			
			image:WritePixels( Vector2.new(x, y), PX_SIZE, pixel )
			read_index += 1
		end
	end
end

return QOI

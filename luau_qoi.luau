
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
local buffer_writestring = buffer.writestring
local buffer_readstring = buffer.readstring
local buffer_create = buffer.create
local buffer_copy = buffer.copy
local buffer_len = buffer.len
local bit32_band = bit32.band
local bit32_rshift = bit32.rshift
local bit32_lshift = bit32.lshift
local tcreate = table.create

export type Pixel = { number }
export type QOIHeader = {
	Signature: "qoif",
	Width: number,
	Height: number,
	Channels: number,
	Colorspace: number,
}
export type ImageData = {
	Width: number,
	Height: number,
	Channels: number?,
	Colorspace: number?,
	Data: buffer,
}

local QOI_OP_RUN = 0b11000000
local QOI_OP_INDEX = 0b00000000
local QOI_OP_DIFF = 0b01000000
local QOI_OP_LUMA = 0b10000000
local QOI_OP_RGB = 0b11111110
local QOI_OP_RGBA = 0b11111111

local QOI_MASK_2 = 0b11000000 -- QOI_MASK192
local QOI_MASK_6 = 0b00111111 -- QOI_MASK63

local MAX_DIM_SIZE = 4096
local HEADER_SIZE = 14
local END_MARKER_BYTES = 8
local END_MARKER_DATA = { 0, 0, 0, 0, 0, 0, 0, 1 }

function QOI_GET_HEADER(file: buffer): QOIHeader
	assert(buffer_readstring(file, 0, 4) == "qoif", "QOI_HEADER: Invalid file signature.")

	return {
		Signature = "qoif",
		Width = buffer_readu32(file, 4),
		Height = buffer_readu32(file, 8),
		Channels = buffer_readu8(file, 12),
		Colorspace = buffer_readu8(file, 13),
	}
end

function QOI_ENCODE(image: ImageData): buffer
	local height = image.Height
	local width = image.Width
	local pixels = image.Data
	local img_data_size = height * width * 4
	local img_end_offset = img_data_size - 4

	assert(height > 1 and height < MAX_DIM_SIZE, "QOI_ENCODING: Invalid height.")
	assert(width > 1 and width < MAX_DIM_SIZE, "QOI_ENCODING: Invalid width.")

	local max_qoi_size = img_data_size + HEADER_SIZE + END_MARKER_BYTES
	local bytes = buffer_create(max_qoi_size)
	local p = 0

	local seen_pixels = tcreate(64)
	local run = 0

	local prev_pixel_u32 = 0xff000000

	for px_pos = 0, img_end_offset, 4 do
		local curr_pixel_u32 = buffer_readu32(pixels, px_pos)

		if curr_pixel_u32 == prev_pixel_u32 then
			run += 1
			if run == 62 or px_pos == img_end_offset then
				buffer_writeu8(bytes, p, QOI_OP_RUN + (run - 1))
				p += 1
				run = 0
			end
		else
			if run > 0 then
				buffer_writeu8(bytes, p, QOI_OP_RUN + (run - 1))
				p += 1
				run = 0
			end

			local r = bit32_band(curr_pixel_u32, 0xff)
			local g = bit32_band(bit32_rshift(curr_pixel_u32, 8), 0xff)
			local b = bit32_band(bit32_rshift(curr_pixel_u32, 16), 0xff)
			local a = bit32_rshift(curr_pixel_u32, 24)

			local hash = (r * 3 + g * 5 + b * 7 + a * 11) % 64
			local seen_packed = seen_pixels[hash + 1]

			if seen_packed and curr_pixel_u32 == seen_packed then
				buffer_writeu8(bytes, p, QOI_OP_INDEX + hash)
				p += 1
			else
				seen_pixels[hash + 1] = curr_pixel_u32

				local pr = bit32_band(prev_pixel_u32, 0xff)
				local pg = bit32_band(bit32_rshift(prev_pixel_u32, 8), 0xff)
				local pb = bit32_band(bit32_rshift(prev_pixel_u32, 16), 0xff)
				local pa = bit32_rshift(prev_pixel_u32, 24)

				if a - pa == 0 then
					local dr = r - pr
					local dg = g - pg
					local db = b - pb

					if (dr >= -2 and dr <= 1) and (dg >= -2 and dg <= 1) and (db >= -2 and db <= 1) then
						buffer_writeu8(bytes, p, QOI_OP_DIFF + bit32_lshift(dr + 2, 4) + bit32_lshift(dg + 2, 2) + (db + 2))
						p += 1
					else
						local dr_dg = dr - dg
						local db_dg = db - dg
						if (dg >= -32 and dg <= 31) and (dr_dg >= -8 and dr_dg <= 7) and (db_dg >= -8 and db_dg <= 7) then
							buffer_writeu8(bytes, p, QOI_OP_LUMA + (dg + 32))
							p += 1
							buffer_writeu8(bytes, p, bit32_lshift(dr_dg + 8, 4) + (db_dg + 8))
							p += 1
						else
							buffer_writeu8(bytes, p, QOI_OP_RGB)
							p += 1
							buffer_writeu8(bytes, p, r)
							p += 1
							buffer_writeu8(bytes, p, g)
							p += 1
							buffer_writeu8(bytes, p, b)
							p += 1
						end
					end
				else
					buffer_writeu8(bytes, p, QOI_OP_RGBA)
					p += 1
					buffer_writeu8(bytes, p, r)
					p += 1
					buffer_writeu8(bytes, p, g)
					p += 1
					buffer_writeu8(bytes, p, b)
					p += 1
					buffer_writeu8(bytes, p, a)
					p += 1
				end
			end
		end
		prev_pixel_u32 = curr_pixel_u32
	end

	for i = 1, END_MARKER_BYTES do
		buffer_writeu8(bytes, p, END_MARKER_DATA[i])
		p += 1
	end

	local file_size = HEADER_SIZE + p
	local file = buffer_create(file_size)

	buffer_writestring(file, 0, "qoif")
	buffer_writeu32(file, 4, width)
	buffer_writeu32(file, 8, height)
	buffer_writeu8(file, 12, image.Channels or 4)
	buffer_writeu8(file, 13, image.Colorspace or 0)

	buffer_copy(file, HEADER_SIZE, bytes, 0, p)

	return file
end

function QOI_DECODE(file: buffer): ImageData
	local header = QOI_GET_HEADER(file)
	local width = header.Width
	local height = header.Height

	local pixels_size = width * height * 4
	local pixels = buffer_create(pixels_size)
	local file_size = buffer_len(file)

	assert(file_size > HEADER_SIZE + END_MARKER_BYTES, "QOI_DECODING: Bad QOI file (too small).")

	local seen_pixels = tcreate(64)
	local run = 0
	local read_idx = HEADER_SIZE
	local write_idx = 0

	local r, g, b, a = 0, 0, 0, 255

	while write_idx < pixels_size do
		if run > 0 then
			run -= 1
		else
			local byte1 = buffer_readu8(file, read_idx)
			read_idx += 1

			local op = bit32_band(byte1, QOI_MASK_2)

			if byte1 == QOI_OP_RGB then
				r = buffer_readu8(file, read_idx)
				g = buffer_readu8(file, read_idx + 1)
				b = buffer_readu8(file, read_idx + 2)
				read_idx += 3
			elseif byte1 == QOI_OP_RGBA then
				r = buffer_readu8(file, read_idx)
				g = buffer_readu8(file, read_idx + 1)
				b = buffer_readu8(file, read_idx + 2)
				a = buffer_readu8(file, read_idx + 3)
				read_idx += 4
			elseif op == QOI_OP_INDEX then
				local packed_pixel = seen_pixels[byte1 + 1]
				r = bit32_band(packed_pixel, 0xff)
				g = bit32_band(bit32_rshift(packed_pixel, 8), 0xff)
				b = bit32_band(bit32_rshift(packed_pixel, 16), 0xff)
				a = bit32_rshift(packed_pixel, 24)
			elseif op == QOI_OP_DIFF then
				r = bit32_band(r + bit32_rshift(bit32_band(byte1, 0x30), 4) - 2, 0xff)
				g = bit32_band(g + bit32_rshift(bit32_band(byte1, 0x0C), 2) - 2, 0xff)
				b = bit32_band(b + bit32_band(byte1, 0x03) - 2, 0xff)
			elseif op == QOI_OP_LUMA then
				local dg = bit32_band(byte1, QOI_MASK_6) - 32
				local byte2 = buffer_readu8(file, read_idx)
				read_idx += 1
				local dr_dg = bit32_rshift(byte2, 4) - 8
				local db_dg = bit32_band(byte2, 0x0f) - 8
				r = bit32_band(r + dg + dr_dg, 0xff)
				g = bit32_band(g + dg, 0xff)
				b = bit32_band(b + dg + db_dg, 0xff)
			elseif op == QOI_OP_RUN then
				run = bit32_band(byte1, QOI_MASK_6)
			end

			seen_pixels[(r * 3 + g * 5 + b * 7 + a * 11) % 64 + 1] = bit32_lshift(a, 24) + bit32_lshift(b, 16) + bit32_lshift(g, 8) + r
		end

		buffer_writeu32(pixels, write_idx, bit32_lshift(a, 24) + bit32_lshift(b, 16) + bit32_lshift(g, 8) + r)
		write_idx += 4
	end

	return {
		Width = width,
		Height = height,
		Channels = header.Channels,
		Colorspace = header.Colorspace,
		Data = pixels,
	}
end

function READ_TO_IMAGE(imageData: ImageData): EditableImage
	assert(game and Vector2, "Cannot read into an editable image; you are in a non-Roblox environment.")
	assert(imageData.Channels == 4, "Cannot read into an editable image; channel amounts other than 4 are unsupported.")

	local AssetService = (game::DataModel):GetService("AssetService")
	local image_size = Vector2.new(imageData.Width, imageData.Height)
	local image = AssetService:CreateEditableImage({ Size = image_size })
	image:WritePixelsBuffer(Vector2.zero, image_size, imageData.Data)
	return image
end

local VERSION = table.freeze({ major = 2, minor = 2, isRelease = true })

return table.freeze({
	version = VERSION,
	getHeader = QOI_GET_HEADER,
	encode = QOI_ENCODE,
	decode = QOI_DECODE,
	read = READ_TO_IMAGE,
})

# QOI in Luau
A [QOI](https://github.com/phoboslab/qoi) image de-/encoder in Luau, for Roblox.

**NOTE:** This program utilizes Roblox's beta feature `EditableImage`, meaning that this cannot be used by published games for the meantime.

## Why?
- This de-/encoder is _stupidly simple_ yet elegant, as it **can compress images down from 50-20%** of it's original size and **decompress losslessly**.
- Encodes and decodes in less that a second (for images less than 1024 by 1024).
- Useful for saving the data of large `EditableImages` in DataStores.

_I can't actually make comparisions of anykind to stb_image nor PNG, as there are no possible ways of benchmarking against the other algorithms within Roblox._

More info at https://qoiformat.org.

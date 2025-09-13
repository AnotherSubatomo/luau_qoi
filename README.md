# QOI in Luau
A [QOI](https://github.com/phoboslab/qoi) image de-/encoder for fast and lossless compression in Luau, for Roblox.

## Why?
- This de-/encoder is **stupidly simple, yet elegant**; despite **being less than 300 *lines of code***, it **can compress images down to 50~20%** of it's original size and **decompress losslessly**.
- Encodes and decodes **in less that a second**.
- Useful for saving the data of large `EditableImages` in DataStores.

_I can't actually make comparisions of anykind to stb_image nor PNG, as there are no possible ways of benchmarking against the other algorithms within Roblox._

More info about the format at https://qoiformat.org.

More info about this implementation at https://devforum.roblox.com/t/2921027.

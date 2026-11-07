# image-tools.nvim

Image and PDF previews using the Kitty graphics protocol.

## Features

- Preview images and paged PDFs in buffers, floats and embedded views.
- Insert clipboard images and localize supported remote images.
- Render optional Markdown, LaTeX and Typst formulas.

## Requirements

Neovim **0.12+**. Requires `termguicolors` and a direct Kitty 0.28+ session. Raster conversion needs ImageMagick; PDF needs Ghostscript and pdfinfo. Other terminals and multiplexers are unsupported.

## Installation

With lazy.nvim:

```lua
{
  "Jacky-Lzx/image-tools.nvim",
  main = "image_tools",
  opts = {},
}
```

Or put this repository and its required dependencies on `runtimepath`, then call:

```lua
require("image_tools").setup({})
```

## Usage

```vim
:ImagePreview
:ImageInfo
```

## Documentation

- [Complete reference](doc/image-tools.txt) — `:help image-tools`.
- [Workflow and integration guide](doc/guide.md).
- Diagnose availability with `:checkhealth image_tools`.
- [Performance measurements](doc/performance.md).
- [Architecture](doc/architecture.md).

## Development

Run from the repository root:

```sh
python3 tests/run.py unit --filter docs
python3 tests/run.py default
```

See [the test workflow](tests/README.md) for dependencies, optional suites and
retained failure evidence. Local development overrides belong in your package
manager configuration; public installation uses the repository above.

[License](LICENSE).

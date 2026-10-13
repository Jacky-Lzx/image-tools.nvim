# image-tools.nvim

Independent image previews for Neovim. Uses the Kitty graphics protocol directly;
no Snacks or image.nvim dependency. Preview windows use Unicode placeholders so
Neovim controls clipping and overlapping windows.

## Requirements

- Neovim 0.11+ with `termguicolors` enabled.
- Kitty 0.28+ in a direct terminal session. Other terminals, multiplexers, SSH and
  GUI frontends have not been validated. Multiplexers are currently rejected.
- ImageMagick (`magick`) for JPG, WebP, AVIF, HEIC, GIF, BMP and TIFF. GIF previews
  show the first frame. PNG preview does not require an external converter.

## Local installation

```lua
{
  dir = vim.fn.expand("~/Documents/Github/nvim_plugins/image-tools.nvim"),
  name = "image-tools.nvim",
  event = "VeryLazy",
  opts = { auto_preview = true, max_width = 60, max_height = 30 },
  config = function(_, opts) require("image_tools").setup(opts) end,
}
```

Set `image = { enabled = false }` in Snacks opts and remove any direct
`Snacks.image` mappings. Restart Neovim to remove its existing handlers.

## Usage

- `:ImagePreview /absolute/or/relative/image.png` opens a file. Spaces are accepted
  literally; do not surround the path with shell quotes.
- `:ImagePreview` previews the Markdown image under the cursor.
- `:ImagePreviewClose` closes the preview and frees its terminal image.
- `:ImagePreviewToggle` toggles automatic previews on `CursorHold`.
- `:checkhealth image_tools` checks the terminal and conversion tools.

Public API: `setup(opts)`, `preview(path, opts)`, `hover(opts)`, `close()`,
`toggle()`, `status()`. `require("image_tools")` alone registers no handlers.
Paths supplied to `preview` are relative to cwd. Markdown references are relative
to the document; changing cwd does not change their meaning. An optional
`root` replaces the document directory, or `resolve(document, source)` can
return a custom absolute path. Neither path searching nor network access occurs.

The preview closes on cursor movement, entering Insert mode, document changes,
window/buffer switching, resizing, scrolling, colorscheme changes, suspend and
exit. Pending requests are invalidated and conversion processes are cancelled.
Only image ids allocated by this plugin are deleted.

## Configuration

```lua
require("image_tools").setup({
  auto_preview = true,
  max_width = 60, -- terminal cells, capped at 64
  max_height = 30, -- terminal cells, capped at 64
  border = "rounded",
  cell_size = { width = 10, height = 20 }, -- fallback when ioctl has no pixel size
  magick = "magick",
  convert_timeout = 10000,
  max_bytes = 32 * 1024 * 1024,
  max_dimension = 16384,
  max_pixels = 64 * 1024 * 1024,
  max_scan_lines = 10000,
  -- cache = vim.fn.stdpath("cache") .. "/image-tools",
  -- root = "/absolute/project/root",
  -- resolve = function(document, source) return nil end,
  force = false, -- bypass terminal-name detection for experimentation only
})
```

Conversion is asynchronous, bounded by a timeout, and cached by path, size and
nanosecond mtime. Preview PNGs are capped at 1920x1080; originals are never
modified. Cache cleanup is manual in this first version.

## Current scope

Markdown supports complete same-line `![alt](path)`, balanced parentheses,
angle-bracket destinations, optional quoted titles, backslash escapes and
percent-encoded paths. Fenced code, indented code and inline code are excluded.
Reference-style images, Obsidian wikilinks, multiline syntax, remote URLs,
LaTeX/Typst, PDF/SVG, inline rendering and picker previews are future work.
The first version retains image-insert.nvim for insertion.

## Development

Run `sh tests/run.sh`. Tests cover real Neovim floating windows with a captured
terminal transport, protocol payloads, path parsing and asynchronous cancellation.
When Python 3 is available, the runner also launches a real Neovim TUI in a PTY
and checks the emitted PNG bytes, true-color ids, placeholders and cleanup.
Actual terminal rendering must additionally be checked in Kitty.

Protocol reference: https://sw.kovidgoyal.net/kitty/graphics-protocol/

# image-tools.nvim

Independent image previews for Neovim. Uses the Kitty graphics protocol directly;
no Snacks or image.nvim dependency. Preview windows use Unicode placeholders so
Neovim controls clipping and overlapping windows.

## Requirements

- Neovim 0.12+ with `termguicolors` enabled (APC graphics response handling).
- Kitty 0.28+ in a direct terminal session. Other terminals, multiplexers, SSH and
  GUI frontends have not been validated. Multiplexers are currently rejected.
- ImageMagick (`magick`) for JPG, WebP, AVIF, HEIC, GIF, BMP, TIFF, PDF and SVG. PDF preview shows the first page; ImageMagick
  needs its Ghostscript delegate for PDF. GIF previews
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
- `:ImagePreview` previews the first Markdown image on the current line.
- `:ImagePreviewClose` closes the preview and keeps uploaded pixels cached for reuse.
- `:ImagePreviewClearCache` closes the preview and frees all this plugin's terminal images.
- `:ImagePreviewToggle` toggles automatic current-line previews.
- `:checkhealth image_tools` checks the terminal and conversion tools.

Public API: `setup(opts)`, `preview(path, opts)`, `hover(opts)`, `close()`,
`clear_cache()`, `toggle()`, `status()`. `require("image_tools")` alone registers no handlers.
Paths supplied to `preview` are relative to cwd. Markdown references are relative
to the document; changing cwd does not change their meaning. An optional
`root` replaces the document directory, or `resolve(document, source)` can
return a custom absolute path. Neither path searching nor network access occurs.

Automatic preview starts when the cursor enters an image line, including when
it is outside the image link. Moving horizontally on that line, entering Insert
mode or editing surrounding text keeps the same preview and pending conversion.
If a line has multiple images, its first image is used consistently.

Moving to another line closes the previous preview immediately and previews
the new line if it contains an image. Replacing or removing the image reference
updates or closes the preview. Window/buffer switching, resizing, scrolling,
colorscheme changes, suspend and exit clean the previous preview; automatic
preview refreshes the current line after layout changes. Stale asynchronous
requests cannot restore a preview after the cursor leaves its line. Only image
ids allocated by this plugin are deleted. Closing hides its placement; recently
uploaded pixels remain cached for reuse. Exiting, suspending and repeated setup
release all retained terminal images and cancel pending requests.

## Configuration

```lua
require("image_tools").setup({
  auto_preview = true,
  position = "cursor", -- "cursor" or "bottom_right"
  transport = "auto", -- "auto", "file" or "direct"
  terminal_timeout = 1500, -- milliseconds to wait for a graphics acknowledgement
  terminal_cache = { max_images = 32, max_bytes = 64 * 1024 * 1024 },
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

Set `position = "bottom_right"` to anchor the preview to the editor's bottom-right
corner, above the command line and status line. The position is independent of
the cursor and split layout. The default `"cursor"` places it near the cursor.

Conversion is asynchronous, bounded by a timeout, and cached by path, inode, size
and nanosecond mtime/ctime. Preview PNGs are capped at 1920x1080; originals are never
modified. Conversion disk-cache cleanup is manual in this first version.

## Transmission and terminal cache

`transport = "auto"` tries Kitty file transmission (`t=f`) in local sessions.
Only the absolute PNG filename is Base64-encoded and sent to the terminal; Lua
reads 33 header bytes and the 12-byte end chunk for dimensions and basic checks.
Kitty's upload acknowledgement confirms decoding. File errors/timeouts fall back
to direct transmission (`t=d`), which sends the PNG bytes in Base64 chunks.
When SSH environment variables are present, auto uses direct transmission;
actual SSH sessions and multiplexers have not been validated.

`"file"` forces file transmission and reports failures. `"direct"` forces the
original inline-data method. Shared-memory (`t=s`) transmission is not implemented.

Uploads are cached by PNG path, inode, size, and nanosecond mtime/ctime. Reopening
an unchanged image sends only a placement request; its acknowledgement verifies
that Kitty still has the data. An `ENOENT` response or placement timeout causes a
fresh upload. File changes evict the previous version. The least recently used
inactive entries are evicted when `terminal_cache` limits are reached.
The byte budget estimates decoded RGBA size, rather than measuring Kitty's actual
GPU memory. Oversized images can be displayed but are released on close. Set
`max_images = 0` to disable retention. `:ImagePreviewClearCache` releases the cache;
`status().terminal_cache` reports image count, bytes, hits, upload attempts and the
last successful transport/error. Caches store metadata, not full PNGs in Lua.

Every upload/placement has a bounded response wait. Cancellation removes response
handlers and timers and deletes incomplete images. Failed file uploads and lost
cached images use fresh ids, preventing late replies from matching the retry.

## Current scope

Markdown supports complete same-line `![alt](path)`, balanced parentheses,
angle-bracket destinations, optional quoted titles, backslash escapes and
percent-encoded paths. Fenced code, indented code and inline code are excluded.
Reference-style images, Obsidian wikilinks, multiline syntax, remote URLs,
Typst and inline rendering are future work.
File insertion is independent of image-insert.nvim. `:ImageInsert [path]` copies an
image into `Figures/` beside the saved document, then inserts a relative Markdown
link. With no path it prompts for a file. `:ImageInsert! [path]` references the
source without copying. `insert(path_or_paths, opts, callback)` also accepts a batch.

`insert = { directory = "Figures", mode = "copy", insert_strategy = "insert_line_after",
prompt_for_file_name = false }` configures insertion. `directory` and `root` may
be functions of the source document path. The default root is the document's
directory; set insertion `root` for a project asset directory. Links remain relative
to the document (or preview `root`). Per-call `filename` overrides the basename,
`alt` sets Markdown alt text, and `mode = "reference"` avoids importing. Strategies
are `insert_before`, `insert_after`, `insert_line_before`, `insert_line_after`.

The returned function cancels pending insertion. Prompts retain the original buffer
and an extmark position across edits and window switches. Batches insert in order
as one text edit; filename collisions use numeric suffixes and never overwrite.
Cancellation or insertion failure rolls back newly imported files. Text undo retains
assets for reuse. Closing/renaming the source buffer or changing its filetype/read-only
state causes rollback. Imports preserve original formats and bytes; conversion is
currently for preview only.

## Development

Run `sh tests/run.sh`. Tests cover real Neovim floating windows with a captured
terminal transport, protocol payloads, path parsing and asynchronous cancellation.
When Python 3 is available, the runner also launches a real Neovim TUI in a PTY
and uses a protocol responder to check file/direct transmission, fallback,
terminal eviction, replies, cache reuse, true-color ids, placeholders and cleanup.
Actual terminal rendering must additionally be checked in Kitty.

Protocol reference: https://sw.kovidgoyal.net/kitty/graphics-protocol/

## macOS clipboard

Install `pngpaste` (`brew install pngpaste`). `:ImagePaste` or `paste(opts, callback)`
reads the system clipboard without modifying it, imports an image, and inserts a
reference at the original source position. Clipboard paste always copies its
resource, including when file insertion uses reference mode. Default PNG preserves
pngpaste's output. Per-call `format = "jpg"`, `"webp"` or `"avif"` converts with
ImageMagick (`quality = 75` by default); `prompt_for_file_name = true` requests a name.
Clipboard commands have a 5-second timeout; conversions use `convert_timeout`.
Empty clipboard, unsupported platform, missing tools and failed conversion report
errors without inserting text or leaving image resources. The cancel function also
stops pending reads/processes and removes temporary files.

## Snacks picker integration

Snacks is an optional dependency for `:ImagePick` / `pick(opts, callback)`. Images
preview in the existing picker window using this plugin's Kitty transport/cache.
Confirm imports the selected images in order into the original document; closing
without confirming cancels. Selection changes cancel pending conversions and
placements; closing releases the picker cache and handlers. Use `pick({ insert =
{ mode = "reference" }, picker = { cwd = "/images" } })` to configure import/picker.

For ordinary Snacks file pickers and the explorer, set `picker.preview =
function(ctx) require("image_tools").snacks_preview(ctx) end` in Snacks opts.
Non-image items retain Snacks' file preview; custom source-specific previewers
remain source-specific. Keep Snacks.image disabled. The independent previewer
never calls Snacks.image for supported images. No monkey patches are installed.

Set `IMAGE_TOOLS_SNACKS_ROOT` to an installed Snacks checkout when running tests
for actual picker window, finder, confirmation, cancellation and TUI integration.

## LaTeX

Automatic preview and insertion support `tex`, `latex` and `plaintex`. Standard
same-line `\includegraphics[options]{path}` (including starred form and
`\detokenize{path}`) is parsed. Comments, `\verb` and verbatim/lstlisting/minted/
comment environments are excluded; macros and multiline references are not expanded.
Literal `\graphicspath{{dir/}{other/}}` in preceding lines and omitted extensions
(PDF/PNG/JPG/JPEG) are resolved. Resolution uses `root` (string/function), then an
existing `b:vimtex.root`, then the document directory. No VimTeX dependency is added.

Insertion emits `\includegraphics[width=\linewidth]{\detokenize{path}}`; load
`graphicx` in your document. PNG/JPEG/PDF imports preserve original formats.
Other formats must be converted before LaTeX insertion. Imported filenames replace
TeX-special characters with underscores; unsafe directory/reference paths fail with
an actionable error and rollback. Spaces and underscores remain supported.
Batch insertion has its own undo block, preserving edits made before confirmation.

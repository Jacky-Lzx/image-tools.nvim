# image-tools.nvim

Independent image previews and insertion for Neovim.
Uses the Kitty graphics protocol directly.
Preview windows use Unicode placeholders so Neovim controls clipping and overlapping windows.

## Requirements

- Neovim 0.12+ with `termguicolors` enabled (APC graphics response handling).
- Kitty 0.28+ in a direct terminal session.
  Other terminals, multiplexers, SSH and GUI frontends have not been validated.
  `TMUX`/`ZELLIJ` sessions are rejected even with `force = true`; that option only
  bypasses terminal-name detection.
- ImageMagick (`magick`) for JPG, WebP, AVIF, HEIC, GIF, BMP, TIFF and PDF.
  - Floating and picker PDF previews show the first page; file buffers support paging.
    ImageMagick needs its Ghostscript delegate for PDF.
  - SVG uses `rsvg-convert` when available; otherwise it requires ImageMagick MSVG.
  - GIF previews show the first frame.
  - PNG preview does not require an external converter.

## Local installation

```lua
{
  dir = vim.fn.expand("~/Documents/Github/nvim_plugins/image-tools.nvim"),
  name = "image-tools.nvim",
  lazy = false, -- install file buffer handlers before startup files are read
  opts = { auto_preview = true, max_width = 60, max_height = 30 },
  config = function(_, opts) require("image_tools").setup(opts) end,
}
```

Set `image = { enabled = false }` in Snacks opts and remove any direct `Snacks.image` mappings.

## Usage

- `:ImagePreview /absolute/or/relative/image.png` opens a file.
  Spaces are accepted literally; do not surround the path with shell quotes.
- `:ImagePreview` previews the Markdown/LaTeX/Typst image reference under the cursor,
  falling back to the first image on the current line when outside all references.
- `:ImagePreviewClose` closes the preview and keeps uploaded pixels cached for reuse.
- `:ImagePreviewClearCache` closes the preview and frees all this plugin's terminal images.
- `:ImageCacheClear` deletes unused converted images from disk, preserving files in use.
- `:ImagePreviewToggle` toggles automatic current-line previews.
- `:checkhealth image_tools` checks the terminal and conversion tools.

Health tool detection uses the standard executable names (`magick`, `pdfinfo`,
`rsvg-convert`, `gs`, `pngpaste`); configured executable overrides apply to the
corresponding operations.

Public API: `setup(opts)`, `preview(path, opts)`, `hover(opts)`, `close()`,
`clear_cache()`, `clear_disk_cache(callback)`, `toggle()`, `status()`, `insert(paths, opts, callback)`,
`paste(opts, callback)`, `pick(opts, callback)`, `snacks_preview(ctx)`,
`open(path)`, `page(n)`, `next_page(delta)`, `reload()`.

`require("image_tools")` alone registers no handlers.
Paths supplied to `preview` are relative to cwd.
Markdown references are relative to the document; changing cwd does not change their meaning.
An optional `root` replaces the document directory, or `resolve(document, source)` can return a custom absolute path.
LaTeX additionally searches literal `graphicspath` directories and tries omitted
extensions. Remote image references are rejected; the plugin does not fetch them.

Automatic preview starts when the cursor enters an image line, including when
it is outside the image link. On a line with multiple images, the reference under
the cursor takes priority; moving onto another image switches the preview. Outside
all references, the first image is used. Moving within the selected reference,
entering Insert mode or editing surrounding text keeps its preview and pending
conversion while the selected source stays unchanged.

Leaving the selected reference's row range closes the previous preview and
previews the new row if it contains an image. Markdown and Typst references cover
one row; LaTeX references can cover several. Replacing or removing the reference
updates or closes the preview. Window/buffer switching, resizing, scrolling,
colorscheme changes, suspend and exit clean the previous preview; automatic
preview refreshes the current line after layout changes. Stale asynchronous
requests cannot restore a preview after the cursor leaves its reference range.
Only image ids allocated by this plugin are deleted. Closing hides its placement; recently
uploaded pixels remain cached for reuse. Exiting, suspending and repeated setup
release all retained terminal images and cancel pending requests.

## Configuration

```lua
require("image_tools").setup({
  auto_preview = true,
  treesitter = true, -- LaTeX/Typst syntax trees, with automatic lexer fallback
  latex = { max_reference_lines = 64, max_reference_bytes = 16 * 1024 },
  buffer = { enabled = true }, -- automatic binary image/PDF file buffers
  pdfinfo = "pdfinfo", -- Poppler, for PDF metadata
  pdf_density = 144,
  position = "cursor", -- "cursor" or "bottom_right"
  transport = "auto", -- "auto", "file" or "direct"
  terminal_timeout = 1500, -- milliseconds to wait for a graphics acknowledgement
  terminal_cache = { max_images = 32, max_bytes = 64 * 1024 * 1024 },
  disk_cache = { enabled = true, max_files = 256, max_bytes = 512 * 1024 * 1024 },
  max_width = 60, -- terminal cells, capped at 297
  max_height = 30, -- terminal cells, capped at 297
  border = "rounded",
  cell_size = { width = 10, height = 20 }, -- fallback when ioctl has no pixel size
  magick = "magick",
  rsvg = "rsvg-convert",
  convert_timeout = 10000,
  convert_concurrency = 2, -- simultaneous converter processes
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

Set `position = "bottom_right"` to anchor the preview to the editor's bottom-right corner, above the command line and
status line.
The position is independent of the cursor and split layout.
The default `"cursor"` places it near the cursor.

`buffer.formats` defaults to `png`, `jpg`, `jpeg`, `webp`, `avif`, `heic`, `gif`,
`bmp`, `tif`, `tiff` and `pdf`. SVG is available through explicit opening, but is
excluded from automatic file interception by default.

Conversion is asynchronous, bounded by a timeout, and cached by path, inode, size and nanosecond mtime/ctime.
Converted previews fit within 1920x1080; native PNGs retain their dimensions and
are checked against `max_dimension`/`max_pixels`. Floating previews do not upscale;
picker and file-buffer images can upscale to fit their viewport. Originals are never modified.
Converted disk images are managed asynchronously by `disk_cache` limits.
Unused images are removed in access order; currently used images are protected
and may temporarily exceed the limits. Set `disk_cache.enabled = false` to
disable automatic eviction. `:ImageCacheClear` clears unused conversions manually.
Cleanup selects hash-named PNGs directly inside the configured cache directory.
Subdirectories, other filenames, symbolic links and conversion temporaries
are excluded. After a restart, file modification times provide the
initial eviction order until images are accessed again.

## Transmission and terminal cache

`transport = "auto"` tries Kitty file transmission (`t=f`) in local sessions.
Only the absolute PNG filename is Base64-encoded and sent to the terminal; Lua
reads 33 header bytes and the 12-byte end chunk for dimensions and basic checks.
Kitty's upload acknowledgement confirms decoding. File errors/timeouts fall back
to direct transmission (`t=d`), which sends the PNG bytes in Base64 chunks.
When `SSH_CONNECTION` or `SSH_TTY` is nonempty, auto uses direct transmission;
actual SSH sessions and multiplexers have not been validated.

`"file"` forces file transmission and reports failures. `"direct"` forces the
original inline-data method. Shared-memory (`t=s`) transmission is not implemented.

Uploads are cached by PNG path, inode, size, and nanosecond mtime/ctime. Reopening
an unchanged image sends only a placement request; its acknowledgement verifies
that Kitty still has the data. An `ENOENT` response or placement timeout causes a
fresh upload when the requesting view is the sole owner. With other owners still
active, a failed placement reports an error instead of replacing their pixels;
reload the affected view to retry. File changes evict unused previous versions. The least recently used
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
Reference-style images, Obsidian wikilinks, multiline Markdown image calls, remote URLs
and inline rendering inside document text are future work.
File insertion is independent of image-insert.nvim. `:ImageInsert [path]` copies an
image into `Figures/` beside the saved document, then inserts a relative Markdown
link. With no path it prompts for a file. `:ImageInsert! [path]` references the
source without copying. `insert(path_or_paths, opts, callback)` also accepts a batch.

`insert = { directory = "Figures", mode = "copy", insert_strategy = "insert_line_after",
prompt_for_file_name = false }` configures insertion. `directory` and `root` may
be functions of the source document path. The default root is the document's
directory; set insertion `root` for a project asset directory. Markdown links use
the document directory or preview `root`; LaTeX links also honor `b:vimtex.root`
when no preview root is set. Typst links always use the document directory.
Per-call `filename` overrides the basename,
`alt` sets Markdown alt text, and `mode = "reference"` avoids importing. Strategies
are `insert_before`, `insert_after`, `insert_line_before`, `insert_line_after`.

The returned function cancels pending insertion. Prompts retain the original buffer
and an extmark position across edits and window switches. Batches insert in order
as one text edit; filename collisions use numeric suffixes and never overwrite.
Cancellation or insertion failure rolls back newly imported files. Text undo retains
assets for reuse. Unloading/deleting or renaming the source buffer, changing its
filetype, or disabling `modifiable` causes rollback. Setting `readonly` alone
does not prevent insertion. File imports preserve original formats and bytes;
clipboard paste can separately request format conversion.

## Development

Run `sh tests/run.sh`. Tests cover real Neovim floating windows with a captured
terminal transport, protocol payloads, path parsing and asynchronous cancellation.
When Python 3 is available, the runner also launches a real Neovim TUI in a PTY
and uses a protocol responder to check file/direct transmission, fallback,
terminal eviction, replies, cache reuse, true-color ids, placeholders and cleanup.
Actual terminal rendering must additionally be checked in Kitty.

TUI assertions accept semicolon/colon RGB encodings and check actual image and
placement colors. Underline-color support can come from terminfo or an answered
terminal capability query; a query is not required when terminfo provides it.

The runner uses a fresh Neovim process for each Lua test, without user config or
automatically loaded plugins. It isolates generated files, caches and logs in a
temporary directory and removes it on exit. The first failure stops the run;
`[run]` identifies the current file and `[skip]` explains omitted optional suites.
Status labels use cyan for `[run]`, yellow for `[skip]`, green for `[done]` and red
for `[fail]`. Colors are disabled when stdout is redirected, `TERM` is unset or
`dumb`, or `NO_COLOR` is set. A failing suite retains its original exit status.
Individual Lua scripts can also report skipped checks, so a successful exit does
not imply that every optional integration was exercised.

The commented groups in `tests/run.sh` cover:

1. Public API, preview windows, cursor/reference lifecycle and health diagnostics.
2. Image conversion, caches, queues, terminal transfer and rendering resources.
3. Insertion, simulated clipboard commands and optional Snacks picker integration.
4. Document format dispatch, scanner caches and Tree-sitter queries/fallback.
5. Optional real-parser asynchronous, incremental and multiline LaTeX checks.
6. LaTeX/Typst syntax and paths, optional real compilation, image buffers and bounds.
7. Real Neovim TUI with a simulated Kitty protocol responder.

Test files follow the implementation subsystems: `tests/core/` covers API/runtime
and lifecycle regressions, while `document/`, `media/`, `render/`, `terminal/` and
`workflow/` hold their respective suites. Shared assets and the interactive demo
live in `tests/fixtures/`. `tests/tui/run.py` launches the TUI scenarios in that
directory; run it directly with `python3 -u tests/tui/run.py` to isolate TUI checks.
The runner keeps an explicit suite list and execution order; it does not discover
manual tests or run TUI Lua scenarios as headless tests.

Neovim and ImageMagick (`magick`, with Ghostscript support for PDF conversion)
are required for the suite. Optional coverage is enabled as follows:

- `IMAGE_TOOLS_PARSER_ROOT`: runtime directory containing both `parser/latex.*`
  and `parser/typst.*`; enables real-parser suites and additional lifecycle cases.
- `IMAGE_TOOLS_SNACKS_ROOT`: Snacks checkout; enables picker integration checks.
- `pdflatex` / `typst`: enable real compilation in the corresponding document tests.
  `pdfimages`, when available, additionally checks embedded image dimensions.
- `python3`: enables the PTY/TUI protocol tests (uses Unix PTY APIs).

Document path assertions prove reference recognition and resolution; lifecycle
tests additionally assert preview windows and cleanup. The TUI responder verifies
protocol traffic, while visible pixels still require a real Kitty check.
`tests/manual/clipboard_native.lua` is a separate opt-in test requiring a prepared system
clipboard; the automatic runner only exercises simulated clipboard commands.

Protocol reference: https://sw.kovidgoyal.net/kitty/graphics-protocol/

Implementation modules are grouped under `document/`, `media/`, `render/`,
`terminal/` and `workflow/`. The public API, configuration, runtime coordinator,
commands and health entry remain at the package root. `require("image_tools.media")`
provides the media entry point from `media/init.lua`; the former
`image_tools.image` module path is removed. Internal imports use the grouped
paths; dependency injection keeps its logical
keys. See [module architecture](doc/architecture.md) for the file layout and
ownership boundaries.

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
Picker previews scale up or down to fit the pane, preserve the aspect ratio and
align the image to the top-left of the pane. They follow pane/terminal resizing and layout changes. The
floating-preview `max_width`/`max_height` limits do not cap the picker; the Kitty
coordinate table permits up to 297 cells per axis. Resizing reuses uploaded pixels.
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

LaTeX and Typst references use Neovim's Tree-sitter buffer parser by default
(`latex` and `typst` languages). Install the corresponding parser to enable this
path; no dependency on nvim-treesitter is required. If the parser, grammar query,
or parsing is unavailable (including syntax errors in preceding context),
recognition falls back to the existing cached Lua scanner. A valid syntax tree
with no supported reference does not trigger fallback.
Large parses yield to Neovim's event loop. Pending parses do not trigger a Lua
scan. Completion requires the same buffer, window, byte column and text version;
movement between rows of the same pending LaTeX reference is allowed.
Capture traversal advances through the requested row; LaTeX argument decoding
can look ahead to the reference's end, within its limits and `max_scan_lines`.
Edits invalidate the affected suffix and any earlier ranges reported by the
parser, preserving valid prefix results.
Set `treesitter = false` to always use the Lua scanner. Project roots, custom
resolvers and file checks remain live. Markdown uses its existing scanner.
`status().treesitter` reports parse/index timing, index hits, indexed rows and
fallback reasons (`parser_unavailable`, `query_error`, `parse_error`, `index_error`,
`error_context`). `:checkhealth image_tools` shows these diagnostics without
starting a parser. Parse timing includes time yielded to the event loop.

Automatic preview and insertion support `tex`, `latex` and `plaintex`. Standard
literal `\includegraphics[options]{path}` (including starred form and
`\detokenize{path}`) is parsed. Comments, `\verb` and verbatim/lstlisting/minted/
comment environments are excluded. The command, optional arguments and path
argument may be on different lines; filename contents must stay on one line.
Macros are not expanded. For example:

```latex
\includegraphics[
  % width=\linewidth,
  keepaspectratio
]{Figures/example.pdf}
```

Every row of a complete reference, including commented option rows, can trigger
preview. Moving inside that reference retains its window and pending conversion;
leaving its range closes it. Multiple references on a shared row select the one
under the cursor, falling back to the first in document order outside all references.
`at_cursor` respects the full byte-column range.
`latex.max_reference_lines` (64) and `latex.max_reference_bytes` (16 KiB) bound
recognition, including compatibility decoding for partial grammar nodes. Lookahead
also respects `max_scan_lines`. Lua fallback uses a bounded local search plus
cached prefix context. Editing any covered row invalidates the full reference.
Unclosed or oversized commands and filenames split over lines are not guessed.
Single-line literal `\graphicspath{{dir/}{other/}}` declarations in preceding
context and omitted extensions (PDF/PNG/JPG/JPEG) are resolved. Resolution uses
`root` (string/function), then an existing `b:vimtex.root`, then the document
directory. No VimTeX dependency is added.
Tree-sitter determines command locations and excluded contexts; literal argument
decoding remains shared with the Lua scanner for starred and `\detokenize` forms
that LaTeX grammars do not consistently represent. Formula preview is not included.

Insertion emits `\includegraphics[width=\linewidth]{\detokenize{path}}`; load
`graphicx` in your document. PNG/JPEG/PDF imports preserve original formats.
Other formats must be converted before LaTeX insertion. Imported filenames replace
TeX-special characters with underscores; unsafe directory/reference paths fail with
an actionable error and rollback. Spaces and underscores remain supported.
Batch insertion has its own undo block, preserving edits made before confirmation.

## Typst

Current-line previews and insertion support literal same-line `#image("path", ...)`
and `image("path", ...)` inside code, including a multiline `#figure` whose image
call is complete on one line. Code strings, inline/block raw text, line comments
and nested block comments are skipped. Variables, path expressions and multiline
image calls are not evaluated. String escapes and Unicode escapes are decoded;
percent signs retain their filesystem meaning.

Relative paths resolve beside the containing document. A leading slash resolves
under configured `root` (or the document directory), matching Typst project paths.
Set `root` to match `typst compile --root` for nested projects. Insertion always
uses document-relative paths, emits `#image(..., width: 100%)`, and supports an
optional `alt`. Imports accept PNG/JPEG/GIF/WebP/SVG/PDF. Direct references outside
the configured/default project root fail; copy the resource or configure the root.
PDF image insertion requires a Typst version supporting PDF images (tested 0.15.1).

SVG preview prefers `rsvg-convert` (option `rsvg` sets its executable); otherwise
it uses ImageMagick's internal MSVG renderer. Both routes are bounded by
`convert_timeout` and output dimensions. MSVG may differ for complex SVGs;
`rsvg-convert` is recommended. Preview never modifies original SVG/PDF files.

## Image and PDF file buffers

With `buffer.enabled = true` (default), opening a PNG/JPEG/WebP/AVIF/HEIC/GIF/BMP/
TIFF/PDF with `:edit`, a file picker, or as a startup file opens a read-only viewer.
Load the plugin with `lazy = false` to intercept startup files before binary data
is read. `:ImageOpen path` / `open(path)` also open an explicit preview, including
SVG. SVG remains editable through normal `:edit` unless added to `buffer.formats`.
Set `buffer.enabled = false` to retain normal file editing and use explicit opening.

The file keeps its named, listed buffer, with a filename/page header and a Kitty
canvas bound to each regular window showing it. The image fits that window while
preserving its aspect ratio and stays at the top-left beneath the header. Splits
have independent placements; resizing refits them, switching buffers/tabs hides
the old canvas, and closing releases its placement. PDF page selection is shared
by splits of the same buffer. Suspending/exiting frees the shared terminal data. Returning
to a hidden file buffer restores its preview. Original files are never replaced by
placeholder text: the view is nonmodifiable, readonly and `nofile`, so `:write!`
cannot overwrite them. Modified source buffers are not automatically taken over.

PDF buffers need ImageMagick with Ghostscript, plus Poppler's `pdfinfo`
(`brew install poppler`). `]p` / `[p` move forward/backward (counts supported).
`:ImagePage 3` selects a page; `:ImageNextPage` / `:ImagePreviousPage` move a page
(counts supported). Relative page movement clamps to the first/last page;
`page(n)` and `:ImagePage N` reject out-of-range values.
Page bounds come from actual PDF metadata. Conversion/transmission caches retain
pages separately, so revisiting an unchanged page can reuse its uploaded pixels.
`r` / `:ImageReload` reloads the current file and refreshes metadata. Source changes
are also checked on buffer/window/focus events. `status().buffer` reports the current
file, page count, error and per-window cache/placement. `page(n)`, `next_page(delta)`
and `reload()` provide the same operations programmatically. Existing terminal,
source-size, dimension, conversion-timeout and terminal-cache limits apply.

Unsupported terminals, invalid/oversized files, encrypted/unreadable PDFs and
missing conversion/metadata tools show a readable error in the file buffer.
No terminal responses, stale conversions or page changes can reopen a canvas after
its source window/buffer is closed. Use `:checkhealth image_tools` to check tools.

Converter processes for distinct image files, PDF pages and clipboard format conversion share a FIFO queue,
with `convert_concurrency = 2` by default. Same-source requests still share one
conversion. Closing a queued preview removes its job; cancelling a running job
keeps its slot until the process exits. Cache hits and PNG reads bypass the queue.
`status().conversion_queue` reports active and queued converters and the current process budget.
Reconfiguration updates that budget; running workers retain their slots until exit.

Terminal pixel data is shared by floating previews, picker previews and file
buffers within one plugin runtime. Each view has a separate Kitty virtual
placement id, encoded in the placeholder underline color, so differently sized
splits reuse one upload. Closing a view releases its placement; other active
placements keep the pixels pinned. Inactive pixels use the shared `terminal_cache`
LRU limits. Setup replacement, suspension and explicit cache clearing release
the runtime's shared data. Explicit clearing also pauses file-buffer canvases
until buffer/tab entry, resume, `:ImageOpen`, or `:ImageReload` refreshes them.
`status().terminal_cache` reports runtime-wide totals and active `placements`;
per-buffer view cache statistics refer to that same pool.

Floating previews check source versions on focus gain and cursor idle, including
external rewrites and removal. `:ImageReload` / `reload()` refresh the current file
viewer, or the floating preview when called from its owning document. Unchanged
sources retain their placements; superseded asynchronous results are discarded.

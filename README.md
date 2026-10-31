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
- Formula previews require `latex`, `dvipng` and the `amsmath`/`amssymb` packages
  (TeX Live/MacTeX). Formulas do not need ImageMagick or Ghostscript.

## Local installation

```lua
local patterns = {}
for _, ext in ipairs({ "png", "jpg", "jpeg", "webp", "avif", "heic", "gif", "bmp", "tif", "tiff", "pdf" }) do
  patterns[#patterns + 1] = "*." .. ext:gsub("%a", function(c)
    return "[" .. c .. c:upper() .. "]"
  end)
end

return {
  dir = vim.fn.expand("~/Documents/Github/nvim_plugins/image-tools.nvim"),
  name = "image-tools.nvim",
  lazy = true,
  ft = { "markdown", "tex", "latex", "plaintex", "typst", "html" },
  event = { { event = "BufReadCmd", pattern = patterns } },
  cmd = {
    "ImagePreview", "ImagePreviewClose", "ImagePreviewToggle", "ImagePreviewClearCache",
    "ImageCacheClear", "ImageInfo", "ImageCheckAssets", "ImageInsert", "ImagePaste", "ImagePick",
    "ImageInlineToggle",
    "ImageOpen", "ImagePage", "ImageNextPage", "ImagePreviousPage", "ImageReload", "ImageZoom", "ImagePan", "ImageMove", "ImageLocalize",
  },
  opts = { auto_preview = true, max_width = 60, max_height = 30 },
  config = function(_, opts) require("image_tools").setup(opts) end,
}
```

This is a lazy.nvim spec file. Empty sessions and unrelated filetypes leave the
plugin unloaded. Document filetypes enable automatic previews; commands and Lua
`require("image_tools")` calls load it on demand. The `BufReadCmd` trigger handles
image/PDF files, including startup arguments and uppercase extensions, before
Neovim reads their binary content. Keep its patterns in sync with custom
`buffer.formats`; add custom adapter filetypes to `ft`. Key mappings may also use
lazy.nvim's `keys` field with callbacks that require the API when invoked.

`lazy = false` remains supported. Setup installs commands and file interception,
while floating-preview and terminal-pixel services wait until the first view.
Default insertion helpers and document adapters also load only when needed;
custom insertion options are still validated during setup. The first view pays
the deferred module-loading cost. See [startup measurements](doc/performance.md).

Set `image = { enabled = false }` in Snacks opts and remove any direct `Snacks.image` mappings.

## Usage

- `:ImagePreview /absolute/or/relative/image.png` opens a file.
  Spaces are accepted literally; do not surround the path with shell quotes.
- `:ImagePreview` previews the image reference or Markdown/LaTeX formula under the
  cursor, falling back to the first image/formula covering the current line.
- `:ImagePreviewClose` closes the preview and keeps uploaded pixels cached for reuse.
- `:ImagePreviewClearCache` closes the preview and frees all this plugin's terminal images.
- `:ImageCacheClear` deletes unused converted images from disk, preserving files in use.
- `:ImagePreviewToggle` toggles automatic current-line previews.
- `:ImageInlineToggle` toggles Markdown inline images and block formulas.
- `:ImageInfo` displays current image/PDF metadata, cache counters and phase timings.
- `:ImageCheckAssets` reports missing references and possibly unused assets.
- `:checkhealth image_tools` checks the terminal and configured conversion tools.

Health tool detection checks configured `magick`, `pdfinfo`, `rsvg` and
the selected clipboard backend, `math.latex` and `math.dvipng` executables, using their standard names when unset. Ghostscript
remains a check for `gs` on PATH; ImageMagick chooses its own PDF delegate.

Public API: `setup(opts)`, `preview(path, opts)`, `hover(opts)`, `close()`,
`clear_cache()`, `clear_disk_cache(callback)`, `toggle()`, `status()`, `insert(paths, opts, callback)`,
`paste(opts, callback)`, `pick(opts, callback)`,
`register_adapter(filetype, definition)`, `unregister_adapter(filetype)`,
`open(path)`, `page(n)`, `next_page(delta)`, `reload()`, `zoom(value)`, `pan(x, y)`, `check_assets(opts, callback)`,
`move(source, destination, opts, callback)`, `localize(opts, callback)`, `toggle_inline()`, `info()`.

### Move images and update references

`:ImageMove Figures/architecture.png` moves the local image selected under the
cursor (with current-line fallback). The destination is relative to cwd; spaces
are literal. This also renames images. Keep the original extension.
The command scans the project and opens selection-tools with one diff per changed
document. Enter opens an explicit Apply move/Cancel choice; Escape abandons the
plan without opening a review split or changing files. Descriptions, titles, reference labels, HTML attributes and
LaTeX/Typst options are preserved. Shared Markdown definitions are updated once.
LaTeX omitted extensions/graphicspath references become explicit paths.

`move(source, destination, opts, callback)` provides the same workflow. Set
`project_root` to choose a scan root (default: nearest `.git`, then the source
document directory); set `confirm = false` for programmatic application without
the diff UI. The returned function cancels pending scanning/review.

Loaded documents retain their unsaved edits and are left modified: save them with
`:wall`. Unopened documents are written atomically, preserving CRLF and final
newlines. Existing destinations and symlink sources are rejected. Incomplete
scans and stale document/image/adapter snapshots prevent application. Failures
roll back document replacements, buffer edits and the new image; an exceptional
rollback failure reports retained recovery backups. Ordinary text undo only
undoes the buffer edits, not the image move.

Only literal references recognized in the scanned project are changed; references
outside that root, excluded directories and dynamic expressions are not updated.
Custom adapters need a `path_edit` hook for referenced images. Moving a file does
not rename an already-open image viewer; reopen that viewer at its new path.

`require("image_tools")` alone registers no handlers.
Paths supplied to `preview` are relative to cwd.
Markdown references are relative to the document; changing cwd does not change their meaning.
An optional `root` replaces the document directory, or `resolve(document, source)` can return a custom absolute path.
LaTeX additionally searches literal `graphicspath` directories and tries omitted
extensions. HTTPS images require `remote.enabled = true`; other remote schemes
are rejected. Explicit localization can download a selected HTTPS reference even
when automatic remote loading is disabled.

Automatic preview selects an image when the cursor enters its line, including when
it is outside the image link. On a line with multiple images, the reference under
the cursor takes priority; moving onto another image switches the preview. Outside
all references, the first image is used. Moving within the selected reference,
entering Insert mode or editing surrounding text keeps its preview and pending
conversion while the selected source stays unchanged.

New automatic selections wait `auto_preview_delay` milliseconds (default 100)
before starting preparation. Crossing references cancels the waiting request;
movement or surrounding edits that retain the same source keep its timer and any
already-started conversion. Manual `:ImagePreview`, `hover()` and `preview()` bypass
this delay. Set `auto_preview_delay = 0` for immediate automatic preparation.

Leaving the selected reference's row range closes the previous preview and
previews the new row if it contains an image. Markdown and Typst references cover
one row for images; LaTeX image references and Markdown/LaTeX formulas can cover several. Replacing or removing the reference
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
  auto_preview_delay = 100, -- milliseconds before preparing a new automatic selection; 0 is immediate
  preview_loading_delay = 300, -- milliseconds before a line-end loading hint; 0 disables it
  treesitter = true, -- LaTeX/Typst syntax trees, with automatic lexer fallback
  inline = { enabled = false, max_width = 60, max_height = 20, max_images = 16, debounce = 50 },
  remote = { enabled = false, curl = "curl", timeout = 10000, ttl = 3600, max_redirects = 5 },
  latex = { max_reference_lines = 64, max_reference_bytes = 16 * 1024 },
  math = {
    enabled = true,
    latex = "latex",
    dvipng = "dvipng",
    density = 360, -- raster DPI; higher values improve detail at the same display size
    foreground = "auto", -- Normal foreground, or "#RRGGBB"
    preamble = "\\usepackage{amsmath,amssymb}",
    max_lines = 64,
    max_bytes = 16 * 1024,
  },
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
  convert_concurrency = 2, -- simultaneous conversion/hash processes
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
Conversions and clipboard normalization take priority over queued import hashes,
with FIFO ordering within each class. While hashes wait, at most three interactive
jobs start before one hash job. Running processes keep their slots until exit.
Converted previews fit within 1920x1080 at default zoom; native PNGs retain their dimensions and
are checked against `max_dimension`/`max_pixels`. Floating previews do not upscale;
picker and file-buffer images can upscale to fit their viewport. Originals are never modified.
Converted disk images are managed asynchronously by `disk_cache` limits.
Unused images are removed in access order; currently used images are protected
and may temporarily exceed the limits. Set `disk_cache.enabled = false` to
disable automatic eviction. `:ImageCacheClear` clears unused conversions manually.
Cleanup selects hash-named converted PNGs and downloaded originals in supported
image formats directly inside the configured cache directory.
Subdirectories, other filenames, symbolic links and conversion temporaries
are excluded. After a restart, file modification times provide the
initial eviction order until images are accessed again.

`info().timings` and `:ImageInfo` report milliseconds for reference lookup,
automatic delay, preparation, process queue/conversion, transfer, upload wait,
placement replies, placeholder drawing and total measured time when available.
Preparation includes queue/conversion; transfer includes upload/placement, so
these fields overlap. Pending measurements grow until completion; successful
and failed measurements then stay fixed. See [performance](doc/performance.md)
for cache/shared-worker timing semantics and benchmarks.

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
Direct uploads encode and send raw data in batches of at most 96 KiB, yielding
between batches.
Other plugin graphics commands wait until the current image's final chunk;
cancellation aborts a partial upload before releasing that queue. Response timers
start when commands are sent, after the final chunk for a direct upload. PNG
source bytes remain in memory during transfer; full-image Base64/protocol copies
are avoided.

## Current scope

Markdown supports complete same-line `![alt](path)`, balanced parentheses,
angle-bracket destinations, optional quoted titles, backslash escapes and
percent-encoded paths. Fenced code, indented code and inline code are excluded.
Multiline Markdown image calls are future work. Optional inline display supports
standalone Markdown images and block formulas as described below.
Reference images (`![alt][id]`, `![id][]`, `![id]`) resolve
case-insensitive, whitespace-normalized labels from same-line definitions, including
forward definitions within `max_scan_lines`. The first definition outside code wins.
Local image wikilinks (`![[path.png|label]]`) resolve literal document-relative paths;
vault-wide filename lookup and heading/block targets are not supported.
File insertion is independent of image-insert.nvim. `:ImageInsert [path]` copies an
image into `Figures/` beside the saved document, then inserts a relative Markdown
link. With no path it opens selection-tools file search with image previews and multi-selection. `:ImageInsert! [path]` references the
source without copying. `insert(path_or_paths, opts, callback)` also accepts a batch.
Files already inside the configured image directory or its subdirectories are
referenced directly, including picker selections in copy mode. They keep their
existing filenames and skip the filename prompt; no copy or deduplication option
is needed.

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
does not prevent insertion. File imports preserve original formats and bytes by
default; processing presets can convert external copied imports.

After a successful insert, paste or picker confirmation, the cursor moves to the
first inserted image and enters Insert mode. In Markdown it starts inside the
description (`![|](path)`, where `|` marks the cursor), before any supplied `alt`
text. In LaTeX it starts inside the first figure's caption; in Typst it starts
immediately after the first image reference.
If you switch windows or documents before an asynchronous import finishes, it
keeps your current focus, cursor and mode.

### Document adapters and HTML

Built-in insertion/lookup supports Markdown, LaTeX, Typst and HTML. HTML emits
`<img src="..." alt="">` and enters the alt text in Insert mode. Paths are URL
encoded and attribute text is escaped. Preview/asset inspection recognizes
literal same-line `img src` attributes, excluding comments and script/style/pre/code
content. Named basic and numeric entities are decoded; dynamic bindings, srcset,
multiline tags and DOM evaluation are unsupported. HTTPS sources use the optional
remote loader described below.

Register additional filetypes without replacing built-ins:

```lua
local remove = require("image_tools").register_adapter("org", {
  image_formats = { "png", "jpg", "jpeg" },
  markup = "[[file:$FILE_PATH]]$CURSOR",
})
-- remove() unregisters this registration; unregister_adapter("org") removes the current one.
```

Registration works before setup and survives reconfiguration. The definition is
copied; registering the same custom filetype replaces it. Its formats also drive
clipboard defaults, processing menus and picker filtering. Add `find` and
`references` callbacks for previews/asset inspection, and `file_extensions` for
offline project discovery. Markup-only adapters can insert images; inspection
reports an unsupported enumeration error instead of classifying all assets as unused.
Replacing/removing an adapter invalidates pending imports using it. See the
[adapter API and full callback example](doc/adapters.md).

### File naming rules

`insert.file_name` (or per-call `file_name`) accepts an `os.date` pattern or
function. For example `file_name = "figure-%Y-%m-%d_%H-%M-%S"`. Without a rule,
clipboard images keep the default timestamp and imported files keep their original
names. An explicit `filename` has priority; reference mode and resources already
inside the asset directory reuse the source without renaming it.

```lua
file_name = function(ctx)
  return ctx.document_name .. "_" .. os.date("%Y-%m-%d", ctx.timestamp)
end
```

Context fields: `document`, `document_name` (stem), `filetype`, `kind` (`file` or
`clipboard`), `extension`, `timestamp`; file copies also supply `source` and
`source_name`. Time is captured before prompts/processing selection. Return a
single basename, optionally without its extension. The actual source/output
extension is retained, TeX names are sanitized, collisions get suffixes and
`deduplicate` still reuses identical resources. Errors roll back the whole batch.

### Custom insertion templates

Set `insert.template` globally or pass `template` to `insert`, `paste`, or
`pick({ insert = ... })`. It accepts a string, a function, or a filetype table.
Missing entries use the built-in template; `tex` entries also cover `latex` and
`plaintex`. Set a per-call `template = false` to use the built-in template.

```lua
require("image_tools").setup({ insert = { template = {
  tex = [[
    \begin{figure}[H]
      \centering
      \includegraphics[width=0.6\linewidth]{$FILE_PATH}
      \caption{$CURSOR}
      \label{custom:$LABEL}
    \end{figure}
  ]],
} } })
```

String placeholders are `$FILE_PATH`, `$FILE_NAME`, `$FILE_NAME_NO_EXT`, `$LABEL`,
`$ALT`, and `$CURSOR`. A single cursor placeholder is allowed; without one, editing
starts after the template. Lua long-string padding is removed. Replacement values
are literal, so `%` and placeholder-like filenames are preserved. Functions receive
`file_path`, `file_name`, `file_name_no_ext`, `label`, `alt`, `filetype`, `document`,
and `cursor`; return a string using `ctx.cursor` at the editing target. Paths and
alt text in custom templates are raw values: escape them for the syntax you emit.
Built-in source-format/path validation and transactional rollback still apply.
Reference previews follow the syntax recognized by the document adapter.

## Inline Markdown images and block formulas

Enable `inline = { enabled = true }`, or use `:ImageInlineToggle` /
`toggle_inline()`. The default is disabled. Independent image/PDF buffers and
embedded previews continue to use their own viewers.

Standalone Markdown images display below their source line, including reference
images and local wikilinks. Only whitespace may surround the reference. Block
formulas using `$$...$$`, `\[...\]` and supported display environments (such as
`equation`/`align`) display below their closing line; they may span several source
rows. Single-dollar math, `\(...\)`, `math` environments, images embedded in prose,
list/blockquote items and multiple images on one line use the existing floating
preview. Existing scanner exclusions and `math.enabled` still apply. Formula
rendering needs latex/dvipng; HTTPS images require `remote.enabled = true`.

Rendering adds window-scoped virtual lines, preserving source text, line counts,
modified state and undo history. Source markup stays visible and editable. Each
split fits images independently to its text width; images do not upscale. The
cell limits `inline.max_width`/`max_height` default to 60/20, also bounded by the
window and Kitty's coordinate limit. Virtual lines follow wrapping/gutters and
clip at window edges, scroll with the document, and hide inside closed folds.
Partially visible image rows remain while scrolling past their source anchor.

Only visible candidates are prepared, with up to `inline.max_images` (16) per
window. `inline.debounce` (50 ms; 0 is immediate) coalesces editor/redraw changes.
Recognizers may read earlier syntax context to exclude code and resolve labels;
offscreen images themselves do not start conversion/downloads. Views share the
normal process queue, disk leases and terminal pixel cache. Leaving the viewport,
switching buffers/tabs, closing a split, disabling inline display or suspending
releases its placements and pending work. Source rewrites, edits, resizing and
colorscheme changes refresh affected views; stale results cannot restore them.

Automatic floating previews skip inline-eligible references while inline mode is
enabled. Manual `:ImagePreview` / `hover()` still opens a float. `auto_preview`
and `:ImagePreviewToggle` control floating previews independently. `:ImageInfo`
reports an inline item when the cursor is on its source; `:ImageReload` refreshes
the current document's inline views if no file viewer/current float is selected.
`status().inline` reports windows, image/ready/pending/failed counts and last error.
`:ImagePreviewClearCache` pauses inline views; window/buffer entry, resume,
reconfiguration or toggling inline mode restores them.

Try the bundled [inline gallery](examples/inline.md), including different split
widths, wrapping, partial scrolling, folds and code examples.

## HTTPS images and localization

Enable `remote = { enabled = true }` to preview HTTPS image links in Markdown/HTML
or with `:ImagePreview https://example.org/image.png`. curl is required for cache
misses; configure `remote.curl` for an executable override. PNG remains usable
without ImageMagick. Other formats use the usual conversion tools.

Downloads share `convert_concurrency`, with interactive priority. TLS verification
stays enabled; curl configuration files are disabled, and initial URLs and redirects
are restricted to HTTPS. `remote.timeout` bounds each download (default 10000 ms),
`max_redirects` defaults to 5, and streamed response bytes are bounded by `max_bytes`,
including responses without Content-Length. Image type is detected from content,
not a URL's extension; error pages and invalid/oversized images are rejected.

Validated original bytes are cached by URL/downloader under the existing disk-cache
limits, with a freshness TTL of 3600 seconds. `remote.ttl = 0` disables reuse.
Simultaneous matching requests share a download; cancelling one subscriber leaves
the others active. Closing the final view cancels pending work. `:ImageReload`
bypasses the URL cache for the current floating preview. `:ImageCacheClear` removes
unused downloads and conversions; active handles pin their files. `status().remote`
reports configuration, download/cache-hit counters and pending shared jobs. Asset
inspection skips HTTPS references and never downloads them.

`:ImageLocalize` / `localize(opts, callback)` downloads the selected HTTPS image,
copies its original format/bytes into `insert.directory`, and replaces only the
reference destination. This explicit operation also works with remote loading
disabled. It supports Markdown inline/reference images and HTML; shared Markdown
definitions retain their labels and update all uses of that definition. Titles,
descriptions and other HTML attributes survive. It returns a cancel function.

Names use the URL basename with the detected extension; `filename` overrides it.
Insertion directory/root, filename prompts, collision suffixes and deduplication
apply. Localization bypasses processing presets to preserve downloaded originals.
The document is left modified, with a separate undo entry. Focus is preserved;
edits, renames, unloads or adapter changes during download/import reject the
replacement and roll back new resource copies. Text undo retains the asset.

## Development

For hands-on testing, open the [manual test gallery](examples/README.md). It
includes every supported image extension, transparency, wide/tall images, a path
with spaces and Unicode, and a three-page PDF with distinct pages for paging.
The assets are bundled; regeneration is optional.

GitHub Actions runs formatting checks plus basic and complete integration jobs.
The integration job pins Neovim and Tree-sitter parsers/CLI, requires its
dependencies before suites can skip them, and retains environment/test logs.
See [automated validation and real Kitty acceptance](doc/testing.md) for pinned
fixture reproduction, coverage boundaries and manual rendering steps.

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
3. Insertion, simulated clipboard commands, optional selection-tools chooser, move review and asset reports.
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
- `IMAGE_TOOLS_SELECTION_ROOT`: selection-tools checkout; enables chooser and chooser TUI integration checks.
- `IMAGE_TOOLS_LAZY_ROOT`: lazy.nvim checkout; tests the installation spec's loading triggers.
- `pdflatex` / `typst`: enable real compilation in the corresponding document tests.
  `pdfimages`, when available, additionally checks embedded image dimensions.
- `latex` / `dvipng`: enable real formula compilation and file/direct TUI formula
  scenarios. Parser, mocked worker and lifecycle tests run without these tools.
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

## Clipboard images

Automatic readers: macOS uses `pngpaste` (`brew install pngpaste`), falling back to
`pbctl`; Linux uses `wl-paste` in Wayland sessions or `xclip` in X11 sessions;
Windows/WSL uses `powershell.exe`. `:ImagePaste` or `paste(opts, callback)`
reads the system clipboard without modifying it, imports an image, and inserts a
reference at the original source position. Clipboard paste always copies its
resource, including when file insertion uses reference mode. Markdown defaults to
AVIF with ImageMagick (`quality = 75`); LaTeX/Typst default to PNG without conversion.
It names the image using the paste's local date/time, such as
`2026-04-28_16-21-17.avif` or `2026-04-28_16-21-17.png`. Same-second collisions add numeric
suffixes. Per-call `filename` overrides the name; `prompt_for_file_name = true`
requests a name. `format = "png"` preserves the reader's PNG without conversion;
`"jpg"` and `"webp"` are also supported. An explicit `format` must be supported by
the document; LaTeX/Typst do not accept AVIF images.
Clipboard commands have a 5-second timeout; conversions use `convert_timeout`.
Empty clipboard, unsupported platform, missing tools and failed conversion report
errors without inserting text or leaving image resources. The cancel function also
stops pending reads/processes and removes temporary files.

Set `insert.clipboard_backend` (or per-call `clipboard_backend`) to `auto`,
`pngpaste`, `pbctl`, `wl-paste`, `xclip`, or `powershell`. Override executable
paths with `clipboard_tools = { ["wl-paste"] = "/path/to/wl-paste" }`.
The legacy `pngpaste` override still selects that reader on macOS. Readers request
PNG; streamed bytes are bounded by `max_bytes`. `:checkhealth image_tools` and
`status().clipboard` report the selected backend/tool or an availability error.
Backend protocol tests run with fixtures; native GUI clipboard validation remains
platform-specific. See [backend commands and native validation](doc/clipboard-backends.md).

### Image processing presets

Pass `process = "select"` to paste to choose from PNG, AVIF, JPEG and a WebP
1600px preset. The menu filters formats using the captured document type. A single
compatible preset runs immediately; cancelling a menu performs no clipboard read.
Configure `insert.process` for a default menu/preset, or pass a preset/list per call:

```lua
require("image_tools").paste({ process = {
  { name = "Original PNG", format = "png" },
  { name = "Small WebP", format = "webp", resize = "1200x1200>", quality = 80 },
} })
```

Presets accept `name`, `format`, `quality`, `resize` (ImageMagick geometry), and
`command`. Custom commands are argv lists containing `$INPUT` and `$OUTPUT`, e.g.
`{ "magick", "$INPUT", "-resize", "800x800>", "$OUTPUT" }`; no shell pipeline is
used. The custom command owns processing/encoding; select a matching `format`.
Converters share the existing queue, timeout, cancellation and import rollback.
Preset values override per-call format/quality. `process = false` bypasses a menu.

The same presets apply to external file imports and picker confirmations:

```lua
require("image_tools").insert({ "/downloads/plot.webp", "/downloads/chart.avif" }, {
  process = { format = "png", resize = "1600x1600>" },
})
require("image_tools").pick({ insert = { process = "select" } })
```

Set `insert.process` for a shared file/clipboard default. File batches choose one
preset, process each external source, then import everything with a single text
edit. PNG is the default output when a file preset omits `format`; clipboard
defaults remain document-specific. Source filenames keep their stem with the
output extension; naming callbacks receive the original `source`/`source_name`
and the output `extension`. Formats offered in menus match the target document.
Processing-enabled pickers also accept convertible input formats, so a LaTeX
document can select WebP/AVIF and import PNG/JPEG.

Reference mode and assets already inside the destination directory skip processing
and retain their filenames/bytes. Such existing assets must already be supported
by the document. Originals are never modified. Converters operate on private
copies; built-in commands select the first page/frame. Output encoding, byte size
and dimensions are checked with ImageMagick before publication. Queue budgets,
timeouts, cancellation, deduplication and import rollback still apply. A failed
batch leaves no inserted text or partial imported resources.

## Picker integration

### Embed images in another plugin's pane

`supports(path)` checks image/PDF extensions without initializing services.
`render(request)` borrows an existing `nofile` buffer/window and returns a view
(or `nil, error` when the target/format/terminal is unsupported):

```lua
local image = require("image_tools")
local view, err = image.render({
  path = "/project/figure.png", buf = preview_buf, win = preview_win,
  is_valid = function() return selection_is_current end,
  on_error = function(message) show_preview_error(message) end,
})
-- On layout changes and selection/owner teardown:
if view then view:resize(); view:close() end
```

For flicker-free replacement, retain a ready view with `previous = view:retain()`
and pass that handle in the next `render({ previous = previous, ... })` request.
The old grid and placement stay visible through preparation/upload; the new
acknowledged grid is painted before the old lease is released. Retaining a pending
view cancels it and returns its last ready predecessor. Close the retained handle
if replacement is abandoned. Retained views never repaint stale selections.

The host owns the scratch buffer, window and focus; image-tools owns preparation,
placeholder highlights and placement leases. Drawing preserves buffer flags and
fits the pane after gutters, with `upscale=true` by default. `page` selects a PDF
page. Optional `paint(draw)` must synchronously execute `draw()` on the main
thread, including both buffer lines and extmarks, and may return false to reject
a stale transaction. This supports hosts whose normal line writer is asynchronous.

`resize()` reuses the shared pixel pool; `close()` is idempotent and preserves the
host's buffer/window. Buffer/window closure, runtime reconfiguration and cache
cleanup also release views. An already-owned target replaces its previous view.
The API does not depend on Snacks, create windows, or register picker callbacks.
Load the plugin only when an image candidate actually needs rendering.

### Image chooser: selection-tools

`:ImagePick` / `pick(opts, callback)` uses selection-tools.nvim's file search and
window/key configuration. Install selection-tools separately; the format glob
filter requires ripgrep. Other image-tools operations do not require a picker.
Images use the public embedded renderer over the existing preview pane, sharing
conversion and terminal pixel caches with other image-tools views.

Search filters follow the original document adapter, including mixed-case image
extensions; `opts.picker.ft` can further restrict extensions. Processing-enabled
copy imports also offer convertible input formats. `opts.picker` otherwise uses
selection-tools `files()` options (`cwd`, `query`, `layout`, `keys`, etc.). Confirm
imports current/multiple selections in source order at the original document
extmark, after picker cleanup. Escape cancels without importing or modifying the
document. The captured insertion context is single-use, so this chooser is not
recorded by picker resume. Selection changes/close release render views, and
resize reuses uploaded pixels. Switching images retains the last ready image
until the next image is acknowledged and drawn, without inserting a Loading
placeholder between them; skipped requests still cancel.

```lua
require("image_tools").pick({
  insert = { mode = "reference" },
  picker = { cwd = "/images", ft = { "png", "pdf" } },
})
```

Set `IMAGE_TOOLS_SELECTION_ROOT` to a selection-tools checkout for chooser,
diff review, resource report and TUI tests. Image-tools has no Snacks adapter;
other preview hosts can use the public `render()` API.

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
that LaTeX grammars do not consistently represent. Formula lookup uses a separate
bounded Lua scanner, independently of `treesitter`.

## Formulas in LaTeX and Markdown

Move onto a formula or run `:ImagePreview` / `hover()` to show a floating formula
preview. Both document types support `$...$`, `$$...$$`, `\(...\)` and `\[...\]`,
including multiline expressions. Supported environments are `math`, `displaymath`,
`equation`, `align`, `alignat`, `gather`, `multline`, `flalign` and `eqnarray`, with
starred variants where LaTeX provides them. Nested `aligned`, `cases`, matrices
and other math content inside these delimiters are passed through to LaTeX.

LaTeX comments, `\verb` and verbatim/listing/comment environments are skipped.
Markdown fenced/indented code, matched backtick code spans, HTML comments and
`<code>`/`<pre>` contents are skipped. Backtick spans can cross lines within a
paragraph and `max_scan_lines`; unmatched runs remain literal text.
Single Markdown dollars require non-whitespace just after the opening delimiter
and just before the closing delimiter; a closing dollar cannot precede a digit.
Unclosed expressions and formulas exceeding `math.max_lines` (64),
`math.max_bytes` (16 KiB) or `max_scan_lines` are ignored. Formula selection,
automatic delay, cross-row movement, editing and cancellation follow the same
rules as image references. `:ImageInfo` reports `format = "math"` and rendering
errors. `:ImageReload` reloads a selected formula.

The renderer compiles a standalone `article` snippet with `math.preamble`, then
uses `dvipng` to crop a transparent PNG. It does not compile the document or inherit
its preamble, macros, packages, bibliography or equation counters. Add required
packages/macros explicitly, retaining the default packages when needed:

```lua
require("image_tools").setup({
  math = {
    preamble = [[
\usepackage{amsmath,amssymb}
\newcommand{\vect}[1]{\mathbf{#1}}
]],
  },
})
```

Compilation runs asynchronously with shell escape disabled and restrictive TeX
file-access settings in a private temporary directory. Both processes share
`convert_concurrency`; each uses `convert_timeout`. Missing tools and invalid
formulas are available through `:ImageInfo` or a manual `:ImagePreview`.
PNG size/dimension limits still apply. Output is cached by formula, preamble,
renderer executables, density and resolved foreground. `foreground = "auto"`
uses `Normal`'s foreground with a light/dark fallback; colorscheme changes select
new pixels. `:ImageCacheClear` also removes unused formula PNGs. Set
`math.enabled = false` to disable recognition. Asset checks enumerate image files
only. Formulas use floating previews, or optional Markdown block-formula inline
display; document text is preserved.

`math.density` defaults to 360 DPI. Formulas use a fixed 180-DPI baseline for
display sizing, so higher density adds raster detail without enlarging the
preview. Set `math = { density = 540 }` or `720` for additional sampling; larger
rasters use more conversion/transfer memory and remain subject to PNG limits.
Changing density selects a new cache entry automatically.

Try [examples/math.md](examples/math.md) and [examples/math.tex](examples/math.tex).

Insertion uses the same default figure template as image-insert.nvim; load
`graphicx` in your document:

```tex
\begin{figure}[ht]
  \centering
  \includegraphics[width=0.8\linewidth]{Figures/my-plot.png}
  \caption{}
  \label{fig:my-plot}
\end{figure}
```

The cursor enters the empty caption in Insert mode. The label uses the final
filename without its extension, lowercased with whitespace replaced by hyphens.
This applies to `tex`, `latex` and `plaintex`, including file insertion, clipboard
paste and picker confirmation. PNG/JPEG/PDF imports preserve original formats.
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

Converters for distinct image files/PDF pages, clipboard normalization and
import hashes share a priority queue,
with `convert_concurrency = 2` by default. Same-source requests still share one
conversion. Closing a queued preview removes its job; cancelling a running job
keeps its slot until the process exits. Cache hits and PNG reads bypass the queue.
`status().conversion_queue` reports active/queued processes, waiting counts for
each priority class and the current process budget.
Reconfiguration updates that budget; running workers retain their slots until exit.

Terminal pixel data is shared by inline views, floating previews, picker previews and file
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

Lua reference scanning retains unchanged prefix checkpoints after edits. For
repeatable cold/warm lookup, tail-edit and movement timings, see
[the recognition benchmark](doc/performance.md#recognition-latency-benchmark).

Image/PDF viewer controls: `+` / `-` zoom by a factor of two, `0` fits the
window, `1` uses native prepared-pixel scale, and arrow keys pan by five terminal
cells (counts supported). `:ImageZoom fit|native|in|out|FACTOR`, `zoom(value)`,
`:ImagePan X Y` and `pan(x, y)` expose the same controls. Numeric zoom is relative
to fit and ranges from 0.125 to 8. Zoom resets pan; pan clamps to image edges.
Each visible split retains independent controls across resize/reload/page changes;
leaving its buffer resets that window's controls. Cropped placements reuse uploaded
pixels. PDF and other converted formats prepare larger rasters when zoomed in; PDF
density and output bounds scale together, bounded by source/output limits and the
existing conversion queue. Native scale refers to the prepared raster, including
configured PDF density. Original files are unchanged.

Set `insert.deduplicate = true` (default false), or pass `deduplicate = true` to
insertion/paste, to reuse byte-identical files with the same extension in the
configured destination directory. Reuse takes precedence over the requested
filename; the directory is not searched recursively. Reads/hashing are bounded
by max_bytes; symlinks are excluded. Cancellation or failed insertion removes
only files created by that transaction, preserving reused files.

Deduplication hashes run in isolated headless Neovim processes, with no extra
tools or user configuration. They share the `convert_concurrency` process budget
and have a 10-second timeout. A 128-entry in-memory LRU caches only digests by
path/inode/size/nanosecond mtime/ctime; live file checks invalidate changed entries.
Concurrent requests for the same revision share a worker; its last subscriber's
cancellation stops it. Encoding and hashing keep file bytes out of the editor
process, although each worker still uses memory proportional to `max_bytes`.
Cold hashes include process startup overhead; repeated unchanged candidates avoid
rehashing. See [the import hashing benchmark](doc/performance.md#import-hashing-benchmark).

`:ImageCheckAssets` opens a searchable selection-tools report, also retained in
quickfix, of missing references and possibly
unused image files in the current document's import directory. It supports
Markdown, LaTeX and Typst literal references, with the same syntax exclusions and
max_scan_lines limit as preview. A truncated scan is marked in the report.
"Possibly unused" only means unused in this document: shared resources may be
referenced elsewhere. Directory inspection is nonrecursive and excludes symlinks.
Entries preview document locations or image assets; Enter jumps to the report location. `Ctrl-q` exports results to quickfix.
No files are deleted. `check_assets(opts, callback)` returns a cancel function;
the callback receives `(error, report)` with `missing`, `unreferenced`, `directory`,
`document`, `scanned` and `truncated`. Edits/rename/unload reject stale inspection.

`:ImageCheckAssets! [directory]` checks a project. With no directory it uses the
nearest `.git` ancestor of the current document, or the document directory.
`check_assets({ scope = "project", project_root = "/project" }, callback)` exposes
the same operation. It recursively discovers `.md`, `.markdown`, `.tex`, `.ltx`
and `.typ` documents and inspects the union of their configured import directories
recursively. Shared images are only reported unused when no scanned document
references them. Reports add `scope`, `project_root`, `documents`, `warnings` and
`references`: a map from canonical image paths to `{ filename, lnum, col }` locations.
Document-only reports also include `scope` and `references`.

Loaded supported buffers supply their current unsaved text. Offline documents use
temporary unnamed buffers without changing focus or loading the original file into
the buffer list. Live edits/rename/unload or a changed disk document reject the
report; cancellation releases temporary buffers. Reference enumeration is shared
through the format adapters and uses the Lua scanners, including code/comment
exclusions, forward Markdown definitions and multiline LaTeX commands.
Offline LaTeX does not infer a master document's VimTeX state; configure `root`
or `resolve` when references depend on that project context.

`assets = { max_entries = 10000, max_document_bytes = 2 * 1024 * 1024,
exclude_dirs = { ".git", ".hg", ".svn", "node_modules", ".venv", "vendor", "build", ".cache" } }`
configures inspection. Each recursive traversal has its own entry budget; each
offline document has a byte budget, and `max_scan_lines` applies per document.
Skipped/unreadable documents or exhausted budgets mark `truncated` and produce
quickfix warnings. Unused results are provisional when any document was skipped.
Directory exclusions apply by name and symlinks are skipped. No assets or source
documents are modified or deleted.

Viewer keymaps are configured by action. Unspecified actions keep their defaults;
set an action to false to disable it, or set `buffer.keymaps = false` to disable
all plugin mappings. Existing user buffer-local mappings take precedence. Setup
replacement removes only mappings still owned by the previous instance. Commands
and API calls remain available when mappings are disabled.

```lua
require("image_tools").setup({
  buffer = { keymaps = { zoom_in = "z", zoom_out = "Z", pan_left = "h",
    pan_right = "l", pan_up = "k", pan_down = "j", info = "i", reload = false } },
  insert = { deduplicate = true },
})
```

Available actions: `reload`, `info`, `zoom_in`, `zoom_out`, `fit`, `native`,
`pan_left`, `pan_right`, `pan_up`, `pan_down`, `next_page`, `previous_page`. Default
keys are `r`, `i`, `+`, `-`, `0`, `1`, arrow keys, `]p`, `[p`, respectively.

`:ImageInfo` / `info()` describe the current file viewer or owning floating
preview: source path/format/bytes, prepared raster dimensions, readiness, PDF
page bounds when known, current zoom/crop, terminal-cache counters and disk-cache
directory. This does not initiate conversion or configure an unused plugin.
Prepared raster dimensions can be pending and can differ from original dimensions.
`stage` distinguishes `preparing`, `placing` (waiting for terminal upload/placement),
`ready` and `failed`. Floating requests still pending after `preview_loading_delay`
milliseconds show a line-end loading hint, removed on completion or cancellation.
Automatic failures remain notification-silent. When no viewer is active, `info()`
and `:ImageInfo` show the most recent floating-preview failure, including its path,
`error` and `error_stage`, with `last_error = true`. This diagnostic retains no
image resources and survives closing a preview; repeated setup resets it.
`info()` returns `(nil, error)` when neither an active viewer nor a retained failure exists.

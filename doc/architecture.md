# Module layout

The public `image_tools` API stays in `init.lua`. Configuration, commands and
runtime lifecycle are provided by `config.lua`, `commands.lua` and `runtime.lua`.

Implementation modules are grouped by responsibility:

```
lua/image_tools/
  init.lua                 public API
  config.lua               option defaults and validation
  runtime.lua              editor lifecycle and subsystem coordination
  commands.lua             user commands
  health.lua               Neovim checkhealth entry point
  image.lua                media compatibility facade
  document/
    init.lua               document API
    formats.lua            filetype aliases and adapter dispatch
    markdown.lua           Markdown syntax and insertion rules
    tex.lua                LaTeX resolution and insertion rules
    tex/reference.lua      bounded multiline decoding and reference ranges
    typst.lua              Typst syntax and insertion rules
    paths.lua              path resolution, project roots and validation
    syntax_cache.lua       buffer results and prefix checkpoints
    treesitter.lua         async syntax indexing and diagnostics
  media/
    formats.lua            supported preview formats
    file_version.lua       source revision keys
    png.lua                PNG reads and validation
    convert.lua            converter commands and output publication
    prepare.lua            shared preparation workers and file leases
    pdf.lua                PDF metadata
    disk_cache.lua         converted-file storage and eviction
    conversion_queue.lua   process budget and scheduling
  render/
    preview.lua            floating preview controller
    buffer.lua             read-only file-buffer controller
    canvas.lua             window-bound file canvas
    geometry.lua           aspect-ratio fitting
    placeholder.lua        placeholder grids and highlights
    session.lua            shared preparation/placement lifecycle
  terminal/
    init.lua               terminal detection, geometry and replies
    protocol.lua           Kitty commands and placeholder encoding
    upload.lua             pixel upload, fallback and cache
    pixel_pool.lua         shared pixel ownership and placements
    transfer.lua           per-view placement manager
  workflow/
    insert.lua             file import and document text transaction
    clipboard.lua          macOS clipboard import
    picker.lua             Snacks selection and preview integration
```

`require("image_tools.document")` retains `supported`, `parse`, `base`, `resolve`, `at_line` and `at_cursor`.
Format modules use the path and syntax-cache helpers directly, without importing the dispatcher.
Format tests live in `tests/document/`; shared image/PDF fixtures remain in `tests/`.

`require("image_tools")`, `require("image_tools.document")` and the existing
`image_tools.image` facade retain their APIs. `image_tools.terminal` resolves to
`terminal/init.lua`. Internal imports and test mocks use the grouped module paths;
the former top-level implementation paths are no longer provided.

Dependency injection still uses logical keys such as `preview`, `buffer`,
`protocol`, `pdf` and `picker`. Controllers map moved defaults to their module
paths while checking supplied dependencies first. Neovim namespaces, highlight
groups and autocmd group names remain independent of these paths.
Tests retain their existing filenames and runner groups; only implementation
imports, mocks and the isolated terminal source lookup change.

## Terminal ownership

`terminal/transfer.new()` always constructs a view placement manager. A supplied
`pixel_pool` shares uploads across managers; a standalone manager owns a private
pool. Within `terminal/`, the dependency direction is `transfer -> pixel_pool ->
upload -> init / protocol`. `upload` handles pixel transmission, fallback, versioning and LRU
storage; it never creates or hides placements. `pixel_pool` owns reference counts,
independent placement ids and bounded placement retry. It consults the uploader's
`cached()` method rather than its entry table. Clearing a shared transfer releases
only its leases; clearing a standalone
transfer also frees its private pool. Clearing the pool frees all owned terminal
pixels.

## Render sessions

Floating previews, file canvases and Snacks renderers supply their own authority,
viewport, window policy and error presentation. `render/session` owns the common
prepare/placement sequence and releases both handles on close, stale completion,
or drawing failure. It also releases handles returned after a synchronous close.
`render/geometry` supplies aspect-ratio fitting; `render/placeholder` draws the Kitty grid and
placement highlight. These helpers do not depend on a particular controller.

## Media preparation and process budget

`image` is the compatibility facade. `media/png` reads and validates PNG data;
`media/file_version` identifies source revisions; `media/formats` lists preview
formats; `media/convert` constructs converters and publishes validated outputs.
`media/prepare` owns process-scoped coalesced workers. Each request has separate
`cancel`, `release` and `close` operations: cancellation suppresses pending delivery;
release unpins delivered files; close performs both. The old `image.prepare`
cancellation function delegates to close. Successful preparation keeps each
subscriber's disk lease until the view closes.

The FIFO `media/conversion_queue` is process-scoped with one explicit budget configured
by Runtime start. Preview and clipboard converters share it. Reducing the budget
does not abandon running workers: queued work waits for sufficient exits.
The new concurrency limit applies when queued processes start; each job retains
the command and options captured when queued. Existing insertion operations retain
their captured document/options. PNG reads and PDF metadata bypass this queue.

## Document format adapters

`document/formats` centralizes filetype aliases and resolves the Markdown, LaTeX
and Typst adapters. Each adapter owns reference detection, supported insertion
formats, markup emission and insertion path base; format-specific validation and
filename sanitation are optional hooks. The picker uses the same format list as
insertion. Markdown derives its list from the media preview capabilities, so
variants such as TIFF cannot disappear from the picker while remaining importable.
`workflow/insert` owns capture/extmarks, file publication, rollback and the single text
transaction. It delegates document rules without branching on filetype.
Its `markup`, `supported` and `relative` functions remain compatibility
helpers; relative path calculation lives alongside other document path helpers.

LaTeX's shared reference decoder preserves byte columns and inclusive row ranges
for complete commands spanning multiple lines. Tree-sitter determines syntax
contexts and command locations; argument decoding can look ahead within the
configured line/byte budgets. The Lua backend combines a bounded local reference
search with cached prefix context. `at_cursor` selects by row and byte column;
`at_line` selects the first covering reference in document order. The runtime
tries cursor selection first and falls back only on a selection miss.

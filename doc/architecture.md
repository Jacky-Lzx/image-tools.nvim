# Module layout

The public `image_tools` API stays in `init.lua`. Configuration, commands and
runtime lifecycle are provided by `config.lua`, `commands.lua` and `runtime.lua`.

Document reference processing lives in one subsystem:

```
lua/image_tools/document/
  init.lua          existing document API
  formats.lua       canonical filetype aliases and adapter dispatch
  markdown.lua      Markdown syntax and insertion rules
  tex.lua           LaTeX syntax, resolution and insertion rules
  typst.lua         Typst syntax, resolution and insertion rules
  paths.lua         shared resolution, project roots and path validation
  syntax_cache.lua  buffer-scoped results and prefix checkpoints
  treesitter.lua    async syntax indexing and backend diagnostics
```

`require("image_tools.document")` retains `supported`, `parse`, `base`, `resolve`,
`at_line` and `at_cursor`. Format modules use the path and syntax-cache helpers
directly, without importing the dispatcher. Format tests live in
`tests/document/`; shared image/PDF fixtures remain in `tests/`.

The remaining modules describe separate responsibilities: preview and file-buffer
controllers (`preview`, `buffer`, `canvas`); media preparation and disk storage
(`image`, `pdf`, `disk_cache`); terminal transmission (`terminal`, `protocol`,
`transfer`); and import/clipboard/picker workflows (`insert`, `clipboard`, `picker`).
They remain at the top level in this change so their dependency-injection names
and existing integration entry points are unchanged.

## Terminal ownership

`transfer.new()` always constructs a view placement manager. A supplied
`pixel_pool` shares uploads across managers; a standalone manager owns a private
pool. The dependency direction is `transfer -> pixel_pool -> upload -> terminal /
protocol`. `upload` handles pixel transmission, fallback, versioning and LRU
storage; it never creates or hides placements. `pixel_pool` owns reference counts,
independent placement ids and bounded placement retry. It consults the uploader's
`cached()` method rather than its entry table. Clearing a shared transfer releases
only its leases; clearing a standalone
transfer also frees its private pool. Clearing the pool frees all owned terminal
pixels.

## Render sessions

Floating previews, file canvases and Snacks renderers supply their own authority,
viewport, window policy and error presentation. `render_session` owns the common
prepare/placement sequence and releases both handles on close, stale completion,
or drawing failure. It also releases handles returned after a synchronous close.
`geometry` supplies aspect-ratio fitting; `placeholder` draws the Kitty grid and
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

The FIFO conversion queue is process-scoped with one explicit budget configured
by Runtime start. Preview and clipboard converters share it. Reducing the budget
does not abandon running workers: queued work waits for sufficient exits. New
configuration applies to queued work, while existing insertion operations retain
their captured document/options. PNG reads and PDF metadata bypass this queue.

## Document format adapters

`document/formats` centralizes filetype aliases and resolves the Markdown, LaTeX
and Typst adapters. Each adapter owns reference detection, supported insertion
formats, markup emission and insertion path base; format-specific validation and
filename sanitation are optional hooks. The picker uses the same format list as
insertion. Markdown derives its list from the media preview capabilities, so
variants such as TIFF cannot disappear from the picker while remaining importable.
`insert` owns capture/extmarks, file publication, rollback and the single text
transaction. It delegates document rules without branching on filetype.
`insert.markup`, `insert.supported` and `insert.relative` remain compatibility
helpers; relative path calculation lives alongside other document path helpers.

# Module Layout

Implementation modules are grouped by responsibility:

Every implementation Lua file starts with English `Purpose`, `Architecture`
and `Ownership` notes. They summarize the module's role, its dependency boundary
and the scope/lifecycle of its state; the sections below describe how the modules
work together.

Functions and state structures use LuaLS annotations (`@class`, `@field`,
`@param` and `@return`) alongside English explanations of their contracts.
Lifecycle comments describe cancellation, resource ownership, stale-result
guards and callbacks that can complete synchronously. Coordinate annotations
distinguish one-based document rows from zero-based buffer offsets and byte
columns; accepted preview requests are distinguished from acknowledged drawing.

```
lua/image_tools/
  init.lua                 public API
  config.lua               option resolution and validation
  defaults.lua             shared option defaults
  runtime.lua              editor lifecycle and subsystem coordination
  commands.lua             user commands
  health.lua               Neovim checkhealth entry point
  document/
    init.lua               document API
    formats.lua            filetype aliases and adapter dispatch
    markdown.lua           Markdown syntax and insertion rules
    tex.lua                LaTeX resolution and insertion rules
    tex/reference.lua      bounded multiline decoding and reference ranges
    typst.lua              Typst syntax and insertion rules
    paths.lua              path resolution, project roots and validation
    syntax_cache.lua       independent buffer/context namespaces and prefix checkpoints
    math.lua               bounded formula ranges and standalone TeX source
    treesitter.lua         async syntax indexing and diagnostics
  media/
    init.lua               unified image helper API
    formats.lua            supported preview formats
    file_version.lua       source revision keys
    png.lua                PNG reads and validation
    convert.lua            converter commands and output publication
    math.lua               latex/dvipng workers and transparent formula PNGs
    prepare.lua            shared preparation workers and file leases
    pdf.lua                PDF metadata
    disk_cache.lua         converted-file storage and eviction
    conversion_queue.lua   process budget and scheduling
    conversion_limits.lua  fixed conversion dimensions and resource limits
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
    constants.lua          fixed Kitty wire-format values
    upload.lua             pixel upload, fallback and cache
    pixel_pool.lua         shared pixel ownership and placements
    transfer.lua           per-view placement manager
  workflow/
    content.lua            background hash coalescing, digest LRU and reuse
    hash_worker.lua        isolated headless-Neovim hashing entry point
    assets.lua               read-only document resource inspection
    asset_project.lua        project discovery, scratch documents and reference aggregation
    insert.lua             file import and document text transaction
    clipboard.lua          macOS clipboard import
    picker.lua             Snacks selection and preview integration
```

`defaults.lua` is the single source for configurable defaults, including service
fallbacks for partial internal options. Consumers treat it as read-only;
`config.resolve()` deep-copies it before merging caller options. Fixed conversion
limits live in `media/conversion_limits.lua`, and shared Kitty wire-format values
live in `terminal/constants.lua`. Other format offsets, scan batches, timing
budgets and rendering priorities are named within their owning modules. String
and command offsets are derived from their actual lengths. This organization
does not add configuration options or change existing limits.

`require("image_tools.document")` retains `supported`, `parse`, `base`,
`resolve`, `at_line` and `at_cursor`. Format modules use the path and
syntax-cache helpers directly, without importing the dispatcher. Format tests
live in `tests/document/`; shared image/PDF fixtures live in `tests/fixtures/`.

`require("image_tools.media")` is the entry point for format checks, PNG reads,
revision keys and preparation. The former `image_tools.image` module is removed
without a compatibility alias. Injected media overrides still use the logical
`image` key; controllers map its default to `image_tools.media`.

## Test Layout

```
tests/
  run.sh                     explicit suite list, isolation and status logs
  core/
    regression.lua           combined API/protocol/preview regressions
    runtime.lua              setup, dependency injection and teardown
    health.lua               diagnostics and cache inspection
    line_lifecycle.lua       line selection, edits and asynchronous cancellation
    preview_diagnostics.lua stages, retained failures and delayed loading hints
    cursor_lifecycle.lua     cursor-based reference selection
    tex_range_lifecycle.lua  multiline reference lifecycle
  document/                  existing format/parser/indexing suites
  media/
    conversion.lua           real conversions and coalescing
    prepare.lua              preparation leases
    conversion_queue.lua     process scheduling and cancellation
    disk_cache.lua           disk limits, leases and cleanup
  render/
    buffer.lua               file-buffer and PDF paging behavior
    canvas_bounds.lua        viewport geometry and owner boundaries
    session.lua              preparation/placement resource lifecycle
  terminal/
    transfer.lua             protocol transmission, replies and cache reuse
    pixel_pool.lua           shared ownership and independent placements
  workflow/
    insert.lua               import, extmarks, batches and rollback
    content.lua              binary hashes, revisions, cache and worker cancellation
    clipboard.lua            simulated clipboard commands
    picker.lua               optional real Snacks integration
  tui/
    run.py                   PTY runner and Kitty protocol responder
    preview.lua              floating preview scenario
    buffer.lua               image/PDF buffer scenario
    picker.lua               optional Snacks scenario
    cursor.lua               reference-selection scenario
    latex.lua                multiline PDF-reference scenario
  manual/
    clipboard_native.lua     opt-in prepared-system-clipboard check
  fixtures/
    fixture.png              raster fixture
    fixture.pdf              two-page PDF fixture
    demo.md                  interactive preview example
```

`tests/run.sh` retains the explicit suite order and optional-dependency gates.
Each headless Lua suite starts in a fresh Neovim process. `tui/run.py` locates the
repository from its own path and launches the adjacent Lua scenarios in a PTY;
these are not standalone headless tests. The native clipboard check is excluded
from automatic runs. Moving fixtures does not change their bytes; the demo's
relative image link resolves within the fixture directory.

## Terminal Ownership

`terminal/transfer.new()` always constructs a view placement manager. A
supplied `pixel_pool` shares uploads across managers; a standalone manager owns
a private pool. Within `terminal/`, the dependency direction is `transfer ->
pixel_pool -> upload -> init / protocol`. `upload` handles pixel transmission,
fallback, versioning and LRU storage; it never creates or hides placements.
`pixel_pool` owns reference counts, independent placement ids and bounded
placement retry. It consults the uploader's `cached()` method rather than its
entry table. Clearing a shared transfer releases only its leases; clearing a
standalone transfer also frees its private pool. Clearing the pool frees all
owned terminal pixels.

## Render Sessions

Floating previews, file canvases and Snacks renderers supply their own
authority, viewport, window policy and error presentation. `render/session`
owns the common prepare/placement sequence and releases both handles on close,
stale completion, or drawing failure. It also releases handles returned after a
synchronous close. `render/geometry` supplies aspect-ratio fitting;
`render/placeholder` draws the Kitty grid and placement highlight. These
helpers do not depend on a particular controller.

Sessions expose independent timing snapshots, clip shared-process timestamps
to each subscriber and retain completed/failing values. Pixel-pool callbacks
report consumer-specific upload/placement waits, including retry attempts.

## Media Preparation and Process Budget

`media/init` is the unified entry point. `media/png` reads and validates PNG data;
`media/file_version` identifies source revisions; `media/formats` lists preview
formats; `media/convert` constructs converters and publishes validated outputs.
`media/prepare` owns process-scoped coalesced workers. Each request has separate
`cancel`, `release` and `close` operations: cancellation suppresses pending delivery;
release unpins delivered files; close performs both. The `media.prepare`
cancellation function delegates to close. Successful preparation keeps each
subscriber's disk lease until the view closes.

The priority-aware `media/conversion_queue` is process-scoped with one explicit
budget configured by Runtime start. Preview/clipboard converters and import hash workers share it.
FIFO ordering applies within each class; up to three interactive starts precede
one waiting background hash. Process timestamps are delivered with exit results.
Reducing the budget does not abandon running workers: queued work waits for sufficient exits.
The new concurrency limit applies when queued processes start; each job retains
the command and options captured when queued. Existing insertion operations retain
their captured document/options. PNG reads and PDF metadata bypass this queue.

## Document Format Adapters

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

`workflow/content` coalesces revision-keyed hash requests, maintains a 128-entry
digest LRU and finds same-directory imports. `workflow/hash_worker` runs only as
an isolated headless-Neovim script: it owns bounded file bytes and encoding/hash
allocations. Each subscriber can cancel independently; the last owner cancels
the queued/running worker. Both worker and parent recheck file revisions before
delivery. `workflow/insert` records reused outputs separately from newly
created files so rollback cannot delete existing resources. `workflow/assets`
uses `document.enumerate` to scan adapter-owned references in scheduled batches.
Its document mode lists possibly unused regular files in one import directory.
`workflow/asset_project` discovers project documents asynchronously, prefers live
buffers, and supplies private document path/filetype overrides to unnamed scratch
buffers for disk text. It combines reference locations before recursively checking
the union of import directories. Directory stats run in 32-entry batches;
shared live-buffer observers and request-owned events invalidate changed scans.
Entry/byte/line budgets flag incomplete reports; full final buffer snapshots and
disk revision rechecks reject stale results. Neither mode
modifies source documents or assets.

## Formula previews

`document/math` uses its own `syntax_cache` namespace alongside image syntax.
It checks a bounded local neighborhood before building prefix context, preserves
byte columns and inclusive row ranges, and only looks ahead within formula/scan
budgets. `document/init` combines formula/image selection in source order while
asset enumeration continues to call image adapters directly. Formula references
carry standalone TeX and an `image-tools-math:` content identity; no temporary
files are created during lookup.

Runtime and the floating preview pass the selected source as `_formula` through
the existing render session. `media/prepare` coalesces formulas and owns subscriber
leases, dispatching workers to `media/math`. That worker runs latex then dvipng
through the shared queue, validates a temporary PNG, and atomically publishes it
into the same managed disk cache. It owns private workspace cleanup and a worker
lease; each delivered subscriber retains its own output lease. Formula compilation
does not read a document preamble or run a project build. Cached color is resolved
from Normal or an explicit RGB value and participates in the content key.
Formula images retain full raster dimensions for validation, diagnostics and
upload, plus a logical `display_size` at a fixed 180-DPI baseline. The floating
preview fits that logical size, so the default 360-DPI raster supplies additional
detail without scaling up the formula window. Cache reads restore the same metadata.

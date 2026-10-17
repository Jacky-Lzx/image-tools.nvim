# Runtime lifecycle

`init.lua` is the public facade. It keeps one private Runtime reference and lazily
configures the plugin for operations that need it. Requiring the module, checking
status, closing, or clearing an unconfigured preview does not register handlers.

`config.resolve()` builds an independent options table and validates it before
replacement starts. Invalid configuration or constructor failure leaves the
active instance intact. `setup()` destroys the previous instance, starts the
replacement, and cleans up a failed start so setup can be retried.

Construction creates the file-buffer service so `BufReadCmd` interception is
ready immediately. The floating controller is created only when a preview is
requested. A lazy `pixel_pool` dependency creates one shared pool on the first
file canvas, inline placement, float or picker view, then caches it for subsequent views. Closing,
clearing, diagnostics and teardown inspect only existing render resources.
`status().terminal_cache` is absent until a pool or injected preview transfer
exists. File-only `info()` reads the pool directly without constructing a float.
Errors from deferred render constructors occur on first use rather than setup;
configuration and file-buffer constructor validation still precede replacement.
Default insertion settings skip unused helper modules; supplied settings retain
their eager validation. Unsupported filetypes consult only the adapter registry
instead of loading document lookup/path services during scheduled refreshes.

The README lazy.nvim spec combines `ft`, `cmd` and `BufReadCmd` patterns. The
binary-file event lets lazy.nvim load setup and replay the read event into the
new file-buffer handlers, including for startup files. Custom adapter filetypes
and buffer extensions need matching lazy.nvim triggers.

`runtime.lua` owns the configuration, floating preview, file-buffer service,
picker renderers, autocmd group, and commands. Its methods use instance fields;
callbacks capture their runtime instead of consulting mutable module state.
Refresh requests are coalesced and ignored once their instance is disposed.
Preview/conversion and buffer metadata cancellation remain in their respective
services; destroying the Runtime delegates cleanup to them. Render controllers
live in `render/`, insertion/clipboard/picker services in `workflow/`, and cache
and conversion services in `media/`. Default dependencies resolve through these
module paths; injected dependency keys remain unchanged.

`commands.lua` registers the existing commands against that Runtime. Destruction
marks the instance disposed before deleting handlers or closing windows, preventing
old callbacks from acting during cleanup. Cleanup is idempotent.

File insertion and clipboard import retain their independent source contexts,
captured document adapter and returned cancellation handles. Public adapter
replacement/removal invalidates pending imports and refreshes current reference
previews. Templates, processing presets and naming rules use the operation's
captured options and document. Reconfiguration does not change the captured
options of an already-started insertion. The Runtime dependency interface allows
controller and document services to be replaced in lifecycle tests.

The Runtime is internal. The supported user-facing API and single active editor
configuration remain `require("image_tools")`; multiple concurrently started
runtimes are not supported because the commands and autocmd groups have fixed names.

Reference previews first query `document.at_cursor` with Neovim's byte column.
Only a selection `miss` falls back to the first reference on the line; errors in
an explicitly selected destination remain errors. Horizontal movement rechecks
selection, while an unchanged source retains its window and preparation handle.
Pending syntax requests capture the column as well as buffer/window/version and
range. Moving between rows of that LaTeX range keeps a pending request valid when
the byte column is unchanged. Selection changes invalidate the old request;
delayed callbacks cannot restore a reference after its range is left.

`close()` closes only the floating preview. `clear_cache()` also destroys picker
renderers, pauses inline virtual-line views, closes file-buffer canvases and clears the shared pixel pool. File
buffers stay attached but paused until buffer/tab entry, resume, explicit opening
or reload refreshes them. Disk conversions are independent; use
`clear_disk_cache(callback)` / `:ImageCacheClear` to remove unused disk outputs
manually, in addition to automatic disk-cache eviction.

Floating previews retain the most recent failure as metadata after releasing all
render resources. info() falls back to that diagnostic when no viewer is active;
setup replacement drops it. Render sessions expose preparing/placing/ready stages
and remember the failing stage. A request-owned delayed line-end hint is removed
on drawing, failure or cancellation, without changing document text.
`info().timings` returns independent per-view phase measurements. Sessions clip
shared converter timestamps to their own lifetime and combine transfer wait
measurements with lookup/automatic-delay metadata. Completion/failure freezes
the measurements; retained failure metadata includes the same timing snapshot.

New automatic selections retain a request-owned delay timer before media work
starts. Selection remains live during the wait. Same-source movement updates
authority without restarting the timer; a different source replaces it. Closing,
clearing or replacing the Runtime cancels it. Manual hover/preview bypasses the
delay and invalidates queued automatic work.

Formula selections carry a content identity plus standalone TeX, following the
same automatic delay, owner/version/range checks and session cancellation as
images. The identity bypasses filesystem path normalization and is reported as
`format = "math"` by `info()`. Reload retains the captured TeX. Formula edits
change the identity and replace pending/visible work; surrounding edits retain
unchanged pixels. The media service owns compilation, coalescing and output
leases; document lookup never spawns processes or writes files.

Inline Markdown is disabled by default and its controller/recognizer stay deferred.
Enabling it constructs the redraw scheduler; terminal pixels are still deferred
until a visible eligible reference needs a placement. `toggle_inline()` controls
it independently of floating auto_preview. Automatic hover yields to inline
eligibility, while manual previews keep their ordinary behavior.

The controller tracks current-tab regular windows and source versions. Cursor,
scroll, layout, option, buffer and redraw events schedule a coalesced sync;
text/name/filetype/unload and colorscheme changes invalidate affected entries.
The provider never runs processes or mutates text. Clear/suspend cancels its timer
and pauses all inline views; buffer/window entry or resume explicitly restarts
them. Runtime marks itself disposed before destroying sessions, then removes the
provider. Late callbacks cannot recreate extmarks in closed/hidden windows.
`info()` may select an inline item at the source cursor when no float/file viewer
is selected; `reload()` invalidates current-document inline views, including URL
cache refresh, in that same fallback case.

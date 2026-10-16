# Runtime lifecycle

`init.lua` is the public facade. It keeps one private Runtime reference and lazily
configures the plugin for operations that need it. Requiring the module, checking
status, closing, or clearing an unconfigured preview does not register handlers.

`config.resolve()` builds an independent options table and validates it before
replacement starts. Invalid configuration or constructor failure leaves the
active instance intact. `setup()` destroys the previous instance, starts the
replacement, and cleans up a failed start so setup can be retried.

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

File insertion and clipboard import retain their independent source contexts and
returned cancellation handles. Reconfiguration does not change the captured
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
renderers, closes file-buffer canvases and clears the shared pixel pool. File
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

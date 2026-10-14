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
services; destroying the Runtime delegates cleanup to them.

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
range, so delayed completion resumes the most recent selected reference.

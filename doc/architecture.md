# Module layout

The public `image_tools` API stays in `init.lua`. Configuration, commands and
runtime lifecycle are provided by `config.lua`, `commands.lua` and `runtime.lua`.

Document reference processing lives in one subsystem:

```
lua/image_tools/document/
  init.lua          filetype dispatch and existing document API
  markdown.lua      inline image parsing and fenced-code context
  tex.lua           includegraphics, graphicspath and excluded environments
  typst.lua         image calls, lexical context and literal strings
  paths.lua         shared resolution, project roots and path validation
  syntax_cache.lua  buffer-scoped results and prefix checkpoints
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
`cached()` method rather than its entry table. Clearing a shared transfer releases only its leases; clearing a standalone
transfer also frees its private pool. Clearing the pool frees all owned terminal
pixels.

## Render sessions

Floating previews, file canvases and Snacks renderers supply their own authority,
viewport, window policy and error presentation. `render_session` owns the common
prepare/placement sequence and releases both handles on close, stale completion,
or drawing failure. It also releases handles returned after a synchronous close.
`geometry` supplies aspect-ratio fitting; `placeholder` draws the Kitty grid and
placement highlight. These helpers do not depend on a particular controller.

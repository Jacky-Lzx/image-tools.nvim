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

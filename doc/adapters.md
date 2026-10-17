# Document adapter API

`require("image_tools").register_adapter(filetype, definition)` registers a custom
filetype and returns a generation-specific unregister function. Re-registering a
custom filetype replaces it; an older cleanup function cannot remove a newer
registration. `unregister_adapter(filetype)` removes the current custom adapter
and returns whether it existed. Built-in Markdown, tex/latex/plaintex, Typst and
HTML adapters are protected; use `insert.template` to customize their markup.

Registration does not initialize a Runtime and survives `setup()` calls. Definitions
and format lists are copied. Pending imports capture adapter identity; replacing
or removing it invalidates their final commit and rolls back newly copied files.
Current reference previews refresh when the public API changes their adapter.
Asset inspection also rejects results after its adapter changes; project scans
reject results if the registration registry changes during discovery/enumeration.

## Insertion-only adapter

```lua
local remove = require("image_tools").register_adapter("org", {
  image_formats = { "png", "jpg", "jpeg" },
  markup = "[[file:$FILE_PATH]]$CURSOR",
})
```

`image_formats` is a nonempty list of lowercase extensions supported by the media
pipeline. It controls insertion validation, clipboard defaults, processing menu
filtering and picker formats. `markup` is a string with the insertion template
placeholders, or `function(path, alt)` returning text and an optional zero-based
byte offset including newlines. Without an offset, editing starts at the end.
Markup must be nonempty and contain no NUL bytes. A function owns escaping for
the document syntax; string-template values are literal/raw.

Optional hooks match the built-in adapter contract:

- `insertion_base(document, opts, buf)` returns the directory used for references;
  defaults to the shared configured-root/document-directory policy.
- `sanitize_filename(name)` returns the copied basename to publish.
- `validate_reference(path, document, opts, buf)` raises an error for invalid roots
  or resource boundaries before markup is committed.
- `find(buf, row, col, opts)` resolves a selected reference for previews.
- `references(buf, row, opts)` enumerates references for asset inspection.
- `path_edit(buf, reference, relative_target, opts)` enables image moves and returns
  `{ row, first, last, text }`: a one-based row, zero-based start and exclusive end
  byte columns, and a single-line replacement destination. Preserve other markup.
  A shared definition may return the same range for multiple references; moves
  deduplicate it. Missing hooks reject moves that would affect this adapter.
- `file_extensions`, e.g. `{ "org" }`, enables offline project discovery when
  `references` is supplied. Defaults to a simple lowercase filetype name; use an
  empty list to disable discovery. Extension conflicts are rejected.

Insertion-only adapters report a preview lookup miss. Asset inspection reports
an enumeration error rather than classifying every file as unused. Their offline
extensions are not registered for project scans.

## Reference callback example

This minimal extension recognizes one literal Org-style file link per line. A
complete Org adapter should also handle its code/comment/escape exclusions and
additional link syntax.

```lua
local api = require("image_tools")
local paths = require("image_tools.document.paths")
local function references(buf, row, opts)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local first, last, src = line:find("%[%[file:(.-)%]%]")
  if not first then return {} end
  local path, err = paths.resolve(src,
    opts._document_path or vim.api.nvim_buf_get_name(buf),
    vim.tbl_extend("force", opts, { literal = true }))
  return {{ path = path, error = err, reference = {
    src = src, start_row = row, end_row = row,
    start_col = first - 1, end_col = last,
  } }}
end

api.register_adapter("org", {
  image_formats = { "png", "jpg", "jpeg" },
  file_extensions = { "org" },
  markup = "[[file:$FILE_PATH]]$CURSOR",
  references = references,
  find = function(buf, row, col, opts)
    for _, item in ipairs(references(buf, row, opts)) do
      local ref = item.reference
      if col == nil or (col >= ref.start_col and col < ref.end_col) then
        return item.path, item.error, nil, ref
      end
    end
    return nil, "No image reference", "miss"
  end,
})
```

Rows are one-based; columns are zero-based byte offsets, with an exclusive ending
column. `find` returns `path, error, status, reference`; a selected path error must
retain its range so it cannot fall back to a different image. Only `status="miss"`
permits cursor-to-line fallback. `references` returns a list of resolved entries
with absolute `path` or `error`, plus a range containing start/end rows and columns.
Offline inspection supplies `opts._document_path` because its scratch buffer is
unnamed. Both callbacks should apply the same syntax exclusions and root rules.

## HTML scope

The built-in HTML adapter recognizes literal same-line `img` tags with quoted or
unquoted `src`. It tracks multiline comments and script/style/pre/code exclusions
through the shared syntax cache. It decodes amp/quot/apos/lt/gt and numeric
entities, uses byte ranges for multiple images on a line and updates after edits.
Insertion percent-encodes paths and escapes alt attributes; editing starts inside
alt text. Supported formats are PNG/JPEG/GIF/WebP/AVIF/BMP/SVG. It does not evaluate
the DOM, JavaScript, template expressions, srcset, remote URLs or multiline img tags.

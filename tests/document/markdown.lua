vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local D = require("image_tools.document")
local opts = { max_scan_lines = 1000 }
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(buf, "/private/tmp/note.md")
vim.bo[buf].filetype = "markdown"
local function check(lines, row, expected, col)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local path = col and D.at_cursor(buf, row, col, opts) or D.at_line(buf, row, opts)
  assert(path == expected, vim.inspect({ path, expected, lines }))
end
check({ "![figure][ A  B ]", '[a b]: <images/a b.png> "title"' }, 1, "/private/tmp/images/a b.png")
check({ "![a][]", "[a]: first.png", "[a]: second.png" }, 1, "/private/tmp/first.png")
check({ "![a]", "[a]: first.png" }, 1, "/private/tmp/first.png")
check({ "![a][id]", "```", "[id]: hidden.png", "```" }, 1, nil)
check({ "![a][id]", "    [id]: hidden.png" }, 1, nil)
check({ "```", "![a][id]", "```", "[id]: a.png" }, 2, nil)
check({ "`![a][id]`", "[id]: a.png" }, 1, nil)
check({ "![a][id]", "[id]: https://example.com/a.png" }, 1, nil)
check({ "![a][missing] ![b](b.png)" }, 1, "/private/tmp/b.png", 20)
check({ "![[images/a%20b.png|200]]" }, 1, "/private/tmp/images/a%20b.png")
check({ "![[note.md]]" }, 1, nil)
check({ "![a][id]", "[id]: replacement.png" }, 1, "/private/tmp/replacement.png")
opts.max_scan_lines = 1
check({ "![a][id]", "[id]: beyond.png" }, 1, nil)
opts.max_scan_lines = 10000
local lines = {}
for i = 1, 1024 do
  lines[i] = "ordinary text"
end
lines[1], lines[2], lines[900] = "![a][id]", "[id]: first.png", "[id]: second.png"
check(lines, 1, "/private/tmp/first.png")
local get_lines, fetched = vim.api.nvim_buf_get_lines, 0
vim.api.nvim_buf_get_lines = function(...)
  local result = get_lines(...)
  fetched = fetched + #result
  return result
end
vim.api.nvim_buf_set_lines(buf, 1000, 1001, false, { "tail edit" })
assert(D.at_line(buf, 1, opts) == "/private/tmp/first.png")
vim.api.nvim_buf_get_lines = get_lines
assert(fetched <= 130, "Tail edits retain earlier definition blocks plus the local formula check")
-- Removing the winning definition reveals a later duplicate; inserted/deleted
-- rows and changed fence context must invalidate all affected suffix blocks.
vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
assert(D.at_line(buf, 1, opts) == "/private/tmp/second.png")
vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "```" })
assert(D.at_line(buf, 1, opts) == nil)
vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "```", "[id]: restored.png" })
assert(D.at_line(buf, 1, opts) == "/private/tmp/restored.png")
-- Scan-limit changes cannot reuse an index built with a different ceiling.
opts.max_scan_lines = 2
assert(D.at_line(buf, 1, opts) == nil)
opts.max_scan_lines = 10000
assert(D.at_line(buf, 1, opts) == "/private/tmp/restored.png")
vim.api.nvim_buf_delete(buf, { force = true })
print("Markdown references: lookup, incremental definitions, duplicate/fence edits and scan limits passed")

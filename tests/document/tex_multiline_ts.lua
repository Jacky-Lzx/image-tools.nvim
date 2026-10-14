vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
vim.opt.rtp:append(assert(vim.env.IMAGE_TOOLS_PARSER_ROOT))
vim.g._ts_force_sync_parsing = true
local D, TS, C =
  require("image_tools.document"),
  require("image_tools.document.treesitter"),
  require("image_tools.document.syntax_cache")
local tmp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP))
local count, serial = 0, 0
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local function buffer(lines)
  serial = serial + 1
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, tmp .. "/ts-multiline-" .. serial .. ".tex")
  vim.bo[buf].filetype = "tex"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end
vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", tmp .. "/a.png")
vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", tmp .. "/b.png")
local opts = require("image_tools.config").resolve()
local sample = { [[  \includegraphics[]], [[  % width=\linewidth,]], [[  % keepaspectratio]], [[  ]{a.png}]] }
local buf = buffer(sample)
local fallback = C.query
C.query = function()
  error("Real Tree-sitter must handle complete multiline syntax without fallback")
end
for row = 1, 4 do
  local path, _, _, reference = D.at_line(buf, row, opts)
  check(path == tmp .. "/a.png", "Real tree previews row " .. row)
  check(
    reference.start_row == 1 and reference.end_row == 4 and reference.start_col == 2 and reference.end_col == 10,
    "Tree range preserves buffer coordinates"
  )
end
check(
  TS.query(buf, 4, "latex").candidates[1] == TS.query(buf, 1, "latex").candidates[1],
  "Rows share one reference object"
)
local before = TS.status(buf).indexed_rows
TS.query(buf, 4, "latex")
check(TS.status(buf).indexed_rows == before, "Warm range lookup skips capture traversal")
-- Editing the end of a range invalidates its cached beginning too.
vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "  ]{b.png}" })
check(D.at_line(buf, 1, opts) == tmp .. "/b.png", "End edit refreshes opening row")
vim.api.nvim_buf_set_lines(buf, 1, 2, false, { " width=1cm" })
check(D.at_line(buf, 3, opts) == tmp .. "/b.png", "Option edit rebuilds covering reference")
vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "" })
check(D.at_line(buf, 5, opts) == tmp .. "/b.png", "Insertion shifts end range")
vim.api.nvim_buf_set_lines(buf, 2, 3, false, {})
check(D.at_line(buf, 4, opts) == tmp .. "/b.png", "Deletion restores end range")
local limits = vim.tbl_deep_extend("force", opts, { latex = { max_reference_lines = 2 } })
check(
  not TS.query(buf, 1, "latex", nil, limits).candidates[1],
  "Reduced limits invalidate tree index without text edit"
)
check(D.at_line(buf, 1, opts) == tmp .. "/b.png", "Restoring policy rebuilds index")
check(
  not TS.query(buf, 1, "latex", nil, { max_scan_lines = 2 }).candidates[1],
  "Whole reference must fit document scan limit"
)
check(D.at_line(buf, 4, opts) == tmp .. "/b.png", "Changed scan ceiling does not poison later query")
for _, lines in ipairs({
  { [[\includegraphics*[]], [[width=1cm]], [[ ]{a.png}]] },
  { [[\includegraphics[]], [[ width=1cm]], [[ ]{\detokenize{a.png}}]] },
  { [[\includegraphics]], [[{a.png}]] },
}) do
  check(D.at_line(buffer(lines), #lines, opts) == tmp .. "/a.png", "Literal multiline compatibility")
end
local two = buffer({ [[\includegraphics[]], [[ ]{a.png} \includegraphics[]], [[ ]{b.png}]] })
check(D.at_line(two, 2, opts) == tmp .. "/a.png", "Earlier command wins shared row")
check(D.at_cursor(two, 2, 20, opts) == tmp .. "/b.png", "Column selects later multiline command")
local eof = buffer({ [[\includegraphics[]], [[ ]{a.png}]] })
check(not D.at_cursor(eof, 2, 10, opts), "End coordinate is exclusive")
C.query = fallback
vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "  ]{b.png" })
check(not D.at_line(buf, 1, opts), "Removing close brace cannot preserve stale range")
print("multiline LaTeX treesitter: " .. count .. " assertions passed")

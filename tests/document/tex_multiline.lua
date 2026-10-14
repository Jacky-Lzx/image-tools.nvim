vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local D, R, config =
  require("image_tools.document"), require("image_tools.document.tex.reference"), require("image_tools.config")
local tmp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP))
local checks, serial = 0, 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function buffer(lines)
  serial = serial + 1
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, tmp .. "/multiline-" .. serial .. ".tex")
  vim.bo[buf].filetype = "tex"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end
vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixture.png", tmp .. "/a.png")
vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixture.png", tmp .. "/b.png")
vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixture.png", tmp .. "/space #%.png")
vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixture.png", tmp .. "/space #.png")
local opts = config.resolve({ treesitter = false })
local sample = {
  [[  \includegraphics[]],
  [[    % scale=0.6]],
  [[    % width=\linewidth,]],
  [[    % height=3cm,]],
  [[    % keepaspectratio]],
  [[  ]{a.png}]],
}
-- Long bracket strings above keep the literal opening '['.
local buf = buffer(sample)
for row = 1, 6 do
  local path, _, _, reference = D.at_line(buf, row, opts)
  check(path == tmp .. "/a.png", "Lua fallback previews every row: " .. row)
  check(
    reference.start_row == 1 and reference.end_row == 6 and reference.start_col == 2 and reference.end_col == 10,
    "Original byte positions preserved through comments"
  )
end
check(not D.at_cursor(buf, 1, 0, opts), "Column before opening command excluded")
check(D.at_cursor(buf, 3, 0, opts) == tmp .. "/a.png", "Intermediate row accepts any column")
check(not D.at_cursor(buf, 6, 10, opts), "Column after closing brace excluded")
local variants = {
  { [[\includegraphics]], [[*]], [[{a.png}]] },
  { [[\includegraphics*]], [[ [width=1cm] ]], [[ {\detokenize{space #.png}}]] },
  { [[\includegraphics% ignored ]{b.png}]], [[ [width=1cm]% ignored]], [[ {a.png}]] },
  { [[\includegraphics]], [[{space \#\%.png}]] },
}
-- A star must directly follow the command, as in the existing syntax contract.
check(not D.at_line(buffer(variants[1]), 2, opts), "Detached star is not guessed")
for i = 2, #variants do
  local path = D.at_line(buffer(variants[i]), 2, opts)
  check(
    path == tmp .. (i == 2 and "/space #.png" or i == 3 and "/a.png" or "/space #%.png"),
    "Literal compatibility " .. i
  )
end
for _, environment in ipairs({ "verbatim", "lstlisting", "minted", "comment" }) do
  local lines = { "\\begin{" .. environment .. "}" }
  vim.list_extend(lines, sample)
  lines[#lines + 1] = "\\end{" .. environment .. "}"
  check(not D.at_line(buffer(lines), 7, opts), "Excluded context: " .. environment)
end
check(not D.at_line(buffer({ [[% \includegraphics[]], [[ ]{a.png}]] }), 2, opts), "Commented command excluded")
check(not D.at_line(buffer({ [[\verb|\includegraphics[|]], [[ ]{a.png}]] }), 2, opts), "Inline verb command excluded")
check(not D.at_line(buffer({ [[\includegraphics[]], [[ broken]], [[ {a.png}]] }), 2, opts), "Unclosed option rejected")
check(not D.at_line(buffer({ [[\includegraphics]], [[ {a]], [[ .png}]] }), 2, opts), "Filename across lines rejected")
check(not D.at_line(buffer({ [[\includegraphics]], [[ {\macro.png}]] }), 2, opts), "Dynamic path rejected")
check(not D.at_line(buffer({ [[\\includegraphics[]], [[ ]{a.png}]] }), 2, opts), "Escaped command rejected")
local bounded = vim.tbl_deep_extend("force", opts, { latex = { max_reference_lines = 3 } })
check(not D.at_line(buf, 6, bounded), "Reference outside line budget rejected")
bounded = vim.tbl_deep_extend("force", opts, { latex = { max_reference_bytes = 20 } })
check(not D.at_line(buf, 6, bounded), "Reference outside byte budget rejected")
check(
  not D.at_line(buf, 1, vim.tbl_extend("force", opts, { max_scan_lines = 3 })),
  "Lookahead respects document scan ceiling"
)
check(not pcall(config.resolve, { latex = { max_reference_lines = 0 } }), "Positive line budget validated")
check(not pcall(config.resolve, { latex = { max_reference_bytes = 1.5 } }), "Integral byte budget validated")
-- Starts before a checkpoint: context and original row positions survive.
local lines = {}
for row = 1, 125 do
  lines[row] = "ordinary"
end
vim.list_extend(lines, sample)
local crossing = buffer(lines)
check(D.at_line(crossing, 130, opts) == tmp .. "/a.png", "Multiline command crosses checkpoint")
vim.api.nvim_buf_set_lines(crossing, 130, 131, false, { "  ]{b.png}" })
check(D.at_line(crossing, 127, opts) == tmp .. "/b.png", "Forward path edit updates preceding row")
vim.api.nvim_buf_set_lines(crossing, 0, 1, false, { "\\begin{verbatim}" })
check(not D.at_line(crossing, 130, opts), "Prefix context edit invalidates fallback")
-- Same-line compatibility, multiple images and no neighboring-line false positives.
local mixed = buffer({ [[\includegraphics[a]{a.png} \includegraphics[b]{b.png}]], "ordinary" })
check(D.at_line(mixed, 1, opts) == tmp .. "/a.png", "First reference wins")
check(D.at_cursor(mixed, 1, 40, opts) == tmp .. "/b.png", "Column selects second reference")
check(not D.at_line(mixed, 2, opts), "Completed previous reference does not match later row")
print("multiline LaTeX lexer: " .. checks .. " assertions passed")

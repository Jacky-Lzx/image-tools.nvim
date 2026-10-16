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
vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", tmp .. "/a.png")
vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", tmp .. "/b.png")
vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", tmp .. "/space #%.png")
vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", tmp .. "/space #.png")
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
local malformed = buffer({ [[\includegraphics[]], "unfinished", [[\includegraphics{b.png}]] })
check(not D.at_line(malformed, 1, opts), "Unclosed earlier option is not guessed")
check(
  D.at_line(malformed, 3, opts) == tmp .. "/b.png",
  "Unclosed earlier command does not hide a later complete reference"
)
local limits = { latex = { max_reference_bytes = 4 } }
check(#R.parse([[\includegraphics{a.png}]], 1, limits) == 0, "Decoder applies byte budget to actual command")
local cached = buffer({ [[\includegraphics[]], [[ ]{a.png}]], "ordinary" })
local parse, decodes = R.parse, 0
R.parse = function(...)
  decodes = decodes + 1
  return parse(...)
end
local candidates = R.nearby(cached, 1, opts)
candidates[1].src = "caller mutation"
check(R.nearby(cached, 1, opts)[1].src == "a.png" and decodes == 1, "Warm decoding is cached with independent results")
vim.api.nvim_buf_set_lines(cached, 1, 2, false, { " ]{b.png}" })
check(R.nearby(cached, 1, opts)[1].src == "b.png" and decodes == 2, "Forward edits invalidate the preceding query")
-- Cached lookahead must account for appended text beyond the old end of file.
vim.api.nvim_buf_set_lines(cached, 0, -1, false, { [[\includegraphics[]] })
check(#R.nearby(cached, 1, opts) == 0, "Incomplete reference cached")
vim.api.nvim_buf_set_lines(cached, 1, 1, false, { " ]{a.png}" })
check(R.nearby(cached, 1, opts)[1].src == "a.png", "Appending completes an earlier cached reference")
check(#R.nearby(cached, 1, bounded) == 0, "Changed budgets do not reuse permissive decoding")
-- An edit beyond a query's bounded lookahead preserves its cached decoding.
local distant = {}
for i = 1, 200 do
  distant[i] = "ordinary"
end
distant[1] = [[\includegraphics{a.png}]]
vim.api.nvim_buf_set_lines(cached, 0, -1, false, distant)
R.nearby(cached, 1, opts)
local before = decodes
vim.api.nvim_buf_set_lines(cached, 150, 151, false, { "suffix edit" })
check(R.nearby(cached, 1, opts)[1].src == "a.png" and decodes == before, "Distant edits preserve cached neighborhoods")
vim.api.nvim_buf_set_lines(cached, 0, 0, false, { "inserted" })
check(
  #R.nearby(cached, 1, opts) == 0 and R.nearby(cached, 2, opts)[1].src == "a.png",
  "Insertion invalidates shifted rows"
)
-- Eviction and unload must allow reconstruction without retaining stale text.
for row = 2, 140 do
  R.nearby(cached, row, opts)
end
check(R.nearby(cached, 2, opts)[1].src == "a.png", "Evicted neighborhoods reconstruct correctly")
vim.cmd("bunload! " .. cached)
vim.fn.bufload(cached)
vim.api.nvim_buf_set_lines(cached, 0, -1, false, { [[\includegraphics{b.png}]] })
check(R.nearby(cached, 1, opts)[1].src == "b.png", "Unload releases decoded neighborhoods")
local adjacent = buffer({
  [[\includegraphics[]],
  [[ width=1cm,]],
  [[ height=2cm]],
  [[ ]{a.png}]],
  [[\includegraphics{b.png}]],
})
local initial = decodes
for row = 1, 4 do
  check(R.nearby(adjacent, row, opts)[1].src == "a.png", "Shared decode covers adjacent row " .. row)
end
check(decodes == initial + 1, "Adjacent rows decode a multiline command only once")
check(
  R.nearby(adjacent, 5, opts)[1].src == "b.png" and decodes == initial + 2,
  "Only a new command needs another decode"
)
vim.api.nvim_buf_set_lines(adjacent, 3, 4, false, { " ]{b.png}" })
check(R.nearby(adjacent, 2, opts)[1].src == "b.png", "Editing shared lookahead invalidates every affected row")
local nested = buffer({ [[\includegraphics[width=\includegraphics{fake.png}]{a.png}]] })
local refs = R.nearby(nested, 1, opts)
check(#refs == 1 and refs[1].src == "a.png", "Command index does not expose nested option commands")
-- Oversized neighboring lines never enter the block index as complete strings.
local long = buffer({ [[\includegraphics{a.png}]], string.rep("x", 1024 * 1024) })
local get_lines, fetched = vim.api.nvim_buf_get_lines, 0
vim.api.nvim_buf_get_lines = function(...)
  local lines = get_lines(...)
  for _, line in ipairs(lines) do
    fetched = fetched + #line
  end
  return lines
end
check(R.nearby(long, 1, opts)[1].src == "a.png", "Long neighboring line preserves a valid short reference")
vim.api.nvim_buf_get_lines = get_lines
check(fetched < opts.latex.max_reference_bytes, "Indexing does not copy an oversized neighboring line")
local many = {}
for row = 1, 300 do
  many[row] = [[\includegraphics{a.png}]]
end
local eviction = buffer(many)
for row = 1, #many do
  R.nearby(eviction, row, opts)
end
check(R.nearby(eviction, 1, opts)[1].src == "a.png", "Evicted anchored decodes rebuild correctly")
-- A malformed command outside its own line budget must not absorb a later image.
local incomplete = buffer({ [[\includegraphics{]], "ordinary", "ordinary", [[\includegraphics{b.png}]], "}" })
check(
  R.nearby(incomplete, 4, config.resolve({ latex = { max_reference_lines = 3 } }))[1].src == "b.png",
  "Over-budget earlier commands cannot hide a complete later image"
)
R.parse = parse
print("multiline LaTeX lexer: " .. checks .. " assertions passed")

vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local document, config = require("image_tools.document"), require("image_tools.config")
local opts = config.resolve({ treesitter = false })
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function buffer(ft, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "/tmp/image-tools-math-" .. buf .. "." .. ft)
  vim.bo[buf].filetype = ft
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end
local function formula(buf, row, col, settings)
  local path, err, _, ref
  if col then
    path, err, _, ref = document.at_cursor(buf, row, col, settings or opts)
  else
    path, err, _, ref = document.at_line(buf, row, settings or opts)
  end
  if path then
    check(path:match("^image%-tools%-math:") and ref.kind == "math", "Formula has a logical identity")
    return ref
  end
  return nil, err
end
for _, ft in ipairs({ "markdown", "tex", "latex", "plaintex" }) do
  for _, source in ipairs({ [[$x^2 + y^2$]], [[$$\frac{a}{b}$$]], [[\(\alpha+1\)]], [=[\[\sum_i x_i\]]=] }) do
    local buf = buffer(ft, { "前缀 " .. source .. " suffix" })
    local ref = assert(formula(buf, 1, #"前缀 "))
    check(
      ref.formula == source and ref.start_col == #"前缀 " and ref.end_col == #"前缀 " + #source,
      "Original UTF-8 byte columns"
    )
    check(not formula(buf, 1, ref.end_col), "End column is exclusive")
  end
  for _, environment in ipairs({
    "equation",
    "align*",
    "gather",
    "multline",
    "alignat*",
    "flalign",
    "eqnarray",
    "displaymath",
    "math",
  }) do
    local buf = buffer(
      ft,
      { "\\begin{" .. environment .. "}", [[a &= b \\]], "c &= d", "\\end{" .. environment .. "}", "outside" }
    )
    local first = assert(formula(buf, 1))
    for row = 2, 4 do
      local ref = assert(formula(buf, row))
      check(
        ref.path == first.path and ref.start_row == 1 and ref.end_row == 4,
        "Every covered row selects the same formula"
      )
    end
    check(not formula(buf, 5), "Outside completed environment")
  end
end
local md = buffer("markdown", {
  "```math",
  "$hidden$",
  "```",
  "    $indented$",
  "`$code$` $visible$",
  "<!--",
  "$comment$",
  "-->",
  [[$$]],
  [[\frac{a}{b}]],
  [[$$]],
  "outside",
})
for _, row in ipairs({ 1, 2, 3, 4, 6, 7, 8, 12 }) do
  check(not formula(md, row), "Markdown excluded row " .. row)
end
check(formula(md, 5).formula == "$visible$", "Skip inline code")
check(formula(md, 10).start_row == 9 and formula(md, 10).end_row == 11, "Multiline dollars")
local tex = buffer("tex", {
  "% $comment$",
  "\\verb|$code$| $visible$",
  "\\begin{minted}{tex}",
  "$hidden$",
  "\\end{minted}",
  "\\[ a % ignored \\]",
  "+ b \\]",
  "\\$escaped",
  "outside",
})
for _, row in ipairs({ 1, 3, 4, 5, 8, 9 }) do
  check(not formula(tex, row), "TeX excluded row " .. row)
end
check(formula(tex, 2).formula == "$visible$", "TeX inline verbatim")
check(formula(tex, 6).end_row == 7, "TeX comment cannot close formula")
local multiple = buffer("markdown", { [[$a$ and $b$]], "outside" })
check(formula(multiple, 1, 8).formula == "$b$", "Cursor selects second formula")
check(formula(multiple, 1).formula == "$a$", "Line selects first formula")
local _, _, status = document.at_cursor(multiple, 1, 4, opts)
check(status == "miss", "Outside formulas permits line fallback")
check(not formula(multiple, 1, nil, config.resolve({ math = { enabled = false } })), "Rendering can be disabled")
local mixed = buffer("markdown", { [[$a$ ![image](sample.png) $b$]], [[![image](sample.png) $c$]] })
check(formula(mixed, 1).formula == "$a$", "Formula precedes image")
local path = document.at_line(mixed, 2, opts)
check(path and not path:find("image-tools-math:", 1, true), "Image precedes formula")
path = document.at_cursor(mixed, 1, 10, opts)
check(path and not path:find("image-tools-math:", 1, true), "Image under cursor wins")
local limited = config.resolve({ math = { max_lines = 2, max_bytes = 20 } })
check(not formula(md, 10, nil, limited), "Line budget")
check(not formula(buffer("tex", { "$" .. string.rep("x", 21) .. "$" }), 1, nil, limited), "Byte budget")
check(not formula(md, 10, nil, config.resolve({ max_scan_lines = 10 })), "Lookahead scan ceiling")
local edit = buffer("markdown", { "$$", "x^2", "$$" })
local first = formula(edit, 2).path
vim.api.nvim_buf_set_lines(edit, 1, 2, false, { "x^3" })
check(formula(edit, 2).path ~= first, "Formula edit changes identity")
vim.api.nvim_buf_set_lines(edit, 2, 3, false, { "unclosed" })
check(not formula(edit, 2), "Closing delimiter removal invalidates cached lookahead")
local lines = {}
for row = 1, 127 do
  lines[row] = "ordinary"
end
vim.list_extend(lines, { "$$", "x^2", "$$" })
local checkpoint = buffer("markdown", lines)
check(formula(checkpoint, 129).start_row == 128, "Formula crosses prefix checkpoint")
vim.api.nvim_buf_set_lines(checkpoint, 0, 1, false, { "```" })
check(not formula(checkpoint, 129), "Prefix edit invalidates formula context")
for _, bad in ipairs({
  { density = 0 },
  { max_lines = 0 },
  { max_bytes = 0 },
  { foreground = "red" },
  { preamble = false },
  { latex = "" },
  { enabled = 1 },
}) do
  check(not pcall(config.resolve, { math = bad }), "Invalid math configuration rejected")
end
-- A cold ordinary row stays local even near the scan ceiling.
local plain = {}
for row = 1, 10000 do
  plain[row] = "ordinary"
end
local large = buffer("markdown", plain)
local get_lines, fetched = vim.api.nvim_buf_get_lines, 0
vim.api.nvim_buf_get_lines = function(...)
  local result = get_lines(...)
  fetched = fetched + #result
  return result
end
check(not formula(large, 10000), "Ordinary row has no formula")
vim.api.nvim_buf_get_lines = get_lines
check(fetched <= opts.math.max_lines + 1, "Cold ordinary row avoids a full prefix scan")
check(not formula(buffer("markdown", { "\t$code$" }), 1), "Tab-indented code is excluded")
local comment = buffer("markdown", { "$$a % fake $$", " + b$$" })
check(formula(comment, 1).end_row == 2, "TeX comments inside Markdown formulas cannot close delimiters")
check(not formula(buffer("markdown", { "$5 and $10" }), 1), "Currency pair is not a formula")
check(not formula(buffer("markdown", { "$ spaced $" }), 1), "Spaced Markdown dollars are excluded")
local unmatched = buffer("markdown", { "Literal unmatched ` text $same$", "$next$" })
check(formula(unmatched, 1).formula == "$same$", "Unmatched backticks are literal on the same row")
check(formula(unmatched, 2).formula == "$next$", "Unmatched backticks do not hide later formulas")
local span = buffer("markdown", { "`` code ` $hidden$", "$hidden$ `` $visible$", "$after$" })
check(not formula(span, 1), "Exact-length backtick runs open multiline code")
check(formula(span, 2).formula == "$visible$", "Multiline code closes before visible formula")
check(formula(span, 3).formula == "$after$", "Multiline code does not leak after closer")
vim.api.nvim_buf_set_lines(span, 1, 2, false, { "$formerly_code$" })
check(formula(span, 1).formula == "$hidden$", "Removing future code closer invalidates prefix snapshots")
vim.api.nvim_buf_set_lines(span, 1, 2, false, { "$hidden$ `` $visible$" })
check(not formula(span, 1), "Adding future code closer invalidates cached literal opener")
local paragraph = buffer("markdown", { "unmatched `", "", "$visible$ `" })
check(formula(paragraph, 3).formula == "$visible$", "Code spans cannot cross blank paragraphs")
local html = buffer("markdown", {
  '<CODE class="example">$hidden$</CODE> $visible$',
  "<pre>",
  "$hidden$ ` <!--",
  "```",
  "    </pre> $after$",
})
check(formula(html, 1).formula == "$visible$", "HTML code tags support attributes and case-insensitive names")
check(not formula(html, 3), "HTML pre content is excluded")
check(formula(html, 5).formula == "$after$", "HTML code contents cannot leak Markdown state")
vim.api.nvim_buf_set_lines(html, 1, 2, false, { "ordinary" })
check(formula(html, 3).formula == "$hidden$", "Editing HTML opening tag updates later context")
local bounded_code = buffer("markdown", { "` $visible$", "later `" })
check(
  formula(bounded_code, 1, nil, config.resolve({ max_scan_lines = 1 })).formula == "$visible$",
  "Code-span lookahead respects scan ceiling"
)
local prefix = {}
for row = 1, 400 do
  prefix[row] = "ordinary"
end
prefix[10], prefix[11], prefix[257] = "` code", "code `", "$prefix$"
local incremental = buffer("markdown", prefix)
check(formula(incremental, 257).formula == "$prefix$", "Formula prefix cache warmed")
local original_get, reads = vim.api.nvim_buf_get_lines, 0
vim.api.nvim_buf_get_lines = function(...)
  local lines = original_get(...)
  reads = reads + #lines
  return lines
end
vim.api.nvim_buf_set_lines(incremental, 390, 391, false, { "suffix edit" })
check(formula(incremental, 257).formula == "$prefix$", "Unrelated edits retain formula prefix snapshots")
vim.api.nvim_buf_get_lines = original_get
check(reads <= opts.math.max_lines + 1, "Suffix edits do not rescan the formula prefix")
prefix[127], prefix[129], prefix[131] = "` code", "$hidden$", "code ` $visible$"
local future = buffer("markdown", prefix)
check(not formula(future, 129), "Code-span lookahead crosses a checkpoint")
vim.api.nvim_buf_set_lines(future, 130, 131, false, { "no closer" })
check(formula(future, 129).formula == "$hidden$", "Future edit invalidates a preceding code-span checkpoint")
print("document math: " .. checks .. " assertions passed")

vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local inline = require("image_tools.document.inline")
local opts = require("image_tools.config").resolve({ inline = { enabled = true, max_images = 30 } })
vim.o.lines = 70
vim.api.nvim_win_set_height(0, 65)
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, vim.env.IMAGE_TOOLS_TEST_TMP .. "/inline.md")
vim.bo[buf].filetype = "markdown"
local source = {
  "![image](fixture.png)",
  "  ![reference][id]  ",
  "![[fixture.png|label]]",
  "text ![embedded](fixture.png)",
  "![one](fixture.png) ![two](fixture.png)",
  "- ![list](fixture.png)",
  "`![code](fixture.png)`",
  "```markdown",
  "![fenced](fixture.png)",
  "$$code$$",
  "```",
  "    ![indented](fixture.png)",
  "$inline$",
  "\\(inline\\)",
  "text $$mixed$$",
  "$$standalone$$",
  "$$",
  "x^2 + y^2",
  "$$",
  "\\[",
  "\\frac{a}{b}",
  "\\]",
  "\\begin{equation}",
  "x=y",
  "\\end{equation}",
  "\\begin{math}inline\\end{math}",
  "[id]: fixture.png",
  "![last](last.png)",
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
vim.cmd.redraw()
local result = inline.collect(buf, vim.api.nvim_get_current_win(), opts)
local rows = {}
for _, item in ipairs(result) do
  rows[#rows + 1] = item.reference.start_row
end
assert(vim.deep_equal(rows, { 1, 2, 3, 16, 17, 20, 23, 28 }), vim.inspect(rows))
assert(result[2].path:match("fixture.png$") and result[4].reference.kind == "math")
assert(result[5].reference.end_row == 19 and result[6].reference.end_row == 22)
opts.inline.max_images = 2
assert(#inline.collect(buf, vim.api.nvim_get_current_win(), opts) == 2, "Visible image budget bounds recognition")
opts.inline.max_images = 30
opts.math.enabled = false
assert(#inline.collect(buf, vim.api.nvim_get_current_win(), opts) == 4, "Formula opt-out retains standalone images")
opts.math.enabled = true
vim.wo.foldmethod = "manual"
vim.cmd("1,3fold")
vim.cmd.redraw()
result = inline.collect(buf, vim.api.nvim_get_current_win(), opts)
assert(#result == 5 and result[1].reference.start_row == 16, "Closed fold headers and bodies are excluded")
vim.cmd("normal! zR")
opts.max_scan_lines = 18
result = inline.collect(buf, vim.api.nvim_get_current_win(), opts)
assert(#result == 4, "Unclosed math past the scan budget is not guessed")
vim.bo[buf].filetype = "tex"
assert(#inline.collect(buf, vim.api.nvim_get_current_win(), opts) == 0)
for _, value in ipairs({ -1, 0.5, "10" }) do
  assert(not pcall(require("image_tools.config").resolve, { inline = { max_images = value } }))
end
assert(not pcall(require("image_tools.config").resolve, { inline = { max_width = 0 } }))
assert(not pcall(require("image_tools.config").resolve, { inline = { enabled = "yes" } }))
assert(pcall(require("image_tools.config").resolve, { inline = { debounce = 0 } }))
print(
  "inline document: standalone images, reference syntax, block math, code exclusions, folds, budgets and configuration passed"
)

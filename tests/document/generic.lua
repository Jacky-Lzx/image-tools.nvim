vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local tmp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP)) .. "/generic"
vim.fn.mkdir(tmp, "p")
for _, name in ipairs({ "first.png", "中文 image (1).PNG", "second.pdf", "bad.png" }) do
  vim.fn.writefile({ "fixture" }, tmp .. "/" .. name)
end
vim.fn.mkdir(tmp .. "/directory.png", "p")
local document = require("image_tools.document")
local options = require("image_tools.config").resolve()
vim.api.nvim_buf_set_name(0, tmp .. "/example.rs")
vim.bo.filetype = "rust"
local function line(text)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
end
line('let img = "中文 image (1).PNG"; first.png and second.pdf')
local actual, _, _, reference = document.at_line(0, 1, options)
assert(actual == tmp .. "/中文 image (1).PNG")
assert(reference.start_col == 11 and reference.end_col == 11 + #"中文 image (1).PNG")
local col = assert(vim.api.nvim_get_current_line():find("second.pdf", 1, true)) - 1
assert(document.at_cursor(0, 1, col, options) == tmp .. "/second.pdf")
local _, _, status = document.at_cursor(0, 1, 0, options)
assert(status == "miss")
for _, source in ipairs({
  "first.png.",
  "(first.png)",
  "[first.png]",
  "{first.png}",
  "`first.png`",
  "Here's first.png",
  tmp .. "/first.png",
}) do
  line(source)
  assert(document.at_line(0, 1, options) == tmp .. "/first.png", source)
end
for _, source in ipairs({
  "missing.png",
  "directory.png",
  "https://host/bad.png",
  "ftp://host/bad.png",
  "not an image",
  string.rep("x", 17000) .. "first.png",
}) do
  line(source)
  assert(document.at_line(0, 1, options) == nil, source:sub(1, 100))
end
line("first.png")
assert(document.at_line(0, 1, vim.tbl_extend("force", options, { path_preview = false })) == nil)
-- Existing adapters retain their syntax exclusions; generic lookup never becomes an asset index.
vim.bo.filetype = "markdown"
line("`![code](first.png)`")
assert(document.at_line(0, 1, options) == nil)
vim.bo.filetype = "rust"
local completed
local cancel = document.enumerate(0, options, function(err)
  assert(err == "Unsupported document filetype")
  completed = true
end)
assert(vim.wait(1000, function()
  return completed
end))
cancel()
print("generic: quoted and bare local paths, byte selection, unsupported sources and adapter authority passed")

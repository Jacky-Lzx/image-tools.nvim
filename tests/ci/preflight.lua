-- Fail an integration job before suites can silently skip promised dependencies.
local parser_root = assert(vim.env.IMAGE_TOOLS_PARSER_ROOT, "Missing parser root")
local snacks_root = assert(vim.env.IMAGE_TOOLS_SNACKS_ROOT, "Missing Snacks root")
vim.opt.rtp:prepend(parser_root)
vim.opt.rtp:prepend(snacks_root)
for _, language in ipairs({ "latex", "typst" }) do
  vim.treesitter.language.add(language, { path = parser_root .. "/parser/" .. language .. ".so" })
  local source = language == "latex" and [[\includegraphics{image.png}]] or [[#image("image.png")]]
  local parser = vim.treesitter.get_string_parser(source, language)
  assert(parser:parse()[1], "Cannot parse " .. language)
end
require("snacks").setup({ image = { enabled = false }, picker = { enabled = true } })
assert(require("snacks.picker"), "Cannot load Snacks picker")
for _, executable in ipairs({
  "magick",
  "gs",
  "pdfinfo",
  "rsvg-convert",
  "python3",
  "openssl",
  "curl",
  "typst",
  "pdflatex",
  "latex",
  "dvipng",
}) do
  assert(vim.fn.executable(executable) == 1, "Missing integration executable: " .. executable)
end
print("CI integration preflight: parsers, Snacks and compiler/converter tools available")

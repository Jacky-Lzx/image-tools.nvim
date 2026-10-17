-- Opt-in real macOS test. The caller owns a fixture clipboard and restores it.
vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local tmp = assert(vim.env.IMAGE_TOOLS_TEST_TMP)
vim.cmd.enew()
vim.api.nvim_buf_set_name(0, tmp .. "/native-clipboard.md")
vim.bo.filetype = "markdown"
local done, err, paths
require("image_tools").setup({ auto_preview = false })
require("image_tools").paste({ format = "png", filename = "native.png" }, function(e, p)
  done, err, paths = true, e, p
end)
assert(
  vim.wait(10000, function()
    return done
  end),
  "Native paste timeout"
)
assert(not err, err)
local compared = vim
  .system({
    "magick",
    "compare",
    "-metric",
    "AE",
    vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png",
    paths[1],
    "null:",
  })
  :wait()
assert(compared.code == 0, "Native image pixels changed: " .. (compared.stderr or ""))
assert(require("image_tools.document").at_line(0, 2, { max_scan_lines = 100 }) == paths[1], "Native reference failed")
print("clipboard native: real AppKit/pngpaste/import/reference passed")

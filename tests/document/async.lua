vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
vim.opt.rtp:append(assert(vim.env.IMAGE_TOOLS_PARSER_ROOT))
local tmp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP))
local TS, D = require("image_tools.document.treesitter"), require("image_tools.document")
local count = 0
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].filetype = "typst"
vim.api.nvim_buf_set_name(buf, tmp .. "/async.typ")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '#image("a.png")' })
vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixture.png", tmp .. "/a.png")
local real = vim.treesitter.get_parser
local callbacks, starts = {}, 0
vim.treesitter.get_parser = function(...)
  local parser = real(...)
  return {
    parse = function(_, range, callback)
      check(range == nil, "Root language only")
      starts = starts + 1
      callbacks[#callbacks + 1] = callback
      return nil
    end,
  }
end
local ready = 0
local opts = {
  max_scan_lines = 100,
  _treesitter_ready = function()
    ready = ready + 1
  end,
}
local lexical = require("image_tools.document.syntax_cache").query
require("image_tools.document.syntax_cache").query = function()
  error("No synchronous fallback while pending")
end
local _, _, status = D.at_line(buf, 1, opts)
check(status == "pending", "Pending is distinct from unavailable")
check(TS.query(buf, 1, "typst").pending and starts == 1, "Requests coalesce")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '#image("a.png") // changed' })
TS.query(buf, 1, "typst", opts._treesitter_ready)
local trees = real(buf, "typst"):parse()
callbacks[1](nil, trees)
vim.wait(10)
check(ready == 0 and TS.query(buf, 1, "typst").pending, "Stale parse never publishes or wakes old preview")
callbacks[2](nil, trees)
vim.wait(10)
check(ready == 1, "Current completion wakes subscriber once")
check(D.at_line(buf, 1, opts) == tmp .. "/a.png", "Ready syntax resolves normally")
callbacks[2](nil, trees)
vim.wait(10)
check(ready == 1, "Duplicate completion ignored")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '#image("a.png")' })
TS.query(buf, 1, "typst", opts._treesitter_ready)
callbacks[3]("timeout", nil)
vim.wait(10)
require("image_tools.document.syntax_cache").query = lexical
check(D.at_line(buf, 1, opts) ~= nil and starts == 3, "Failed async parse falls back without retry loop")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '#image("b.png")' })
TS.query(buf, 1, "typst", opts._treesitter_ready)
vim.api.nvim_buf_delete(buf, { force = true })
check(pcall(callbacks[4], nil, trees), "Detached completion is harmless")
vim.treesitter.get_parser = real
print("async treesitter: " .. count .. " assertions passed")

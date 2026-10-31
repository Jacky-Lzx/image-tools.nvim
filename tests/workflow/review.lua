vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
if not vim.env.IMAGE_TOOLS_SELECTION_ROOT then
  print("review: skipped (set IMAGE_TOOLS_SELECTION_ROOT)")
  return
end
vim.opt.rtp:prepend(vim.env.IMAGE_TOOLS_SELECTION_ROOT)
vim.o.columns, vim.o.lines = 150, 60
local selection = require("selection_tools")
local open, picker = selection.open, nil
selection.open = function(opts)
  picker = open(opts)
  return picker
end
local ui = require("image_tools.workflow.selection")
local plan = {
  source = "/tmp/old.png",
  target = "/tmp/new.png",
  changes = {
    { path = "/tmp/a.md", lines = { "![a](new.png)" } },
    { path = "/tmp/b.md", lines = { "![b](new.png)" } },
  },
  snapshots = {
    ["/tmp/a.md"] = { lines = { "![a](old.png)" } },
    ["/tmp/b.md"] = { lines = { "![b](old.png)" } },
  },
}
local windows = #vim.api.nvim_list_wins()
local function reviewed(p, needle)
  assert(
    vim.wait(1000, function()
      return table.concat(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false), "\n"):find(needle, 1, true)
    end, 1),
    "Diff preview not painted"
  )
  assert(vim.bo[p.preview_buf].filetype == "diff")
end
local completed, applied, calls = false, nil, 0
local function result(value)
  completed, applied, calls = true, value, calls + 1
end
local review = ui.review(plan, result)
assert(#picker.matches == 2 and not picker.opts.resume)
reviewed(picker, "![a](old.png)")
picker:move(1)
reviewed(picker, "![b](old.png)")
picker:confirm()
assert(
  not completed and #picker.matches == 2 and picker:current() == "Apply move",
  "Review must precede explicit confirmation"
)
picker:close()
assert(completed and not applied and calls == 1 and #vim.api.nvim_list_wins() == windows)
completed = false
review = ui.review(plan, result)
picker:confirm()
picker:confirm()
assert(completed and applied and calls == 2)
completed = false
review = ui.review(plan, result)
picker:confirm()
local stale = picker.opts.on_choice
review:close()
stale("Apply move")
assert(not completed and picker.closed and calls == 2, "Cancelled review must ignore late confirmation")
-- The report reuses quickfix indices and source positions, and supports images.
local temp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP)) .. "/review"
vim.fn.mkdir(temp, "p")
vim.fn.writefile({ "first", "missing image" }, temp .. "/note.md")
vim.fn.writefile({ "pixels" }, temp .. "/asset.png")
vim.fn.setqflist({}, " ", {
  title = "Image assets",
  items = {
    { filename = temp .. "/note.md", lnum = 2, col = 1, text = "Missing reference" },
    { filename = temp .. "/asset.png", lnum = 1, text = "Possibly unused" },
    { text = "Scan incomplete", type = "W" },
  },
})
local renders, closed = 0, 0
local assets = ui.assets(function(request)
  renders = renders + 1
  request.paint(function()
    vim.api.nvim_buf_set_lines(request.buf, 0, -1, false, { "image preview" })
  end)
  return {
    close = function()
      closed = closed + 1
    end,
  }
end)
assert(
  vim.wait(1000, function()
    return vim.api.nvim_buf_get_lines(assets.preview_buf, 0, 1, false)[1] == "first"
  end, 1),
  "Source location has a text preview"
)
assets:move(1)
assert(renders == 1 and vim.api.nvim_buf_get_lines(assets.preview_buf, 0, 1, false)[1] == "image preview")
assets:move(1)
assert(closed == 1 and #assets.matches == 3, "Warning rows survive and release images")
assets:close()
assert(#vim.fn.getqflist() == 3, "Cancelling preserves the native quickfix report")
assets = ui.assets(function()
  return nil, "conversion unavailable"
end)
assets:move(1)
assert(
  vim.wait(1000, function()
    return vim.api.nvim_buf_get_lines(assets.preview_buf, 0, 1, false)[1] == "Image preview: conversion unavailable"
  end, 1),
  "An image error must not fall through to the binary file preview"
)
assets:close()
assets = ui.assets(function()
  error("Not an image")
end)
assets:confirm()
assert(
  vim.api.nvim_buf_get_name(0) == temp .. "/note.md" and vim.api.nvim_win_get_cursor(0)[1] == 2,
  "Report confirmation jumps to the exact source row: "
    .. vim.api.nvim_buf_get_name(0)
    .. " "
    .. vim.inspect(vim.api.nvim_win_get_cursor(0))
)
assert(not package.loaded.snacks and not package.loaded["snacks.image"])
print(
  "review: per-document diffs, explicit apply, Escape/late cancellation, source/image asset previews and exact quickfix navigation passed"
)

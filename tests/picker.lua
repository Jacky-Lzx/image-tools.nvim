vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local snacks = vim.env.IMAGE_TOOLS_SNACKS_ROOT
if not snacks or not vim.uv.fs_stat(snacks .. "/lua/snacks/init.lua") then
  print("picker: Snacks integration skipped (set IMAGE_TOOLS_SNACKS_ROOT)")
  return
end
vim.opt.rtp:prepend(snacks)
vim.o.termguicolors = true
vim.o.columns, vim.o.lines = 120, 40
local pending, requests, writes = {}, {}, {}
package.loaded["image_tools.terminal"] = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function(command)
    writes[#writes + 1] = command
  end,
  request = function(id, command, _, cb)
    requests[#requests + 1] = command
    local cancelled = false
    vim.schedule(function()
      if not cancelled then
        cb(nil)
      end
    end)
    return function()
      cancelled = true
    end
  end,
}
local original = require("image_tools.image")
local source = vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixture.png"
require("snacks").setup({ image = { enabled = false }, picker = { enabled = true } })
local count = 0
local function check(value, msg)
  count = count + 1
  assert(value, msg)
end
local tmp = vim.env.IMAGE_TOOLS_TEST_TMP .. "/picker"
vim.fn.mkdir(tmp, "p")
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, tmp .. "/note.md")
vim.bo.filetype = "markdown"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "source" })
local image = require("image_tools")
image.setup({ auto_preview = false })
local done, err, paths
local picker = image.pick(
  { picker = { cwd = vim.env.IMAGE_TOOLS_ROOT .. "/tests", ft = { "png" }, layout = { preset = "default" } } },
  function(e, p)
    done, err, paths = true, e, p
  end
)
check(picker ~= nil, "Real Snacks picker created")
check(
  vim.wait(3000, function()
    return picker._image_tools_preview and picker._image_tools_preview.state and picker._image_tools_preview.state.id
  end),
  "Own image preview uploaded/placed: "
    .. vim.inspect({
      item = picker:current(),
      state = picker._image_tools_preview and picker._image_tools_preview.state,
      win = picker.preview.win.win,
      lines = vim.api.nvim_buf_get_lines(picker.preview.win.buf, 0, -1, false),
      requests = requests,
    })
)
local renderer, win = picker._image_tools_preview, picker.preview.win.win
check(renderer.state.win == win, "Rendered in existing picker preview window")
check(
  vim.api.nvim_buf_get_lines(renderer.state.buf, 0, 1, false)[1]:find(vim.fn.nr2char(0x10EEEE), 1, true),
  "Own placeholders"
)
check(package.loaded["snacks.image"] == nil, "Snacks.image not loaded for own preview")
local before = #requests
picker.preview:show(picker, { force = true })
check(
  vim.wait(1000, function()
    return renderer.state and renderer.state.id
  end),
  "Preview redraw"
)
check(#requests == before + 1 and renderer.transfer:status().hits == 1, "Picker reuses uploaded image")
-- Actual confirm closes picker and uses origin context even with subsequent edits.
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "before source" })
picker.opts.actions.confirm(picker)
check(
  vim.wait(3000, function()
    return done
  end),
  "Confirm finished import"
)
check(not err and #paths == 1, err)
check(
  vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:match("fixture.png"),
  "Confirm imports into extmark source position"
)
check(renderer.transfer:status().images == 0, "Close frees picker cache")
check(not renderer.group, "Close removes lifecycle group")
check(vim.api.nvim_buf_is_valid(buf), "Source buffer retained")
-- A slow conversion cancelled by moving to a different selection cannot draw late.
package.loaded["image_tools.image"] = {
  supported = original.supported,
  prepare = function(_, _, cb)
    pending[#pending + 1] = cb
    return function() end
  end,
}
local cancelled
picker = image.pick({ picker = { cwd = vim.env.IMAGE_TOOLS_ROOT .. "/tests", ft = { "png" } } }, function(e)
  cancelled = e
end)
check(
  vim.wait(1000, function()
    return #pending > 0
  end),
  "Deferred conversion started"
)
renderer = picker._image_tools_preview
picker.opts.on_change(picker, nil)
local previous = #requests
pending[#pending](nil, { path = source, width = 160, height = 100, key = "late", size = 100 })
check(not renderer.state and #requests == previous, "Stale selection never uploads")
picker:close()
check(cancelled == "Cancelled", "Closing picker cancels insertion context")
package.loaded["image_tools.image"] = original
check(package.loaded["snacks.image"] == nil, "Snacks.image remained disabled")
print("picker: " .. count .. " assertions with real Snacks windows passed")

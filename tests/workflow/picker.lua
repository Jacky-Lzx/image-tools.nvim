-- Retain coverage for ordinary Snacks preview consumers; ImagePick uses selection-tools.
vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local root = vim.env.IMAGE_TOOLS_SNACKS_ROOT
if not root or not vim.uv.fs_stat(root .. "/lua/snacks/init.lua") then
  print("Snacks preview compatibility: skipped (set IMAGE_TOOLS_SNACKS_ROOT)")
  return
end
vim.opt.rtp:prepend(root)
vim.o.columns, vim.o.lines = 180, 80
package.loaded["image_tools.terminal"] = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function() end,
  request = function(_, _, _, callback)
    local cancelled = false
    vim.schedule(function()
      if not cancelled then
        callback(nil)
      end
    end)
    return function()
      cancelled = true
    end
  end,
}
local image = require("image_tools")
image.setup({ auto_preview = false })
require("snacks").setup({ image = { enabled = false }, picker = { enabled = true } })
local closed = 0
local picker = Snacks.picker.files({
  cwd = vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures",
  ft = { "png" },
  preview = function(ctx)
    image.snacks_preview(ctx)
  end,
  on_close = function()
    closed = closed + 1
  end,
})
assert(vim.wait(3000, function()
  return picker._image_tools_preview and picker._image_tools_preview.state and picker._image_tools_preview.state.id
end, 2))
local view = picker._image_tools_preview
assert(view.state.win == picker.preview.win.win)
local id = view.state.id
local win = picker.preview.win.win
vim.api.nvim_win_set_config(win, { width = 100, height = 40 })
vim.api.nvim_exec_autocmds("WinResized", { group = view.group })
assert(vim.wait(3000, function()
  return view.state and view.state.width == 100 and view.state.height == 32
end, 2))
assert(view.state.id == id and view.transfer:status().uploads == 1)
picker:close()
assert(closed == 1 and not view.group and view.transfer:status().placements == 0)
assert(not package.loaded["snacks.image"])
print("Snacks preview compatibility: real pane, cached resize and cleanup passed")

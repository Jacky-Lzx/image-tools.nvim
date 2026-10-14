local root, temporary = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
vim.opt.rtp:prepend(root)
vim.o.termguicolors, vim.o.showtabline = true, 0
local Canvas = require("image_tools.render.canvas")
local options = require("image_tools.config").resolve({ cache = temporary .. "/bounds-cache" })
local dependencies = {
  terminal = {
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
  },
}
local canvas, count = Canvas.new(options, dependencies), 0
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local owner_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(owner_buf, 0, -1, false, { "Image/PDF filename and page header" })
vim.api.nvim_win_set_buf(0, owner_buf)
local owner = vim.api.nvim_get_current_win()
local meta = { path = root .. "/tests/fixtures/fixture.png", page = 1, generation = 1 }
local function render(label)
  canvas:close()
  vim.cmd.redraw()
  local info = vim.fn.getwininfo(owner)[1]
  local _, height, _, row = Canvas.viewport(owner)
  check(height == info.height - (info.height > 1 and 1 or 0), label .. ": viewport uses text height")
  local completed, failure = false, nil
  canvas:open(meta, owner_buf, owner, function(err)
    failure, completed = err, true
  end)
  check(vim.wait(3000, function()
    return completed
  end) and not failure, label .. ": canvas rendered")
  vim.cmd.redraw()
  local state = canvas.state
  local position = vim.api.nvim_win_get_position(state.win)
  local owner_position = vim.api.nvim_win_get_position(owner)
  check(
    position[1] == vim.fn.screenpos(owner, 1, 1).row - 1 + row,
    label .. ": canvas starts below winbar and filename header"
  )
  check(
    position[1] + vim.api.nvim_win_get_height(state.win) <= owner_position[1] + vim.api.nvim_win_get_height(owner),
    label .. ": canvas stays above statusline or split separator"
  )
  check(
    position[2] >= owner_position[2]
      and position[2] + vim.api.nvim_win_get_width(state.win) <= owner_position[2] + vim.api.nvim_win_get_width(owner),
    label .. ": canvas stays within owner width"
  )
end
for _, split in ipairs({ false, true }) do
  if split then
    canvas:close()
    vim.cmd.split()
    owner = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_height(owner, 9)
  end
  for status = 0, 3 do
    vim.o.laststatus = status
    for _, cmdheight in ipairs({ 1, 2 }) do
      vim.o.cmdheight = cmdheight
      for _, winbar in ipairs({ "", "Owner winbar" }) do
        vim.wo[owner].winbar = winbar
        render(
          (split and "split" or "single")
            .. ": laststatus="
            .. status
            .. " cmdheight="
            .. cmdheight
            .. " winbar="
            .. winbar
        )
      end
    end
  end
end
vim.wo[owner].number, vim.wo[owner].signcolumn, vim.wo[owner].foldcolumn = true, "yes", "2"
render("number/sign/fold columns")
check(canvas.transfer:status().uploads == 1, "Geometry changes reuse uploaded pixels")
-- The smallest text area still fits one row without crossing the separator.
vim.api.nvim_win_set_height(owner, 1)
render("one text row with winbar")
canvas:destroy()
print("image-tools canvas bounds: " .. count .. " assertions passed")

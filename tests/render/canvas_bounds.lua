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
-- Grow the owner while PDF preparation is pending. Completing the old request
-- must schedule a higher-resolution frame even if no later resize event arrives.
local callbacks, targets = {}, {}
local delayed = Canvas.new(
  options,
  vim.tbl_extend("force", dependencies, {
    image = {
      prepare = function(path, opts, callback)
        local target = assert(opts._raster_size, "PDF canvas needs viewport pixels by default")
        targets[#targets + 1] = target
        local scale = math.min(target.width / 160, target.height / 100)
        local pixels = {
          key = "pending:" .. #targets,
          path = path,
          data = "pixels",
          width = math.floor(160 * scale),
          height = math.floor(100 * scale),
        }
        callbacks[#callbacks + 1] = function()
          callback(nil, pixels)
        end
        return function() end
      end,
    },
  })
)
meta.path = root .. "/tests/fixtures/fixture.pdf"
vim.api.nvim_win_set_height(owner, 4)
delayed:open(meta, owner_buf, owner, function(err)
  check(not err, err)
end)
check(#callbacks == 1, "PDF preparation is pending")
vim.api.nvim_win_set_height(owner, 12)
callbacks[1]()
check(
  vim.wait(3000, function()
    return #callbacks == 2
  end),
  "Completing an undersized PDF starts a viewport detail upgrade"
)
check(targets[2].height > targets[1].height, "Pending resize requests more pixels")
callbacks[2]()
check(
  vim.wait(3000, function()
    return delayed.state and delayed.state.render.stage == "ready"
  end),
  "Upgraded PDF canvas becomes ready"
)
delayed:destroy()
print("image-tools canvas bounds: " .. count .. " assertions passed")

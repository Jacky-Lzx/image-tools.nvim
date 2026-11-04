local root = assert(vim.env.IMAGE_TOOLS_ROOT)
vim.opt.rtp:prepend(root)
vim.o.columns, vim.o.lines = 100, 40
local count, pending, closes = 0, {}, 0
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local image = {
  prepare = function(path, _, callback)
    pending[#pending + 1] = function()
      callback(nil, { path = path, key = path, width = 360, height = 160, data = "pixels" })
    end
    return function() end
  end,
}
local terminal = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function() end,
  request = function(_, _, _, callback)
    callback(nil)
    return function() end
  end,
}
package.loaded["image_tools.terminal"], package.loaded["image_tools.media"] = terminal, image
local tools = require("image_tools")
tools.setup({ auto_preview = false, position = "bottom_right", right_padding = 3 })
local owner = vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "$a$", "$b$", "outside" })
local valid = true
local function open()
  return assert(tools.float({
    path = "/tmp/generated-formula.png",
    title = " Formula ",
    display_size = { width = 180, height = 80 },
    is_valid = function()
      return valid
    end,
    on_close = function()
      closes = closes + 1
    end,
  }))
end
local view = open()
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_buf_set_lines(0, 0, 1, false, { "$changed$" })
pending[#pending]()
local win = assert(view.preview.state.win)
check(
  vim.api.nvim_win_get_width(win) == 18 and vim.api.nvim_win_get_height(win) == 4,
  "Logical dimensions keep high-DPI images at the intended size"
)
check(vim.api.nvim_win_get_config(win).col == 97, "External floats share right padding")
check(vim.api.nvim_win_get_config(win).title[1][1] == " Formula ", "External title reaches the float")
check(vim.api.nvim_get_current_win() == owner, "External floats never steal focus")
local uploads = tools.status().terminal_cache.uploads
view:resize()
pending[#pending]()
check(not view.closed and closes == 0, "Resizing preserves host file authority")
check(tools.status().terminal_cache.uploads == uploads, "Resizing reuses terminal pixels")
valid = false
vim.api.nvim_exec_autocmds("CursorMoved", {})
check(view.closed and closes == 1, "Host selection authority closes stale floats")
view:close()
check(closes == 1, "Producer lease is released exactly once")
valid = true
view = open()
view:close()
pending[#pending]()
check(not view.preview.state and closes == 2, "Late preparation cannot resurrect a closed float")
view = open()
pending[#pending]()
vim.api.nvim_win_close(view.preview.state.win, true)
check(view.closed and closes == 3, "External float closure releases producer resources")
view = open()
pending[#pending]()
tools.clear_cache()
check(view.closed and closes == 4, "Runtime cleanup releases external floats")
view = open()
pending[#pending]()
tools.setup({ auto_preview = false })
check(view.closed and closes == 5, "Reconfiguration closes external floats")
for _, size in ipairs({
  { width = 0, height = 1 },
  { width = math.huge, height = 1 },
  { width = 0 / 0, height = 1 },
  "bad",
}) do
  local bad, err = tools.float({ path = "/tmp/generated-formula.png", display_size = size })
  check(not bad and err:find("display_size", 1, true), "Invalid logical sizes fail before allocating a view")
end
local failure
image.prepare = function(_, _, callback)
  vim.schedule(function()
    callback("producer image missing")
  end)
  return function() end
end
local failed = assert(tools.float({
  path = "/tmp/missing.png",
  on_error = function(err)
    failure = err
  end,
  on_close = function()
    closes = closes + 1
  end,
}))
check(
  vim.wait(1000, function()
    return failed.closed
  end),
  "Asynchronous image errors close the external handle"
)
check(failure == "producer image missing" and closes == 6, "Errors reach the producer and release its lease once")
check(failed:status().error == failure, "Public status retains the error after cleanup")
print("image-tools external float: " .. count .. " assertions passed")

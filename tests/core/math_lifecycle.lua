vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
vim.o.termguicolors = true
local checks, requests, cancelled = 0, {}, 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
package.loaded["image_tools.terminal"] = {
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
local actual = require("image_tools.media")
package.loaded["image_tools.media"] = {
  supported = actual.supported,
  prepare = function(path, opts, callback)
    requests[#requests + 1] = { path = path, formula = opts._formula, callback = callback }
    return function()
      cancelled = cancelled + 1
    end
  end,
}
local image = require("image_tools")
local function move(row, col)
  vim.api.nvim_win_set_cursor(0, { row, col or 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
end
local function complete(index)
  local request = requests[index]
  request.callback(nil, {
    path = request.path .. ".png",
    key = request.path,
    source = request.path,
    width = 360,
    height = 160,
    display_size = { width = 180, height = 80 },
    data = "fixture",
  })
end
for _, ft in ipairs({ "tex", "markdown" }) do
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, "/tmp/image-tools-lifecycle-" .. ft)
  vim.bo[buf].filetype = ft
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "$$", "x^2 + y^2", "$$", "outside", "$a$ and $b$" })
  move(2)
  local before = #requests
  image.setup({ treesitter = false, auto_preview_delay = 0, position = "bottom_right", buffer = { enabled = false } })
  check(
    vim.wait(1000, function()
      return #requests > before
    end, 1),
    "Automatic formula preparation starts"
  )
  local index, closed = #requests, cancelled
  check(requests[index].formula == "$$\nx^2 + y^2\n$$", "Selected TeX reaches media preparation")
  check(requests[index].path:match("^image%-tools%-math:"), "Virtual identity is not normalized as a path")
  move(1)
  move(3)
  check(#requests == index and cancelled == closed, "Moving inside formula retains pending work")
  complete(index)
  local win = assert(image.status().window)
  check(
    vim.api.nvim_win_get_width(win) == 18 and vim.api.nvim_win_get_height(win) == 4,
    "High-resolution pixels retain the logical formula display size"
  )
  check(image.info().width == 360 and image.info().height == 160, "Diagnostics retain actual raster resolution")
  check(image.info().format == "math" and image.info().ready, "Formula diagnostics identify ready rendering")
  move(2, 3)
  check(image.status().window == win and #requests == index, "Multiline formula retains visible preview")
  move(4)
  check(not image.status().window, "Leaving formula closes preview")
  move(2)
  index = #requests
  move(4)
  complete(index)
  check(not image.status().window, "Late result cannot restore preview after leaving")
  move(2)
  index = #requests
  complete(index)
  local old_path = image.status().path
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "x^3 + y^3" })
  vim.api.nvim_exec_autocmds("TextChanged", {})
  check(
    #requests == index + 1 and requests[#requests].path ~= old_path,
    "Editing formula replaces pending/visible pixels"
  )
  complete(#requests)
  check(image.reload(), "Formula can be reloaded")
  check(requests[#requests].formula == "$$\nx^3 + y^3\n$$", "Reload preserves formula source")
  complete(#requests)
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "unclosed" })
  vim.api.nvim_exec_autocmds("TextChanged", {})
  check(not image.status().window, "Removing delimiter closes stale preview")
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "$$" })
  vim.api.nvim_exec_autocmds("TextChanged", {})
  move(5, 8)
  check(requests[#requests].formula == "$b$", "Cursor selects second formula")
  complete(#requests)
  move(5, 4)
  check(requests[#requests].formula == "$a$", "Outside formulas selects first on line")
  requests[#requests].callback("Invalid formula")
  check(
    not image.status().window and image.info().format == "math" and image.info().stage == "failed",
    "Formula failures retain diagnostics after cleanup"
  )
  image.clear_cache()
end
-- Formula selections share the automatic delay and manual bypass.
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.bo.filetype = "markdown"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "$a$", "$b$", "outside" })
move(1)
image.setup({ auto_preview_delay = 40, buffer = { enabled = false } })
local before = #requests
move(2)
move(3)
vim.wait(80, function()
  return false
end)
check(#requests == before, "Leaving delayed formula avoids compilation")
move(1)
check(image.hover({ silent = true }) and #requests == before + 1, "Manual formula hover bypasses delay")
image.clear_cache()
print("math lifecycle: " .. checks .. " assertions passed")

vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local Preview = require("image_tools.render.preview")
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
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
local prepared
local image = {
  prepare = function(_, _, callback)
    callback(nil, prepared)
    return function() end
  end,
}
vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("x", 200) })
vim.wo.wrap = false
vim.o.lines = 40
local function render(position, formula, narrow, border, reserved, padding)
  prepared = {
    key = "bounds",
    path = "/tmp/image-tools-bounds.png",
    data = "pixels",
    width = 2400,
    height = 120,
    display_size = formula and { width = 1200, height = 60 } or nil,
  }
  vim.o.columns = narrow and 12 or 100
  vim.api.nvim_win_set_cursor(0, { 1, narrow and 9 or 95 })
  local preview = Preview.new({
    position = position,
    right_padding = padding,
    max_width = 200,
    max_height = 30,
    border = border,
    preview_loading_delay = 0,
  }, { terminal = terminal, image = image })
  check(preview:open(prepared.path, { _formula = formula and "$x$" or nil }), "Preview accepted")
  local win = assert(preview.state.win)
  local config = vim.api.nvim_win_get_config(win)
  local edge = vim.o.columns - reserved
  local outer_width = config.width + (border == "none" and 0 or 2)
  local right = position == "bottom_right" and config.col or config.col + outer_width
  check(right <= edge, "Image/formula and border stay left of the scrollbar lane")
  if position == "bottom_right" then
    check(right == edge, "Bottom-right anchor reserves exactly the scrollbar lane")
  end
  check(config.width <= math.max(1, edge - 4), "Sizing accounts for reserved space in narrow editors")
  check(vim.api.nvim_get_current_win() == preview.state.owner_win, "Preview retains owner focus")
  preview:destroy()
end
for _, state in ipairs({ "unloaded", "disabled", "enabled", "disabled", "unloaded" }) do
  -- An enabled module may have no bar yet: refresh is deferred, or all lines
  -- fit. Reservation must still work without consulting a live scrollbar win.
  package.loaded["ui_tools.scrollbar"] = state ~= "unloaded" and { enabled = state == "enabled", bars = {} } or nil
  local reserved = state == "enabled" and 1 or 0
  for _, position in ipairs({ "bottom_right", "cursor" }) do
    for _, formula in ipairs({ false, true }) do
      for _, narrow in ipairs({ false, true }) do
        for _, border in ipairs({ "rounded", "none" }) do
          render(position, formula, narrow, border, reserved)
          render(position, formula, narrow, border, reserved, 0)
          render(position, formula, narrow, border, 3, 3)
          render(position, formula, narrow, border, (narrow and 12 or 100) - 3, 1000)
        end
      end
    end
  end
  check((package.loaded["ui_tools.scrollbar"] == nil) == (state == "unloaded"), "Preview never loads optional UI")
end
vim.o.columns = 100
package.loaded["ui_tools.scrollbar"] = { enabled = true, bars = {} }
vim.cmd.vsplit()
render("bottom_right", false, false, "rounded", 1)
vim.cmd.wincmd("p")
render("bottom_right", true, false, "rounded", 1)
package.loaded["ui_tools.scrollbar"] = nil
-- Window/title geometry is independent of the image's Kitty placement size.
for _, position in ipairs({ "bottom_right", "cursor" }) do
  for _, case in ipairs({
    { title = " Formula ", expected = 9 },
    { title = " 公式预览 ", expected = 10 },
    { title = " Formula ", limit = 6, expected = 6 },
    { title = " Formula ", columns = 12, expected = 5 },
    { title = " Formula ", border = "none", expected = 3 },
    { title = "", expected = 3 },
  }) do
    vim.o.columns = case.columns or 100
    prepared = {
      path = "/tmp/short-formula.png",
      key = "short-formula",
      data = "pixels",
      width = 120,
      height = 80,
      display_size = { width = 30, height = 20 },
    }
    local preview = Preview.new({
      position = position,
      right_padding = 3,
      max_width = case.limit or 60,
      max_height = 30,
      border = case.border or "rounded",
      preview_loading_delay = 0,
    }, { terminal = terminal, image = image })
    check(preview:open(prepared.path, { title = case.title }), "Short formula preview accepted")
    local state = preview.state
    local config = vim.api.nvim_win_get_config(state.win)
    check(config.width == case.expected, "Title fits within width and screen limits using display cells")
    check(state.width == 3 and state.height == 1, "Title padding never upscales the image placement")
    local line = vim.api.nvim_buf_get_lines(state.buf, 0, 1, false)[1]
    local offset = math.floor((case.expected - 3) / 2)
    check(line:match("^ *") == string.rep(" ", offset), "Small image is centered inside the wider frame")
    check(vim.fn.strdisplaywidth(line) == offset + 3, "Padding preserves the placeholder grid width")
    local outer = config.width + (case.border == "none" and 0 or 2)
    local right = position == "bottom_right" and config.col or config.col + outer
    check(right <= vim.o.columns - 3, "Title expansion respects right padding at both positions")
    check(vim.api.nvim_get_current_win() == state.owner_win, "Title padding retains owner focus")
    preview:destroy()
  end
end
vim.o.columns = 100
local resolve = require("image_tools.config").resolve
check(resolve().right_padding == 0, "Right padding defaults to zero")
check(resolve({ right_padding = 3 }).right_padding == 3, "Right padding accepts non-negative integers")
for _, invalid in ipairs({ -1, 1.5, "2", false, math.huge, 0 / 0 }) do
  local ok, err = pcall(resolve, { right_padding = invalid })
  check(not ok and tostring(err):find("right_padding", 1, true), "Invalid padding reports the option name")
end
print("image-tools preview bounds: " .. checks .. " assertions passed")

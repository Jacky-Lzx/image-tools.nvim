vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
if vim.env.IMAGE_TOOLS_PARSER_ROOT then
  vim.opt.rtp:append(vim.env.IMAGE_TOOLS_PARSER_ROOT)
end
vim.o.termguicolors = true
local tmp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP)) .. "/range-lifecycle"
vim.fn.mkdir(tmp, "p")
for _, name in ipairs({ "a", "b" }) do
  vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", tmp .. "/" .. name .. ".png")
end
local writes, requests, cancelled, checks, serial = {}, {}, 0, 0, 0
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
  write = function(data)
    writes[#writes + 1] = data
  end,
  request = function(_, command, _, callback)
    writes[#writes + 1] = command
    callback(nil)
    return function() end
  end,
}
local real_image = require("image_tools.media")
package.loaded["image_tools.media"] = {
  supported = real_image.supported,
  prepare = function(path, _, callback)
    requests[#requests + 1] = { path = path, callback = callback }
    return function()
      cancelled = cancelled + 1
    end
  end,
}
local image = require("image_tools")
local sample = {
  [[  \includegraphics[]],
  [[ % width=\linewidth]],
  [[ % height=3cm]],
  [[ % keepaspectratio]],
  [[  ]{a.png}]],
  "ordinary",
}
local function buffer()
  serial = serial + 1
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, tmp .. "/range-" .. serial .. ".tex")
  vim.bo[buf].filetype = "tex"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, sample)
  return buf
end
local function move(row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
end
local function complete(index)
  local request = requests[index]
  request.callback(nil, { path = request.path, key = request.path, width = 160, height = 100, data = "fixture" })
end
local function edit(buf, first, last, lines)
  vim.api.nvim_buf_set_lines(buf, first, last, false, lines)
  vim.api.nvim_exec_autocmds("TextChangedI", {})
end
for _, treesitter in ipairs(vim.env.IMAGE_TOOLS_PARSER_ROOT and { false, true } or { false }) do
  local buf = buffer()
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  image.setup({
    treesitter = treesitter,
    auto_preview = true,
    auto_preview_delay = 0,
    position = "bottom_right",
    buffer = { enabled = false },
  })
  local before = #requests
  check(
    vim.wait(1000, function()
      return #requests > before
    end, 1),
    "Entering an option row starts preview"
  )
  local index, old_cancelled = #requests, cancelled
  move(1)
  move(5)
  check(#requests == index and cancelled == old_cancelled, "Range movement retains pending conversion")
  complete(index)
  local win = assert(image.status().window)
  local upload_count = image.status().terminal_cache.uploads
  for row = 1, 5 do
    move(row)
    check(image.status().window == win, "Range row " .. row .. " retains visible window")
  end
  check(
    #requests == index and image.status().terminal_cache.uploads == upload_count,
    "Range movement performs no new conversion or upload"
  )
  move(6)
  check(image.status().window == nil, "Leaving reference closes preview")
  move(3)
  index = #requests
  move(6)
  complete(index)
  check(image.status().window == nil, "Late converted result cannot reopen after leaving")
  move(3)
  index = #requests
  complete(index)
  check(image.status().terminal_cache.uploads == upload_count, "Returning reuses terminal pixels")
  edit(buf, 4, 5, { "  ]{b.png}" })
  check(
    requests[#requests].path == tmp .. "/b.png" and image.status().window == nil,
    "Editing end path updates preview from option row"
  )
  index = #requests
  complete(index)
  win = image.status().window
  edit(buf, 1, 2, { " % changed option" })
  check(#requests == index and image.status().window == win, "Unchanged source retains existing preview during edits")
  edit(buf, 2, 2, { "" })
  move(6)
  check(image.status().window == win and #requests == index, "Inserted row updates coverage without retransmission")
  edit(buf, 5, 6, { "  ]{b.png" })
  check(image.status().window == nil, "Unclosed reference immediately hides stale preview")
  image.clear_cache()
end
-- Manual preview can move across a pending parse even with automatic preview off.
if vim.env.IMAGE_TOOLS_PARSER_ROOT then
  local get_parser = vim.treesitter.get_parser
  local callbacks = {}
  vim.treesitter.get_parser = function(...)
    get_parser(...)
    return {
      parse = function(_, _, ready)
        callbacks[#callbacks + 1] = ready
      end,
    }
  end
  local buf = buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  image.setup({ auto_preview = false, position = "bottom_right", buffer = { enabled = false } })
  image.hover({ silent = true })
  move(4)
  image.hover({ silent = true })
  check(#callbacks == 1, "Manual pending parse coalesces across range")
  local before = #requests
  callbacks[1](nil, get_parser(buf, "latex"):parse())
  check(
    vim.wait(1000, function()
      return #requests > before
    end, 1),
    "Manual hover resumes at new row within range"
  )
  complete(#requests)
  check(image.status().window ~= nil, "Manual async result opens at current option row")
  image.clear_cache()
  buf = buffer()
  move(1)
  image.hover({ silent = true })
  move(6)
  move(1)
  before = #requests
  callbacks[2](nil, get_parser(buf, "latex"):parse())
  vim.wait(20)
  check(
    #requests == before and image.status().window == nil,
    "Leaving and returning cannot resurrect cancelled manual parse"
  )
  vim.treesitter.get_parser = get_parser
end
image.clear_cache()
print("LaTeX range lifecycle: " .. checks .. " assertions passed")

local root, temporary = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
vim.opt.rtp:prepend(root)
vim.o.termguicolors, vim.o.swapfile = true, false
local image = require("image_tools")
local first_path, second_path = temporary .. "/中文 image (1).png", temporary .. "/second.png"
local text = "文字 ![first](<中文 image (1).png>) and ![second](second.png) suffix"
local function column(path)
  return assert(text:find(path, 1, true)) - 1
end
vim.api.nvim_buf_set_name(0, temporary .. "/cursor.md")
vim.bo.filetype = "markdown"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { text, "plain text" })
vim.api.nvim_win_set_cursor(0, { 1, column("second.png") })
image.setup({ auto_preview = true, auto_preview_delay = 0, position = "bottom_right", cache = temporary .. "/cache" })
local window
local steps = {
  function()
    window = assert(image.status().window, "automatic cursor preview did not open")
    assert(image.status().path == second_path, "automatic preview did not select the second path")
    vim.api.nvim_win_set_cursor(0, { 1, column("second.png") + 2 })
  end,
  function()
    assert(image.status().window == window, "movement within the selected path recreated its preview")
    vim.api.nvim_win_set_cursor(0, { 1, column("中文 image (1).png") })
  end,
  function()
    local current = assert(image.status().window, "first path did not render after cursor movement")
    assert(current ~= window and image.status().path == first_path, "cursor did not switch images")
    assert(image.status().terminal_cache.uploads == 2, "distinct paths did not upload separately")
    vim.api.nvim_win_set_cursor(0, { 1, column("second.png") })
  end,
  function()
    assert(
      image.status().window and image.status().path == second_path,
      "returning cursor did not select the second image"
    )
    assert(image.status().terminal_cache.uploads == 2, "returning cursor failed to reuse cached pixels")
    vim.api.nvim_win_set_cursor(0, { 1, #text - 1 })
  end,
  function()
    assert(
      image.status().window and image.status().path == first_path,
      "outside references did not fall back to first image"
    )
    assert(image.status().terminal_cache.uploads == 2, "fallback did not reuse cached pixels")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
  end,
  function()
    assert(not image.status().window, "leaving the image line retained a placement")
    vim.fn.writefile(
      { vim.json.encode({ cursor = true, lifecycle = true, cache = image.status().terminal_cache }) },
      temporary .. "/result.json"
    )
    vim.cmd("qa!")
  end,
}
local function step(index)
  vim.defer_fn(function()
    local ok, err = pcall(steps[index])
    if not ok then
      vim.fn.writefile({ tostring(err), vim.inspect(image.status()) }, temporary .. "/error.txt")
      vim.cmd("cquit")
      return
    end
    if steps[index + 1] then
      step(index + 1)
    end
  end, 250)
end
step(1)

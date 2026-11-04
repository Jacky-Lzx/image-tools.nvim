local root, temporary = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
vim.opt.rtp:prepend(root)
vim.o.termguicolors = true
vim.o.swapfile = false
vim.api.nvim_create_autocmd("TermResponse", {
  callback = function(event)
    vim.fn.writefile({ vim.inspect(event.data) }, temporary .. "/responses.log", "a")
  end,
})
local image = require("image_tools")
image.setup({
  auto_preview = true,
  auto_preview_delay = 0,
  position = "bottom_right",
  right_padding = tonumber(vim.env.IMAGE_TOOLS_TEST_RIGHT_PADDING) or 0,
  cache = temporary .. "/cache",
  transport = vim.env.IMAGE_TOOLS_TEST_TRANSPORT or "auto",
})
vim.api.nvim_buf_set_name(0, temporary .. "/note.md")
vim.bo.filetype = "markdown"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "prefix ![fixture](<中文 image (1).png>) trailing text",
  "another ![fixture](<中文 image (1).png>)",
  "plain text",
})
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local scrollbar
if vim.env.IMAGE_TOOLS_UI_ROOT then
  vim.opt.rtp:prepend(vim.env.IMAGE_TOOLS_UI_ROOT)
  vim.api.nvim_buf_set_lines(0, -1, -1, false, vim.fn["repeat"]({ "scrollbar fixture" }, 100))
  scrollbar = require("ui_tools.scrollbar")
  scrollbar.setup({ handle = " ", blend = 100, cursor = true, cursor_char = "●" })
end
local results, first, second = {}, nil, nil
local steps = {
  function()
    local win = assert(image.status().window, "current-line image did not preview automatically")
    first = win
    results.geometry = { vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) }
    local location = vim.api.nvim_win_get_position(win)
    local padding = math.max(tonumber(vim.env.IMAGE_TOOLS_TEST_RIGHT_PADDING) or 0, scrollbar and 1 or 0)
    assert(location[2] + results.geometry[1] + 2 == vim.o.columns - padding, "incorrect right edge")
    if scrollbar then
      local bar = assert(scrollbar.bars[vim.api.nvim_get_current_win()], "actual scrollbar missing")
      assert(
        location[2] + results.geometry[1] + 2 <= vim.api.nvim_win_get_position(bar.win)[2],
        "actual scrollbar overlaps image preview border"
      )
    end
    assert(
      location[1] + results.geometry[2] + 2 == vim.o.lines - vim.o.cmdheight - 1,
      "float is not above the command and status lines"
    )
    results.position = "bottom_right"
    results.cell = require("image_tools.terminal").cell_size({ width = 10, height = 20 })
    vim.api.nvim_win_set_cursor(0, { 1, #vim.api.nvim_get_current_line() - 1 })
  end,
  function()
    assert(image.status().window == first, "same-line movement recreated the preview")
    assert(image.hover())
    vim.api.nvim_input("i")
  end,
  function()
    assert(vim.fn.mode() == "i", "test did not enter Insert mode")
    assert(image.status().window == first, "entering Insert mode closed the preview")
    vim.api.nvim_input("x")
  end,
  function()
    assert(image.status().window == first, "editing surrounding text recreated the preview")
    vim.api.nvim_input("\27")
  end,
  function()
    assert(image.status().window == first, "leaving Insert mode closed the preview")
    results.same_line = true
    image.close()
    assert(not image.status().window)
    assert(image.hover())
  end,
  function()
    second = assert(image.status().window, "manual line preview failed")
    assert(second ~= first)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
  end,
  function()
    local third = assert(image.status().window, "entering another image line did not preview")
    assert(third ~= second, "line transition retained the previous owner")
    results.image_line_transition = true
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
  end,
  function()
    assert(not image.status().window, "leaving the image line left a preview")
    assert(image.preview(temporary .. "/中文 image (1).png"))
    vim.cmd("enew!")
  end,
  function()
    assert(not image.status().window, "buffer switch revived a stale preview")
    results.lifecycle = true
    results.cache = image.status().terminal_cache
    vim.fn.writefile({ vim.json.encode(results) }, temporary .. "/result.json")
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

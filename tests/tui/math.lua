local root, temporary = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
vim.opt.rtp:prepend(root)
vim.o.termguicolors = true
vim.o.swapfile = false
local image = require("image_tools")
local scrollbar
if vim.env.IMAGE_TOOLS_UI_ROOT then
  vim.opt.rtp:prepend(vim.env.IMAGE_TOOLS_UI_ROOT)
  scrollbar = require("ui_tools.scrollbar")
end
local results, first, step, deadline = {}, nil, 1, vim.uv.hrtime() + 10e9
local function document(ft)
  vim.cmd("enew!")
  vim.api.nvim_buf_set_name(0, temporary .. "/formula." .. ft)
  vim.bo.filetype = ft
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "$$", "g(x)", "$$", "outside" })
  if scrollbar then
    vim.api.nvim_buf_set_lines(0, -1, -1, false, vim.fn["repeat"]({ "scrollbar fixture" }, 100))
    scrollbar.setup({ handle = " ", blend = 100, cursor = true, cursor_char = "●" })
  end
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
end
document("markdown")
image.setup({
  auto_preview_delay = 0,
  treesitter = false,
  position = "bottom_right",
  right_padding = tonumber(vim.env.IMAGE_TOOLS_TEST_RIGHT_PADDING) or 0,
  transport = vim.env.IMAGE_TOOLS_TEST_TRANSPORT,
  cache = temporary .. "/cache",
  math = { foreground = "#cad3f5" },
})
local function move(row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
end
local function poll()
  local ok, err = pcall(function()
    assert(vim.uv.hrtime() < deadline, "Formula TUI timed out: " .. vim.inspect(image.info()))
    local win = image.status().window
    if win then
      local padding = math.max(tonumber(vim.env.IMAGE_TOOLS_TEST_RIGHT_PADDING) or 0, scrollbar and 1 or 0)
      assert(
        vim.api.nvim_win_get_position(win)[2] + vim.api.nvim_win_get_width(win) + 2 == vim.o.columns - padding,
        "incorrect formula right padding"
      )
    end
    if win and scrollbar then
      local bar = assert(scrollbar.bars[vim.api.nvim_get_current_win()], "actual scrollbar missing")
      assert(
        vim.api.nvim_win_get_position(win)[2] + vim.api.nvim_win_get_width(win) + 2
          <= vim.api.nvim_win_get_position(bar.win)[2],
        "actual scrollbar overlaps formula preview border"
      )
    end
    if step == 1 and win then
      assert(image.info().format == "math" and image.info().ready)
      vim.cmd("redraw")
      local position = vim.api.nvim_win_get_position(win)
      local border = ""
      for col = 1, vim.api.nvim_win_get_width(win) + 2 do
        border = border .. vim.fn.screenstring(position[1] + 1, position[2] + col)
      end
      assert(border:find(" Formula ", 1, true), "Short formula title was truncated: " .. border)
      first = win
      move(1)
      move(3)
      assert(image.status().window == first, "Formula range movement recreated preview")
      move(4)
      assert(not image.status().window, "Leaving formula retained placement")
      move(2)
      step = 2
    elseif step == 2 and win then
      assert(image.status().terminal_cache.uploads == 1, "Returning retransmitted formula")
      image.close()
      image.hover()
      step = 3
    elseif step == 3 and win then
      assert(image.status().terminal_cache.uploads == 1, "Repeated Markdown formulas did not share pixels")
      results.math, results.lifecycle, results.shared = true, true, true
      results.cache = image.status().terminal_cache
      image.close()
      assert(not image.status().window)
      vim.fn.writefile({ vim.json.encode(results) }, temporary .. "/result.json")
      vim.cmd("qa!")
      return
    end
    vim.defer_fn(poll, 40)
  end)
  if not ok then
    vim.fn.writefile({ tostring(err), vim.inspect(image.status()) }, temporary .. "/error.txt")
    vim.cmd("cquit")
  end
end
vim.defer_fn(poll, 40)

local root, temporary = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
vim.opt.rtp:prepend(root)
vim.o.termguicolors = true
vim.o.swapfile = false
local image = require("image_tools")
local results, first, step, deadline = {}, nil, 1, vim.uv.hrtime() + 10e9
local function document(ft)
  vim.cmd("enew!")
  vim.api.nvim_buf_set_name(0, temporary .. "/formula." .. ft)
  vim.bo.filetype = ft
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "$$", "\\frac{a}{b} + \\sqrt{x}", "$$", "outside" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
end
document("markdown")
image.setup({
  auto_preview_delay = 0,
  treesitter = false,
  position = "bottom_right",
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
    if step == 1 and win then
      assert(image.info().format == "math" and image.info().ready)
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
      document("tex")
      image.hover()
      step = 3
    elseif step == 3 and win then
      assert(image.status().terminal_cache.uploads == 1, "Identical Markdown/LaTeX formulas did not share pixels")
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

-- Used as -u init so BufReadCmd runs before the startup PNG file is read.
local root, tmp = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
vim.opt.rtp:prepend(root)
vim.o.termguicolors, vim.o.swapfile, vim.o.hidden = true, false, true
vim.o.winbar, vim.o.statusline, vim.o.laststatus = "PDF owner winbar", "PDF_STATUSLINE_VISIBLE", 2
vim.o.showtabline = 2
local image = require("image_tools")
image.setup({ auto_preview = false, transport = "auto" })
local results, win, source_buf, id = { buffer = true }, nil, nil, nil
local function within_owner()
  assert(vim.fn.getwininfo(win)[1].winbar == 1, "PDF test needs an owner winbar")
  local canvas = assert(image.status().buffer.views[win].window)
  local top = vim.api.nvim_win_get_position(canvas)[1]
  local first = vim.fn.screenpos(win, 1, 1).row - 1
  local last = vim.api.nvim_win_get_position(win)[1] + vim.api.nvim_win_get_height(win)
  assert(top == first + 1, "Canvas covers winbar or PDF header")
  assert(top + vim.api.nvim_win_get_height(canvas) <= last, "Canvas covers statusline")
  vim.cmd.redraw()
  local cells = {}
  for column = 1, vim.api.nvim_win_get_width(win) do
    cells[column] = vim.fn.screenstring(last + 1, vim.api.nvim_win_get_position(win)[2] + column)
  end
  assert(
    table.concat(cells):find("PDF_STATUSLINE_VISIBLE", 1, true),
    "PDF statusline is not visible on screen: " .. vim.inspect(table.concat(cells))
  )
end
local steps = {
  function()
    win, source_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    assert(vim.bo.filetype == "image_tools", "Startup file was read as binary text")
    local view = assert(image.status().buffer.views[win], "Startup image has no view")
    assert(view.window, "Startup image did not acknowledge")
    assert(not vim.bo.modifiable and vim.bo.readonly and not vim.bo.modified, "Startup image is writable")
    assert(not pcall(vim.cmd, "write!"), "Forced write was allowed")
    vim.cmd.vsplit()
  end,
  function()
    local status = image.status().buffer
    local other = vim.api.nvim_get_current_win()
    assert(other ~= win and status.views[win].window and status.views[other].window, "Shared split canvases missing")
    assert(
      status.views[win].cache.uploads == 1 and status.views[win].cache.placements == 2,
      "Split duplicated terminal pixels"
    )
    local function color(owner)
      local buf = vim.api.nvim_win_get_buf(status.views[owner].window)
      local mark = vim.api.nvim_buf_get_extmarks(
        buf,
        vim.api.nvim_create_namespace("image_tools.canvas"),
        0,
        -1,
        { details = true }
      )[1]
      return vim.api.nvim_get_hl(0, { name = mark[4].hl_group })
    end
    local first, second = color(win), color(other)
    assert(first.fg == second.fg and first.sp ~= second.sp, "Split placement ids are not independent")
    results.shared_placements = { first.sp, second.sp }
    results.shared = true
    vim.api.nvim_win_close(other, true)
    assert(image.status().buffer.views[win].window, "Closing split removed remaining canvas")
    assert(image.open(tmp .. "/pages.pdf"))
  end,
  function()
    local status = assert(image.status().buffer)
    assert(status.pages == 2 and status.page == 1, "Wrong PDF metadata")
    assert(status.views[win].window and status.views[win].page == 1, "Page one not displayed")
    within_owner()
    vim.api.nvim_input("]p")
  end,
  function()
    local status = image.status().buffer
    assert(status.views[win].window and status.views[win].page == 2, "Page two not displayed")
    within_owner()
    assert(not image.page(3), "Out-of-bounds page accepted")
    vim.api.nvim_input("2[p")
  end,
  function()
    local status = image.status().buffer
    assert(status.views[win].window and status.views[win].page == 1, "Back to page one failed")
    within_owner()
    results.statusline = true
    assert(
      status.views[win].cache.uploads == 3 and status.views[win].cache.hits >= 1,
      "PDF paging did not reuse uploaded pixels"
    )
    results.cache = status.views[win].cache
    vim.cmd.enew()
  end,
  function()
    assert(not image.status().buffer, "Plain buffer was intercepted")
    local overlays = 0
    for _, window in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(window)].filetype == "image_tools_canvas" then
        overlays = overlays + 1
      end
    end
    assert(overlays == 0, "Leaving image buffer leaked a canvas")
    results.lifecycle = true
    vim.fn.writefile({ vim.json.encode(results) }, tmp .. "/result.json")
    vim.cmd("qa!")
  end,
}
local function step(index)
  vim.defer_fn(function()
    local ok, err = pcall(steps[index])
    if not ok then
      vim.fn.writefile({ tostring(err), vim.inspect(image.status()) }, tmp .. "/error.txt")
      vim.cmd("cquit")
    elseif steps[index + 1] then
      step(index + 1)
    end
  end, 700)
end
step(1)

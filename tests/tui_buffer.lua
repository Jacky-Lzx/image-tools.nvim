-- Used as -u init so BufReadCmd runs before the startup PNG file is read.
local root, tmp = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
vim.opt.rtp:prepend(root)
vim.o.termguicolors, vim.o.swapfile, vim.o.hidden = true, false, true
local image = require("image_tools")
image.setup({ auto_preview = false, transport = "auto" })
local results, win, source_buf, id = { buffer = true }, nil, nil, nil
local steps = {
  function()
    win, source_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    assert(vim.bo.filetype == "image_tools", "Startup file was read as binary text")
    local view = assert(image.status().buffer.views[win], "Startup image has no view")
    assert(view.window, "Startup image did not acknowledge")
    assert(not vim.bo.modifiable and vim.bo.readonly and not vim.bo.modified, "Startup image is writable")
    assert(not pcall(vim.cmd, "write!"), "Forced write was allowed")
    assert(image.open(tmp .. "/pages.pdf"))
  end,
  function()
    local status = assert(image.status().buffer)
    assert(status.pages == 2 and status.page == 1, "Wrong PDF metadata")
    assert(status.views[win].window and status.views[win].page == 1, "Page one not displayed")
    vim.api.nvim_input("]p")
  end,
  function()
    local status = image.status().buffer
    assert(status.views[win].window and status.views[win].page == 2, "Page two not displayed")
    assert(not image.page(3), "Out-of-bounds page accepted")
    vim.api.nvim_input("2[p")
  end,
  function()
    local status = image.status().buffer
    assert(status.views[win].window and status.views[win].page == 1, "Back to page one failed")
    assert(
      status.views[win].cache.uploads == 2 and status.views[win].cache.hits >= 1,
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

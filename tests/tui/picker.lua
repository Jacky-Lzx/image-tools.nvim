local root, temporary = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_SELECTION_ROOT))
vim.o.termguicolors, vim.o.swapfile = true, false
require("selection_tools").setup({ layout = { width = 0.6, height = 0.65, preview_height = 0.6 } })
local image = require("image_tools")
image.setup({ auto_preview = false, transport = "auto" })
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, temporary .. "/note.md")
vim.bo.filetype = "markdown"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "original document" })
local done, err, paths
local picker = image.pick(
  { picker = { cwd = temporary, ft = { "png" }, layout = { width = 0.6, height = 0.65 } } },
  function(e, p)
    done, err, paths = true, e, p
  end
)
local results, renderer, initial_width, initial_height = { picker = true }
local steps = {
  function()
    renderer = assert(picker.preview.provider, "Selection picker preview did not start")
    assert(renderer.id, "Picker image did not acknowledge")
    local win = picker.preview_win
    assert(renderer.win == win, "Wrong preview window")
    assert(not package.loaded.snacks and not package.loaded["snacks.image"], "Snacks was loaded")
    local width, height = renderer.width, renderer.height
    assert(width == renderer.view_width or height == renderer.view_height, "Image does not fill pane")
    assert(width > 16 or height > 5, "Small image did not upscale")
    initial_width, initial_height = width, height
    picker.opts.layout.width = 0.95
    picker.opts.layout.height = 0.95
    picker.opts.layout.preview_height = 0.8
    picker:resize()
  end,
  function()
    assert(renderer.id, "Preview redraw failed")
    local state = renderer
    assert(state.width ~= initial_width or state.height ~= initial_height, "Layout change did not resize the image")
    assert(state.width == state.view_width or state.height == state.view_height, "Resized image does not fill pane")
    assert(
      vim.api.nvim_buf_get_lines(state.buf, 0, 1, false)[1]:find(vim.fn.nr2char(0x10EEEE), 1, true) == 1,
      "Image is not top-left aligned"
    )
    results.cache = renderer.transfer:status()
    picker.opts.actions.confirm(picker)
  end,
  function()
    assert(done and not err, err or "Insertion not completed")
    assert(
      require("image_tools.document").at_line(buf, 2, { max_scan_lines = 100 }) == paths[1],
      "Wrong imported reference"
    )
    assert(renderer.transfer:status().placements == 0, "Picker placement leaked")
    results.inserted = true
    vim.fn.writefile({ vim.json.encode(results) }, temporary .. "/result.json")
    vim.cmd("qa!")
  end,
}
local function step(index)
  vim.defer_fn(function()
    local ok, failure = pcall(steps[index])
    if not ok then
      vim.fn.writefile({ tostring(failure) }, temporary .. "/error.txt")
      vim.cmd("cquit")
    elseif steps[index + 1] then
      step(index + 1)
    end
  end, 350)
end
step(1)

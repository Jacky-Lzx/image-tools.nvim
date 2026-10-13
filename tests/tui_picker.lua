local root, temporary = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_SNACKS_ROOT))
vim.o.termguicolors, vim.o.swapfile = true, false
require("snacks").setup({ image = { enabled = false }, picker = { enabled = true } })
local image = require("image_tools")
image.setup({ auto_preview = false, transport = "auto" })
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, temporary .. "/note.md")
vim.bo.filetype = "markdown"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "original document" })
local done, err, paths
local picker = image.pick(
  { picker = { cwd = temporary, ft = { "png" }, layout = { preset = "default" } } },
  function(e, p)
    done, err, paths = true, e, p
  end
)
local results, renderer = { picker = true }
local steps = {
  function()
    renderer = assert(picker._image_tools_preview, "Picker preview did not start")
    assert(renderer.state and renderer.state.id, "Picker image did not acknowledge")
    local win = picker.preview.win.win
    assert(renderer.state.win == win, "Wrong preview window")
    assert(package.loaded["snacks.image"] == nil, "Snacks image was used")
    picker.preview:show(picker, { force = true })
  end,
  function()
    assert(renderer.state and renderer.state.id, "Preview redraw failed")
    results.cache = renderer.transfer:status()
    picker.opts.actions.confirm(picker)
  end,
  function()
    assert(done and not err, err or "Insertion not completed")
    assert(
      require("image_tools.document").at_line(buf, 2, { max_scan_lines = 100 }) == paths[1],
      "Wrong imported reference"
    )
    assert(renderer.transfer:status().images == 0, "Picker cache leaked")
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

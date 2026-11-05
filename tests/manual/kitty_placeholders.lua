local api = vim.api
local root, tmp = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
vim.opt.rtp:prepend(root)
vim.o.termguicolors, vim.o.swapfile = true, false
vim.o.showtabline, vim.o.laststatus = 0, 0
local image = require("image_tools")
image.setup({ auto_preview = false, transport = "file" })
local views, windows, phase = {}, {}, 1
for index, shape in ipairs({ { 40, 2 }, { 26, 48 } }) do
  local buf = api.nvim_create_buf(false, true)
  windows[index] = api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 2,
    col = shape[2],
    width = shape[1],
    height = 14,
    style = "minimal",
    border = "single",
    focusable = false,
  })
  views[index] = assert(image.render({ path = tmp .. "/white.png", buf = buf, win = windows[index] }))
end
local function save()
  local value = { phase = phase, columns = vim.o.columns, lines = vim.o.lines, rects = {} }
  for index, view in pairs(views) do
    if not view.closed then
      local pos = api.nvim_win_get_position(windows[index])
      local hl = api.nvim_get_hl(0, { name = view.highlight })
      assert(not hl.underline and hl.sp == nil, "Visible placeholder decoration")
      value.rects[#value.rects + 1] =
        { row = pos[1], col = pos[2], width = view.width, height = view.height, id = view.id }
    end
  end
  value.cache = image.status().terminal_cache
  vim.cmd.redraw()
  vim.fn.writefile({ vim.json.encode(value) }, tmp .. "/state.json")
end
local function settle()
  local ok, err = pcall(function()
    for _, view in pairs(views) do
      if not view.closed and (not view.session or view.session.stage ~= "ready") then
        vim.defer_fn(settle, 30)
        return
      end
    end
    save()
  end)
  if not ok then
    vim.fn.writefile({ tostring(err) }, tmp .. "/error.txt")
    vim.cmd.cquit()
  end
end
vim.keymap.set("n", "<F6>", function()
  phase = 2
  api.nvim_win_set_config(windows[1], { width = 44 })
  views[1]:resize()
  settle()
end)
vim.keymap.set("n", "<F7>", function()
  phase = 3
  views[1]:close()
  api.nvim_win_close(windows[1], true)
  settle()
end)
vim.keymap.set("n", "<F8>", function()
  phase = 4
  views[2]:close()
  api.nvim_win_close(windows[2], true)
  image.clear_cache()
  settle()
end)
vim.defer_fn(settle, 60)

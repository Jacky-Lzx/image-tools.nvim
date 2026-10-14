local root, tmp = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
vim.opt.rtp:prepend(root)
if vim.env.IMAGE_TOOLS_PARSER_ROOT then
  vim.opt.rtp:append(vim.env.IMAGE_TOOLS_PARSER_ROOT)
end
vim.o.termguicolors, vim.o.swapfile = true, false
local image = require("image_tools")
vim.api.nvim_buf_set_name(0, tmp .. "/main.tex")
vim.bo.filetype = "tex"
local lines = {}
for row = 1, 111 do
  lines[row] = "ordinary text"
end
vim.list_extend(lines, {
  [[  \includegraphics[]],
  [[    % scale=0.6]],
  [[    % width=\linewidth,]],
  [[    % height=3cm,]],
  [[    % keepaspectratio]],
  [[  ]{SC_multiplier_accurate.pdf}]],
  "ordinary text",
})
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.api.nvim_win_set_cursor(0, { 117, 0 })
image.setup({ position = "bottom_right", auto_preview = true, buffer = { enabled = false } })
local win, results = nil, { latex = true }
local function move(row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
end
local steps = {
  function()
    win = assert(image.status().window, "PDF on row 117 failed to preview")
    assert(image.status().path == tmp .. "/SC_multiplier_accurate.pdf", "Wrong multiline PDF source")
    assert(image.status().terminal_cache.uploads == 1, "Initial preview should upload once")
    move(112)
  end,
  function()
    assert(image.status().window == win, "Opening row recreated preview")
    move(115)
  end,
  function()
    assert(image.status().window == win, "Commented option row recreated preview")
    assert(image.status().terminal_cache.uploads == 1, "Range movement retransmitted pixels")
    results.range_preserved = true
    move(118)
  end,
  function()
    assert(image.status().window == nil, "Leaving range did not close preview")
    move(117)
  end,
  function()
    assert(image.status().window ~= nil, "Returning to path row did not preview")
    results.cache = image.status().terminal_cache
    assert(results.cache.uploads == 1 and results.cache.hits >= 1, "Returning did not reuse PDF pixels")
    results.range_lifecycle = true
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
  end, index == 1 and 1200 or 500)
end
step(1)

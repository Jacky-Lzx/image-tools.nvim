local root, tmp = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
vim.opt.rtp:prepend(root)
vim.o.termguicolors, vim.o.swapfile = true, false
vim.wo.wrap, vim.wo.foldmethod = false, "manual"
local image = require("image_tools")
local formula = vim.env.IMAGE_TOOLS_INLINE_MATH == "1"
local source = { "![visible](<中文 image (1).png>)", "ordinary text", "more text" }
if formula then
  vim.list_extend(source, { "$$", "\\frac{a}{b} + \\sqrt{x}", "$$" })
end
for row = #source + 1, 100 do
  source[row] = row == 70 and "![offscreen](missing.png)" or ("text " .. row)
end
local buf, owner = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_name(buf, tmp .. "/inline.md")
vim.bo[buf].filetype = "markdown"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
vim.bo[buf].modified = false
local tick = vim.api.nvim_buf_get_changedtick(buf)
image.setup({
  auto_preview = true,
  auto_preview_delay = 0,
  inline = { enabled = true, debounce = 0 },
  transport = vim.env.IMAGE_TOOLS_TEST_TRANSPORT,
  cache = tmp .. "/inline-cache",
  math = { foreground = "#cad3f5" },
})
local expected, step, split = formula and 2 or 1, 1, nil
local placements, deadline = {}, vim.uv.hrtime() + 12e9
local function marks()
  local found = {}
  for name, ns in pairs(vim.api.nvim_get_namespaces()) do
    if name:match("^image_tools.inline.window%.") then
      local scoped = vim.api.nvim__ns_get(ns).wins
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        if mark[4].virt_lines then
          local hl = mark[4].virt_lines[1][1][2]
          local attrs = vim.api.nvim_get_hl(0, { name = hl })
          found[#found + 1] = { win = scoped[1], row = mark[2] + 1, placement = attrs.sp }
        end
      end
    end
  end
  return found
end
local function poll()
  local ok, err = pcall(function()
    assert(vim.uv.hrtime() < deadline, "Inline TUI timed out: " .. vim.inspect(image.status()))
    local status = image.status()
    local inline = status.inline
    assert(not status.window, "Inline references must not also open automatic floats")
    if step == 1 and inline.ready == expected then
      assert(inline.failed == 0, "Offscreen missing files are never prepared")
      for _, mark in ipairs(marks()) do
        placements[#placements + 1] = mark.placement
      end
      vim.cmd.vsplit()
      split = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_width(split, 25)
      step = 2
    elseif step == 2 and inline.ready == expected * 2 then
      local scoped = marks()
      assert(#scoped == expected * 2)
      local per_window = {}
      for _, mark in ipairs(scoped) do
        per_window[mark.win] = (per_window[mark.win] or 0) + 1
        placements[#placements + 1] = mark.placement
      end
      assert(per_window[owner] == expected and per_window[split] == expected)
      assert(status.terminal_cache.uploads == expected, "Splits reuse image and formula pixels")
      vim.api.nvim_win_close(split, true)
      step = 3
    elseif step == 3 and inline.windows == 1 and inline.ready == expected then
      vim.cmd("1,2fold")
      step = 4
    elseif step == 4 and inline.ready == expected - 1 then
      for _, mark in ipairs(marks()) do
        assert(mark.row ~= 1, "Closed fold retained image decorations")
      end
      vim.cmd("normal! zR")
      step = 5
    elseif step == 5 and inline.ready == expected then
      vim.api.nvim_win_set_cursor(owner, { 1, 0 })
      vim.cmd("normal! zt")
      vim.cmd("normal! 3\5")
      step = 6
    elseif step == 6 and inline.ready == expected then
      local partial = vim.fn.winsaveview()
      assert(partial.topline == 2 and partial.topfill > 0, vim.inspect(partial))
      vim.api.nvim_win_set_cursor(owner, { 70, 0 })
      vim.cmd("normal! zt")
      step = 7
    elseif step == 7 and inline.ready == 0 and inline.failed == 1 then
      assert(vim.deep_equal(source, vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
      assert(vim.api.nvim_buf_get_changedtick(buf) == tick and not vim.bo[buf].modified)
      local result = {
        inline = true,
        scoped = true,
        lifecycle = true,
        source_preserved = true,
        shared_placements = placements,
        cache = status.terminal_cache,
      }
      image.clear_cache()
      assert(image.status().inline.images == 0)
      vim.fn.writefile({ vim.json.encode(result) }, tmp .. "/result.json")
      vim.cmd("qa!")
      return
    end
    vim.defer_fn(poll, 40)
  end)
  if not ok then
    vim.fn.writefile({ tostring(err), vim.inspect(image.status()) }, tmp .. "/error.txt")
    vim.cmd("cquit")
  end
end
vim.defer_fn(poll, 40)

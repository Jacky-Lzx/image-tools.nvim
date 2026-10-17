local root, tmp = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
vim.opt.rtp:prepend(root)
tmp = assert(vim.uv.fs_realpath(tmp))
-- Keep the headless screen's real dimensions. Changing 'columns' without an
-- attached UI makes Neovim's tabline overrun its grid when a second tab opens.
vim.o.termguicolors = true
vim.wo.wrap = false
local uv, actual = vim.uv, require("image_tools.media")
local fixture = tmp .. "/fixture.png"
assert(uv.fs_copyfile(root .. "/tests/fixtures/fixture.png", fixture))
assert(uv.fs_copyfile(fixture, tmp .. "/far.png"))
assert(uv.fs_copyfile(fixture, tmp .. "/slow.png"))
local requested, held, cancelled = {}, {}, 0
local image = {
  prepare = function(path, opts, callback)
    requested[#requested + 1] = { path = path, formula = opts._formula }
    if path:match("slow.png$") then
      held[#held + 1] = callback
      return function()
        cancelled = cancelled + 1
      end
    end
    if opts._formula then
      return actual.prepare(fixture, vim.tbl_extend("force", opts, { _formula = false }), function(err, value)
        if value then
          value.display_size = { width = 80, height = 40 }
        end
        callback(err, value)
      end)
    end
    return actual.prepare(path, opts, callback)
  end,
}
local terminal = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function() end,
  request = function(_, _, _, callback)
    local active = true
    vim.schedule(function()
      if active then
        callback(nil)
      end
    end)
    return function()
      active = false
    end
  end,
}
local options = require("image_tools.config").resolve({
  auto_preview_delay = 0,
  inline = { enabled = true, debounce = 0, max_height = 6 },
  cache = tmp .. "/inline-cache",
})
local runtime = require("image_tools.runtime").new(options, { terminal = terminal, image = image })
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, tmp .. "/inline.md")
vim.bo[buf].filetype = "markdown"
local lines = {
  "![first](fixture.png)",
  "text",
  "$$x^2$$",
  "text with $inline$",
  "text ![image](fixture.png)",
  "```",
  "![code](fixture.png)",
  "```",
  "\\[",
  "x=y",
  "\\]",
}
for i = #lines + 1, 120 do
  lines[i] = i == 70 and "![far](far.png)" or ("ordinary text " .. i)
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.bo[buf].modified = false
local tick = vim.api.nvim_buf_get_changedtick(buf)
vim.cmd.redraw()
runtime:start()
local function wait_for(predicate, label)
  assert(
    vim.wait(4000, function()
      vim.cmd.redraw()
      return predicate()
    end, 5),
    label .. ": " .. vim.inspect(runtime.inline:status())
  )
end
local function view(win)
  return assert(runtime.inline.views[win or vim.api.nvim_get_current_win()])
end
local function at(v, row)
  for _, entry in pairs(v.entries) do
    if entry.reference.start_row == row then
      return entry
    end
  end
end
wait_for(function()
  return runtime.inline:status().ready == 3
end, "Initial visible inline rendering")
assert(not runtime.preview or not runtime.preview.state, "Automatic floats skip inline references")
assert(vim.api.nvim_buf_get_changedtick(buf) == tick and not vim.bo[buf].modified)
assert(vim.deep_equal(lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false)), "Source bytes remain untouched")
local owner = vim.api.nvim_get_current_win()
local initial = view(owner)
local first = assert(at(initial, 1))
local original_id = first.id
assert(first.width == 16 and first.height == 5)
local marks = vim.api.nvim_buf_get_extmarks(buf, initial.ns, 0, -1, { details = true })
assert(#marks == 3 and #marks[1][4].virt_lines == 5)
assert(marks[1][4].virt_lines[1][1][1]:find(vim.fn.nr2char(0x10EEEE), 1, true))
assert(runtime:info().inline and runtime:info().ready)
for _, request in ipairs(requested) do
  assert(not request.path:match("far.png$"), "Offscreen files are not prepared")
end
local syncs = runtime.inline.syncs
vim.wait(120)
assert(runtime.inline.syncs - syncs < 6, "A stable redraw must not create a refresh loop")
-- Virtual line namespaces and Kitty placements are independent per split.
vim.cmd.vsplit()
local split = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_width(split, 10)
runtime.inline:sync()
wait_for(function()
  return runtime.inline:status().ready == 6
end, "Independent split rendering")
local other = view(split)
local other_first = assert(at(other, 1))
first = assert(at(view(owner), 1))
assert(first.width == 16 and other_first.width == 10)
assert(first.id == other_first.id and first.placement_id ~= other_first.placement_id)
assert(view(owner).ns ~= other.ns)
assert(vim.deep_equal(vim.api.nvim__ns_get(other.ns).wins, { split }))
vim.wo[split].wrap = true
runtime.inline:sync()
wait_for(function()
  return runtime.inline:status().ready == 5
end, "Wrapping excludes formulas below the narrow viewport")
assert(at(view(split), 1) and not at(view(split), 9))
vim.wo[split].wrap = false
runtime.inline:sync()
wait_for(function()
  return runtime.inline:status().ready == 6
end, "Disabling wrapping restores visible block formulas")
assert(
  runtime:terminal_status().uploads == 1,
  "Splits and placements share uploaded pixels: " .. vim.inspect(runtime:terminal_status()) .. vim.inspect(requested)
)
vim.api.nvim_win_close(split, true)
runtime.inline:sync()
wait_for(function()
  return runtime.inline:status().windows == 1 and runtime.inline:status().ready == 3
end, "Closing a split releases only that window")
-- Fold changes are detected from redraw even if the cursor never moves.
vim.wo[owner].foldmethod = "manual"
vim.cmd("1,2fold")
vim.cmd.redraw()
wait_for(function()
  return runtime.inline:status().ready == 2
end, "Closed folds release placements")
assert(not at(view(owner), 1))
vim.cmd("normal! zR")
vim.cmd.redraw()
wait_for(function()
  return runtime.inline:status().ready == 3
end, "Opening folds restores inline images")
-- Partial scrolling preserves the anchor above topline while topfill is visible.
vim.api.nvim_win_set_cursor(owner, { 1, 0 })
vim.cmd("normal! zt")
vim.cmd("normal! 3\5")
vim.cmd.redraw()
local partial = vim.fn.winsaveview()
assert(partial.topline == 2 and partial.topfill > 0, vim.inspect(partial))
runtime.inline:sync()
assert(at(view(owner), 1).id == original_id, "Partially scrolled virtual lines retain their image")
vim.api.nvim_win_set_cursor(owner, { 70, 0 })
vim.cmd("normal! zt")
runtime.inline:sync()
wait_for(function()
  return runtime.inline:status().ready == 1 and at(view(owner), 70) ~= nil
end, "Scrolling prepares newly visible files")
assert(not at(view(owner), 1), "Offscreen placements are released")
local far_id = at(view(owner), 70).id
assert(uv.fs_utime(tmp .. "/far.png", os.time() + 1, os.time() + 1))
runtime.inline:sync()
wait_for(function()
  local entry = at(view(owner), 70)
  return entry and entry.mark and entry.id ~= far_id
end, "Source revisions invalidate cached pixels")
vim.api.nvim_win_set_cursor(owner, { 1, 0 })
vim.cmd("normal! zt")
runtime.inline:sync()
wait_for(function()
  return runtime.inline:status().ready == 3
end, "Return to earlier images")
assert(at(view(owner), 1).id == original_id, "Returning reuses retained pixels")
-- Hidden tabs release placements; the same pixels are reusable on return.
local tab = vim.api.nvim_get_current_tabpage()
vim.cmd.tabnew()
runtime.inline:sync()
assert(runtime.inline:status().images == 0 and runtime:terminal_status().placements == 0)
vim.api.nvim_set_current_tabpage(tab)
runtime.inline:sync()
wait_for(function()
  return runtime.inline:status().ready == 3
end, "Returning to a tab restores its visible inline views")
assert(at(view(owner), 1).id == original_id)
vim.wo[owner].number, vim.wo[owner].signcolumn, vim.wo[owner].foldcolumn = true, "yes", "2"
runtime.inline:sync()
wait_for(function()
  return runtime.inline:status().ready == 3
end, "Gutter changes refit the text viewport")
assert(view(owner).width == vim.fn.getwininfo(owner)[1].width - vim.fn.getwininfo(owner)[1].textoff)
local previous_placement = at(view(owner), 1).placement_id
vim.api.nvim_exec_autocmds("ColorScheme", {})
wait_for(function()
  return runtime.inline:status().ready == 3
end, "Color changes replace inline placements")
assert(at(view(owner), 1).placement_id ~= previous_placement)
-- Clear pauses rendering until an explicit entry/resume event.
runtime:clear_cache()
vim.cmd.redraw()
vim.wait(100)
assert(runtime.inline:status().images == 0 and runtime:terminal_status().images == 0)
vim.api.nvim_exec_autocmds("WinEnter", {})
wait_for(function()
  return runtime.inline:status().ready == 3
end, "Window entry resumes paused inline rendering")
assert(not runtime:toggle_inline())
assert(runtime.inline:status().images == 0)
assert(runtime:toggle_inline())
wait_for(function()
  return runtime.inline:status().ready == 3
end, "Inline toggle restores rendering")
-- Text edits and late preparation results cannot restore old decorations.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "![slow](slow.png)", "outside" })
runtime.inline:sync()
assert(#held == 1)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "removed", "outside" })
runtime.inline:sync()
local uploads = runtime:terminal_status().uploads
held[1](nil, { path = fixture, key = "late", data = "late", width = 160, height = 100 })
assert(cancelled == 1 and runtime.inline:status().images == 0 and runtime:terminal_status().uploads == uploads)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "![missing](missing.png)" })
runtime.inline:sync()
wait_for(function()
  return runtime.inline:status().failed == 1
end, "Errors are retained without stale placeholders")
assert(runtime:info().inline and runtime:info().stage == "failed")
local requests = #requested
vim.wait(80)
assert(#requested == requests, "Failed entries do not continuously retry")
runtime:destroy()
assert(#vim.api.nvim_buf_get_extmarks(buf, initial.ns, 0, -1, {}) == 0)
assert(runtime.inline:status().images == 0)
-- Reconfiguration reuses namespace slots and cancels the previous provider/views.
package.loaded["image_tools.terminal"] = terminal
local api = require("image_tools")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "![first](fixture.png)" })
local function namespace_count()
  local count = 0
  for name in pairs(vim.api.nvim_get_namespaces()) do
    if name:match("^image_tools.inline.window%.") then
      count = count + 1
    end
  end
  return count
end
local namespace_slots = namespace_count()
for _ = 1, 3 do
  api.setup(options)
  assert(
    vim.wait(2000, function()
      vim.cmd.redraw()
      return api.status().inline.ready == 1
    end, 5),
    vim.inspect(api.status())
  )
  assert(namespace_count() == namespace_slots, "Reconfiguration recycles namespaces")
end
vim.cmd("ImageInlineToggle")
assert(not api.status().inline.enabled and api.status().inline.images == 0)
assert(api.toggle_inline())
assert(vim.wait(2000, function()
  vim.cmd.redraw()
  return api.status().inline.ready == 1
end, 5))
vim.api.nvim_exec_autocmds("VimSuspend", {})
assert(api.status().inline.images == 0 and api.status().inline.paused)
vim.wait(50)
assert(api.status().inline.images == 0)
vim.api.nvim_exec_autocmds("VimResume", {})
assert(vim.wait(2000, function()
  vim.cmd.redraw()
  return api.status().inline.ready == 1
end, 5))
api.setup({ auto_preview = false })
assert(not api.status().inline.enabled and api.status().terminal_cache == nil)
-- Non-document Markdown buffers retain automatic floating previews.
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(scratch, tmp .. "/scratch.md")
vim.bo[scratch].filetype = "markdown"
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "![first](fixture.png)" })
vim.api.nvim_set_current_buf(scratch)
api.setup({ auto_preview = true, auto_preview_delay = 0, inline = { enabled = true, debounce = 0 } })
assert(api.hover({ automatic = true, silent = true }))
assert(vim.wait(2000, function()
  return api.status().window ~= nil
end, 5))
assert(api.status().inline.images == 0, "Scratch buffers retain floats instead of suppressed inline views")
api.setup({ auto_preview = false })
print(
  "inline rendering: source preservation, visible-only work, split scoping/shared pixels, folds, partial scrolling, revision refresh, pause/toggle and stale cleanup passed"
)

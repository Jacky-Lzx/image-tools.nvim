vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local selection = vim.env.IMAGE_TOOLS_SELECTION_ROOT
if not selection then
  print("selection handoff: skipped (set IMAGE_TOOLS_SELECTION_ROOT)")
  return
end
vim.opt.rtp:prepend(selection)
vim.o.columns, vim.o.lines = 180, 80
local pending, cancelled, writes = {}, {}, {}
package.loaded["image_tools.terminal"] = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function(command)
    writes[#writes + 1] = command
  end,
  request = function(_, command, _, callback)
    writes[#writes + 1] = command
    local closed = false
    vim.schedule(function()
      if not closed then
        callback(nil)
      end
    end)
    return function()
      closed = true
    end
  end,
}
package.loaded["image_tools.media"] = {
  prepare = function(path, _, callback)
    pending[path] = callback
    return function()
      cancelled[path] = (cancelled[path] or 0) + 1
    end
  end,
}
local temp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP)) .. "/handoff"
vim.fn.mkdir(temp, "p")
for _, name in ipairs({ "a.png", "b.png", "c.png" }) do
  vim.fn.writefile({ "fixture" }, temp .. "/" .. name)
end
local doc = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(doc, temp .. "/note.md")
vim.bo.filetype = "markdown"
vim.api.nvim_buf_set_lines(doc, 0, -1, false, { "source" })
local tools = require("image_tools")
tools.setup({ auto_preview = false })
local p = assert(tools.pick({ picker = { cwd = temp } }))
assert(vim.wait(2000, function()
  return pending[temp .. "/a.png"]
end, 2))
local function complete(name)
  local path = temp .. "/" .. name
  pending[path](nil, { key = path, path = path, width = 160, height = 100, size = 100 })
end
complete("a.png")
assert(vim.wait(1000, function()
  return p.preview.provider and p.preview.provider.id
end, 2))
local a = p.preview.provider
local old_highlight = a.highlight
local grid = vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false)
p:move(1)
assert(
  vim.deep_equal(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false), grid),
  "Switch replaced the old image with Loading/blank before the next image was ready"
)
assert(not a.closed and tools.status().terminal_cache.placements == 1, "Visible image lost its placement lease")
assert(vim.wait(1000, function()
  return pending[temp .. "/b.png"]
end, 2))
local b = p.preview.provider
p:move(1)
assert(
  b.closed and not a.closed and cancelled[temp .. "/b.png"] == 1,
  "Skipped request cancels while retaining the last visible image"
)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false), grid))
local before = #writes
complete("b.png")
assert(#writes == before, "Late skipped image uploaded or replaced the retained view")
assert(vim.wait(1000, function()
  return pending[temp .. "/c.png"]
end, 2))
complete("c.png")
assert(vim.wait(1000, function()
  return p.preview.provider and p.preview.provider.id
end, 2))
local c = p.preview.provider
assert(
  a.closed and not c.closed and tools.status().terminal_cache.placements == 1,
  "Ready image atomically retires the previous lease"
)
assert(c.highlight ~= old_highlight, "New image was not painted")
assert(not vim.wo[p.preview_win].number, "Old view restored line numbers over its replacement")
local previous_callback = pending[temp .. "/b.png"]
p:move(-1)
assert(vim.wait(1000, function()
  return pending[temp .. "/b.png"] ~= previous_callback
end, 2))
assert(not c.closed)
p:close()
assert(
  c.closed and tools.status().terminal_cache.placements == 0,
  "Closing a pending replacement releases retained pixels"
)
assert(vim.api.nvim_buf_get_lines(doc, 0, -1, false)[1] == "source")
tools.clear_cache()
print(
  "selection handoff: old grid/lease preserved during preparation; skipped images cancelled; ready swap and close cleanup passed"
)

vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
vim.o.termguicolors = true
local requests = {}
package.loaded["image_tools.terminal"] = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function() end,
  request = function(_, _, _, callback)
    callback(nil)
    return function() end
  end,
}
local media = require("image_tools.media")
package.loaded["image_tools.media"] = {
  supported = media.supported,
  prepare = function(path, _, callback)
    requests[#requests + 1] = { path = path, callback = callback }
    return function() end
  end,
}
local api = require("image_tools")
vim.api.nvim_buf_set_name(0, "/tmp/delayed.md")
vim.bo.filetype = "markdown"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "![a](a.png) ![b](b.png)", "![c](c.png)", "plain" })
local function move(row, col)
  vim.api.nvim_win_set_cursor(0, { row, col or 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
end
local function settle()
  vim.wait(100)
end
api.setup({ auto_preview_delay = 40, treesitter = false })
move(1)
move(1, 14)
move(2)
assert(#requests == 0, "Crossing references does not start conversions")
assert(vim.wait(500, function()
  return #requests == 1
end))
assert(requests[1].path == vim.fs.dirname(vim.api.nvim_buf_get_name(0)) .. "/c.png", "Only the final selection starts")
assert(
  api.info().timings.automatic_delay_ms > 0 and api.info().timings.lookup_ms >= 0,
  "Automatic diagnostics include selection and actual delay"
)
move(2, 4)
settle()
assert(#requests == 1, "Movement within a selected source retains its preparation")
requests[1].callback(nil, { width = 10, height = 10, data = "pixels" })
local window = assert(api.status().window)
local total = api.info().timings.total_ms
move(2, 7)
assert(api.status().window == window and #requests == 1)
assert(api.info().timings.total_ms == total, "Same-source movement preserves completed timings")
move(1)
assert(#requests == 1)
api.hover({ silent = true })
assert(
  #requests == 2 and requests[2].path == vim.fs.dirname(vim.api.nvim_buf_get_name(0)) .. "/a.png",
  "Manual hover bypasses the delay"
)
assert(
  api.info().timings.lookup_ms >= 0 and not api.info().timings.automatic_delay_ms,
  "Manual hover has lookup time without an automatic wait"
)
settle()
assert(#requests == 2, "Manual preview cancels the queued automatic request")
move(1, 14)
api.preview("/tmp/explicit.png", { silent = true })
assert(#requests == 3 and requests[3].path == "/tmp/explicit.png")
assert(
  not api.info().timings.lookup_ms and not api.info().timings.automatic_delay_ms,
  "Explicit files do not inherit document selection timings"
)
settle()
assert(#requests == 3, "Explicit preview also supersedes automatic work")
move(2)
move(3)
settle()
assert(#requests == 3, "Leaving references cancels delayed work")
move(1)
api.clear_cache()
settle()
assert(#requests == 3, "Cache clearing cancels delayed work")
move(1)
api.setup({ auto_preview = false })
settle()
assert(#requests == 3, "Replacing the runtime cancels its timer")
api.setup({ auto_preview_delay = 0 })
move(1)
assert(#requests == 4, "Zero delay restores immediate preparation")
api.close()
assert(not pcall(require("image_tools.config").resolve, { auto_preview_delay = -1 }))
assert(not pcall(require("image_tools.config").resolve, { auto_preview_delay = 0.5 }))
print("Automatic preview delay: selection, manual bypass, reuse and cancellation passed")

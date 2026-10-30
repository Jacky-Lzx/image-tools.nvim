vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
vim.o.columns, vim.o.lines = 180, 80
local pending, placement, commands, hold = {}, nil, {}, false
package.loaded["image_tools.terminal"] = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function(command)
    commands[#commands + 1] = command
  end,
  request = function(_, command, _, callback)
    commands[#commands + 1] = command
    if hold and command:find("a=p", 1, true) then
      placement = callback
    else
      vim.schedule(function()
        callback(nil)
      end)
    end
    return function() end
  end,
}
package.loaded["image_tools.media"] = {
  prepare = function(path, _, callback)
    pending[path] = callback
    return function() end
  end,
}
local image = require("image_tools")
image.setup({ auto_preview = false })
local buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].modifiable = false
local win = vim.api.nvim_open_win(
  buf,
  false,
  { relative = "editor", row = 1, col = 1, width = 70, height = 20, style = "minimal" }
)
vim.wo[win].number = true
local function render(name, previous, callback)
  return assert(
    image.render({ path = "/tmp/" .. name .. ".png", buf = buf, win = win, previous = previous, on_error = callback })
  )
end
local function prepare(name)
  local path = "/tmp/" .. name .. ".png"
  assert(vim.wait(1000, function()
    return pending[path]
  end, 1))
  pending[path](nil, { path = path, key = path, width = 160, height = 100, size = 100 })
end
local function ready(view)
  assert(vim.wait(1000, function()
    return view.id
  end, 1))
end
local a = render("a")
prepare("a")
ready(a)
local grid = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local ns = vim.api.nvim_get_namespaces()["image_tools.embedded"]
local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
assert(a:retain() == a)
hold = true
local b = render("b", a)
prepare("b")
assert(vim.wait(1000, function()
  return placement ~= nil
end, 1))
assert(
  not a.closed and vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), grid),
  "Upload/placement wait erased old grid"
)
assert(
  vim.deep_equal(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }), marks),
  "Old image colors changed before acknowledgement"
)
placement(nil)
ready(b)
assert(a.closed and not b.closed and image.status().terminal_cache.placements == 1)
assert(
  b.group and #vim.api.nvim_get_autocmds({ group = b.group }) > 0,
  "Retiring predecessor removed replacement lifecycle hooks"
)
assert(not vim.wo[win].number)
hold = false
assert(b:retain() == b)
local failure
local c = render("c", b, function(message)
  failure = message
end)
assert(vim.wait(1000, function()
  return pending["/tmp/c.png"]
end, 1))
pending["/tmp/c.png"]("conversion failed")
assert(failure and c.closed and b.closed and image.status().terminal_cache.placements == 0)
assert(vim.wo[win].number and not vim.bo[buf].modifiable, "Failure did not restore the original pane options")
local d = render("d")
prepare("d")
ready(d)
assert(d:retain() == d)
local e = render("e", d)
assert(vim.wait(1000, function()
  return pending["/tmp/e.png"]
end, 1))
vim.api.nvim_win_close(win, true)
assert(
  d.closed and e.closed and image.status().terminal_cache.placements == 0,
  "Closing a pending handoff leaked its predecessor"
)
assert(vim.api.nvim_buf_is_valid(buf), "Renderer deleted the host buffer")
image.clear_cache()
print(
  "embedded handoff: old grid/colors survive upload and placement waits; retirement preserves new hooks; failure/close release both views"
)

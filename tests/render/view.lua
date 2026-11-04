vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
vim.o.columns, vim.o.lines = 180, 80
local count = 0
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local callbacks, hold, commands = {}, false, {}
local cancelled_preparations = 0
local terminal = {
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
    vim.schedule(function()
      callback(nil)
    end)
    return function() end
  end,
}
local image = {
  prepare = function(path, _, callback)
    local function deliver()
      callback(nil, { key = path, source = path, path = path, width = 160, height = 100, data = "pixels" })
    end
    if hold then
      callbacks[#callbacks + 1] = deliver
    else
      vim.schedule(deliver)
    end
    return function()
      cancelled_preparations = cancelled_preparations + 1
    end
  end,
}
package.loaded["image_tools.terminal"] = terminal
package.loaded["image_tools.media"] = image
local tools = require("image_tools")
check(tools.supports("figure.PDF") and not tools.supports("source.lua"), "Public format check")
check(not tools.status().configured, "Capabilities do not initialize services")
tools.setup({ auto_preview = false })
local origin = vim.api.nvim_get_current_win()
local function pane(width, height)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(
    buf,
    false,
    { relative = "editor", row = 1, col = 1, width = width or 50, height = height or 12, style = "minimal" }
  )
  vim.wo[win].number = true
  return buf, win
end
local function ready(view)
  check(
    vim.wait(2000, function()
      return view.session and view.session.stage == "ready"
    end, 1),
    "View becomes ready"
  )
end
local a, aw = pane()
local before = #vim.api.nvim_list_wins()
local first = assert(tools.render({ path = "/tmp/shared.png", buf = a, win = aw }))
ready(first)
check(
  #vim.api.nvim_list_wins() == before and vim.api.nvim_get_current_win() == origin,
  "No windows created and no focus stolen"
)
check(first.width == 39 and first.height == 12, "Geometry fits the borrowed viewport")
check(not vim.bo[a].modifiable and not vim.bo[a].modified and not vim.wo[aw].number, "Buffer flags and minimal view")
local id = first.id
vim.api.nvim_win_set_config(aw, { width = 100, height = 40 })
first:resize()
ready(first)
check(
  first.width == 100 and first.height == 32 and first.id == id,
  "Resize preserves ratio and reuses pixels: "
    .. vim.inspect({
      width = first.width,
      height = first.height,
      id = first.id,
      previous = id,
      viewport = { first:viewport() },
      status = tools.status().terminal_cache,
    })
)
check(tools.status().terminal_cache.uploads == 1, "Resizing uses a shared upload")
local b, bw = pane()
local second = assert(tools.render({ path = "/tmp/shared.png", buf = b, win = bw }))
ready(second)
check(second.id == first.id and second.placement_id ~= first.placement_id, "Two panes own independent placements")
local cancelled_before = cancelled_preparations
first:close()
first:close()
check(cancelled_preparations == cancelled_before + 1, "Preparation lease released exactly once")
check(
  vim.wo[aw].number and vim.api.nvim_buf_is_valid(a) and vim.api.nvim_win_is_valid(aw),
  "Close restores window and preserves host resources"
)
check(tools.status().terminal_cache.placements == 1 and not second.closed, "Closing one view preserves the other")
local logical = assert(tools.render({
  path = "/tmp/shared.png",
  buf = a,
  win = aw,
  display_size = { width = 80, height = 50 },
  upscale = false,
}))
ready(logical)
check(logical.width == 8 and logical.height == 3, "Embedded images respect logical size independently of raster DPI")
logical:close()
local old_grid = vim.api.nvim_buf_get_lines(b, 0, -1, false)
check(#old_grid > 0, "Second view retains its grid")
tools.clear_cache()
check(second.closed and vim.api.nvim_buf_is_valid(b), "Runtime cache cleanup releases embedded views")
local paints = 0
local third = assert(tools.render({
  path = "/tmp/shared.png",
  buf = a,
  win = aw,
  paint = function(draw)
    paints = paints + 1
    return draw()
  end,
}))
ready(third)
check(paints == 1, "Host paint callback encloses synchronous lines and marks")
local replacement = assert(tools.render({ path = "/tmp/other.png", buf = a, win = aw }))
check(third.closed, "Replacing the same target closes previous owner")
ready(replacement)
vim.api.nvim_win_set_buf(aw, vim.api.nvim_create_buf(false, true))
check(replacement.closed, "Leaving the target buffer closes its view")
hold = true
local valid = true
local stale = assert(tools.render({
  path = "/tmp/late.png",
  buf = b,
  win = bw,
  is_valid = function()
    return valid
  end,
}))
vim.wait(20)
check(#callbacks == 1, "Preparation can remain pending")
valid = false
callbacks[1]()
check(stale.closed and not stale.id, "Stale preparation never draws")
valid = true
local late = assert(tools.render({ path = "/tmp/late-close.png", buf = b, win = bw }))
vim.wait(20)
late:close()
callbacks[#callbacks]()
check(not late.id and late.closed, "Late completion after close is harmless")
hold = false
local reconfigured = assert(tools.render({ path = "/tmp/shared.png", buf = b, win = bw }))
ready(reconfigured)
vim.bo[b].modifiable = true
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "new host content" })
vim.bo[b].modifiable = false
tools.setup({ auto_preview = false })
check(vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == "new host content", "Cleanup preserves replacement host content")
check(reconfigured.closed, "Reconfiguration closes borrowed views")
local c, cw = pane()
local wiped = assert(tools.render({ path = "/tmp/wiped.png", buf = c, win = cw }))
ready(wiped)
vim.api.nvim_buf_delete(c, { force = true })
check(wiped.closed, "Wiping a host buffer releases its view")
if vim.api.nvim_win_is_valid(cw) then
  vim.api.nvim_win_close(cw, true)
end
local original_prepare = image.prepare
image.prepare = function()
  error("preparation threw")
end
local failure
local failed = assert(tools.render({
  path = "/tmp/failure.png",
  buf = b,
  win = bw,
  on_error = function(message)
    failure = message
  end,
}))
check(
  vim.wait(1000, function()
    return failure ~= nil
  end, 1),
  "Preparation exceptions reach the error hook"
)
check(failed.closed and vim.wo[bw].number, "Failure restores host options and closes the view")
local failed_default = assert(tools.render({ path = "/tmp/failure-default.png", buf = b, win = bw }))
local modified_before = vim.bo[b].modified
check(
  vim.wait(1000, function()
    return failed_default.closed
  end, 1),
  "Default failure closes its view"
)
check(
  vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]:find("preparation threw", 1, true)
    and vim.bo[b].modified == modified_before
    and not vim.bo[b].modifiable,
  "Default errors preserve scratch flags"
)
image.prepare = original_prepare
local invalid, invalid_error = tools.render({ path = "/tmp/shared.png", buf = b, win = bw, paint = "invalid" })
check(not invalid and invalid_error and vim.wo[bw].number, "Invalid callbacks leave the host unchanged")
local document = vim.api.nvim_create_buf(false, false)
local rejected, err = tools.render({ path = "/tmp/shared.png", buf = document, win = bw })
check(not rejected and err, "Document buffers cannot be overwritten")
vim.api.nvim_win_close(aw, true)
vim.api.nvim_win_close(bw, true)
tools.clear_cache()
check(
  not package.loaded["snacks"] and not package.loaded["snacks.image"],
  "Embedded rendering is independent of Snacks"
)
print(("image-tools embedded view: %d assertions passed"):format(count))

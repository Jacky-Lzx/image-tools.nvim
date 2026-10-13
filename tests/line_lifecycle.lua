local root = assert(vim.env.IMAGE_TOOLS_ROOT)
vim.opt.rtp:prepend(root)
vim.o.termguicolors = true
local checks, requests, writes, cancelled = 0, {}, {}, 0
local function eq(actual, expected, message)
  checks = checks + 1
  assert(
    vim.deep_equal(actual, expected),
    (message or "mismatch") .. "\n" .. vim.inspect(actual) .. "\n" .. vim.inspect(expected)
  )
end
local fixture = { data = "png-test-payload", width = 160, height = 100 }
package.loaded["image_tools.terminal"] = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function(data)
    writes[#writes + 1] = data
  end,
}
package.loaded["image_tools.image"] = {
  prepare = function(path, _, callback)
    requests[#requests + 1] = { path = path, callback = callback }
    return function()
      cancelled = cancelled + 1
    end
  end,
}
local api = require("image_tools")
vim.cmd("enew!")
local owner = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(owner, "/private/tmp/image-line-note.md")
vim.bo.filetype = "markdown"
vim.api.nvim_buf_set_lines(owner, 0, -1, false, {
  "prefix ![one](one.png) and ![two](two.png) suffix",
  "plain text",
  "another ![three](three.png) trailing text",
  "```markdown",
  "![code](code.png)",
  "```",
})
vim.api.nvim_win_set_cursor(0, { 1, 0 })
api.setup({ auto_preview = true, position = "bottom_right" })
vim.wait(20, function()
  return #requests > 0
end)
eq(#requests, 1, "setup should preview the current line without waiting for CursorHold")
eq(requests[1].path, "/private/tmp/one.png", "preview the first image even when the cursor is before it")
vim.api.nvim_win_set_cursor(0, { 1, 44 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
eq(#requests, 1, "horizontal movement must not restart a pending conversion")
eq(cancelled, 0)
vim.api.nvim_buf_set_lines(owner, 0, 1, false, { "changed prefix ![one](one.png) and ![two](two.png) suffix" })
vim.api.nvim_exec_autocmds("TextChangedI", {})
eq(#requests, 1, "editing surrounding text must preserve a pending conversion")
requests[1].callback(nil, fixture)
local window = assert(api.status().window, "horizontal movement must not reject conversion completion")
vim.api.nvim_win_set_cursor(0, { 1, 31 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
eq(api.status().window, window, "same-line movement over the second image must preserve the first preview")
eq(#writes, 1, "same-line movement must not reupload the image")
vim.api.nvim_exec_autocmds("InsertEnter", {})
vim.api.nvim_exec_autocmds("CursorMovedI", {})
eq(api.status().window, window, "Insert-mode movement on the same line must preserve the preview")
vim.api.nvim_buf_set_lines(owner, 0, 1, false, { "edited prefix ![one](one.png) and ![two](two.png) suffix" })
vim.api.nvim_exec_autocmds("TextChangedI", {})
eq(api.status().window, window, "editing surrounding text must retain the unchanged source")
eq(#requests, 1)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
eq(api.status().window, nil, "leaving the line must immediately close the preview")
eq(#writes, 2, "leaving the line must delete the owned image")
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
eq(requests[2].path, "/private/tmp/three.png", "entering another image line must start its preview immediately")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
requests[2].callback(nil, fixture)
eq(api.status().window, nil, "leaving during conversion must suppress its completion")
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.api.nvim_exec_autocmds("CursorMovedI", {})
vim.api.nvim_buf_set_lines(owner, 2, 3, false, { "![replacement](new.png)" })
vim.api.nvim_exec_autocmds("TextChangedI", {})
eq(requests[4].path, "/private/tmp/new.png", "changing the source must cancel the old request")
requests[3].callback(nil, fixture)
eq(api.status().window, nil)
requests[4].callback(nil, fixture)
assert(api.status().window)
vim.api.nvim_buf_set_lines(owner, 2, 3, false, { "no image now" })
vim.api.nvim_exec_autocmds("TextChanged", {})
eq(api.status().window, nil, "removing the image reference must close the preview")
vim.api.nvim_win_set_cursor(0, { 5, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
eq(#requests, 4, "fenced-code image syntax must not preview")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
requests[5].callback(nil, fixture)
assert(api.status().window)
vim.cmd("vsplit")
vim.wait(20, function()
  return #requests > 5
end)
eq(#requests, 6, "entering a different split must request a preview owned by that window")
requests[6].callback(nil, fixture)
window = assert(api.status().window)
vim.api.nvim_win_set_cursor(0, { 1, 10 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
eq(api.status().window, window)
vim.cmd("enew!")
vim.wait(20, function()
  return false
end)
eq(api.status().window, nil, "changing buffer must close even if the cursor row is unchanged")
api.setup({ auto_preview = false })
vim.api.nvim_set_current_buf(owner)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
vim.wait(20, function()
  return false
end)
eq(#requests, 6, "disabled automatic preview must not create a request")
api.hover()
requests[7].callback(nil, fixture)
window = assert(api.status().window)
vim.api.nvim_win_set_cursor(0, { 1, 40 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
eq(api.status().window, window, "manual line preview should also persist horizontally")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
eq(api.status().window, nil)
print("image-tools line lifecycle: " .. checks .. " assertions passed")

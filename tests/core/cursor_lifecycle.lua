vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
if vim.env.IMAGE_TOOLS_PARSER_ROOT then
  vim.opt.rtp:append(vim.env.IMAGE_TOOLS_PARSER_ROOT)
end
vim.o.termguicolors = true
local tmp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP)) .. "/cursor"
vim.fn.mkdir(tmp, "p")
for _, name in ipairs({ "a", "b" }) do
  assert(vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", tmp .. "/" .. name .. ".png"))
end
local requests, writes, replies, held, count = {}, {}, {}, false, 0
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local function await(predicate)
  check(vim.wait(2000, predicate, 1), "Cursor selection timed out")
end
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
    if held then
      replies[#replies + 1] = callback
    else
      callback(nil)
    end
    return function() end
  end,
}
local image = require("image_tools.image")
package.loaded["image_tools.image"] = vim.tbl_extend("force", image, {
  prepare = function(path, _, callback)
    local request = { path = path, callback = callback }
    requests[#requests + 1] = request
    return function()
      request.cancelled = true
    end
  end,
})
local api, document = require("image_tools"), require("image_tools.document")
local serial = 0
local lines = {
  markdown = "文字 ![first](a.png) and ![second](b.png) suffix",
  tex = "\\includegraphics{a.png} \\includegraphics{b.png} suffix",
  typst = '#image("a.png") #image("b.png") suffix',
}
local function buffer(filetype, text)
  serial = serial + 1
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, tmp .. "/note-" .. serial .. "." .. filetype)
  vim.bo.filetype = filetype
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  return buf
end
local function column(text, name)
  return assert(text:find(name, 1, true)) - 1
end
local function move(col, event)
  vim.api.nvim_win_set_cursor(0, { 1, col })
  vim.api.nvim_exec_autocmds(event or "CursorMoved", {})
end
local function complete(request)
  request.callback(nil, { path = request.path, key = request.path, width = 160, height = 100 })
end
local function newest(path)
  local request = requests[#requests]
  check(request and request.path == tmp .. "/" .. path, "Selected " .. path .. ": " .. vim.inspect(request))
  return request
end
for _, treesitter in ipairs(vim.env.IMAGE_TOOLS_PARSER_ROOT and { false, true } or { false }) do
  for _, filetype in ipairs({ "markdown", "tex", "typst" }) do
    local text = lines[filetype]
    local buf = buffer(filetype, text)
    vim.api.nvim_win_set_cursor(0, { 1, column(text, "b.png") })
    api.setup({ auto_preview = false, treesitter = treesitter, buffer = { enabled = false } })
    local before = #requests
    api.hover({ silent = true })
    await(function()
      return #requests > before
    end)
    complete(newest("b.png"))
    local window = assert(api.status().window)
    check(api.status().path == tmp .. "/b.png", filetype .. ": manual hover selects the second path")
    move(column(text, "b.png") + 2, "CursorMovedI")
    check(
      api.status().window == window and #requests == before + 1,
      "Movement within selected path retains conversion/window"
    )
    text = "prefix " .. text
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { text })
    vim.api.nvim_win_set_cursor(0, { 1, column(text, "b.png") + 1 })
    vim.api.nvim_exec_autocmds("TextChangedI", {})
    await(function()
      return api.status().window == window
    end)
    check(#requests == before + 1, "Surrounding edits with unchanged selection retain prepared pixels")
    move(column(text, "a.png"))
    local abandoned = newest("a.png")
    check(api.status().window == nil, "Switching paths immediately closes the old placement")
    move(column(text, "b.png"))
    local surviving = newest("b.png")
    local sent = #writes
    complete(abandoned)
    check(
      abandoned.cancelled and #writes == sent and api.status().window == nil,
      "Late first-path conversion cannot replace selected second path"
    )
    complete(surviving)
    check(
      api.status().window ~= nil and api.status().terminal_cache.uploads == 1,
      "Returning to second path reuses its cached upload"
    )
    move(column(text, "a.png"))
    complete(newest("a.png"))
    check(
      api.status().path == tmp .. "/a.png" and api.status().window ~= nil,
      "First path remains individually selectable"
    )
    move(column(text, "b.png"))
    complete(newest("b.png"))
    check(api.status().terminal_cache.uploads == 2, "Two paths retain separate reusable uploads")
    move(#text - 1)
    complete(newest("a.png"))
    check(api.status().path == tmp .. "/a.png", "Outside references uses the line's first image")
    local _, _, status = document.at_cursor(buf, 1, #text - 1, { treesitter = treesitter, max_scan_lines = 100 })
    check(status == "miss", "Strict cursor lookup reports a selection miss independently of fallback")
    -- A selected invalid destination must report its failure, not show another image.
    text = text:gsub("b.png", "https://invalid.example/b.png")
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { text })
    vim.api.nvim_win_set_cursor(0, { 1, column(text, "https:") + 2 })
    before = #requests
    local ok = api.hover({ silent = true })
    check(
      not ok and api.status().window == nil and #requests == before,
      "Invalid selected path does not fall back to the first image"
    )
    api.clear_cache()
  end
end
-- Cursor movement while awaiting an actual syntax tree must select the latest
-- column without starting a second parse or resuming the old column's request.
if vim.env.IMAGE_TOOLS_PARSER_ROOT then
  local original, callbacks = vim.treesitter.get_parser, {}
  vim.treesitter.get_parser = function(...)
    original(...)
    return {
      parse = function(_, _, callback)
        callbacks[#callbacks + 1] = callback
      end,
    }
  end
  for _, filetype in ipairs({ "tex", "typst" }) do
    local text = lines[filetype]
    local buf = buffer(filetype, text)
    vim.api.nvim_win_set_cursor(0, { 1, column(text, "a.png") })
    api.setup({ auto_preview = false, buffer = { enabled = false } })
    local parses, before = #callbacks, #requests
    api.hover({ silent = true })
    move(column(text, "b.png"))
    api.hover({ silent = true })
    check(#callbacks == parses + 1 and #requests == before, "Column movement coalesces the pending syntax parse")
    callbacks[#callbacks](nil, original(buf, filetype == "tex" and "latex" or "typst"):parse())
    await(function()
      return #requests == before + 1
    end)
    complete(newest("b.png"))
    check(
      api.status().path == tmp .. "/b.png" and api.status().window ~= nil,
      "Delayed syntax completion resumes only the latest cursor selection"
    )
    api.clear_cache()
  end
  vim.treesitter.get_parser = original
end
-- Late terminal acknowledgements are also bound to the selected image.
local text = lines.markdown
buffer("markdown", text)
vim.api.nvim_win_set_cursor(0, { 1, column(text, "b.png") })
api.setup({ auto_preview = false, buffer = { enabled = false } })
api.hover({ silent = true })
held = true
complete(newest("b.png"))
move(column(text, "a.png"))
local sent = #writes
replies[#replies](nil)
check(
  #writes == sent and not api.status().window,
  "Old upload acknowledgement cannot place an image after cursor selection changes"
)
held = false
complete(newest("a.png"))
check(
  api.status().path == tmp .. "/a.png" and api.status().window ~= nil,
  "Surviving selection renders after stale acknowledgement"
)
api.clear_cache()
print("cursor selection: " .. count .. " assertions passed")

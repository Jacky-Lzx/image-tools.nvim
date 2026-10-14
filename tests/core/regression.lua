local root, temporary = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
temporary = assert(vim.uv.fs_realpath(temporary))
vim.opt.rtp:prepend(root)
local count = 0
local function eq(actual, expected, message)
  count = count + 1
  assert(
    vim.deep_equal(actual, expected),
    (message or "mismatch") .. "\n" .. vim.inspect(actual) .. "\n" .. vim.inspect(expected)
  )
end
local function await(predicate)
  assert(vim.wait(5000, predicate, 10), "asynchronous operation timed out")
end
local api = require("image_tools")
eq(api.status().configured, false, "require must not setup")
eq(vim.fn.exists(":ImagePreview"), 0)
local document, protocol = require("image_tools.document"), require("image_tools.terminal.protocol")
local opts = {
  max_bytes = 32 * 1024 * 1024,
  max_dimension = 16384,
  max_pixels = 64 * 1024 * 1024,
  magick = "magick",
  convert_timeout = 5000,
  cache = temporary .. "/converted",
  max_scan_lines = 10000,
}

eq(document.parse("![alt](images/a.png)")[1], { src = "images/a.png", start_col = 0, end_col = 20 })
eq(document.parse('![a](<images/a b.png> "caption")')[1].src, "images/a b.png")
eq(document.parse("![a](a(b(c)).png)")[1].src, "a(b(c)).png")
eq(document.parse("![a](a\\(b\\).png)")[1].src, "a\\(b\\).png")
eq(document.parse('![a](foo.png "title")')[1].src, "foo.png")
eq(document.parse('![a](foo.png "title (with parentheses)")')[1].src, "foo.png")
eq(document.parse('![a](<a)b.png> "title )")')[1].src, "a)b.png")
eq(#document.parse("![a](foo.png) ![b](bar.png)"), 2)
eq(#document.parse("\\![a](foo.png)"), 0)
eq(#document.parse("`![a](foo.png)`"), 0)
eq(#document.parse("``x ` ![a](foo.png)``"), 0)
eq(#document.parse("![a](foo.png"), 0)
eq(#document.parse("![a][reference]"), 0)
eq(#document.parse("![a](a b.png)"), 0)
eq(document.resolve("../Figures/a%20b.png", "/project/docs/note.md", {}), "/project/Figures/a b.png")
eq(document.resolve("a\\(b\\).png", "/project/note.md", {}), "/project/a(b).png")
eq(document.resolve("a.png", "/project/docs/note.md", { root = "/project" }), "/project/a.png")
eq(
  document.resolve("a.png", "/project/note.md", {
    resolve = function()
      return "/custom/a.png"
    end,
  }),
  "/custom/a.png"
)
eq(document.resolve("https://example.org/a.png", "/project/note.md", {}), nil)
eq(document.resolve("a.png", "", {}), nil)
eq(document.resolve("a%00.png", "/project/note.md", {}), nil)

vim.cmd("enew")
local owner = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(owner, temporary .. "/note.md")
vim.bo[owner].filetype = "markdown"
vim.api.nvim_buf_set_lines(
  owner,
  0,
  -1,
  false,
  { "```markdown", "![a](a.png)", "```", "![a](a.png)", "    ![a](a.png)" }
)
eq(document.at_cursor(owner, 2, 3, opts), nil, "fenced code must not preview")
eq(document.at_cursor(owner, 4, 3, opts), temporary .. "/a.png")
eq(document.at_cursor(owner, 5, 7, opts), nil, "indented code must not preview")
vim.cmd("lcd /private/tmp")
eq(document.at_cursor(owner, 4, 3, opts), temporary .. "/a.png", "cwd must not change Markdown resolution")

local grid = protocol.grid(3, 2)
eq(vim.fn.strdisplaywidth(grid[1]), 3)
eq(vim.fn.strdisplaywidth(grid[2]), 3)
eq(grid[1]:sub(1, 8), vim.fn.nr2char(0x10EEEE) .. vim.fn.nr2char(0x305) .. vim.fn.nr2char(0x305))
eq(protocol.max_cells, 297)
local wide_grid = protocol.grid(120, 80)
eq(vim.fn.strdisplaywidth(wide_grid[80]), 120, "large grids preserve cell widths")
eq(
  wide_grid[65]:sub(1, 8),
  vim.fn.nr2char(0x10EEEE) .. vim.fn.nr2char(0x659) .. vim.fn.nr2char(0x305),
  "coordinate 64 uses the official diacritic"
)
local payload = string.rep("abcdef", 2000)
local uploaded, decoded = protocol.upload(123, payload), {}
local chunks = 0
for fields, data in uploaded:gmatch("\27_G([^;]+);(.-)\27\\") do
  chunks = chunks + 1
  assert(#data <= 4096 and #data % 4 == 0)
  if chunks == 1 then
    assert(fields:find("a=t", 1, true) and fields:find("i=123", 1, true))
  else
    assert(not fields:find("i=", 1, true))
  end
  decoded[#decoded + 1] = data
end
eq(vim.base64.decode(table.concat(decoded)), payload, "chunked transfer must preserve bytes")
assert(uploaded:find("m=0", 1, true))
assert(protocol.place(123, 3, 2):find("U=1", 1, true))
assert(protocol.delete(123):find("d=I", 1, true))
assert(not protocol.delete(123):find("d=A", 1, true))

local image = require("image_tools.media")
local fixture = root .. "/tests/fixtures/fixture.png"
local prepared, failure
image.prepare(fixture, opts, function(err, value)
  failure, prepared = err, value
end)
await(function()
  return prepared ~= nil or failure ~= nil
end)
assert(not failure, failure)
eq({ prepared.width, prepared.height }, { 160, 100 })
eq(image.info("not an image", opts), nil)
local limited = vim.tbl_extend("force", opts, { max_dimension = 10 })
eq(image.info(prepared.data, limited), nil)
local done = false
image.read(fixture, vim.tbl_extend("force", opts, { max_bytes = 10 }), function(err)
  assert(err:find("max_bytes", 1, true))
  done = true
end)
await(function()
  return done
end)
local called = false
local cancel = image.prepare(fixture, opts, function()
  called = true
end)
cancel()
vim.wait(100, function()
  return false
end)
eq(called, false, "cancelled reads must not complete")

-- Real Neovim float/buffer lifecycle, with only terminal IO replaced.
local writes, callbacks, cancellations = {}, {}, 0
local transport = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function(data)
    writes[#writes + 1] = data
  end,
  request = function(_, command, _, callback)
    writes[#writes + 1] = command
    callback(nil)
    return function() end
  end,
}
local loader = {
  prepare = function(_, _, callback)
    callbacks[#callbacks + 1] = callback
    return function()
      cancellations = cancellations + 1
    end
  end,
}
local preview_opts = vim.tbl_extend("force", opts, { max_width = 60, max_height = 30, border = "rounded" })
local preview = require("image_tools.render.preview").new(preview_opts, { terminal = transport, image = loader })
local width, height = require("image_tools.render.preview").fit(
  { width = 1600, height = 1000 },
  { width = 10, height = 20 },
  40,
  30
)
eq({ width, height }, { 40, 13 })
local fit = require("image_tools.render.preview").fit
local function fitted(image, max_width, max_height, upscale)
  return { fit(image, { width = 10, height = 20 }, max_width, max_height, upscale) }
end
eq(fitted({ width = 160, height = 100 }, 100, 40, true), { 100, 32 }, "picker upscales to pane width")
eq(fitted({ width = 100, height = 400 }, 100, 40, true), { 20, 40 }, "portrait fills height without stretching")
eq(fitted({ width = 160, height = 100 }, 100, 40), { 16, 5 }, "floating preview retains native-size cap")
eq(fitted({ width = 1600, height = 1000 }, 20, 4, true), { 13, 4 }, "small pane bounds")
preview:open(fixture)
preview:close()
callbacks[1](nil, prepared)
eq(preview.state, nil, "stale callback must not reopen preview")
eq(#writes, 0)
preview:open(fixture)
preview:open(fixture)
callbacks[2](nil, prepared)
eq(preview.state.win, nil, "older request must not render")
callbacks[3](nil, prepared)
local state = assert(preview.state)
assert(vim.api.nvim_win_is_valid(state.win))
eq(vim.api.nvim_win_get_width(state.win), 16)
eq(vim.api.nvim_win_get_height(state.win), 5)
eq(vim.api.nvim_get_current_buf(), owner, "preview must not steal focus")
eq(#writes, 2)
preview:close()
eq(vim.api.nvim_win_is_valid(state.win), false)
eq(vim.api.nvim_buf_is_valid(state.buf), false)
eq(#writes, 3)
assert(writes[3]:find("i=" .. state.id, 1, true), "cleanup must hide only the owned id")
preview:close()
eq(#writes, 3, "close must be idempotent")
preview:open(fixture)
vim.api.nvim_win_set_cursor(0, { 4, 1 })
callbacks[4](nil, prepared)
eq(preview.state, nil, "cursor changes must invalidate a pending preview")
preview:open(fixture)
vim.api.nvim_buf_set_lines(owner, 3, 4, false, { "changed" })
callbacks[5](nil, prepared)
eq(preview.state, nil, "document changes must invalidate a pending preview")
preview:open(fixture)
vim.cmd("enew!")
callbacks[6](nil, prepared)
eq(preview.state, nil, "buffer switches must invalidate a pending preview")

-- Headless Neovim exposes anchor coordinates; the TUI test additionally checks
-- the resolved border position after the window is actually drawn.
local corner = require("image_tools.render.preview").new(
  vim.tbl_extend("force", preview_opts, { position = "bottom_right" }),
  { terminal = transport, image = loader }
)
local saved =
  { lines = vim.o.lines, columns = vim.o.columns, cmdheight = vim.o.cmdheight, laststatus = vim.o.laststatus }
local function corner_bounds(laststatus, cmdheight, status_rows)
  vim.o.laststatus, vim.o.cmdheight = laststatus, cmdheight
  corner:open(fixture)
  callbacks[#callbacks](nil, prepared)
  local win = assert(corner.state.win)
  local config = vim.api.nvim_win_get_config(win)
  eq(config.anchor, "SE")
  eq(config.col, vim.o.columns, "border must reach the editor's right edge")
  eq(config.row, vim.o.lines - cmdheight - status_rows, "bottom border must stay above command and status lines")
  assert(config.width + 2 <= vim.o.columns, "float must fit a narrow editor")
  assert(config.height + 2 + cmdheight + status_rows <= vim.o.lines, "float must fit a short editor")
  corner:close()
end
corner_bounds(2, 1, 1)
corner_bounds(3, 2, 1)
corner_bounds(0, 0, 0)
corner_bounds(1, 1, 0)
vim.cmd("vsplit")
corner_bounds(1, 1, 1)
vim.cmd("close")
vim.o.lines, vim.o.columns = 12, 12
corner_bounds(2, 1, 1)
vim.o.lines, vim.o.columns = saved.lines, saved.columns
vim.o.cmdheight, vim.o.laststatus = saved.cmdheight, saved.laststatus

-- Verify actual setup handlers and repeated setup without real terminal output.
package.loaded["image_tools.terminal"] = transport
api.setup({ auto_preview = false })
local groups = #vim.api.nvim_get_autocmds({ group = "image_tools" })
api.setup({ auto_preview = false })
eq(#vim.api.nvim_get_autocmds({ group = "image_tools" }), groups)
eq(vim.fn.exists(":ImagePreview"), 2)
api.preview(fixture)
await(function()
  return api.status().window ~= nil
end)
eq(vim.api.nvim_win_get_config(api.status().window).anchor, "NW", "default placement must remain near the cursor")
local old_window = api.status().window
vim.api.nvim_exec_autocmds("VimResized", {})
eq(api.status().window, nil)

local real_transport = require("image_tools.terminal")
-- The original implementation is loaded separately because the preview suite
-- replaces only the module transport, not Neovim's environment APIs.
local terminal = dofile(root .. "/lua/image_tools/terminal/init.lua")
eq(terminal.supports({}), false, "headless operation must not write graphics")
local uis = vim.api.nvim_list_uis
vim.api.nvim_list_uis = function()
  return { { chan = 1 } }
end
local tmux, zellij, kitty, term = vim.env.TMUX, vim.env.ZELLIJ, vim.env.KITTY_WINDOW_ID, vim.env.TERM
vim.o.termguicolors = true
vim.env.KITTY_WINDOW_ID, vim.env.TMUX, vim.env.ZELLIJ = "test", nil, nil
eq(terminal.supports({}), true)
vim.env.TMUX = "test"
eq(terminal.supports({}), false, "multiplexers must be rejected explicitly")
vim.env.TMUX, vim.env.KITTY_WINDOW_ID, vim.env.TERM = nil, nil, "unknown-terminal"
eq(terminal.supports({}), false)
eq(terminal.supports({ force = true }), true)
local has = vim.fn.has
vim.fn.has = function(name)
  return name == "nvim-0.12" and 0 or has(name)
end
eq(terminal.supports({ force = true }), false, "old Neovim versions need an explicit compatibility diagnostic")
vim.fn.has = has
vim.api.nvim_list_uis = uis
vim.env.TMUX, vim.env.ZELLIJ, vim.env.KITTY_WINDOW_ID, vim.env.TERM = tmux, zellij, kitty, term
package.loaded["image_tools.terminal"] = real_transport
eq(vim.api.nvim_win_is_valid(old_window), false)
api.preview(fixture)
await(function()
  return api.status().window ~= nil
end)
old_window = api.status().window
vim.api.nvim_win_close(old_window, true)
eq(api.status().window, nil, "external float close must free the image")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "first", "second" })
api.preview(fixture)
await(function()
  return api.status().window ~= nil
end)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
eq(api.status().window, nil)
api.preview(fixture)
api.close()
vim.wait(100, function()
  return false
end)
eq(api.status().window, nil)
api.setup({ auto_preview = true })
vim.bo.filetype = "markdown"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "![fixture](" .. fixture .. ")" })
vim.api.nvim_win_set_cursor(0, { 1, 3 })
vim.api.nvim_exec_autocmds("CursorHold", {})
await(function()
  return api.status().window ~= nil
end)
vim.api.nvim_exec_autocmds("InsertEnter", {})
assert(api.status().window, "entering Insert mode on the same line must retain the preview")
api.close()

if vim.fn.executable("magick") == 1 then
  local avif = temporary .. "/中文 image (1)%.avif"
  assert(vim.system({ "magick", fixture, avif }):wait().code == 0)
  local before = vim.uv.fs_stat(avif)
  prepared, failure = nil, nil
  image.prepare(avif, opts, function(err, value)
    failure, prepared = err, value
  end)
  await(function()
    return prepared ~= nil or failure ~= nil
  end)
  assert(not failure, failure)
  assert(vim.uv.fs_stat(prepared.path), "converted PNG must be atomically cached")
  eq(vim.uv.fs_stat(avif).mtime, before.mtime, "conversion must preserve the original")
  local cached_path = prepared.path
  prepared = nil
  image.prepare(avif, opts, function(err, value)
    failure, prepared = err, value
  end)
  await(function()
    return prepared ~= nil or failure ~= nil
  end)
  eq(prepared.path, cached_path, "unchanged images should reuse cache")
  local copy = temporary .. "/cancelled.avif"
  assert(vim.uv.fs_copyfile(avif, copy))
  local invoked = false
  local cancel_conversion = image.prepare(copy, opts, function()
    invoked = true
  end)
  -- Execute the scheduled subprocess launch, then cancel the pending result.
  vim.wait(1, function()
    return false
  end)
  cancel_conversion()
  vim.wait(200, function()
    return false
  end)
  eq(invoked, false, "cancelled conversion must not complete")
  eq(#vim.fn.glob(opts.cache .. "/*.tmp.png", false, true), 0, "cancelled conversion must clean temporary files")
end
print("image-tools: " .. count .. " assertions passed, including float lifecycle and asynchronous conversion")

vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local uv, remote = vim.uv, require("image_tools.media.remote")
local base = assert(vim.env.IMAGE_TOOLS_HTTPS_URL)
local root = assert(vim.env.IMAGE_TOOLS_TEST_TMP)
local opts = require("image_tools.config").resolve({
  auto_preview = false,
  cache = root .. "/remote-cache",
  remote = {
    enabled = true,
    curl = assert(vim.env.IMAGE_TOOLS_HTTPS_CURL),
    timeout = 2000,
  },
})
local function await(start)
  local done, failure, result, close
  close = start(function(err, value)
    done, failure, result = true, err, value
  end)
  assert(
    vim.wait(10000, function()
      return done
    end, 1),
    "HTTPS operation timed out"
  )
  return result, failure, close
end
local function fetch(path, extra)
  return await(function(cb)
    return remote.fetch(base .. path, vim.tbl_deep_extend("force", opts, extra or {}), cb)
  end)
end
local disabled, disabled_err, close = fetch("/disabled.png", { remote = { enabled = false } })
assert(not disabled and disabled_err:find("Enable remote.enabled"))
close()
assert(not remote.validate("http://example.com/image.png", opts))
assert(not remote.validate("https://example.com/a\n.png", opts))
local paths = require("image_tools.document.paths")
assert(paths.resolve(base .. "/image.png?x=1%202", root .. "/note.md", opts) == base .. "/image.png?x=1%202")
assert(not paths.resolve("file:///tmp/image.png", root .. "/note.md", opts))
local path, err
path, err, close = fetch("/image.png")
assert(path, err)
assert(
  vim.deep_equal(
    vim.fn.readfile(path, "b"),
    vim.fn.readfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", "b")
  )
)
local initial = remote.status().downloads
close()
path, err, close = fetch("/image.png")
assert(path and remote.status().downloads == initial and remote.status().hits >= 1, err)
close()
path, err, close = fetch("/image.png", { _remote_refresh = true })
assert(path and remote.status().downloads == initial + 1, err)
close()
assert(uv.fs_utime(path, os.time() - 7200, os.time() - 7200))
path, err, close = fetch("/image.png")
assert(path and remote.status().downloads == initial + 2, "Expired entries are downloaded again")
close()
path, err, close = fetch("/image.png", { remote = { curl = root .. "/missing-curl" } })
assert(not path and err:find("downloader not found"), tostring(err))
close()
path, err, close = fetch("/redirect")
assert(path, err)
close()
for _, endpoint in ipairs({ "/http-redirect", "/missing", "/invalid", "/broken.png", "/loop" }) do
  path, err, close = fetch(endpoint)
  assert(not path and err, endpoint .. " must fail")
  close()
end
path, err, close = fetch("/huge.png", { max_bytes = 1024 })
assert(not path and err:find("max_bytes"), tostring(err))
close()
path, err, close = fetch("/slow.png?timeout=1", { remote = { timeout = 20 } })
assert(not path and err:find("download failed"), tostring(err))
close()
path, err, close = fetch("/image.png?dimensions=1", { max_dimension = 10 })
assert(not path and err:find("dimensions"), tostring(err))
close()
-- Coalesced requests retain independent cancellation authority.
local first_called, second_done, shared, second_error
local first = remote.fetch(base .. "/shared.png", opts, function()
  first_called = true
end)
local second = remote.fetch(base .. "/shared.png", opts, function(e, p)
  second_done, shared, second_error = true, p, e
end)
first()
assert(vim.wait(5000, function()
  return second_done
end, 1))
assert(shared and not first_called, second_error)
second()
local stale_called
close = remote.fetch(base .. "/slow.png?cancel=1", opts, function()
  stale_called = true
end)
vim.wait(20)
close()
vim.wait(350)
assert(not stale_called and remote.status().pending == 0)
-- Real HTTPS flows through the normal floating renderer with simulated terminal acknowledgements.
local terminal = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function() end,
  request = function(_, _, _, cb)
    local active = true
    vim.schedule(function()
      if active then
        cb(nil)
      end
    end)
    return function()
      active = false
    end
  end,
}
vim.o.termguicolors = true
local Runtime = require("image_tools.runtime")
local runtime = Runtime.new(opts, { terminal = terminal })
runtime:start()
assert(runtime:open_preview(base .. "/image.png"))
assert(vim.wait(5000, function()
  return runtime.preview and runtime.preview.state and runtime.preview.state.win ~= nil
end, 1))
assert(runtime:info().path == base .. "/image.png" and runtime:info().format == "png" and runtime:info().bytes > 0)
local downloads = remote.status().downloads
assert(runtime:reload())
assert(vim.wait(5000, function()
  return runtime.preview and runtime.preview.state and runtime.preview.state.win ~= nil
end, 1))
assert(remote.status().downloads == downloads + 1, "Reload bypasses URL cache")
runtime:close()
assert(runtime:open_preview(base .. "/slow.png?preview-cancel=1"))
runtime:close()
vim.wait(350)
assert(not runtime.preview.state, "Cancelled downloads cannot reopen previews")
-- Document-driven automatic selection retains the same stale-result authority.
local automatic = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(automatic)
vim.api.nvim_buf_set_name(automatic, root .. "/automatic.md")
vim.bo[automatic].filetype = "markdown"
vim.api.nvim_buf_set_lines(automatic, 0, -1, false, { "![remote](" .. base .. "/slow.png?automatic=1)", "elsewhere" })
runtime.options.auto_preview, runtime.options.auto_preview_delay = true, 0
vim.api.nvim_win_set_cursor(0, { 1, 0 })
runtime:refresh()
vim.api.nvim_win_set_cursor(0, { 2, 0 })
runtime:refresh()
vim.wait(350)
assert(not runtime.preview.state, "Leaving a remote reference cancels automatic preparation")
vim.api.nvim_buf_set_lines(automatic, 0, 1, false, { "![remote](" .. base .. "/image.png)" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
runtime:refresh()
assert(vim.wait(5000, function()
  return runtime.preview.state and runtime.preview.state.win
end, 1))
assert(runtime:info().path == base .. "/image.png")
runtime:destroy()
opts.auto_preview = false
-- Localize just the destination, preserving original bytes and markup.
local localize = require("image_tools.workflow.localize")
local function buffer(name, ft, lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, root .. "/" .. name)
  vim.bo[buf].filetype = ft
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return buf
end
local buf = buffer("note.md", "markdown", { "![keep](<" .. base .. '/wrong-extension.jpg?query=1> "title")' })
local inline_runtime = Runtime.new(
  vim.tbl_deep_extend("force", opts, { inline = { enabled = true, debounce = 0 } }),
  { terminal = terminal }
)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "![remote](" .. base .. "/image.png)" })
inline_runtime:start()
assert(
  vim.wait(5000, function()
    vim.cmd.redraw()
    return inline_runtime.inline:status().ready == 1
  end, 5),
  vim.inspect(inline_runtime.inline:status())
)
assert(inline_runtime:info().inline and inline_runtime:info().path == base .. "/image.png")
inline_runtime:destroy()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "![keep](<" .. base .. '/wrong-extension.jpg?query=1> "title")' })
local outputs
outputs, err = await(function(cb)
  return localize.run(vim.tbl_deep_extend("force", opts, { remote = { enabled = false } }), cb)
end)
assert(outputs, err)
assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == '![keep](<Figures/wrong-extension.png> "title")')
assert(
  vim.deep_equal(
    vim.fn.readfile(outputs[1], "b"),
    vim.fn.readfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", "b")
  )
)
buf = buffer("reference.md", "markdown", { "![label][id]", "[id]: " .. base .. "/no-extension 'title'" })
outputs, err = await(function(cb)
  return localize.run(opts, cb)
end)
assert(outputs and outputs[1]:match("%.jpg$"), err)
assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "![label][id]")
assert(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "[id]: Figures/no-extension.jpg 'title'")
buf = buffer("page.html", "html", { '<img alt="keep" src="' .. base .. '/image.png" width=50>' })
outputs, err = await(function(cb)
  return localize.run(opts, cb)
end)
assert(outputs, err)
assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == '<img alt="keep" src="Figures/image.png" width=50>')
-- Editing/renaming/unloading while downloading rejects the replacement and rolls back copies.
buf = buffer("changed.md", "markdown", { "![keep](" .. base .. "/slow.png?edit=1)" })
outputs, err = await(function(cb)
  local cancel = localize.run(opts, cb)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "user edit" })
  return cancel
end)
assert(not outputs and err:find("Document changed"), tostring(err))
assert(not uv.fs_stat(root .. "/Figures/slow.png"))
buf = buffer("rollback.md", "markdown", { "![keep](" .. base .. "/image.png)" })
local set_text = vim.api.nvim_buf_set_text
vim.api.nvim_buf_set_text = function(buffer_id, ...)
  if buffer_id == buf then
    error("injected replacement failure")
  end
  return set_text(buffer_id, ...)
end
outputs, err = await(function(cb)
  return localize.run(vim.tbl_extend("force", opts, { filename = "rollback.png" }), cb)
end)
vim.api.nvim_buf_set_text = set_text
assert(not outputs and err:find("injected replacement failure"), tostring(err))
assert(not uv.fs_stat(root .. "/Figures/rollback.png"), "Failed replacements remove newly imported resources")
assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "![keep](" .. base .. "/image.png)")
-- Reconfiguration cancels pending localization without touching the source document.
buf = buffer("reconfigure.md", "markdown", { "![keep](" .. base .. "/slow.png?reconfigure=1)" })
local api = require("image_tools")
api.setup(opts)
local reconfigured_callback
api.localize({}, function()
  reconfigured_callback = true
end)
vim.wait(10)
api.setup(opts)
vim.wait(350)
assert(not reconfigured_callback and not uv.fs_stat(root .. "/Figures/slow.png"))
assert(#vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("image_tools.insert"), 0, -1, {}) == 0)
buf = buffer("untouched.md", "markdown", { "![remote](" .. base .. "/image.png)" })
local report
report, err = await(function(cb)
  return require("image_tools.workflow.assets").check(opts, cb)
end)
assert(report and #report.missing == 0, err)
-- Cache cleanup recognizes and protects downloaded originals, including JPEG.
path, err, close = fetch("/no-extension")
assert(path and path:match("%.jpg$"), err)
local cleared
require("image_tools.media.disk_cache").clear(opts, function(value)
  cleared = value
end)
assert(vim.wait(5000, function()
  return cleared ~= nil
end, 1))
assert(uv.fs_stat(path) and cleared.protected >= 1, "Active remote files are pinned")
close()
cleared = nil
require("image_tools.media.disk_cache").clear(opts, function(value)
  cleared = value
end)
assert(vim.wait(5000, function()
  return cleared ~= nil
end, 1))
assert(not uv.fs_stat(path), "Unused downloaded originals can be cleared")
assert(cleared.protected == 0, "All remote workflow leases are released")
assert(remote.status().pending == 0)
print(
  "HTTPS media: TLS/redirects, sniffing, cache, limits, sharing, cancellation, preview/reload and reference localization passed"
)

local root = assert(vim.env.IMAGE_TOOLS_ROOT)
vim.opt.rtp:prepend(root)
local count = 0
local function check(ok, message)
  count = count + 1
  assert(ok, message)
end
local deferred = {
  "render.preview",
  "render.view",
  "render.inline",
  "document.inline",
  "render.canvas",
  "terminal.pixel_pool",
  "terminal.upload",
  "terminal.transfer",
  "workflow.selection",
  "workflow.template",
  "workflow.process",
  "workflow.naming",
  "document.markdown",
  "document.tex",
  "document.typst",
  "document.html",
}
local function unloaded()
  for _, name in ipairs(deferred) do
    check(not package.loaded["image_tools." .. name], name .. " must stay deferred")
  end
end
local api = require("image_tools")
check(not api.status().configured, "Requiring the API does not configure it")
check(api.supports("example.PNG") and not api.supports("example.txt"), "Capability checks are lightweight")
check(not api.status().configured, "Capability checks do not configure services")
api.setup()
vim.wait(20, function()
  return false
end)
unloaded()
vim.bo.filetype = "lua"
vim.api.nvim_exec_autocmds("CursorMoved", {})
api.info()
api.close()
api.clear_cache()
api.setup({ auto_preview = false })
unloaded()
check(api.status().terminal_cache == nil, "Status does not create an unused pixel pool")
unloaded()

-- Exercise the file viewer first: it must share its lazy pool with a later float.
local Runtime = require("image_tools.runtime")
local runtime = Runtime.new(require("image_tools.config").resolve({ auto_preview = false }))
runtime:start()
check(runtime:open(root .. "/tests/fixtures/fixture.png"), "Open a binary file with interception ready")
check(
  vim.wait(1000, function()
    return next(runtime.buffers.views) ~= nil
  end, 1),
  "File viewer constructs a canvas"
)
check(not package.loaded["image_tools.render.preview"], "File viewing does not load floating previews")
local pool = rawget(runtime.dependencies, "pixel_pool")
check(pool ~= nil, "The first file canvas constructs the shared pool")
local view = runtime.buffers.views[vim.api.nvim_get_current_win()]
check(view.canvas.transfer.pool == pool, "File canvas owns a manager over the shared pool")
check(runtime:info().terminal_cache ~= nil, "File-only diagnostics can inspect the pool")
runtime:ensure_preview()
check(runtime.preview.transfer.pool == pool, "The first float reuses file-viewer pixels")
runtime:clear_cache()
runtime:destroy()
check(rawget(runtime.dependencies, "pixel_pool") == pool, "Cleanup does not replace or recreate the pool")
print(string.format("image-tools startup: %d assertions passed", count))

vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
vim.o.termguicolors = true
local prepare, place, supported = nil, nil, true
local notices = {}
vim.notify = function(message)
  notices[#notices + 1] = message
end
package.loaded["image_tools.terminal"] = {
  supports = function()
    return supported, "Unsupported terminal fixture"
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
}
local media = require("image_tools.media")
package.loaded["image_tools.media"] = {
  supported = media.supported,
  prepare = function(_, _, callback)
    prepare = callback
    return function() end
  end,
}
package.loaded["image_tools.terminal.transfer"] = {
  new = function()
    return {
      status = function()
        return { images = 0, hits = 0, uploads = 0 }
      end,
      clear = function() end,
      acquire = function(_, _, _, _, callback)
        place = callback
        return function() end
      end,
    }
  end,
}
local api = require("image_tools")
local ns = vim.api.nvim_create_namespace("image_tools.preview_loading")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "document", "another row" })
local owner = vim.api.nvim_get_current_buf()
local function marks()
  return vim.api.nvim_buf_get_extmarks(owner, ns, 0, -1, {})
end
api.setup({ auto_preview = false, preview_loading_delay = 10 })
assert(api.preview("/tmp/diagnostic.png", { silent = true }))
assert(api.info().stage == "preparing")
assert(
  vim.wait(200, function()
    return #marks() == 1
  end),
  "Slow request shows its loading hint"
)
prepare("Conversion fixture failed")
local info = assert(api.info())
assert(info.stage == "failed" and info.error_stage == "preparing" and info.last_error)
assert(info.path == "/tmp/diagnostic.png" and info.error == "Conversion fixture failed")
assert(api.status().window == nil and api.status().path == nil and #marks() == 0)
assert(#notices == 0, "Automatic errors remain silent")
api.close()
assert(api.info().error == info.error, "Closing preserves metadata without retaining a view")
vim.cmd("ImageInfo")
assert(notices[#notices]:find("Conversion fixture failed", 1, true))
api.preview("/tmp/placement.png", { silent = true })
prepare(nil, { width = 10, height = 10 })
assert(api.info().stage == "placing")
place("Terminal fixture timeout")
assert(api.info().error_stage == "placing" and api.info().stage == "failed")
api.preview("/tmp/cancelled.png", { silent = true })
local stale = prepare
api.close()
vim.wait(30)
stale("Late error must be ignored")
assert(#marks() == 0 and api.info().error == "Terminal fixture timeout")
api.preview("/tmp/ready.png", { silent = true })
prepare(nil, { width = 10, height = 10 })
place(nil, { id = 1, placement_id = 1 })
assert(api.info().stage == "ready" and api.info().ready and not api.info().last_error)
assert(#marks() == 0 and vim.api.nvim_buf_get_lines(owner, 0, 1, false)[1] == "document")
api.close()
supported = false
assert(not api.preview("/tmp/unsupported.png", { silent = true }))
assert(api.info().error_stage == "terminal")
api.setup({ auto_preview = false, preview_loading_delay = 0 })
assert(api.info() == nil, "Setup resets retained failures")
supported = true
api.preview("/tmp/no-hint.png", { silent = true })
vim.wait(30)
assert(#marks() == 0, "Loading hints can be disabled")
api.close()
assert(not pcall(require("image_tools.config").resolve, { preview_loading_delay = -1 }))
print("Preview diagnostics: stages, silent errors, loading hints and stale cleanup passed")

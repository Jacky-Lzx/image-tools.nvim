vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local api = require("image_tools")
local health = require("image_tools.health")
local disk = require("image_tools.media.disk_cache")
local tmp = assert(vim.env.IMAGE_TOOLS_TEST_TMP) .. "/health-unified"
local inspect = disk.inspect
local scans = 0
disk.inspect = function(...)
  scans = scans + 1
  return inspect(...)
end
local reports, original = {}, {}
for _, kind in ipairs({ "start", "ok", "warn", "info", "error" }) do
  original[kind] = vim.health[kind]
  vim.health[kind] = function(message)
    reports[#reports + 1] = { kind, message }
  end
end
health.check()
assert(#reports == 2 and reports[2][1] == "info")
assert(not api.status().configured and not package.loaded["image_tools.runtime"])
local executable, probed = vim.fn.executable, {}
vim.fn.executable = function(cmd)
  probed[cmd] = true
  return 1
end
api.setup({
  force = true,
  auto_preview = false,
  math = { enabled = false },
  magick = "/fixture/magick",
  pdfinfo = "/fixture/pdfinfo",
  cache = tmp,
})
reports = {}
health.check()
assert(scans == 0 and not vim.uv.fs_stat(tmp), "Health does not scan, create or clean the disk cache")
assert(probed["/fixture/magick"] and probed["/fixture/pdfinfo"], "Check actual configured commands")
assert(not probed.latex and not probed.dvipng, "Disabled formula rendering is not checked")
assert(#reports <= 3 and reports[2][1] == "info", vim.inspect(reports))
local info = api.configuration()
info.magick = "changed"
assert(api.configuration().magick == "/fixture/magick", "Configuration snapshot is detached")
vim.fn.executable = function(cmd)
  return cmd == "/fixture/magick" and 0 or 1
end
reports = {}
health.check()
assert(reports[2][1] == "warn" and reports[2][2]:find("/fixture/magick", 1, true))
for _, row in ipairs(reports) do
  assert(row[1] ~= "ok", "Warnings must not be followed by all-clear")
end
vim.fn.executable = executable
-- Detailed cache inspection moved to explicit ImageInfo and works without a preview.
local notify, text = vim.notify, nil
vim.notify = function(message)
  text = message
end
vim.cmd("ImageInfo")
assert(vim.wait(5000, function()
  return text ~= nil
end, 1))
assert(scans == 1 and text:find("Runtime and disk cache", 1, true))
assert(not vim.uv.fs_stat(tmp), "Info does not create a missing cache directory")
vim.notify = notify
disk.inspect = inspect
for kind, fn in pairs(original) do
  vim.health[kind] = fn
end
vim.cmd("checkhealth image_tools")
assert(vim.bo.filetype == "checkhealth")
local rendered = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(rendered:find("image-tools.nvim", 1, true) and not rendered:find("Current usage", 1, true))
print("Image health/Info: compact rendering, scoped tools, no implicit initialization or disk scans passed")

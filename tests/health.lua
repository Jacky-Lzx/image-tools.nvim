vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local api, disk, health = require("image_tools"), require("image_tools.media.disk_cache"), require("image_tools.health")
local tmp = assert(vim.uv.fs_realpath(assert(vim.env.IMAGE_TOOLS_TEST_TMP))) .. "/health"
vim.fn.mkdir(tmp, "p")
local count = 0
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local function snapshot(opts)
  local result
  disk.inspect(opts, function(status)
    result = status
  end)
  check(
    vim.wait(5000, function()
      return result ~= nil
    end, 1),
    "Read-only inspection completes"
  )
  return result
end
local captured = {}
local original = {}
for _, name in ipairs({ "start", "ok", "info", "warn", "error" }) do
  original[name] = vim.health[name]
  vim.health[name] = function(message)
    captured[#captured + 1] = { name, message }
  end
end
local function report()
  captured = {}
  health.check()
  local lines = {}
  for _, entry in ipairs(captured) do
    lines[#lines + 1] = entry[2]
  end
  return table.concat(lines, "\n")
end
local before = api.status().configured
local text = report()
check(text:find("default disk%-cache settings") ~= nil, "Unconfigured health describes defaults")
check(api.status().configured == before and vim.fn.exists(":ImagePreview") == 0, "Health does not initialize runtime")
check(text:find("Limits: 256 file(s) / 512.00 MiB", 1, true), "Default limits are visible")
local folder = tmp .. "/configured"
vim.fn.mkdir(folder, "p")
local path = folder .. "/" .. vim.fn.sha256("one") .. ".png"
assert(vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixture.png", path))
vim.fn.writefile({ "ignore" }, folder .. "/notes.txt")
local symlink = folder .. "/" .. vim.fn.sha256("link") .. ".png"
assert(vim.uv.fs_symlink(path, symlink))
local settings = { cache = folder, disk_cache = { enabled = false, max_files = 7, max_bytes = 3 * 1024 * 1024 } }
local result = snapshot(settings)
check(result.files == 1 and result.bytes == vim.uv.fs_stat(path).size, "Usage excludes unrelated files and symlinks")
check(result.protected == 0 and not result.cleanup_running, "Unused cache has no protected files or cleanup")
api.setup(vim.tbl_extend("force", settings, { auto_preview = false }))
check(
  api.status().disk_cache.path == folder and api.status().disk_cache.max_files == 7,
  "Status exposes actual configured policy"
)
text = report()
check(text:find("Directory: " .. folder, 1, true), "Custom directory is displayed")
check(text:find("Automatic eviction: disabled", 1, true), "Disabled policy is displayed")
check(text:find("Limits: 7 file(s) / 3.00 MiB", 1, true), "Custom limits are displayed")
check(text:find("Current usage: 1 file(s)", 1, true), "Actual usage is displayed")
check(text:find("ImageCacheClear", 1, true), "Cleanup command hint is displayed")
local release = disk.acquire(settings, path, function() end)
result = snapshot(settings)
check(result.protected == 1 and result.protected_bytes == result.bytes, "Protected usage is inspected")
text = report()
check(text:find("Protected files in use: 1 file(s)", 1, true), "Protected usage appears in health")
release()
-- Reporting an over-budget cache does not remove its contents.
local over = vim.tbl_extend("force", settings, { disk_cache = { enabled = true, max_files = 0, max_bytes = 0 } })
api.setup(vim.tbl_extend("force", over, { auto_preview = false }))
text = report()
check(text:find("Cache exceeds configured limits", 1, true), "Unprotected over-budget cache is reported")
check(vim.uv.fs_stat(path) ~= nil, "Inspection never evicts files")
api.setup({ auto_preview = false, cache = tmp .. "/missing" })
text = report()
check(text:find("has not been created", 1, true), "Missing cache directory is normal")
check(not vim.uv.fs_stat(tmp .. "/missing"), "Inspection never creates directories")
api.setup({ auto_preview = false, cache = folder .. "/notes.txt" })
text = report()
check(text:find("Cannot inspect disk cache", 1, true), "Unreadable/non-directory cache reports diagnostic")
-- Cancellation/timeout cannot append late results to another health report.
local called = false
local cancel = disk.inspect(settings, function()
  called = true
end)
cancel()
vim.wait(20, function()
  return false
end)
check(not called, "Cancelled inspection has no late callback")
local inspect = disk.inspect
local wait = vim.wait
local cancelled = false
disk.inspect = function()
  return function()
    cancelled = true
  end
end
vim.wait = function(timeout, ...)
  if timeout == 3000 then
    return false
  end
  return wait(timeout, ...)
end
text = report()
check(cancelled and text:find("inspection timed out", 1, true), "Timed-out inspection is cancelled and reported")
disk.inspect = inspect
vim.wait = wait
api.setup({ auto_preview = false, treesitter = false, cache = folder })
text = report()
check(text:find("Tree-sitter: disabled; using Lua scanner", 1, true), "Explicit scanner backend is described")
check(text:find("index hit(s)", 1, true), "Syntax counters appear without parser initialization")
for name, callback in pairs(original) do
  vim.health[name] = callback
end
-- Exercise Neovim's actual health report buffer rather than just captured calls.
api.setup(vim.tbl_extend("force", settings, { auto_preview = false }))
vim.cmd("checkhealth image_tools")
text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
check(
  vim.bo.filetype == "checkhealth" and text:find("image%-tools: disk cache"),
  "Real checkhealth creates cache section"
)
check(
  text:find(folder, 1, true) and text:find("Current usage: 1 file(s)", 1, true),
  "Real checkhealth renders current cache data"
)
print("health: " .. count .. " assertions passed")

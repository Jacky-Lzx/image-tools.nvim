vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local D, I = require("image_tools.media.disk_cache"), require("image_tools.media")
local root = assert(vim.uv.fs_realpath(assert(vim.env.IMAGE_TOOLS_TEST_TMP))) .. "/disk"
local fixture = vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png"
local checks = 0
local function check(value, msg)
  checks = checks + 1
  assert(value, msg)
end
local function opts(name, limits)
  local dir = root .. "/" .. name
  vim.fn.mkdir(dir, "p")
  return require("image_tools.config").resolve({ cache = dir, disk_cache = limits })
end
local function file(options, name, age)
  local path = options.cache .. "/" .. vim.fn.sha256(name) .. ".png"
  assert(vim.uv.fs_copyfile(fixture, path))
  local time = os.time() - (age or 0)
  assert(vim.uv.fs_utime(path, time, time))
  return path
end
local function await(fn)
  check(vim.wait(15000, fn, 1), "Async cache completion")
end
local function prune(options, clear)
  local status
  D[clear and "clear" or "prune"](options, function(result)
    status = result
  end)
  await(function()
    return status ~= nil
  end)
  check(not status.error, status.error)
  return status
end
local a = opts("lru", { max_files = 2 })
local first, second, third = file(a, "old", 100), file(a, "middle", 50), file(a, "recent", 1)
local original = I.key(first, vim.uv.fs_stat(first))
local release = D.acquire(a, first, function() end)
release()
local status = prune(a)
check(
  vim.uv.fs_stat(first) and not vim.uv.fs_stat(second) and vim.uv.fs_stat(third),
  "Recently accessed old file survives LRU"
)
check(status.files == 2 and status.removed == 1, "File count limit")
check(
  I.key(first, vim.uv.fs_stat(first)) == original,
  "Access tracking does not change PNG version or invalidate terminal cache"
)
local b = opts("bytes", { max_bytes = vim.uv.fs_stat(fixture).size, max_files = 10 })
file(b, "one", 50)
file(b, "two", 1)
status = prune(b)
check(status.files == 1 and status.bytes <= b.disk_cache.max_bytes, "Byte limit")
local c = opts("protected", { max_files = 0, max_bytes = 0 })
local active = file(c, "active", 100)
release = D.acquire(c, active, function() end)
status = prune(c, true)
check(vim.uv.fs_stat(active) and status.protected == 1, "Clear protects leased image")
release()
await(function()
  return not vim.uv.fs_stat(active)
end)
check(not vim.uv.fs_stat(active), "Last release triggers deferred eviction")
local disabled = opts("disabled", { enabled = false, max_files = 0, max_bytes = 0 })
local kept = file(disabled, "keep")
release = D.acquire(disabled, kept, function() end)
release()
status = prune(disabled)
check(vim.uv.fs_stat(kept) and status.removed == 0, "Automatic management can be disabled")
status = prune(disabled, true)
check(not vim.uv.fs_stat(kept), "Explicit clear works when automatic management is disabled")
local safe = opts("safe", { max_files = 0, max_bytes = 0 })
local unrelated = safe.cache .. "/important.png"
assert(vim.uv.fs_copyfile(fixture, unrelated))
local transient = safe.cache .. "/" .. vim.fn.sha256("temp") .. ".123.tmp.png"
assert(vim.uv.fs_copyfile(fixture, transient))
local target = root .. "/outside.png"
assert(vim.uv.fs_copyfile(fixture, target))
local link = safe.cache .. "/" .. vim.fn.sha256("link") .. ".png"
assert(vim.uv.fs_symlink(target, link))
file(safe, "managed")
status = prune(safe, true)
check(
  status.removed == 1 and vim.uv.fs_stat(unrelated) and vim.uv.fs_stat(transient),
  "Only managed hash filenames are deleted"
)
check(vim.uv.fs_lstat(link) and vim.uv.fs_stat(target), "Symlinks and their targets are preserved")
-- Opening the cache file while asynchronous deletion is pending waits for it.
local race = opts("race", { max_files = 0, max_bytes = 0 })
local doomed = file(race, "doomed")
local original_unlink = vim.uv.fs_unlink
local deleting, finish_delete
vim.uv.fs_unlink = function(path, callback)
  if path == doomed and callback then
    deleting = true
    finish_delete = function()
      return original_unlink(path, callback)
    end
    return
  end
  return original_unlink(path, callback)
end
D.prune(race)
await(function()
  return deleting
end)
local ready = false
release = D.acquire(race, doomed, function()
  ready = true
end)
check(not ready, "New reader waits for in-flight deletion")
finish_delete()
await(function()
  return ready
end)
check(not vim.uv.fs_stat(doomed), "Reader resumes after deletion and can safely create a new conversion")
release()
vim.uv.fs_unlink = original_unlink
-- Exercise directory traversal across multiple batches and queued callbacks.
local many = opts("many", { max_files = 10 })
for index = 1, 145 do
  file(many, "entry-" .. index, index)
end
status = prune(many)
check(status.files == 10 and status.removed == 135, "Multi-batch scan enforces limits")
local completed = 0
D.prune(many, function(result)
  check(result.files <= 10, "Coalesced prune callback respects limits")
  completed = completed + 1
end)
D.clear(many, function(result)
  check(result.files == 0, "Queued clear callback")
  completed = completed + 1
end)
await(function()
  return completed == 2
end)
-- Real conversion leases keep the generated file alive through preview use.
local actual = opts("conversion", { max_files = 0, max_bytes = 0 })
local jpg = root .. "/source.jpg"
assert(vim.system({ "magick", fixture, jpg }):wait().code == 0)
local image, err
local cancel = I.prepare(jpg, actual, function(e, value)
  err, image = e, value
end)
await(function()
  return image or err
end)
check(not err, err)
prune(actual)
check(vim.uv.fs_stat(image.path), "Converted image stays pinned after callback")
cancel()
await(function()
  return not vim.uv.fs_stat(image.path)
end)
check(not vim.uv.fs_stat(image.path), "Finished request releases its disk lease on close")
-- Nonexistent cache directories under symlinked parents keep one stable manager.
local alias = root .. "/parent-alias"
assert(vim.uv.fs_symlink(root, alias))
local fresh = require("image_tools.config").resolve({
  cache = alias .. "/fresh-cache",
  disk_cache = { max_files = 0, max_bytes = 0 },
})
image, err = nil, nil
cancel = I.prepare(jpg, fresh, function(e, value)
  err, image = e, value
end)
await(function()
  return image or err
end)
check(not err, err)
status = prune(fresh)
check(status.protected == 1 and vim.uv.fs_stat(image.path), "Symlinked parent preserves file protection after mkdir")
cancel()
await(function()
  return not vim.uv.fs_stat(image.path)
end)
-- Raw PNG file viewers can also open a managed conversion safely.
local raw = opts("raw", { max_files = 0, max_bytes = 0 })
local raw_path = file(raw, "raw")
image, err = nil, nil
cancel = I.prepare(raw_path, raw, function(e, value)
  err, image = e, value
end)
await(function()
  return image or err
end)
check(not err and vim.uv.fs_stat(raw_path), "Managed PNG view is protected too")
cancel()
await(function()
  return not vim.uv.fs_stat(raw_path)
end)
check(
  not pcall(require("image_tools.config").resolve, { disk_cache = { max_bytes = -1 } }),
  "Invalid cache limit is rejected"
)
check(
  not pcall(require("image_tools.config").resolve, { disk_cache = { max_files = 1.5 } }),
  "Fractional file limit is rejected"
)
print("disk cache: " .. checks .. " assertions passed")

vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local Prepare, Disk = require("image_tools.media.prepare"), require("image_tools.media.disk_cache")
local tmp = vim.env.IMAGE_TOOLS_TEST_TMP .. "/media-lease"
vim.fn.mkdir(tmp, "p")
local source = tmp .. "/source.jpg"
assert(vim.system({ "magick", vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixture.png", source }):wait().code == 0)
local opts = require("image_tools.config").resolve({ cache = tmp .. "/cache", disk_cache = { enabled = false } })
local count = 0
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local function await(predicate)
  assert(vim.wait(10000, predicate, 1), "Media lease timeout")
end
local function protected()
  local result
  Disk.inspect(opts, function(status)
    result = status
  end)
  await(function()
    return result ~= nil
  end)
  return result.protected
end
local delivered, prepared = 0, nil
local function receive(err, image)
  assert(not err, err)
  delivered, prepared = delivered + 1, image
end
local a = Prepare.request(source, opts, receive)
local b = Prepare.request(source, opts, receive)
check(Prepare.status().pending_jobs == 1, "Preparation service owns one shared pending worker")
await(function()
  return delivered == 2
end)
check(
  Prepare.status().pending_jobs == 0 and protected() == 1,
  "Completion replaces worker ownership with subscriber leases"
)
a.cancel()
b.close()
check(protected() == 1, "Cancelling a delivered request preserves its file until explicit release")
a.release()
a.close()
check(protected() == 0, "Release and repeated close unpin the delivered file once")
delivered = 0
a = Prepare.request(prepared.path, opts, receive)
await(function()
  return delivered == 1
end)
check(protected() == 1, "Cached PNG readers also retain explicit file leases")
a.close()
check(protected() == 0, "Closing a cached PNG reader releases its file")
-- Releasing before delivery cannot leave a future subscriber pin behind.
delivered = 0
a = Prepare.request(source, opts, receive)
a.release()
await(function()
  return delivered == 1
end)
check(protected() == 0, "Early release does not acquire a new pin during scheduled delivery")
a.close()
delivered = 0
a = Prepare.request(prepared.path, opts, receive)
a.cancel()
vim.wait(20)
check(delivered == 0 and protected() == 0, "Pending PNG cancellation suppresses delivery and releases its pin")
a.close()
print("media leases: " .. count .. " assertions passed")

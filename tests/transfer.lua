local root, temporary = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
temporary = assert(vim.uv.fs_realpath(temporary))
vim.opt.rtp:prepend(root)
local checks = 0
local function eq(actual, expected, message)
  checks = checks + 1
  assert(
    vim.deep_equal(actual, expected),
    (message or "mismatch") .. "\n" .. vim.inspect(actual) .. "\n" .. vim.inspect(expected)
  )
end
local function await(predicate)
  assert(vim.wait(5000, predicate, 5), "asynchronous operation timed out")
end
local protocol, reader = require("image_tools.protocol"), require("image_tools.image")
local opts = {
  transport = "auto",
  terminal_timeout = 100,
  max_bytes = 32 * 1024 * 1024,
  max_dimension = 16384,
  max_pixels = 64 * 1024 * 1024,
  terminal_cache = { max_images = 2, max_bytes = 64000 * 2 },
}
local path = temporary .. "/中文 image (1).png"
assert(vim.uv.fs_copyfile(root .. "/tests/fixture.png", path))

-- Real asynchronous metadata reads must avoid reading the entire PNG.
local real_read, sizes = vim.uv.fs_read, {}
vim.uv.fs_read = function(fd, size, offset, callback)
  sizes[#sizes + 1] = size
  return real_read(fd, size, offset, callback)
end
local metadata, error
reader.prepare(path, opts, function(err, image)
  error, metadata = err, image
end)
await(function()
  return metadata ~= nil or error ~= nil
end)
assert(not error, error)
vim.uv.fs_read = real_read
eq(sizes, { 33, 12 }, "file transport must read only the header and end chunk")
eq(metadata.data, nil)
eq({ metadata.width, metadata.height }, { 160, 100 })
assert(metadata.key and metadata.size)
local png
reader.read(path, opts, function(err, image)
  error, png = err, image
end)
await(function()
  return png ~= nil or error ~= nil
end)
assert(not error, error)
eq(metadata.key, png.key, "metadata and full reads must identify the same file version")
local direct_metadata
reader.prepare(path, vim.tbl_extend("force", opts, { transport = "direct" }), function(err, image)
  error, direct_metadata = err, image
end)
await(function()
  return direct_metadata ~= nil or error ~= nil
end)
eq(direct_metadata.data, nil, "direct mode should defer full reads until a cache miss")
local command = protocol.upload_file(77, path)
local encoded_path = assert(command:match(";(.-)\27\\"))
eq(vim.base64.decode(encoded_path), path, "file paths must be encoded literally")
assert(command:find("t=f", 1, true) and command:find("q=0", 1, true))
assert(#command < #protocol.upload(77, png.data), "file transfer should send less data than inline PNG")

-- Real TermResponse routing, timeout, cancellation and handler cleanup.
local terminal = require("image_tools.terminal")
local real_write, sent = terminal.write, {}
terminal.write = function(data)
  sent[#sent + 1] = data
end
local initial_handlers = #vim.api.nvim_get_autocmds({ event = "TermResponse" })
local function response(id, result)
  vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=" .. id .. ";" .. result .. "\27\\" } })
end
local replies = {}
terminal.request(101, "request", 100, function(err)
  replies[#replies + 1] = err or "success"
end)
response(102, "OK")
eq(#replies, 0, "unrelated replies must not satisfy a request")
response(101, "OK")
eq(replies, { "success" })
terminal.request(105, "request", 100, function(err)
  replies[#replies + 1] = err or "normalized"
end)
vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=105;OK" } })
eq(replies[2], "normalized", "Neovim's normalized APC response has no terminator")
table.remove(replies, 2)
response(101, "ENOENT:late reply")
eq(#replies, 1, "completed requests must not accept late replies")
eq(#vim.api.nvim_get_autocmds({ event = "TermResponse" }), initial_handlers)
terminal.request(103, "request", 20, function(err)
  replies[#replies + 1] = err
end)
await(function()
  return #replies == 2
end)
assert(replies[2]:match("^ETIMEDOUT"))
response(103, "OK")
eq(#replies, 2)
local cancel_request = terminal.request(104, "request", 20, function(err)
  replies[#replies + 1] = err or "unexpected"
end)
cancel_request()
response(104, "OK")
vim.wait(30, function()
  return false
end)
eq(#replies, 2)
eq(#vim.api.nvim_get_autocmds({ event = "TermResponse" }), initial_handlers)
local matched = {}
terminal.request(107, "placement one", 100, function(err)
  matched[#matched + 1] = err or "one"
end, 11)
terminal.request(107, "placement two", 100, function(err)
  matched[#matched + 1] = err or "two"
end, 12)
response(107, "OK")
eq(#matched, 0, "Image-only response cannot acknowledge a specific placement")
vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=107,p=12;OK" } })
eq(matched, { "two" }, "Placement acknowledgement only completes its own request")
vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=107,p=11;OK" } })
eq(matched, { "two", "one" }, "Concurrent placements may acknowledge in reverse order")
eq(#vim.api.nvim_get_autocmds({ event = "TermResponse" }), initial_handlers, "Placement handlers clean up")
terminal.write = real_write

local function fields(command)
  local result = {}
  for key, value in assert(command:match("\27_G([^;\27]+)")):gmatch("([^,=]+)=([^,]+)") do
    result[key] = value
  end
  return result
end
local function harness(overrides)
  local calls, pending, responses = {}, {}, {}
  local wire = {
    write = function(command)
      calls[#calls + 1] = { fields = fields(command), command = command }
    end,
    request = function(id, command, _, callback)
      calls[#calls + 1] = { fields = fields(command), command = command }
      local result = table.remove(responses, 1)
      if result == "hold" then
        pending[#pending + 1] = callback
      else
        callback(result or nil)
      end
      return function() end
    end,
  }
  local manager = require("image_tools.transfer").new(
    vim.tbl_deep_extend("force", vim.deepcopy(opts), overrides or {}),
    { terminal = wire }
  )
  return manager, calls, responses, pending
end
local function acquire(manager, image)
  local result, failure
  local cancel = manager:acquire(image, 16, 5, function(err, entry)
    failure, result = err, entry
  end)
  await(function()
    return failure ~= nil or result ~= nil
  end)
  assert(not failure, failure)
  return result, cancel
end
local manager, calls = harness()
local entry, release = acquire(manager, metadata)
local first_id = entry.id
eq(calls[1].fields.t, "f")
eq(calls[2].fields.a, "p")
release()
eq(calls[3].fields.d, "i", "closing must preserve the uploaded image")
entry, release = acquire(manager, metadata)
eq(entry.id, first_id)
eq(calls[4].fields.a, "p", "cache hit must only place the uploaded image")
eq(manager:status().uploads, 1)
eq(manager:status().hits, 1)
release()
manager:clear()
eq(calls[#calls].fields.d, "I", "cache cleanup must free the terminal data")
eq(manager:status().images, 0)

-- File versions include inode, size and nanosecond mtime/ctime.
manager, calls = harness()
local version_one = {
  key = "converted-v1",
  path = "/tmp/v1.png",
  source = "/tmp/original.avif",
  data = png.data,
  width = 160,
  height = 100,
}
local version_two = vim.tbl_extend("force", version_one, { key = "converted-v2", path = "/tmp/v2.png" })
entry, release = acquire(manager, version_one)
release()
entry, release = acquire(manager, version_two)
eq(manager:status().images, 1, "new conversion paths must invalidate the same original source")
release()
manager:clear()

assert(vim.uv.fs_utime(path, os.time(), os.time() + 2))
local changed
reader.prepare(path, opts, function(err, image)
  error, changed = err, image
end)
await(function()
  return changed ~= nil or error ~= nil
end)
assert(not error, error)
assert(changed.key ~= metadata.key)
manager, calls = harness()
entry, release = acquire(manager, metadata)
first_id = entry.id
release()
entry, release = acquire(manager, changed)
assert(entry.id ~= first_id)
eq(calls[4].fields.d, "I", "replacing a file must evict its previous version")
eq(manager:status().images, 1)
release()
manager:clear()

-- LRU and decoded-byte bounds, disabled caching, and oversized active images.
local function sample(key)
  return { key = key, path = "/tmp/" .. key .. ".png", width = 160, height = 100, data = png.data }
end
manager, calls = harness()
local a, free_a = acquire(manager, sample("a"))
free_a()
local b, free_b = acquire(manager, sample("b"))
free_b()
a, free_a = acquire(manager, sample("a"))
free_a()
local c, free_c = acquire(manager, sample("c"))
eq(manager:status().images, 2, "LRU retains two images; terminal deletion below identifies the evicted entry")
eq(manager:status().images, 2)
local deleted_b = false
for _, call in ipairs(calls) do
  if call.fields.d == "I" and tonumber(call.fields.i) == b.id then
    deleted_b = true
  end
end
eq(deleted_b, true)
free_c()
manager:clear()
manager = harness({ terminal_cache = { max_images = 10, max_bytes = 64000 } })
a, free_a = acquire(manager, sample("a"))
free_a()
b, free_b = acquire(manager, sample("b"))
free_b()
eq(manager:status().images, 1)
eq(manager:status().bytes, 64000)
manager:clear()
manager, calls = harness({ terminal_cache = { max_images = 0 } })
a, free_a = acquire(manager, metadata)
free_a()
eq(manager:status().images, 0)
eq(calls[#calls].fields.d, "I")
a, free_a = acquire(manager, metadata)
free_a()
eq(manager:status().uploads, 2)
manager = harness({ terminal_cache = { max_bytes = 1 } })
a, free_a = acquire(manager, metadata)
free_a()
eq(manager:status().images, 0, "oversized image must be released instead of retained")

-- Cached data may disappear when Kitty evicts images or resets its screen.
local responses, pending
manager, calls, responses = harness()
entry, release = acquire(manager, changed)
release()
first_id = entry.id
responses[1] = "ENOENT:image not found"
entry, release = acquire(manager, changed)
assert(entry.id ~= first_id, "reupload must allocate a fresh id")
eq(manager:status().uploads, 2)
eq(manager:status().hits, 0, "failed cached placement is not a cache hit")
release()
manager:clear()

-- Auto falls back to direct on file failures, while explicit file reports them.
manager, calls, responses = harness()
responses[1] = "EBADF:Failed to read image file"
entry, release = acquire(manager, changed)
eq(calls[1].fields.t, "f")
eq(calls[3].fields.t, "d")
assert(calls[1].fields.i ~= calls[3].fields.i, "fallback must not reuse the failed upload id")
eq(manager:status().last_transport, "direct")
release()
manager:clear()
manager, calls, responses = harness({ transport = "file" })
responses[1] = "EBADF:Failed to read image file"
local failure
manager:acquire(changed, 16, 5, function(err)
  failure = err
end)
assert(failure:match("^EBADF"))
eq(manager:status().images, 0)
eq(manager:status().uploads, 1, "explicit file mode must not silently change transports")

local ssh, tty = vim.env.SSH_CONNECTION, vim.env.SSH_TTY
vim.env.SSH_CONNECTION, vim.env.SSH_TTY = "test-remote", nil
manager, calls = harness()
entry, release = acquire(manager, png)
eq(calls[1].fields.t, "d", "remote auto mode must use direct transmission")
release()
manager:clear()
vim.env.SSH_CONNECTION, vim.env.SSH_TTY = "", ""
manager, calls = harness()
entry, release = acquire(manager, changed)
eq(calls[1].fields.t, "f", "empty SSH environment values must count as local")
release()
manager:clear()
vim.env.SSH_CONNECTION, vim.env.SSH_TTY = ssh, tty

manager, calls, responses, pending = harness()
responses[1] = "hold"
local invoked = false
local cancel_upload = manager:acquire(changed, 16, 5, function()
  invoked = true
end)
cancel_upload()
pending[1](nil)
eq(invoked, false, "cancelled uploads must not complete a preview")
eq(manager:status().images, 0)
eq(calls[#calls].fields.d, "I", "cancelled uploads must free their partial image")
manager, calls, responses, pending = harness()
responses[1] = "hold"
manager:acquire(changed, 16, 5, function()
  invoked = true
end)
manager:clear()
pending[1](nil)
eq(invoked, false)
eq(manager:status().images, 0, "clear must cancel pending uploads as well as ready images")
print("image-tools transfer: " .. checks .. " assertions passed")

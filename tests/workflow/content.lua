vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local uv = vim.uv
local content = require("image_tools.workflow.content")
local queue = require("image_tools.media.conversion_queue")
local root = vim.env.IMAGE_TOOLS_TEST_TMP .. "/hashes"
vim.fn.mkdir(root, "p")
local function write(name, data)
  local path = root .. "/" .. name
  local fd = assert(uv.fs_open(path, "w", 384))
  assert(uv.fs_write(fd, data, 0))
  uv.fs_close(fd)
  return path
end
local function wait(predicate)
  assert(vim.wait(5000, predicate, 1), "Hash test timed out")
end
local function digest(path, limit)
  local done, message, hash = false, nil, nil
  content.digest(path, limit or 1024, function(err, result)
    message, hash, done = err, result, true
  end)
  wait(function()
    return done
  end)
  return message, hash
end
local data = "binary\0content\255"
local path = write("中文 ' $ image.bin", data)
local expected = vim.fn.sha256(vim.base64.encode(data))
local sha256, encode = vim.fn.sha256, vim.base64.encode
vim.fn.sha256 = function()
  error("Hashing must not execute on the editor thread")
end
vim.base64.encode = function()
  error("Encoding must not execute on the editor thread")
end
local err, hash = digest(path)
assert(not err and hash == expected, tostring(err))
local before = content.status()
err, hash = digest(path)
assert(not err and hash == expected and content.status().workers == before.workers)
assert(content.status().hits == before.hits + 1, "Unchanged revisions reuse a cached digest")
write("中文 ' $ image.bin", "changed\0bytes\255")
err, hash = digest(path)
assert(not err and hash ~= expected and content.status().workers == before.workers + 1)
assert(digest(path, 1), "Size limits also apply before a cached digest is returned")
assert(digest(root .. "/missing"), "Missing sources report errors")
vim.fn.sha256, vim.base64.encode = sha256, encode
local empty = write("empty.bin", "")
err, hash = digest(empty)
assert(not err and hash == sha256(""), "Empty files have a stable binary-safe digest")

-- Control worker completion to prove cancellation and revision races deterministically.
local run, jobs, stopped = queue.run, {}, 0
queue.run = function(command, options, callback)
  jobs[#jobs + 1] = { command = command, options = options, callback = callback }
  return function()
    stopped = stopped + 1
  end
end
path = write("shared.bin", "shared")
local first, second = false, false
local cancel_first = content.digest(path, 1024, function()
  first = true
end)
content.digest(path, 1024, function(message, result)
  assert(not message and result == expected)
  second = true
end)
wait(function()
  return #jobs == 1
end)
-- Drain the second subscriber's stat callback before checking coalescing/cancelling.
vim.wait(20)
assert(#jobs == 1 and jobs[1].options.timeout == 10000)
cancel_first()
assert(stopped == 0, "Cancelling one subscriber preserves shared work")
jobs[1].callback({ code = 0, stdout = expected })
wait(function()
  return second
end)
assert(not first)
local cancelled, cancel = false, nil
path = write("cancel.bin", "cancel")
cancel = content.digest(path, 1024, function()
  cancelled = true
end)
wait(function()
  return #jobs == 2
end)
cancel()
assert(stopped == 1 and content.status().pending == 0)
local replacement = false
content.digest(path, 1024, function(message)
  assert(not message)
  replacement = true
end)
wait(function()
  return #jobs == 3
end)
jobs[2].callback({ code = 0, stdout = expected })
vim.wait(20)
assert(not cancelled and not replacement and content.status().pending == 1)
jobs[3].callback({ code = 0, stdout = expected })
wait(function()
  return replacement
end)
path = write("race.bin", "before")
local failure
content.digest(path, 1024, function(message)
  failure = message
end)
wait(function()
  return #jobs == 4
end)
write("race.bin", "after!")
jobs[4].callback({ code = 0, stdout = expected })
wait(function()
  return failure ~= nil
end)
assert(failure == "File changed while hashing")
-- Invalid worker output must never enter the cache, and failures permit retry.
local function finish_failure(result)
  local done, message = false, nil
  local count = #jobs
  content.digest(path, 1024, function(error_message)
    message, done = error_message, true
  end)
  wait(function()
    return #jobs == count + 1
  end)
  jobs[#jobs].callback(result)
  wait(function()
    return done
  end)
  assert(message and content.status().pending == 0)
end
finish_failure({ code = 0, stdout = "invalid" })
finish_failure({ code = 124, stderr = "timed out" })
-- The LRU remains bounded even across many distinct import temporaries.
for i = 1, 130 do
  path = write("cache-" .. i, "small")
  local done = false
  local count = #jobs
  content.digest(path, 1024, function(message)
    assert(not message)
    done = true
  end)
  wait(function()
    return #jobs == count + 1
  end)
  jobs[#jobs].callback({ code = 0, stdout = expected })
  wait(function()
    return done
  end)
end
assert(content.status().entries == 128)
queue.run = run
print("Content hashes: background binary hashing, LRU, coalescing, cancellation, races and errors passed")

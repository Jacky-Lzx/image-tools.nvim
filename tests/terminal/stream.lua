vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local protocol, terminal = require("image_tools.terminal.protocol"), require("image_tools.terminal")
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function await(predicate)
  assert(vim.wait(5000, predicate, 1), "Stream operation timed out")
end
local function reply(id, message)
  vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=" .. id .. ";" .. message } })
end
local commands, uploads, partial, fail_write = {}, {}, nil, false
terminal.write = function(batch)
  if fail_write then
    fail_write = false
    error("simulated write failure")
  end
  for control, payload in batch:gmatch("\27_G([^;\27]+);?(.-)\27\\") do
    local fields = {}
    for key, value in control:gmatch("([^,=]+)=([^,]+)") do
      fields[key] = value
    end
    commands[#commands + 1] = fields
    if fields.a == "d" then
      partial = nil
    elseif fields.a == "t" then
      check(not partial, "Uploads cannot interleave")
      partial = { id = fields.i, chunks = {} }
    elseif fields.a then
      check(not partial, "Other graphics commands wait for the last chunk")
    end
    if fields.m then
      check(partial ~= nil, "Continuation belongs to a live upload")
      check(#payload <= 4096 and #payload % 4 == 0, "Each wire chunk obeys Base64 payload limits")
      partial.chunks[#partial.chunks + 1] = payload
      if fields.m == "0" then
        local id = partial.id
        uploads[id] = vim.base64.decode(table.concat(partial.chunks))
        partial = nil
        reply(id, "OK")
      end
    end
  end
end
local stream = require("image_tools.terminal.stream").wrap(terminal)
check(stream == require("image_tools.terminal.stream").wrap(terminal), "Terminal wrappers share one queue")
check(stream == require("image_tools.terminal.stream").wrap(stream), "Wrapping is idempotent")
local initial_handlers = #vim.api.nvim_get_autocmds({ event = "TermResponse" })
local bytes = string.rep("\0abc\255", 80000)
local complete = {}
stream.upload(10, bytes, 100, function(err)
  assert(not err, err)
  complete[#complete + 1] = 10
end)
check(#commands == 32 and not uploads["10"], "First turn encodes only a bounded batch")
stream.write(protocol.place(99, 1, 1))
stream.upload(11, bytes .. "tail", 100, function(err)
  assert(not err, err)
  complete[#complete + 1] = 11
end)
check(#commands == 32, "Concurrent graphics writes wait while upload yields")
await(function()
  return #complete == 2
end)
check(
  uploads["10"] == bytes and uploads["11"] == bytes .. "tail",
  "Incremental encoding preserves arbitrary bytes and padding"
)
check(vim.deep_equal(complete, { 10, 11 }), "Serialized uploads complete in request order")
check(
  #vim.api.nvim_get_autocmds({ event = "TermResponse" }) == initial_handlers,
  "Streaming reply handlers are cleaned up"
)
-- Cancellation aborts the partial stream before queued graphics are flushed.
local invoked = false
local cancel = stream.upload(12, bytes, 100, function()
  invoked = true
end)
local queued_cancel = stream.upload(13, bytes, 100, function()
  error("Queued upload was cancelled")
end)
queued_cancel()
local handlers = #vim.api.nvim_get_autocmds({ event = "TermResponse" })
local cancel_placement = stream.request(99, protocol.place(99, 9, 9), 5, function()
  error("Queued placement was cancelled")
end)
check(
  #vim.api.nvim_get_autocmds({ event = "TermResponse" }) == handlers,
  "Queued requests acquire no response handlers"
)
cancel_placement()
stream.write(protocol.place(99, 2, 2))
cancel()
check(not partial and commands[#commands].a == "p", "Cancellation aborts before draining queued graphics")
local count = #commands
vim.wait(10, function()
  return false
end)
reply(12, "OK")
check(#commands == count and not invoked and not uploads["13"], "Cancelled batches and queued uploads cannot resume")
check(
  #vim.api.nvim_get_autocmds({ event = "TermResponse" }) == initial_handlers,
  "Cancellation releases response handlers"
)
-- Separate uploader instances also share this queue through their terminal dependency.
local Uploader, config = require("image_tools.terminal.upload"), require("image_tools.config")
local a = Uploader.new(config.resolve({ transport = "direct" }), { terminal = terminal })
local b = Uploader.new(config.resolve({ transport = "direct" }), { terminal = terminal })
local first_done, second_done = false, false
local cancel_first = a:acquire({ key = "first", data = bytes, width = 160, height = 100 }, function()
  first_done = true
end)
collectgarbage("collect")
local cancel_second = b:acquire({ key = "second", data = bytes, width = 160, height = 100 }, function(err)
  assert(not err, err)
  second_done = true
end)
cancel_first()
await(function()
  return second_done
end)
check(
  not first_done and a:status().images == 0 and b:status().images == 1,
  "Cancelling one uploader preserves another queued upload"
)
cancel_second()
a:clear()
b:clear()
-- A failure between batches releases the lock and reports a single error.
local failure
stream.upload(14, bytes, 100, function(err)
  failure = err
end)
fail_write = true
stream.write(protocol.place(99, 3, 3))
await(function()
  return failure ~= nil
end)
check(
  failure:find("simulated write failure", 1, true) and not partial,
  "Mid-stream write failure aborts partial pixels"
)
check(commands[#commands].a == "p", "Write failure releases queued commands")
-- A queued response timeout begins only when that command is actually written.
local timed_out
stream.upload(15, bytes, 100, function(err)
  assert(not err, err)
end)
stream.request(99, protocol.place(99, 4, 4), 5, function(err)
  timed_out = err
end)
await(function()
  return timed_out ~= nil
end)
check(timed_out:match("^ETIMEDOUT"), "Queued requests retain bounded response waits")
local timeout
local stop, arm = terminal.request(100, "", 5, function(err)
  timeout = err
end, nil, true)
vim.wait(15, function()
  return false
end)
check(not timeout, "Deferred upload timeout does not run during transmission")
arm()
await(function()
  return timeout ~= nil
end)
stop()
check(timeout:match("^ETIMEDOUT"), "Timeout is armed after transmission")
check(#vim.api.nvim_get_autocmds({ event = "TermResponse" }) == initial_handlers, "Timeouts release handlers")
print("terminal stream: " .. checks .. " assertions passed")

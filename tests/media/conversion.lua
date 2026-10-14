vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local I = require("image_tools.image")
local tmp = assert(vim.uv.fs_realpath(assert(vim.env.IMAGE_TOOLS_TEST_TMP))) .. "/conversion"
vim.fn.mkdir(tmp, "p")
local source = tmp .. "/source.jpg"
assert(vim.system({ "magick", vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", source }):wait().code == 0)
local checks = 0
local function check(v, msg)
  checks = checks + 1
  assert(v, msg)
end
local function options(name)
  return require("image_tools.config").resolve({ cache = tmp .. "/" .. name })
end
local original = vim.system
local launches, kills = 0, 0
vim.system = function(command, ...)
  if command[1] == "magick" then
    launches = launches + 1
  end
  local job = original(command, ...)
  if command[1] == "magick" then
    return {
      kill = function(_, signal)
        kills = kills + 1
        return job:kill(signal)
      end,
    }
  end
  return job
end
local function await(test)
  check(vim.wait(12000, test, 1), "Async conversion completion")
end
local opts = options("shared")
local completed, images, errors = 0, {}, {}
for i = 1, 3 do
  I.prepare(source, opts, function(err, image)
    completed = completed + 1
    images[i] = image
    errors[i] = err
  end)
end
await(function()
  return completed == 3
end)
check(launches == 1, "Three cold consumers launch one actual converter")
check(
  not next(errors) and images[1].path == images[2].path and images[2].path == images[3].path,
  "Consumers receive same cached pixels"
)
images[1].width = 1
check(images[2].width > 1, "Consumer metadata tables are independent")
local before = launches
opts = options("cancel-one")
local abandoned, received = false, false
local cancel = I.prepare(source, opts, function()
  abandoned = true
end)
I.prepare(source, opts, function(err)
  check(not err, err)
  received = true
end)
cancel()
cancel()
await(function()
  return received
end)
check(not abandoned and launches == before + 1 and kills == 0, "One cancellation leaves shared conversion alive")
-- Last cancellation kills the worker, then a new request can retry normally.
opts = options("cancel-all")
local late = false
local first = I.prepare(source, opts, function()
  late = true
end)
local second = I.prepare(source, opts, function()
  late = true
end)
local expected = launches + 1
await(function()
  return launches == expected
end)
first()
second()
vim.wait(100, function()
  return false
end)
check(not late and kills == 1, "Last cancellation kills the converter and subscribers remain silent")
completed = 0
I.prepare(source, opts, function(err)
  check(not err, err)
  completed = 1
end)
await(function()
  return completed == 1
end)
check(launches == expected + 1, "Cancelled job is removed and can retry")
-- Errors fan out and do not poison retries.
opts = options("failed")
local fail_original = vim.system
vim.system = function(command, options, callback)
  launches = launches + 1
  vim.schedule(function()
    callback({ code = 1, stderr = "test failure" })
  end)
  return {
    kill = function()
      kills = kills + 1
    end,
  }
end
completed = 0
for _ = 1, 2 do
  I.prepare(source, opts, function(err)
    check(err and err:find("test failure", 1, true), "Shared error delivered")
    completed = completed + 1
  end)
end
await(function()
  return completed == 2
end)
vim.system = fail_original
completed = 0
I.prepare(source, opts, function(err)
  check(not err, err)
  completed = 1
end)
await(function()
  return completed == 1
end)
-- PDF page and conversion settings are independent identities.
local pdf = vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.pdf"
opts = options("pages")
completed = 0
before = launches
for page = 1, 2 do
  I.prepare(pdf, vim.tbl_extend("force", opts, { page = page }), function(err)
    check(not err, err)
    completed = completed + 1
  end)
end
await(function()
  return completed == 2
end)
check(launches == before + 2, "Different PDF pages are not merged")
opts = options("limits")
completed = 0
before = launches
I.prepare(source, opts, function(err)
  check(not err, err)
  completed = completed + 1
end)
I.prepare(source, vim.tbl_extend("force", opts, { max_dimension = 10 }), function(err)
  check(err and err:find("dimensions"), "Each request respects its validation limits")
  completed = completed + 1
end)
await(function()
  return completed == 2
end)
check(launches == before + 2, "Different validation limits are not merged")
-- A changing source cannot publish a conversion under its old version key.
opts = options("source-change")
completed = 0
vim.system = function(command, settings, callback)
  return original(command, settings, function(result)
    local stat = assert(vim.uv.fs_stat(source))
    assert(vim.uv.fs_utime(source, stat.atime.sec, stat.mtime.sec + 5))
    callback(result)
  end)
end
I.prepare(source, opts, function(err)
  check(err and err:find("source changed", 1, true), "Source change is detected before publishing")
  completed = 1
end)
await(function()
  return completed == 1
end)
check(#vim.fn.globpath(opts.cache, "*.png", false, true) == 0, "Changed source leaves no cached output")
vim.system = fail_original
-- Cancellation after publication, before scheduled fan-out, still suppresses it.
opts = options("scheduled")
received, abandoned = false, false
local pending_callback
local reader = require("image_tools.media.png")
local read = reader.read
reader.read = function(path, options, callback, metadata)
  if path:find(".tmp.png", 1, true) then
    pending_callback = callback
  end
  return read(path, options, callback, metadata)
end
cancel = I.prepare(source, opts, function()
  abandoned = true
end)
I.prepare(source, opts, function(err)
  check(not err, err)
  received = true
end)
await(function()
  return pending_callback ~= nil
end)
cancel()
await(function()
  return received
end)
check(not abandoned, "Cancelled subscriber stays silent during completion")
reader.read = read
-- Distinct real sources use the process budget, not just same-source coalescing.
local active, peak, burst_launches = 0, 0, 0
vim.system = function(command, settings, callback)
  active, burst_launches = active + 1, burst_launches + 1
  peak = math.max(peak, active)
  return original(command, settings, function(result)
    active = active - 1
    callback(result)
  end)
end
opts = options("burst")
require("image_tools.media.conversion_queue").configure(1)
completed = 0
for i = 1, 5 do
  local input = tmp .. "/burst-" .. i .. ".jpg"
  assert(vim.uv.fs_copyfile(source, input))
  I.prepare(input, opts, function(err)
    check(not err, err)
    completed = completed + 1
  end)
end
await(function()
  return completed == 5
end)
check(burst_launches == 5 and peak == 1, "Five actual distinct converters obey configured concurrency")
check(require("image_tools.media.conversion_queue").status().active == 0, "All actual workers release slots")
vim.system = original
print("conversion sharing: " .. checks .. " assertions passed")

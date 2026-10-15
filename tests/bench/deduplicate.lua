-- Run from the repository with nvim --headless -u NONE -i NONE --noplugin -l tests/bench/deduplicate.lua.
-- Optional IMAGE_TOOLS_CONTENT_BASELINE points to a saved pre-change content.lua.
vim.opt.rtp:prepend(vim.fn.getcwd())
local content = vim.env.IMAGE_TOOLS_CONTENT_BASELINE and dofile(vim.env.IMAGE_TOOLS_CONTENT_BASELINE)
  or require("image_tools.workflow.content")
local uv = vim.uv
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local function measure(path, bytes)
  local done, error_message, previous, max_gap = false, nil, uv.hrtime(), 0
  local timer = uv.new_timer()
  timer:start(1, 1, function()
    local now = uv.hrtime()
    max_gap, previous = math.max(max_gap, (now - previous) / 1e6), now
  end)
  local started = uv.hrtime()
  content.digest(path, bytes, function(err)
    error_message, done = err, true
  end)
  assert(
    vim.wait(30000, function()
      return done
    end, 1),
    "Hash benchmark timed out"
  )
  local finished = uv.hrtime()
  max_gap = math.max(max_gap, (finished - previous) / 1e6)
  timer:stop()
  timer:close()
  assert(not error_message, error_message)
  return (finished - started) / 1e6, max_gap
end
local ok, err = pcall(function()
  print("MiB  cold_ms  warm_ms  cold_max_loop_gap_ms  warm_max_loop_gap_ms")
  for _, mib in ipairs({ 1, 8, 32 }) do
    local path = directory .. "/" .. mib .. ".bin"
    local fd = assert(uv.fs_open(path, "w", 384))
    local chunk = string.rep("\0binary\255", 128 * 1024)
    for offset = 0, mib - 1 do
      assert(uv.fs_write(fd, chunk, offset * #chunk))
    end
    uv.fs_close(fd)
    local cold, cold_gap = measure(path, mib * 1024 * 1024)
    local warm, warm_gap = measure(path, mib * 1024 * 1024)
    print(string.format("%3d  %7.2f  %7.2f  %20.2f  %20.2f", mib, cold, warm, cold_gap, warm_gap))
  end
end)
vim.fn.delete(directory, "rf")
assert(ok, err)

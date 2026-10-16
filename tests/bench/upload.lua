-- Encoding/scheduling benchmark; no real terminal, file reads or image decoding.
vim.opt.rtp:prepend(vim.env.IMAGE_TOOLS_ROOT or vim.fn.getcwd())
local baseline = vim.env.IMAGE_TOOLS_PROTOCOL_BASELINE and dofile(vim.env.IMAGE_TOOLS_PROTOCOL_BASELINE)
local wire = require("image_tools.terminal.stream").wrap({
  write = function() end,
  request = function(_, _, _, callback)
    callback(nil)
    return function() end
  end,
})
local function measure(label, run)
  collectgarbage("collect")
  local last, gap = vim.uv.hrtime(), 0
  local timer = vim.uv.new_timer()
  timer:start(1, 1, function()
    local now = vim.uv.hrtime()
    gap, last = math.max(gap, (now - last) / 1e6), now
  end)
  local started, done = vim.uv.hrtime(), false
  run(function()
    done = true
  end)
  assert(
    vim.wait(10000, function()
      return done
    end, 1),
    "Upload benchmark timed out"
  )
  local elapsed = (vim.uv.hrtime() - started) / 1e6
  vim.wait(5, function()
    return false
  end, 1) -- Observe a final tick after synchronous work.
  timer:stop()
  timer:close()
  print(string.format("%s: total=%.2f ms max_loop_gap=%.2f ms", label, elapsed, gap))
end
for _, size in ipairs({ 1, 8, 32 }) do
  local data = string.rep("x", size * 1024 * 1024)
  if baseline then
    measure("baseline " .. size .. " MiB", function(done)
      baseline.upload(1, data, 0)
      done()
    end)
  end
  measure("batched " .. size .. " MiB", function(done)
    wire.upload(1, data, 100, function(err)
      assert(not err, err)
      done()
    end)
  end)
end

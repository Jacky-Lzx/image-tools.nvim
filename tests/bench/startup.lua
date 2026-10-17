-- Fresh-process timings exclude Neovim startup and external media/terminal work.
local root = vim.env.IMAGE_TOOLS_ROOT or vim.fn.getcwd()
local worker = vim.fn.tempname() .. ".lua"
vim.fn.writefile(
  vim.split(
    [[
vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_BENCH_ROOT))
local function modules()
  local count = 0
  for name in pairs(package.loaded) do
    if name:match("^image_tools") then count = count + 1 end
  end
  return count
end
local started = vim.uv.hrtime()
local api = require("image_tools")
local required = vim.uv.hrtime()
api.setup()
local configured = vim.uv.hrtime()
local sync_modules = modules()
local done = false
vim.schedule(function()
  io.stdout:write(vim.json.encode({
    require_ms = (required - started) / 1e6,
    setup_ms = (configured - required) / 1e6,
    total_ms = (configured - started) / 1e6,
    idle_ms = (vim.uv.hrtime() - configured) / 1e6,
    modules = sync_modules,
    idle_modules = modules(),
  }) .. "\n")
  done = true
end)
assert(vim.wait(1000, function() return done end, 1))
]],
    "\n",
    { plain = true }
  ),
  worker
)
local ok, err = pcall(function()
  local targets = { { "current", root } }
  if vim.env.IMAGE_TOOLS_STARTUP_BASELINE then
    table.insert(targets, 1, { "baseline", vim.env.IMAGE_TOOLS_STARTUP_BASELINE })
  end
  local runs = tonumber(vim.env.IMAGE_TOOLS_BENCH_RUNS) or 30
  assert(runs >= 1 and runs % 1 == 0, "IMAGE_TOOLS_BENCH_RUNS must be a positive integer")
  for _, target in ipairs(targets) do
    local samples = {}
    for _ = 1, runs do
      local result = vim
        .system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "--noplugin", "-l", worker }, {
          text = true,
          env = { IMAGE_TOOLS_BENCH_ROOT = target[2] },
        })
        :wait()
      assert(result.code == 0, result.stderr)
      local sample = vim.json.decode(result.stdout)
      for key, value in pairs(sample) do
        samples[key] = samples[key] or {}
        table.insert(samples[key], value)
      end
    end
    print(target[1] .. " (" .. runs .. " fresh processes):")
    for _, key in ipairs({ "require_ms", "setup_ms", "total_ms", "idle_ms", "modules", "idle_modules" }) do
      local values = samples[key]
      table.sort(values)
      print(string.format("  %s p50=%.3f p95=%.3f", key, values[math.ceil(runs * 0.5)], values[math.ceil(runs * 0.95)]))
    end
  end
end)
vim.fn.delete(worker)
assert(ok, err)

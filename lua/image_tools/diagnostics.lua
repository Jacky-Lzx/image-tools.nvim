-- Explicit, read-only diagnostics; never create or evict cache files.
local M = {}

function M.show(runtime, lines)
  local state = runtime:status()
  local opts = vim.deepcopy(runtime.options)
  local finished = false
  local function display(cache)
    if finished then
      return
    end
    finished = true
    local details = vim.deepcopy(state)
    details.disk_cache = cache
    lines[#lines + 1] = "Runtime and disk cache:\n" .. vim.inspect(details)
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "image-tools" })
  end
  local cancel = require("image_tools.media.disk_cache").inspect(opts, display)
  vim.defer_fn(function()
    if not finished then
      cancel()
      display({ error = "Disk-cache inspection timed out", path = opts.cache })
    end
  end, 3000)
end

return M

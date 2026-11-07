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
    local heading = table.concat(lines, "\n") .. "\nRuntime and disk cache:\n"
    local value = vim.inspect(details)
    vim.notify(heading .. value, vim.log.levels.INFO, {
      title = "image-tools",
      markdown = false,
      spans = { { start = #heading, finish = #heading + #value, filetype = "lua" } },
    })
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

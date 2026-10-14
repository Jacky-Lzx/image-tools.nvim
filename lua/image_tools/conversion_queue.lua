local M = {}
local queued, active, pumping = {}, 0, false

local function pump()
  if pumping then
    return
  end
  pumping = true
  while queued[1] do
    local job = queued[1]
    if job.cancelled then
      table.remove(queued, 1)
    elseif active >= job.limit then
      break
    else
      table.remove(queued, 1)
      active, job.running = active + 1, true
      local function finish(result)
        if job.finished then
          return
        end
        job.finished, job.running = true, false
        active = active - 1
        -- Process callbacks may arrive from libuv's fast event context.
        vim.schedule(function()
          local ok, err = pcall(job.callback, result)
          pump()
          if not ok then
            error(err)
          end
        end)
      end
      local ok, process = pcall(vim.system, job.command, job.options, finish)
      if ok then
        job.process = process
      else
        finish({ code = -1, stderr = tostring(process) })
      end
    end
  end
  pumping = false
end

-- A cancelled running process holds its slot until it actually exits.
-- Queued work can be removed without spawning or creating a partial output.
function M.run(command, options, limit, callback)
  local job = { command = command, options = options, limit = limit or 2, callback = callback }
  queued[#queued + 1] = job
  pump()
  return function()
    if job.cancelled or job.finished then
      return
    end
    job.cancelled = true
    if job.running and job.process then
      job.process:kill(15)
    end
    pump()
  end
end
function M.status()
  local waiting = 0
  for _, job in ipairs(queued) do
    if not job.cancelled then
      waiting = waiting + 1
    end
  end
  return { active = active, queued = waiting }
end
return M

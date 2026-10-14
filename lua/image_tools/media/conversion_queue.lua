-- Module: image_tools.media.conversion_queue
--
-- Purpose:
--   Enforce a shared FIFO process budget for image and clipboard conversion.
--
-- Architecture:
--   Accept process commands/options and run them through vim.system. Runtime
--   configuration sets the process-wide limit; media and clipboard workers
--   share it, while PNG reads/PDF metadata bypass it.
--
-- Ownership:
--   Own queued jobs and the active count. Queued cancellation avoids spawning;
--   a cancelled running job keeps its slot until exit, and callbacks resume
--   queue pumping.

local M = {}
local queued, active, pumping, limit = {}, 0, false, 2

local function pump()
  if pumping then
    return
  end
  pumping = true
  while queued[1] do
    local job = queued[1]
    if job.cancelled then
      table.remove(queued, 1)
    elseif active >= limit then
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
function M.run(command, options, callback)
  local job = { command = command, options = options, callback = callback }
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
function M.configure(concurrency)
  assert(
    type(concurrency) == "number" and concurrency >= 1 and concurrency % 1 == 0,
    "Conversion concurrency must be a positive integer"
  )
  limit = concurrency
  pump()
end
function M.status()
  local waiting = 0
  for _, job in ipairs(queued) do
    if not job.cancelled then
      waiting = waiting + 1
    end
  end
  return { active = active, queued = waiting, limit = limit }
end
return M

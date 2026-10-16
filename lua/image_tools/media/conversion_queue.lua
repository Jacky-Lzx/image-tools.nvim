-- Module: image_tools.media.conversion_queue
--
-- Purpose:
--   Enforce a shared process budget, prioritizing interactive work over hashing.
--
-- Architecture:
--   Accept process commands/options and run them through vim.system. Runtime
--   configuration sets the process-wide limit; media, clipboard and hash workers
--   share it, while PNG reads/PDF metadata bypass it.
--
-- Ownership:
--   Own queued jobs and the active count. Queued cancellation avoids spawning;
--   a cancelled running job keeps its slot until exit, and callbacks resume
--   queue pumping.

---@class ImageToolsProcessResult
---@field code integer Process exit code; -1 reports a spawn failure.
---@field stdout? string Captured process output when available.
---@field stderr? string Captured process error output when available.
---@field signal? integer Process termination signal when supplied by vim.system.
---@field timing? ImageToolsProcessTiming Monotonic timestamps for queue/process diagnostics.
---@class ImageToolsProcessTiming
---@field queued number Nanoseconds when enqueued.
---@field started number Nanoseconds immediately before spawning.
---@field finished number Nanoseconds when the exit/spawn-failure callback arrives.
---@class ImageToolsQueueStatus
---@field active integer Running processes, including cancelled jobs awaiting exit.
---@field queued integer Uncancelled jobs waiting to spawn.
---@field queued_background integer Waiting hash jobs.
---@field queued_interactive integer Waiting conversion/clipboard jobs.
---@field limit integer Current process-wide concurrency budget.

---@class ImageToolsConversionQueue
local M = {}
local SIGTERM = 15
local SPAWN_FAILURE = -1
local queued, active, pumping, limit = {}, 0, false, require("image_tools.defaults").convert_concurrency
local INTERACTIVE_BURST = 3
local interactive_streak = 0

-- FIFO within each class. While background work waits, admit at most three
-- interactive jobs before one background job, so sustained previews cannot starve imports.
local function take()
  local interactive, background
  for index, job in ipairs(queued) do
    if job.priority == "background" then
      background = background or index
    else
      interactive = interactive or index
    end
  end
  local index
  if background and (not interactive or interactive_streak >= INTERACTIVE_BURST) then
    index, interactive_streak = background, 0
  else
    index = interactive
    interactive_streak = background and interactive_streak + 1 or 0
  end
  return table.remove(queued, index)
end

-- Spawn waiting jobs within the current budget and schedule callbacks after releasing finished
-- slots.
---@return nil
local function pump()
  if pumping then
    return
  end
  pumping = true
  while queued[1] and active < limit do
    local job = take()
    active, job.running = active + 1, true
    job.started = vim.uv.hrtime()
    -- Release the occupied slot once and deliver completion on the main loop before pumping
    -- queued work.
    ---@param result ImageToolsProcessResult Spawn/exit result.
    ---@return nil
    local function finish(result)
      if job.finished then
        return
      end
      job.finished, job.running = true, false
      result.timing = { queued = job.queued, started = job.started, finished = vim.uv.hrtime() }
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
      finish({ code = SPAWN_FAILURE, stderr = tostring(process) })
    end
  end
  pumping = false
end

-- A cancelled running process holds its slot until it actually exits.
-- Queued work can be removed without spawning or creating a partial output.
-- Enqueue a process with captured command/options. Cancellation before spawn skips completion;
-- after spawn, the exit callback still runs and callers must suppress stale delivery.
---@param command string[] Executable and arguments passed directly to vim.system.
---@param options table vim.system options, including timeout/text when needed.
---@param callback fun(result: ImageToolsProcessResult) Completion callback; cancelled callers must suppress stale delivery.
---@param priority? "interactive"|"background" Defaults to interactive; FIFO within each class.
---@return ImageToolsCancel cancel Removes queued work or signals a running process without releasing its slot early.
function M.run(command, options, callback, priority)
  priority = priority or "interactive"
  assert(priority == "interactive" or priority == "background", "Unknown process priority")
  local job =
    { command = command, options = options, callback = callback, priority = priority, queued = vim.uv.hrtime() }
  queued[#queued + 1] = job
  pump()
  return function()
    if job.cancelled or job.finished then
      return
    end
    job.cancelled = true
    if job.running and job.process then
      job.process:kill(SIGTERM)
    else
      for index, waiting in ipairs(queued) do
        if waiting == job then
          table.remove(queued, index)
          break
        end
      end
    end
    pump()
  end
end

-- Change the shared process limit and start newly eligible queued jobs.
---@param concurrency integer Positive process budget; running jobs retain their slots.
---@return nil
function M.configure(concurrency)
  assert(
    type(concurrency) == "number" and concurrency >= 1 and concurrency % 1 == 0,
    "Conversion concurrency must be a positive integer"
  )
  limit = concurrency
  pump()
end

-- Snapshot running/queued work and the current concurrency limit.
---@return ImageToolsQueueStatus status
function M.status()
  local waiting, background = 0, 0
  for _, job in ipairs(queued) do
    if not job.cancelled then
      waiting = waiting + 1
      background = background + (job.priority == "background" and 1 or 0)
    end
  end
  return {
    active = active,
    queued = waiting,
    queued_background = background,
    queued_interactive = waiting - background,
    limit = limit,
  }
end
return M

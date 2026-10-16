-- Module: image_tools.terminal.stream
--
-- Purpose:
--   Yield between bounded direct-upload batches without interleaving graphics.
--
-- Architecture:
--   Share one wrapper per terminal dependency. Serialize graphics writes until
--   the last upload chunk, while acknowledgement waits remain independent.
--
-- Ownership:
--   Each queued request owns its bytes, cancellation and reply handle. Abort
--   partial uploads before unlocking; cancellation removes queued data/timers.

local M = {}
local protocol = require("image_tools.terminal.protocol")
local kitty = require("image_tools.terminal.constants")
local BATCH_CHUNKS = 32 -- 96 KiB of raw bytes per batch; yield between batches.
local wrappers = setmetatable({}, { __mode = "k" })

-- Return the shared graphics queue for an actual or injected terminal service.
---@param terminal table write/request primitives; other methods pass through unchanged.
---@return table wire Queued write/request primitives and cancellable upload(id, bytes, timeout, callback).
function M.wrap(terminal)
  local state = wrappers[terminal]
  if state and state.wrapper[1] then
    return state.wrapper[1]
  end
  state = state or { queued = {}, pumping = false, wrapper = setmetatable({}, { __mode = "v" }) }
  local wire = setmetatable({}, { __index = terminal })
  -- A weak wrapper reference avoids keeping disposable injected terminals alive
  -- through the weak-key registry. Queue state survives wrapper collection.
  state.wrapper[1] = wire
  wrappers[terminal], wrappers[wire] = state, state
  local queued = state.queued
  local pump

  local function stop_timer(job)
    if job.timer and not job.timer:is_closing() then
      job.timer:stop()
      job.timer:close()
    end
    job.timer = nil
  end

  local function unlock(job, abort)
    stop_timer(job)
    job.data, job.next_chunk = nil, nil
    if state.current == job then
      if abort and job.sent then
        -- Kitty aborts an incomplete chunk sequence upon a delete command.
        pcall(terminal.write, protocol.delete(job.id))
      end
      state.current = nil
    end
  end

  pump = function()
    if state.pumping then
      return
    end
    state.pumping = true
    while not state.current and #queued > 0 do
      local job = table.remove(queued, 1)
      if not job.cancelled then
        local ok, err = pcall(job.start)
        if not ok then
          unlock(job, true)
          if job.on_error then
            job.on_error(err)
          else
            vim.schedule(function()
              error(err)
            end)
          end
        end
      end
    end
    state.pumping = false
  end

  local function enqueue(job)
    queued[#queued + 1] = job
    pump()
    return function()
      if job.cancelled then
        return
      end
      job.cancelled = true
      if job.cancel_reply then
        job.cancel_reply()
        job.cancel_reply = nil
      end
      unlock(job, true)
      for i, waiting in ipairs(queued) do
        if waiting == job then
          table.remove(queued, i)
          break
        end
      end
      job.start = nil
      pump()
    end
  end

  function wire.write(command)
    if not state.current and not state.pumping then
      return terminal.write(command)
    end
    enqueue({
      start = function()
        terminal.write(command)
      end,
    })
  end

  function wire.request(id, command, timeout, callback, placement)
    local job = {}
    job.start = function()
      job.start = nil
      local replied = false
      local cancel = terminal.request(id, command, timeout, function(err)
        replied = true
        job.cancel_reply = nil
        if not job.cancelled then
          callback(err)
        end
      end, placement)
      if not replied and not job.cancelled then
        job.cancel_reply = cancel
      elseif job.cancelled then
        cancel()
      end
    end
    return enqueue(job)
  end

  -- Register replies before the first bytes, but start their timeout only when
  -- all bytes have been sent. Synchronous injected replies wait for that point.
  function wire.upload(id, data, timeout, callback)
    if #data == 0 then
      callback("Cannot upload empty PNG data")
      return function() end
    end
    local job = { id = id, data = data }
    local replied, reply_error, arm = false, nil, nil
    local function deliver(err)
      job.cancel_reply = nil
      if not job.cancelled then
        local ok, message = pcall(callback, err)
        if not ok then
          vim.schedule(function()
            error(message)
          end)
        end
      end
    end
    local function fail(err)
      if job.cancel_reply then
        job.cancel_reply()
        job.cancel_reply = nil
      end
      unlock(job, true)
      deliver(tostring(err))
      pump()
    end
    job.on_error = fail
    local step
    step = function()
      job.timer = nil
      if job.cancelled or state.current ~= job then
        return
      end
      local final = false
      local ok, err = pcall(function()
        local commands = {}
        for _ = 1, BATCH_CHUNKS do
          local command, last = job.next_chunk()
          if not command then
            break
          end
          final = last
          commands[#commands + 1] = command
        end
        local batch = table.concat(commands)
        if not job.sent then
          job.sent = true
          local cancel
          cancel, arm = terminal.request(id, batch, timeout, function(message)
            replied, reply_error = true, message
            if state.current ~= job then
              deliver(message)
            elseif message then
              fail(message)
            end
          end, nil, true)
          if not replied and not job.cancelled then
            job.cancel_reply = cancel
          elseif job.cancelled then
            cancel()
          end
        else
          terminal.write(batch)
        end
      end)
      if not ok then
        fail(err)
        return
      end
      if state.current ~= job then
        return
      end
      if final then
        unlock(job)
        if not replied and arm then
          arm()
        elseif replied then
          deliver(reply_error)
        end
        pump()
      else
        job.timer = vim.defer_fn(step, 0)
      end
    end
    job.start = function()
      job.start = nil
      state.current = job
      job.next_chunk = protocol.upload_chunks(id, job.data, kitty.REPLY_ALL)
      job.data = nil
      step()
    end
    return enqueue(job)
  end

  return wire
end

return M

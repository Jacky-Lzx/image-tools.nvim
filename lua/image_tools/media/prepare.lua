-- Module: image_tools.media.prepare
--
-- Purpose:
--   Coordinate media preparation and coalesce matching conversion requests.
--
-- Architecture:
--   Dispatch native PNG reads or media/convert workers behind the image facade.
--   Share a convertible-source worker while delivering independent metadata and
--   cancel/release/close handles to subscribers.
--
-- Ownership:
--   Own process-scoped pending jobs and subscriber file leases. Cancelling the
--   last pending subscriber stops work; delivered outputs stay pinned until
--   their handles release or close.

local M = {}
local uv = vim.uv
local disk = require("image_tools.media.disk_cache")
local version = require("image_tools.media.file_version")
local convertible = require("image_tools.media.formats").formats
local pending = {}

local function worker(path, opts, callback)
  if path:lower():sub(-4) == ".png" then
    return require("image_tools.media.png").read(path, opts, callback, opts.transport ~= nil)
  end
  return require("image_tools.media.convert").prepare(path, opts, callback, opts.transport ~= nil)
end

local function single(path, opts, callback)
  local active, cancelled, released, cancel_work, disk_release = true, false, false, nil, nil
  local function release_file()
    if disk_release then
      disk_release()
      disk_release = nil
    end
  end
  local function start()
    if not active then
      return
    end
    cancel_work = worker(path, opts, function(err, image)
      if active then
        active = false
        callback(err, image)
        if released then
          release_file()
        end
      end
    end)
    if cancelled then
      cancel_work()
    end
  end
  if path:lower():sub(-4) == ".png" and disk.owns(opts, path) then
    disk_release = disk.acquire(opts, path, start)
    if not active and released then
      release_file()
    end
  else
    start()
  end
  local function cancel()
    if active then
      active, cancelled = false, true
      if cancel_work then
        cancel_work()
      end
      release_file()
    end
  end
  local function release()
    released = true
    if not active then
      release_file()
    end
  end
  return {
    cancel = cancel,
    release = release,
    close = function()
      cancel()
      release()
    end,
  }
end

function M.request(path, opts, callback)
  local extension = path:match("%.([^./]+)$")
  extension = extension and extension:lower()
  local stat = convertible[extension] and uv.fs_stat(path)
  if
    not stat
    or stat.type ~= "file"
    or extension == "pdf"
      and (opts.page ~= nil and (type(opts.page) ~= "number" or opts.page < 1 or opts.page % 1 ~= 0))
  then
    return single(path, opts, callback)
  end
  local key = table.concat({
    version.key(path, stat),
    opts.cache or "",
    opts.magick or "",
    opts.rsvg or "rsvg-convert",
    tostring(opts.page or 1),
    tostring(opts.pdf_density or 144),
    tostring(opts.transport ~= nil),
    tostring(opts.max_bytes),
    tostring(opts.max_dimension),
    tostring(opts.max_pixels),
    tostring(opts.convert_timeout),
  }, "\0")
  local job = pending[key]
  local fresh = not job
  if fresh then
    job = { subscribers = {} }
    pending[key] = job
  end
  local subscriber = { active = true }
  job.subscribers[subscriber] = callback
  if fresh then
    job.cancel = worker(path, opts, function(err, image)
      if job.done then
        return
      end
      job.done = true
      if pending[key] == job then
        pending[key] = nil
      end
      local subscribers = job.subscribers
      job.subscribers = {}
      for consumer, receive in pairs(subscribers) do
        if image and consumer.active and not consumer.released then
          consumer.disk_release = disk.acquire(opts, image.path, function() end)
        end
        -- One callback cannot prevent other subscribers from completing.
        vim.schedule(function()
          if consumer.active then
            consumer.active = false
            receive(err, image and vim.deepcopy(image) or nil)
          end
        end)
      end
    end)
  end
  local function release()
    subscriber.released = true
    if subscriber.disk_release then
      subscriber.disk_release()
      subscriber.disk_release = nil
    end
  end
  local function cancel()
    if not subscriber.active then
      return
    end
    subscriber.active = false
    release()
    job.subscribers[subscriber] = nil
    if not job.done and not next(job.subscribers) then
      job.done = true
      if pending[key] == job then
        pending[key] = nil
      end
      if job.cancel then
        job.cancel()
      end
    end
  end
  return {
    cancel = cancel,
    release = release,
    close = function()
      cancel()
      release()
    end,
  }
end

function M.status()
  return { pending_jobs = vim.tbl_count(pending) }
end

return M

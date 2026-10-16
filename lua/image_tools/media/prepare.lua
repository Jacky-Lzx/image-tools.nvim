-- Module: image_tools.media.prepare
--
-- Purpose:
--   Coordinate media preparation and coalesce matching conversion requests.
--
-- Architecture:
--   Dispatch native PNG reads, media/convert or media/math workers behind the media entry point.
--   Share a convertible-source worker while delivering independent metadata and
--   cancel/release/close handles to subscribers.
--
-- Ownership:
--   Own process-scoped pending jobs and subscriber file leases. Cancelling the
--   last pending subscriber stops work; delivered outputs stay pinned until
--   their handles release or close.

---@class ImageToolsPreparationHandle
---@field cancel ImageToolsCancel Suppress pending delivery; completed output leases need release/close.
---@field release ImageToolsCancel Unpin delivered output; may be requested before completion.
---@field close ImageToolsCancel Perform both cancellation and release, idempotently.

---@class ImageToolsPreparation
local M = {}
local uv = vim.uv
local disk = require("image_tools.media.disk_cache")
local version = require("image_tools.media.file_version")
local convertible = require("image_tools.media.formats").formats
local defaults = require("image_tools.defaults")
local pending = {}

-- Select a native PNG read or converter without duplicating transport-specific read policy.
---@param path string Image source.
---@param opts table Preparation settings; presence of transport requests metadata-only pixels.
---@param callback ImageToolsImageCallback Completion consumer.
---@return ImageToolsCancel cancel
local function worker(path, opts, callback)
  if opts._formula then
    return require("image_tools.media.math").prepare(path, opts, callback, opts.transport ~= nil)
  end
  if path:lower():sub(-#".png") == ".png" then
    return require("image_tools.media.png").read(path, opts, callback, opts.transport ~= nil)
  end
  return require("image_tools.media.convert").prepare(path, opts, callback, opts.transport ~= nil)
end

-- Create an independent request for PNGs, missing sources or requests ineligible for coalescing.
---@param path string Source path.
---@param opts table Preparation/validation settings.
---@param callback ImageToolsImageCallback Completion consumer.
---@return ImageToolsPreparationHandle handle
local function single(path, opts, callback)
  local active, cancelled, released, cancel_work, disk_release = true, false, false, nil, nil
  -- Release the independent request disk pin at most once.
  ---@return nil
  local function release_file()
    if disk_release then
      disk_release()
      disk_release = nil
    end
  end

  -- Start work only while active and handle cancellation occurring during synchronous setup.
  ---@return nil
  local function start()
    if not active then
      return
    end
    cancel_work = worker(path, opts, function(err, image, timing)
      if active then
        active = false
        callback(err, image, timing)
        if released then
          release_file()
        end
      end
    end)
    if cancelled then
      cancel_work()
    end
  end
  if path:lower():sub(-#".png") == ".png" and disk.owns(opts, path) then
    disk_release = disk.acquire(opts, path, start)
    if not active and released then
      release_file()
    end
  else
    start()
  end

  -- Cancel pending delivery; release owned pending resources without releasing already delivered
  -- leases.
  ---@return nil
  local function cancel()
    if active then
      active, cancelled = false, true
      if cancel_work then
        cancel_work()
      end
      release_file()
    end
  end

  -- Record release intent and unpin any output lease already delivered.
  ---@return nil
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

-- Coalesce matching convertible sources and give each subscriber an independent lifecycle handle.
---@param path string Source path.
---@param opts table Cache, renderer, page, validation and delivery policy.
---@param callback ImageToolsImageCallback Metadata is deep-copied for each subscriber.
---@return ImageToolsPreparationHandle handle
function M.request(path, opts, callback)
  local extension = path:match("%.([^./]+)$")
  extension = extension and extension:lower()
  local stat = convertible[extension] and uv.fs_stat(path)
  if
    not opts._formula and (not stat or stat.type ~= "file")
    or extension == "pdf"
      and (opts.page ~= nil and (type(opts.page) ~= "number" or opts.page < 1 or opts.page % 1 ~= 0))
  then
    return single(path, opts, callback)
  end
  local key = table.concat({
    opts._formula and require("image_tools.media.math").key(opts) or version.key(path, assert(stat)),
    opts.cache or "",
    opts.magick or "",
    opts.rsvg or "rsvg-convert",
    tostring(opts.page or 1),
    tostring(opts.pdf_density or defaults.pdf_density),
    tostring(opts.render_scale or 1),
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

  -- A subscriber can cancel pending delivery independently from releasing a delivered disk pin.
  ---@class ImageToolsPreparationSubscriber
  ---@field active boolean Pending callback is still permitted.
  ---@field released? boolean Disk-pin ownership has been relinquished.
  ---@field disk_release? ImageToolsCancel Delivered-output lease, independent of worker lifetime.
  ---@type ImageToolsPreparationSubscriber
  local subscriber = { active = true }
  job.subscribers[subscriber] = callback
  if fresh then
    job.cancel = worker(path, opts, function(err, image, timing)
      if job.done then
        return
      end
      job.done = true
      if pending[key] == job then
        pending[key] = nil
      end

      -- Detach the worker callback set before delivery so reentrant requests start fresh work.
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
            receive(err, image and vim.deepcopy(image) or nil, timing and vim.deepcopy(timing) or nil)
          end
        end)
      end
    end)
  end

  -- Record release intent and unpin any output lease already delivered.
  ---@return nil
  local function release()
    subscriber.released = true
    if subscriber.disk_release then
      subscriber.disk_release()
      subscriber.disk_release = nil
    end
  end

  -- Cancel pending delivery; release owned pending resources without releasing already delivered
  -- leases.
  ---@return nil
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

-- Snapshot outstanding shared workers without starting preparation.
---@return table status Contains pending_jobs; native independent reads are not counted.
function M.status()
  return { pending_jobs = vim.tbl_count(pending) }
end

return M

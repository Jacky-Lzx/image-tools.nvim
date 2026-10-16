-- Module: image_tools.terminal.pixel_pool
--
-- Purpose:
--   Share uploaded pixels while allocating an independent placement for each
--   view.
--
-- Architecture:
--   Compose an uploader and per-view managers. Coalesce pixel ownership,
--   acknowledge placements and retry lost pixels only when the requester is the
--   sole owner, protecting other views.
--
-- Ownership:
--   Each pool owns consumer sets and upload leases; placement ids are
--   process-scoped. Releasing the last consumer unpins pixels, manager clearing
--   releases its leases, and pool clearing frees shared data.

-- Logical dependency keys remain stable across module directory changes.
local dependency_modules = {
  protocol = "image_tools.terminal.protocol",
}

---@class ImageToolsPlacement
---@field id integer Acknowledged Kitty image id.
---@field placement_id integer Independent virtual placement for this view.
---@field cancel ImageToolsCancel Release this placement lease without disturbing other views.
---@alias ImageToolsPlacementCallback fun(err: string?, placement: ImageToolsPlacement?, timing: table?)
---@class ImageToolsTerminalStatus: ImageToolsUploadStatus
---@field placements integer Active acknowledged consumer placements.
---@class ImageToolsPlacementConsumer
---@field active boolean Whether this consumer can still receive completion.
---@field placement integer Process-scoped nonzero placement id.
---@field shared boolean Whether pixels were already owned by another consumer.
---@field cancel ImageToolsCancel Release request, placement and consumer membership.
---@field ready? fun(err: string?) Continue after upload readiness or failure.
---@field request? ImageToolsCancel Pending placement acknowledgement wait.
---@field sent? boolean A placement request was sent; cancellation may hide it.
---@field placed? boolean A successful placement reply was received.
---@class ImageToolsPixelState
---@field consumers table<table, boolean> Live view leases sharing one upload.
---@field reused boolean Whether an acknowledged uploader entry existed at state creation.
---@field pixel? ImageToolsUploadEntry Uploaded entry after readiness.
---@field cancel_upload? ImageToolsUploadCancel Shared upload lease released after the last consumer.
---@class ImageToolsPixelPool
---@field uploader ImageToolsUploader Pixel cache/uploader owned by this pool.
---@field opts ImageToolsOptions Transport/cache/timeout settings.
---@field dependencies table<string, table> Logical module overrides.
---@field states table<string, ImageToolsPixelState> Active pixel ownership, separate from inactive uploader cache.
---@field hits integer Successful reused/shared placements.
---@field last_error? string Most recent placement error, cleared by acknowledged placement.
---@field dependency fun(self: ImageToolsPixelPool, name: string): table
---@field manager fun(self: ImageToolsPixelPool): ImageToolsPlacementManager
---@field status fun(self: ImageToolsPixelPool): ImageToolsTerminalStatus
---@field clear fun(self: ImageToolsPixelPool)
---@class ImageToolsPlacementManager
---@field pool ImageToolsPixelPool Shared or private underlying pool.
---@field leases table<table, boolean> Only this manager's consumers, including pending requests.
---@field status fun(self: ImageToolsPlacementManager): ImageToolsTerminalStatus
---@field clear fun(self: ImageToolsPlacementManager)
---@field acquire fun(self: ImageToolsPlacementManager, image: ImageToolsUploadImage, width: integer, height: integer, callback: ImageToolsPlacementCallback, retried: boolean?): ImageToolsCancel
---@type table, table
local Pool, Handle = {}, {}
Pool.__index, Handle.__index = Pool, Handle
local defaults = require("image_tools.defaults")
local kitty = require("image_tools.terminal.constants")

local placement = 0

-- Allocate a process-scoped nonzero 24-bit placement id independently of upload ids.
---@return integer placement
local function next_placement()
  placement = placement % kitty.MAX_ID + 1
  return placement
end

-- Create an uploader-backed pool without starting terminal I/O.
---@param options ImageToolsOptions Shared transport/cache settings.
---@param dependencies? table<string, table> Logical module overrides.
---@return ImageToolsPixelPool pool
function Pool.new(options, dependencies)
  dependencies = vim.tbl_extend("force", {}, dependencies or {})
  local uploader = require("image_tools.terminal.upload").new(options, dependencies)
  return setmetatable({ uploader = uploader, opts = options, dependencies = dependencies, states = {}, hits = 0 }, Pool)
end

-- Resolve an injected logical dependency first, then load the default subsystem module.
---@param name string Logical key such as terminal, protocol, image or pdf.
---@return table module
---@param self ImageToolsPixelPool
function Pool:dependency(name)
  return self.dependencies[name] or require(dependency_modules[name] or ("image_tools." .. name))
end

-- Create an independent view lease set over this pool.
---@return ImageToolsPlacementManager manager
---@param self ImageToolsPixelPool
function Pool:manager()
  return setmetatable({ pool = self, leases = {} }, Handle)
end

-- Combine uploader counters, shared cache hits and active acknowledged placements.
---@return ImageToolsTerminalStatus status
---@param self ImageToolsPixelPool
function Pool:status()
  local status = self.uploader:status()
  ---@cast status ImageToolsTerminalStatus
  status.hits = status.hits + self.hits
  status.last_error = self.last_error or status.last_error
  status.placements = 0
  for _, state in pairs(self.states) do
    for consumer in pairs(state.consumers) do
      if consumer.placed then
        status.placements = status.placements + 1
      end
    end
  end
  return status
end

-- Cancel all consumers before clearing the uploader, so no placement callback can revive pixels.
---@return nil
---@param self ImageToolsPixelPool
function Pool:clear()
  for _, state in pairs(vim.tbl_extend("force", {}, self.states)) do
    for consumer in pairs(vim.tbl_extend("force", {}, state.consumers)) do
      consumer.cancel()
    end
  end
  self.uploader:clear()
end

-- Return pool-wide statistics, not only the current manager leases.
---@return ImageToolsTerminalStatus status
---@param self ImageToolsPlacementManager
function Handle:status()
  return self.pool:status()
end

-- Release this manager consumers while preserving pixels still owned by other managers.
---@return nil
---@param self ImageToolsPlacementManager
function Handle:clear()
  for consumer in pairs(vim.tbl_extend("force", {}, self.leases)) do
    consumer.cancel()
  end
end

-- Share the upload, create a distinct placement and deliver only acknowledged placement readiness.
---@param image ImageToolsUploadImage Prepared pixels or in-memory PNG descriptor.
---@param width integer Placement columns.
---@param height integer Placement rows.
---@param callback ImageToolsPlacementCallback Can run synchronously when injected transport replies immediately.
---@param retried? boolean Internal one-retry guard for missing/evicted terminal pixels.
---@return ImageToolsCancel cancel Release this view; cancellation suppresses pending delivery.
---@param self ImageToolsPlacementManager
---@param crop? {x: integer, y: integer, width: integer, height: integer} Source pixel rectangle.
function Handle:acquire(image, width, height, callback, retried, crop, timing)
  timing = timing or { upload_ms = 0, placement_ms = 0 }
  local upload_started = vim.uv.hrtime()
  local pool, uploader = self.pool, self.pool.uploader
  local terminal, protocol = pool:dependency("terminal"), pool:dependency("protocol")
  local key = image.key or vim.fn.sha256((image.path or "") .. (image.data or ""))
  local state = pool.states[key]
  local fresh = not state
  if fresh then
    state = { consumers = {}, reused = uploader:cached(key) }
    pool.states[key] = state
  end
  local consumer = { active = true, placement = next_placement(), shared = not fresh }
  state.consumers[consumer], self.leases[consumer] = true, true
  local replacement
  -- Release a retry replacement, pending placement and consumer membership; unpin after the last
  -- consumer.
  ---@return nil
  local function cancel()
    if replacement then
      replacement()
      replacement = nil
    end
    if not consumer.active then
      return
    end
    consumer.active = false
    if consumer.request then
      consumer.request()
      consumer.request = nil
    end
    if consumer.sent and state.pixel then
      terminal.write(protocol.hide(state.pixel.id, consumer.placement))
    end
    state.consumers[consumer], self.leases[consumer] = nil, nil
    if not next(state.consumers) then
      if pool.states[key] == state then
        pool.states[key] = nil
      end
      if state.cancel_upload then
        state.cancel_upload()
      end
    end
  end
  consumer.cancel = cancel
  -- Record the placement/upload error, release this consumer and deliver an error without a
  -- placement.
  ---@param err string Failure message.
  ---@return nil
  local function fail(err)
    pool.last_error = err
    cancel()
    callback(err, nil, vim.deepcopy(timing))
  end

  -- Start placement only for a live consumer and retry missing pixels without replacing another
  -- view upload.
  ---@param err? string Upload readiness failure.
  ---@return nil
  function consumer.ready(err)
    if not consumer.active or consumer.sent then
      return
    end
    timing.upload_ms = timing.upload_ms + (vim.uv.hrtime() - upload_started) / 1e6
    if err then
      fail(err)
      return
    end
    consumer.sent = true
    local placement_started = vim.uv.hrtime()
    local done = false
    local cancellation = terminal.request(
      state.pixel.id,
      protocol.place(state.pixel.id, width, height, kitty.REPLY_ALL, consumer.placement, crop),
      pool.opts.terminal_timeout or defaults.terminal_timeout,
      -- A failed placement can replace pixels only when this consumer is their sole active owner.
      ---@param place_err string?
      ---@return nil
      function(place_err)
        if done then
          return
        end
        done = true
        consumer.request = nil
        if not consumer.active then
          return
        end
        timing.placement_ms = timing.placement_ms + (vim.uv.hrtime() - placement_started) / 1e6
        if place_err then
          -- Re-upload only when this consumer is the sole owner. An upload
          -- replaces every placement, so it must never disrupt another view.
          if
            not retried
            and (place_err:match("^ENOENT") or place_err:match("^ETIMEDOUT"))
            and next(state.consumers, consumer) == nil
            and next(state.consumers) == consumer
          then
            cancel()
            uploader:discard(state.pixel)
            replacement = self:acquire(image, width, height, callback, true, crop, timing)
          else
            fail(place_err)
          end
          return
        end
        consumer.placed = true
        pool.last_error = nil
        if state.reused or consumer.shared then
          pool.hits = pool.hits + 1
        end
        callback(nil, { id = state.pixel.id, placement_id = consumer.placement, cancel = cancel }, vim.deepcopy(timing))
      end,
      consumer.placement
    )
    if not done then
      consumer.request = cancellation
    end
  end
  if fresh then
    local cancellation = uploader:acquire(image, function(err, entry)
      state.pixel = entry
      for waiting in pairs(vim.tbl_extend("force", {}, state.consumers)) do
        waiting.ready(err)
      end
    end)
    state.cancel_upload = cancellation
    if not next(state.consumers) then
      cancellation()
    end
  elseif state.pixel then
    consumer.ready()
  end

  return cancel
end

return Pool

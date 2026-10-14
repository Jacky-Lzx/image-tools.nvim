-- Module: image_tools.terminal.transfer
--
-- Purpose:
--   Expose a view-scoped placement manager over a terminal pixel pool.
--
-- Architecture:
--   Use an injected shared pixel_pool when provided, otherwise create a private
--   pool. Render controllers consume acquire/clear/status without handling
--   upload/cache implementation details.
--
-- Ownership:
--   Own one manager and record pool ownership. Clear releases this view's
--   leases and clears pixels only when the pool is private; statistics come
--   from the underlying pool.

-- A view's placement manager. Pixel storage and upload are owned by its pool.
---@class ImageToolsTransfer
---@field pool ImageToolsPixelPool Shared injected pool or owned private pool.
---@field handle ImageToolsPlacementManager Per-view consumer lease manager.
---@field owns_pool boolean True only when construction created the pool.
local M = {}
M.__index = M

-- Create a view manager using shared injected pixels or a new private pool.
---@param opts ImageToolsOptions Transport/cache/timeout settings.
---@param dependencies? table<string, table> May include pixel_pool and module overrides.
---@return ImageToolsTransfer transfer
function M.new(opts, dependencies)
  local pool = dependencies and dependencies.pixel_pool
    or require("image_tools.terminal.pixel_pool").new(opts, dependencies)
  return setmetatable(
    { pool = pool, handle = pool:manager(), owns_pool = not (dependencies and dependencies.pixel_pool) },
    M
  )
end

-- Forward a prepared-image placement request to this view lease manager.
---@param image ImageToolsUploadImage Prepared image descriptor.
---@param width integer Columns.
---@param height integer Rows.
---@param callback ImageToolsPlacementCallback Acknowledged placement or error.
---@return ImageToolsCancel cancel
function M:acquire(image, width, height, callback)
  return self.handle:acquire(image, width, height, callback)
end

-- Release view leases; clear all pixels only if this manager owns a private pool.
---@return nil
function M:clear()
  self.handle:clear()
  if self.owns_pool then
    self.pool:clear()
  end
end

-- Return shared pool usage/counters rather than per-manager statistics.
---@return ImageToolsTerminalStatus status
function M:status()
  return self.pool:status()
end

return M

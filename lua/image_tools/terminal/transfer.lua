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
local M = {}
M.__index = M

function M.new(opts, dependencies)
  local pool = dependencies and dependencies.pixel_pool
    or require("image_tools.terminal.pixel_pool").new(opts, dependencies)
  return setmetatable(
    { pool = pool, handle = pool:manager(), owns_pool = not (dependencies and dependencies.pixel_pool) },
    M
  )
end

function M:acquire(image, width, height, callback)
  return self.handle:acquire(image, width, height, callback)
end

function M:clear()
  self.handle:clear()
  if self.owns_pool then
    self.pool:clear()
  end
end

function M:status()
  return self.pool:status()
end

return M

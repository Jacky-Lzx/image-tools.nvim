-- A view's placement manager. Pixel storage and upload are owned by its pool.
local M = {}
M.__index = M

function M.new(opts, dependencies)
  local pool = dependencies and dependencies.pixel_pool or require("image_tools.pixel_pool").new(opts, dependencies)
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

-- Bound a requested raster box before starting a converter or retaining it in a view.
local M = {}
function M.limit(size, options)
  local scale = math.min(
    1,
    options.max_dimension / size.width,
    options.max_dimension / size.height,
    math.sqrt(options.max_pixels / (size.width * size.height))
  )
  return {
    width = math.max(1, math.floor(size.width * scale)),
    height = math.max(1, math.floor(size.height * scale)),
  }
end
-- Translate a terminal viewport to a quantized, bounded raster box. Sampling
-- changes detail without changing the caller's logical display geometry.
function M.viewport(width, height, cell, options, scale)
  scale = scale or 1
  return M.limit({
    width = math.ceil(width * cell.width * scale / 64) * 64,
    height = math.ceil(height * cell.height * scale / 64) * 64,
  }, options)
end
return M

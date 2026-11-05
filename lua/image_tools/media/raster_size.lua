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
return M

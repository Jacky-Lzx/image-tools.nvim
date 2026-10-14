local M = {}

function M.fit(image, cell, max_width, max_height, upscale)
  local columns, rows = image.width / cell.width, image.height / cell.height
  local scale = math.min(upscale and math.huge or 1, max_width / columns, max_height / rows)
  return math.max(1, math.min(max_width, math.ceil(columns * scale))),
    math.max(1, math.min(max_height, math.ceil(rows * scale)))
end

return M

-- Module: image_tools.render.geometry
--
-- Purpose:
--   Fit image pixel dimensions into a terminal-cell viewport with preserved
--   aspect ratio.
--
-- Architecture:
--   A shared calculation for floating previews, file canvases and picker panes.
--   Convert pixels through cell geometry and apply caller-supplied bounds;
--   upscaling is an explicit caller choice.
--
-- Ownership:
--   Own no mutable state or editor resources. Callers determine viewport policy
--   and protocol coordinate limits.

local M = {}

function M.fit(image, cell, max_width, max_height, upscale)
  local columns, rows = image.width / cell.width, image.height / cell.height
  local scale = math.min(upscale and math.huge or 1, max_width / columns, max_height / rows)
  return math.max(1, math.min(max_width, math.ceil(columns * scale))),
    math.max(1, math.min(max_height, math.ceil(rows * scale)))
end

return M

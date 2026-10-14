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

-- Convert pixel size to cells, fit both viewport bounds and cap at native size unless upscaling is
-- enabled.
---@param image ImageToolsImageSize Pixel dimensions.
---@param cell ImageToolsCellSize Pixels per terminal cell.
---@param max_width integer Positive viewport columns.
---@param max_height integer Positive viewport rows.
---@param upscale? boolean Allow enlarging images to fill the viewport.
---@return integer width Rounded placement columns, at least one.
---@return integer height Rounded placement rows, at least one.
function M.fit(image, cell, max_width, max_height, upscale)
  local columns, rows = image.width / cell.width, image.height / cell.height
  local scale = math.min(upscale and math.huge or 1, max_width / columns, max_height / rows)
  return math.max(1, math.min(max_width, math.ceil(columns * scale))),
    math.max(1, math.min(max_height, math.ceil(rows * scale)))
end

return M

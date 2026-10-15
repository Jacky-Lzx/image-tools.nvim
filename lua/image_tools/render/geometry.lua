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

-- Crop a scaled image to its viewport. Offsets are terminal cells; crop coordinates are pixels.
function M.viewport(image, cell, width, height, viewport)
  local columns, rows = image.width / cell.width, image.height / cell.height
  local fit = math.min(width / columns, height / rows)
  local scale = viewport.zoom == "native" and 1 or fit * (tonumber(viewport.zoom) or 1)
  local full_width, full_height = math.ceil(columns * scale), math.ceil(rows * scale)
  local x = math.max(0, math.min(viewport.x or 0, math.max(0, full_width - width)))
  local y = math.max(0, math.min(viewport.y or 0, math.max(0, full_height - height)))
  local w, h = math.min(width, full_width), math.min(height, full_height)
  local left = math.min(image.width - 1, math.floor(x * cell.width / scale))
  local top = math.min(image.height - 1, math.floor(y * cell.height / scale))
  local crop = {
    x = left,
    y = top,
    width = math.min(image.width - left, math.max(1, math.ceil(w * cell.width / scale))),
    height = math.min(image.height - top, math.max(1, math.ceil(h * cell.height / scale))),
  }
  return w, h, crop, x, y, scale / fit
end

return M

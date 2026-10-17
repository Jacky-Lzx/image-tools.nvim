-- Module: image_tools.render.placeholder
--
-- Purpose:
--   Populate a render buffer with Kitty placeholder grids and placement
--   highlights.
--
-- Architecture:
--   Shared by inline views, floating previews, file canvases and picker renderers. Use the
--   supplied protocol to encode pixels/placement selection, then write lines
--   and apply namespace-specific extmarks.
--
-- Ownership:
--   Record dimensions, ids and highlight name on caller-owned state. Clear
--   removes the highlight definition; controllers own buffer/window cleanup and
--   terminal placement leases.

---@class ImageToolsDrawState
---@field buf? integer Buffer supplied by the drawing controller; required when draw executes.
---@field win? integer Render window owned by the controller.
---@field id? integer Kitty image id after drawing.
---@field placement_id? integer Virtual placement selector after drawing.
---@field width? integer Drawn placeholder columns.
---@field height? integer Drawn placeholder rows.
---@field highlight? string Highlight name cleared separately from buffer/window cleanup.

---@class ImageToolsPlaceholder
local M = {}
local PLACEHOLDER_HIGHLIGHT_PRIORITY = 1000

-- Virtual lines share the same explicit Kitty coordinates and highlight encoding
-- as render buffers, while leaving document bytes and undo history untouched.
function M.virtual(state, prefix, entry, width, height, protocol)
  state.id, state.placement_id, state.width, state.height = entry.id, entry.placement_id, width, height
  state.highlight = prefix .. entry.id .. "_" .. (entry.placement_id or 0)
  vim.api.nvim_set_hl(0, state.highlight, protocol.highlight(entry.id, entry.placement_id))
  local lines = {}
  for _, line in ipairs(protocol.grid(width, height)) do
    lines[#lines + 1] = { { line, state.highlight } }
  end
  return lines
end

-- Record placement identity, populate placeholder rows and highlight their exact byte ranges.
---@param state ImageToolsDrawState Caller-owned state with a live buf.
---@param namespace integer Controller namespace for extmarks.
---@param prefix string Prefix for the per-image/per-placement highlight name.
---@param entry ImageToolsPlacement Acknowledged placement.
---@param width integer Placeholder columns.
---@param height integer Placeholder rows.
---@param protocol table Grid/highlight encoding dependency.
---@param set_lines? fun(lines: string[]) Optional picker-specific line writer.
---@param rows? integer Pad to this many rows; defaults to image height.
---@return nil
function M.draw(state, namespace, prefix, entry, width, height, protocol, set_lines, rows)
  state.id, state.placement_id = entry.id, entry.placement_id
  state.width, state.height = width, height
  state.highlight = prefix .. entry.id .. "_" .. (entry.placement_id or 0)
  vim.api.nvim_set_hl(0, state.highlight, protocol.highlight(entry.id, entry.placement_id))
  local lines = protocol.grid(width, height)
  for _ = height + 1, rows or height do
    lines[#lines + 1] = ""
  end
  if set_lines then
    set_lines(lines)
  else
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  end
  for row = 0, height - 1 do
    vim.api.nvim_buf_set_extmark(state.buf, namespace, row, 0, {
      end_row = row + 1,
      end_col = 0,
      hl_group = state.highlight,
      priority = PLACEHOLDER_HIGHLIGHT_PRIORITY,
    })
  end
end

-- Clear the caller recorded highlight; window, buffer and placement cleanup belong to the
-- controller.
---@param state ImageToolsDrawState State whose highlight may exist.
---@return nil
function M.clear(state)
  if state.highlight then
    vim.api.nvim_set_hl(0, state.highlight, {})
  end
end

return M

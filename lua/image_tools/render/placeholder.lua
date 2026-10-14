-- Module: image_tools.render.placeholder
--
-- Purpose:
--   Populate a render buffer with Kitty placeholder grids and placement
--   highlights.
--
-- Architecture:
--   Shared by floating previews, file canvases and picker renderers. Use the
--   supplied protocol to encode pixels/placement selection, then write lines
--   and apply namespace-specific extmarks.
--
-- Ownership:
--   Record dimensions, ids and highlight name on caller-owned state. Clear
--   removes the highlight definition; controllers own buffer/window cleanup and
--   terminal placement leases.

local M = {}

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
      priority = 1000,
    })
  end
end

function M.clear(state)
  if state.highlight then
    vim.api.nvim_set_hl(0, state.highlight, {})
  end
end

return M

local M = {}
local entries, attached = {}, {}
local block_size, max_queries = 128, 128

-- Cache syntax only: resolution callbacks, project roots and filesystem checks
-- still run for each request. Buffer edits invalidate every prefix checkpoint.
function M.query(buf, row, kind, initial, scan)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local entry = entries[buf]
  if not entry or entry.tick ~= tick or entry.kind ~= kind then
    entry = { tick = tick, kind = kind, through = 0, states = { [0] = initial }, queries = {}, order = {} }
    entries[buf] = entry
  end
  if not attached[buf] then
    attached[buf] = vim.api.nvim_buf_attach(buf, false, {
      on_lines = function()
        entries[buf] = nil
      end,
      on_reload = function()
        entries[buf] = nil
      end,
      on_detach = function()
        entries[buf], attached[buf] = nil, nil
      end,
    })
  end
  if entry.queries[row] then
    return entry.queries[row]
  end
  local checkpoint = math.floor((row - 1) / block_size) * block_size
  while entry.through < checkpoint do
    local start = entry.through
    local _, state =
      scan(vim.api.nvim_buf_get_lines(buf, start, start + block_size, false), vim.deepcopy(entry.states[start]))
    entry.through = start + block_size
    entry.states[entry.through] = state
  end
  local result = scan(vim.api.nvim_buf_get_lines(buf, checkpoint, row, false), vim.deepcopy(entry.states[checkpoint]))
  entry.queries[row] = result
  entry.order[#entry.order + 1] = row
  if #entry.order > max_queries then
    entry.queries[table.remove(entry.order, 1)] = nil
  end
  return result
end
return M

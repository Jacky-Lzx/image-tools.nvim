-- Module: image_tools.document.syntax_cache
--
-- Purpose:
--   Cache Lua-scanner prefix context and queried rows for loaded buffers.
--
-- Architecture:
--   Accept an adapter-provided scanner and initial context. Build 128-line
--   checkpoints and retain up to 128 query results per buffer; leave filesystem
--   resolution outside the cache.
--
-- Ownership:
--   Own per-buffer entries and attachments. Edits/reloads invalidate cached
--   context, and detach releases entries; Tree-sitter indexing is managed
--   separately.

---@class ImageToolsSyntaxCacheEntry
---@field tick integer Buffer text version used by the cached scanner context.
---@field kind string Adapter/context identity.
---@field through integer Number of prefix lines checkpointed, in 128-line blocks.
---@field states table<integer, table> Scanner states after each checkpoint; index zero is initial context.
---@field queries table<integer, any> Adapter-specific queried-row results, keyed by one-based row.
---@field order integer[] Query insertion order for bounded eviction.

---@class ImageToolsSyntaxCache
local M = {}
local entries, attached = {}, {}
local CHECKPOINT_LINES = 128
local MAX_QUERY_RESULTS = 128

-- Cache syntax only: resolution callbacks, project roots and filesystem checks
-- still run for each request. Buffer edits invalidate every prefix checkpoint.
-- Reuse a row result or scan from the nearest checkpoint with a deep-copied prefix state.
---@param buf integer Buffer id; zero resolves to current.
---@param row integer One-based target row.
---@param kind string Scanner/adapter identity.
---@param initial table Prefix state before any lines.
---@param scan fun(lines: string[], state: table): any, table Returns target-row result and next prefix state.
---@return any result Adapter-defined syntax result; paths/filesystem decisions remain live.
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
  local checkpoint = math.floor((row - 1) / CHECKPOINT_LINES) * CHECKPOINT_LINES
  while entry.through < checkpoint do
    local start = entry.through
    local _, state =
      scan(vim.api.nvim_buf_get_lines(buf, start, start + CHECKPOINT_LINES, false), vim.deepcopy(entry.states[start]))
    entry.through = start + CHECKPOINT_LINES
    entry.states[entry.through] = state
  end
  local result = scan(vim.api.nvim_buf_get_lines(buf, checkpoint, row, false), vim.deepcopy(entry.states[checkpoint]))
  entry.queries[row] = result
  entry.order[#entry.order + 1] = row
  if #entry.order > MAX_QUERY_RESULTS then
    entry.queries[table.remove(entry.order, 1)] = nil
  end
  return result
end
return M

local M = {}
local entries, attached, queries = {}, {}, {}
local watched = setmetatable({}, { __mode = "k" })
local sources = {
  latex = [[
    (ERROR) @error
    (graphics_include) @image
    ((generic_command command: (command_name) @_name) @command
      (#any-of? @_name "\\graphicspath" "\\includegraphics" "\\includegraphics*"))
  ]],
  typst = [[
    (ERROR) @error
    ((call item: (ident) @_name (group . (string) @path)) @image
      (#eq? @_name "image"))
  ]],
}
local excluded = {
  comment = true,
  line_comment = true,
  source_code = true,
  verbatim_environment = true,
  listing_environment = true,
  minted_environment = true,
  comment_environment = true,
  raw = true,
  string = true,
}

local function allowed(node)
  local parent = node:parent()
  while parent do
    if excluded[parent:type()] then
      return false
    end
    parent = parent:parent()
  end
  return true
end

local function invalidate(entry, first)
  entry = entry and (entry.previous or entry)
  if not entry or not entry.frontier then
    return
  end
  -- A capture spanning the edit must be re-read from its beginning.
  for _, err in ipairs(entry.errors) do
    if err.last >= first then
      first = math.min(first, err.row - 1)
    end
  end
  entry.frontier = math.min(entry.frontier, first)
  for row in pairs(entry.rows) do
    if row > first then
      entry.rows[row] = nil
    end
  end
  entry.directories = vim.tbl_filter(function(change)
    return change.row <= first
  end, entry.directories)
  entry.errors = vim.tbl_filter(function(err)
    return err.row <= first
  end, entry.errors)
end

local function index(buf, entry, finish)
  local lang, query, tree, first = entry.lang, entry.query, entry.tree, entry.frontier
  local lines, parsed = {}, {}
  local function line_at(row)
    if not lines[row] then
      lines[row] = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    end
    return lines[row]
  end
  for id, node in query:iter_captures(tree:root(), buf, first, finish) do
    local capture = query.captures[id]
    if capture == "error" then
      local row, col, last = node:range()
      if row >= first then
        entry.errors[#entry.errors + 1] = { row = row + 1, col = col, last = last }
      end
    elseif (capture == "image" or capture == "command") and allowed(node) and node:start() >= first then
      local row, col, last = node:range()
      local line = line_at(row)
      if lang == "latex" then
        local tex = require("image_tools.document.tex")
        local name = node:field("command")[1]
        if name and vim.treesitter.get_node_text(name, buf) == "\\graphicspath" then
          if row == last then
            local directories = tex.graphicspath(line, col + 1)
            if directories then
              entry.directories[#entry.directories + 1] = { row = row + 1, col = col, paths = directories }
            end
          end
        else
          -- latex grammars do not consistently cover starred commands or
          -- nested \detokenize arguments. The tree supplies command/context;
          -- the existing same-line decoder validates complete literal syntax.
          parsed[row] = parsed[row] or tex.parse(line)
          for _, candidate in ipairs(parsed[row]) do
            if candidate.start_col == col then
              entry.rows[row + 1] = entry.rows[row + 1] or {}
              table.insert(entry.rows[row + 1], candidate)
            end
          end
        end
      elseif row == last and not node:has_error() then
        local group = node:named_child(1)
        local path = group and group:named_child(0)
        if path and path:type() == "string" then
          local text = vim.treesitter.get_node_text(path, buf)
          local src, finish = require("image_tools.document.typst").quoted(text, 1)
          if src and finish == #text then
            local _, _, _, end_col = node:range()
            entry.rows[row + 1] = entry.rows[row + 1] or {}
            table.insert(entry.rows[row + 1], {
              src = src,
              start_col = col - (line:sub(col, col) == "#" and 1 or 0),
              end_col = end_col,
            })
          end
        end
      end
    end
  end
  for _, candidates in pairs(entry.rows) do
    table.sort(candidates, function(a, b)
      return a.start_col < b.start_col
    end)
  end
  table.sort(entry.directories, function(a, b)
    return a.row < b.row or a.row == b.row and a.col < b.col
  end)
  entry.frontier = finish
end

-- Pending parses are authoritative too: never scan the buffer synchronously
-- while Neovim is yielding a large parse back to the event loop.
function M.query(buf, row, lang, ready)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local entry = entries[buf]
  if not entry or entry.tick ~= tick or entry.lang ~= lang then
    local ok, parser, query = pcall(function()
      local parser = vim.treesitter.get_parser(buf, lang)
      if not parser then
        return
      end
      queries[lang] = queries[lang] or vim.treesitter.query.parse(lang, sources[lang])
      return parser, queries[lang]
    end)
    if not ok or not parser then
      return
    end
    local previous = entry and entry.lang == lang and (entry.previous or entry)
    if previous and not previous.frontier then
      previous = nil
    end
    entry = { tick = tick, lang = lang, pending = true, waiters = {}, previous = previous }
    if parser.register_cbs and not watched[parser] then
      watched[parser] = true
      parser:register_cbs({
        on_changedtree = function(ranges)
          for _, range in ipairs(ranges) do
            invalidate(entries[buf], range[1])
          end
        end,
      })
    end
    entries[buf] = entry
    if not attached[buf] then
      attached[buf] = vim.api.nvim_buf_attach(buf, false, {
        on_lines = function(_, _, _, first)
          invalidate(entries[buf], first)
        end,
        on_reload = function()
          entries[buf] = nil
        end,
        on_detach = function()
          entries[buf], attached[buf] = nil, nil
        end,
      })
    end
    local function complete(err, trees)
      if not entry.pending then
        return
      end
      if
        entries[buf] ~= entry
        or not vim.api.nvim_buf_is_loaded(buf)
        or vim.api.nvim_buf_get_changedtick(buf) ~= tick
      then
        return
      end
      entry.pending = false
      if not err and trees and trees[1] then
        local result = previous or { rows = {}, directories = {}, errors = {}, frontier = 0 }
        result.tick, result.lang, result.tree, result.query = tick, lang, trees[1], query
        entries[buf] = result
      else
        entries[buf] = { tick = tick, lang = lang, failed = true }
      end
      for _, callback in ipairs(entry.waiters) do
        vim.schedule(function()
          if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_changedtick(buf) == tick then
            callback()
          end
        end)
      end
      entry.waiters = {}
    end
    -- nil range parses only the root language, excluding injected examples.
    local success, result = pcall(parser.parse, parser, nil, complete)
    if not success then
      complete(tostring(result))
    elseif result then
      complete(nil, result)
    end
    entry = entries[buf]
  end
  if entry.pending then
    if ready then
      entry.waiters[#entry.waiters + 1] = ready
    end
    return { pending = true, candidates = {} }
  end
  if entry.failed then
    return
  end
  if entry.frontier < row then
    local ok = pcall(index, buf, entry, row)
    if not ok then
      entry.failed = true
      return
    end
  end
  local candidates = entry.rows[row] or {}
  for _, err in ipairs(entry.errors) do
    -- Error recovery can expose calls inside unfinished raw/environment blocks.
    -- When preceding context is unreliable, let the existing lexer handle it.
    if err.row < row or err.row == row and candidates[1] and err.col < candidates[1].start_col then
      return
    end
  end
  local directories = {}
  for _, change in ipairs(entry.directories) do
    if change.row > row then
      break
    end
    directories = change.paths
  end
  return { candidates = candidates, directories = directories }
end

return M

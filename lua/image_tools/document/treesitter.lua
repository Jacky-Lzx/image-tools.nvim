local M = {}
local entries, attached, queries = {}, {}, {}
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

local function index(buf, lang, tick, trees, query)
  if not trees or not trees[1] then
    return
  end
  local entry = { tick = tick, lang = lang, rows = {}, directories = {}, errors = {} }
  local lines, parsed = {}, {}
  local function line_at(row)
    if not lines[row] then
      lines[row] = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    end
    return lines[row]
  end
  for id, node in query:iter_captures(trees[1]:root(), buf) do
    local capture = query.captures[id]
    if capture == "error" then
      local row, col = node:range()
      entry.errors[#entry.errors + 1] = { row = row + 1, col = col }
    elseif (capture == "image" or capture == "command") and allowed(node) then
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
  return entry
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
    entry = { tick = tick, lang = lang, pending = true, waiters = {} }
    entries[buf] = entry
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
      local success, result = pcall(index, buf, lang, tick, trees, query)
      entry.pending = false
      entries[buf] = not err and success and result or { tick = tick, lang = lang, failed = true }
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

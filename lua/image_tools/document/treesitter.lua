-- Module: image_tools.document.treesitter
--
-- Purpose:
--   Index LaTeX/Typst reference syntax with native buffer parsers and
--   diagnostics.
--
-- Architecture:
--   Use grammar capture queries, adapter decoders and context exclusions.
--   Pending parses are authoritative; failures report lexer fallback reasons,
--   while valid empty results remain authoritative.
--
-- Ownership:
--   Own buffer indexes, parse waiters, shared queries and diagnostic counters.
--   Ignore stale text versions; edits invalidate affected suffixes and
--   overlapping reference ranges.

---@class ImageToolsSyntaxResult
---@field candidates ImageToolsReference[] Supported references covering the query row.
---@field pending? boolean True while native parsing is authoritative but unfinished.
---@field directories? string[] LaTeX path context available before the queried row.
---@class ImageToolsSyntaxDiagnostic
---@field lang string Root parser language.
---@field backend "pending"|"treesitter"|"lexer" Current lookup backend.
---@field reason? string Lexer fallback category, absent for successful/pending trees.
---@field detail? string Additional failure/context message.
---@field parse_ms? number Most recent parse wall time, including event-loop yields.
---@field index_ms? number Most recent incremental capture-index duration.
---@class ImageToolsSyntaxStatus
---@field parses integer Native parse attempts across buffers.
---@field hits integer Reused indexes and queries.
---@field indexed_rows integer Rows traversed while extending indexes.
---@field fallbacks table<string, integer> Counts by lexer fallback reason.
---@field current? ImageToolsSyntaxDiagnostic Current-buffer backend state.
---@field enabled? boolean Runtime adds the configured Tree-sitter policy.
---@class ImageToolsSyntaxEntry
---@field tick integer Buffer changedtick captured by this parse/index.
---@field lang string Root parser language.
---@field pending? boolean Parsing has not completed.
---@field failed? boolean Backend cannot serve the current text version.
---@field previous? ImageToolsSyntaxEntry Valid previous index retained during a new parse.
---@field waiters? function[] Continuations scheduled only for a current text version.
---@field tree? TSTree Native root syntax tree after successful parsing.
---@field query? vim.treesitter.Query Compiled grammar capture query.
---@field frontier? integer Exclusive zero-based capture limit, equal to the last indexed one-based row.
---@field rows? table<integer, ImageToolsReference[]> Covering references indexed by one-based row.
---@field references? ImageToolsReference[] Indexed multiline references used for overlap invalidation.
---@field seen? table<string, boolean> Reference identities prevent duplicate indexing across rows.
---@field directories? table[] Ordered row/column graphicspath changes.
---@field errors? table[] Error spans affecting contextual trust.
---@field options? table Captured syntax budgets only; no Runtime resolver/callback retention.
---@field policy? string LaTeX budget identity, used to rebuild indexes after option changes.

---@class ImageToolsReadySyntaxEntry: ImageToolsSyntaxEntry
---@field tree TSTree Completed native root tree.
---@field query vim.treesitter.Query Compiled capture query.
---@field frontier integer Last indexed one-based row.
---@field rows table<integer, ImageToolsReference[]> Indexed covering references.
---@field directories table[] Ordered graphicspath changes.
---@field errors table[] Indexed syntax errors.
---@field options table Captured scan limits.

---@class ImageToolsTreesitter
local M = {}
local entries, attached, queries = {}, {}, {}
local diagnostics = {}
local totals = { parses = 0, hits = 0, indexed_rows = 0, fallbacks = {} }
-- Update current-buffer backend diagnostics and count explicitly reported fallback events.
---@param buf integer Buffer id.
---@param lang string Parser language.
---@param backend string Current pending/tree/lexer backend.
---@param reason? string Optional fallback category.
---@param detail? string Optional explanatory message.
---@return ImageToolsSyntaxDiagnostic diagnostic
local function report(buf, lang, backend, reason, detail)
  local state = diagnostics[buf] or { lang = lang }
  state.lang, state.backend, state.reason, state.detail = lang, backend, reason, detail
  diagnostics[buf] = state
  if reason then
    totals.fallbacks[reason] = (totals.fallbacks[reason] or 0) + 1
  end
  return state
end

-- Deep-copy global counters and current-buffer diagnostics without initializing a parser.
---@param buf? integer Current buffer when nil/zero.
---@return ImageToolsSyntaxStatus status Global counters plus optional current-buffer diagnostic.
function M.status(buf)
  if buf == nil or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local result = vim.deepcopy(totals)
  result.current = vim.deepcopy(diagnostics[buf])
  return result
end
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

-- Reject capture nodes nested inside comment, raw, string or excluded source environments.
---@param node TSNode Grammar capture.
---@return boolean allowed
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

-- Move the trusted frontier backward to cover edits and overlapping references; preserve earlier
-- valid results.
---@param entry? ImageToolsSyntaxEntry Active or pending-with-previous index.
---@param first integer Zero-based first changed row.
---@return nil
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
  for _, reference in ipairs(entry.references or {}) do
    if reference.end_row > first then
      first = math.min(first, reference.start_row - 1)
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
  entry.references = vim.tbl_filter(function(reference)
    return reference.end_row <= first
  end, entry.references or {})
  entry.seen = {}
  for _, reference in ipairs(entry.references) do
    entry.seen[reference.start_row .. ":" .. reference.start_col] = true
  end
  entry.errors = vim.tbl_filter(function(err)
    return err.row <= first
  end, entry.errors)
end

-- Traverse only the unindexed capture suffix, decoding references and populating every covered
-- row.
---@param buf integer Buffer id.
---@param entry ImageToolsReadySyntaxEntry Ready index with tree/query/frontier.
---@param finish integer Exclusive zero-based traversal limit (one-based target row).
---@return nil
local function index(buf, entry, finish)
  local lang, query, tree, first = entry.lang, entry.query, entry.tree, entry.frontier
  local lines, parsed = {}, {}
  -- Read one zero-based source row once per indexing operation.
  ---@param row integer Zero-based buffer row.
  ---@return string line
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
      if lang == "latex" then
        local tex = require("image_tools.document.tex")
        local name = node:field("command")[1]
        if name and vim.treesitter.get_node_text(name, buf) == "\\graphicspath" then
          if row == last then
            local directories = tex.graphicspath(line_at(row), col + 1)
            if directories then
              entry.directories[#entry.directories + 1] = { row = row + 1, col = col, paths = directories }
            end
          end
        else
          local decoder = require("image_tools.document.tex.reference")
          local decode_key = row .. ":" .. col
          if not parsed[decode_key] then
            local max_lines, max_bytes = decoder.limits(entry.options)
            local _, _, last_row, last_col = node:range()
            local _, _, start_byte = node:start()
            local _, _, end_byte = node:end_()
            if node:type() ~= "graphics_include" or node:has_error() then
              parsed[decode_key] = decoder.at(buf, row, col, entry.options)
            elseif
              last_row - row + 1 <= max_lines
              and end_byte - start_byte <= max_bytes
              and last_row + 1 <= (entry.options.max_scan_lines or 10000)
            then
              local text = table.concat(vim.api.nvim_buf_get_text(buf, row, col, last_row, last_col, {}), "\n")
              parsed[decode_key] = decoder.parse(text, row + 1, entry.options)
              for _, reference in ipairs(parsed[decode_key]) do
                if reference.start_row == row + 1 then
                  reference.start_col = reference.start_col + col
                end
                if reference.end_row == row + 1 then
                  reference.end_col = reference.end_col + col
                end
              end
            else
              parsed[decode_key] = {}
            end
          end
          for _, reference in ipairs(parsed[decode_key]) do
            local identity = reference.start_row .. ":" .. reference.start_col
            if reference.start_col == col and not entry.seen[identity] then
              entry.seen[identity] = true
              entry.references[#entry.references + 1] = reference
              for covered = reference.start_row, reference.end_row do
                entry.rows[covered] = entry.rows[covered] or {}
                table.insert(entry.rows[covered], reference)
              end
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
              start_col = col - (line_at(row):sub(col, col) == "#" and 1 or 0),
              end_col = end_col,
            })
          end
        end
      end
    end
  end
  for _, candidates in pairs(entry.rows) do
    table.sort(candidates, function(a, b)
      return (a.start_row or 0) < (b.start_row or 0) or a.start_row == b.start_row and a.start_col < b.start_col
    end)
  end
  table.sort(entry.directories, function(a, b)
    return a.row < b.row or a.row == b.row and a.col < b.col
  end)
  entry.frontier = finish
end

-- Pending parses are authoritative too: never scan the buffer synchronously
-- while Neovim is yielding a large parse back to the event loop.
-- Parse or extend a current index; nil permits Lua fallback, while pending/empty results remain
-- authoritative.
---@param buf integer Buffer id; zero means current.
---@param row integer One-based target row.
---@param lang string Root parser language (latex/typst).
---@param ready? fun() Resume selection after a current parse finishes.
---@param options? table LaTeX reference budgets and scan ceiling.
---@return ImageToolsSyntaxResult? syntax Nil reports unavailable/failed/contextually unsafe parsing.
function M.query(buf, row, lang, ready, options)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if not attached[buf] then
    attached[buf] = vim.api.nvim_buf_attach(buf, false, {
      on_lines = function(_, _, _, first)
        invalidate(entries[buf], first)
      end,
      on_reload = function()
        entries[buf] = nil
      end,
      on_detach = function()
        entries[buf], attached[buf], diagnostics[buf] = nil, nil, nil
      end,
    })
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local entry = entries[buf]
  options = options or {}
  local max_lines, max_bytes = require("image_tools.document.tex.reference").limits(options)
  -- Cache syntax policy only; runtime callbacks/resolvers must not be retained
  -- by a loaded buffer's parser cache after setup replacement or teardown.
  options = {
    latex = { max_reference_lines = max_lines, max_reference_bytes = max_bytes },
    max_scan_lines = options.max_scan_lines or 10000,
  }
  local policy = lang == "latex" and table.concat({ max_lines, max_bytes, options.max_scan_lines or 10000 }, ":") or ""
  if entry and entry.tree and entry.policy ~= policy then
    entry.rows, entry.directories, entry.errors, entry.references, entry.seen, entry.frontier = {}, {}, {}, {}, {}, 0
    entry.policy, entry.options = policy, options
  end

  if not entry or entry.tick ~= tick or entry.lang ~= lang then
    local stage = "parser_unavailable"
    local ok, parser, query = pcall(function()
      local parser = vim.treesitter.get_parser(buf, lang)
      if not parser then
        return
      end
      stage = "query_error"
      local query = queries[lang] or vim.treesitter.query.parse(lang, sources[lang])
      return parser, query
    end)
    if not ok or not parser then
      report(buf, lang, "lexer", stage, not ok and tostring(parser) or "No buffer parser")
      return
    end
    local started = vim.uv.hrtime()
    totals.parses = totals.parses + 1
    report(buf, lang, "pending")
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
    -- Publish a parse only if its buffer/version and entry token remain current, then schedule
    -- waiters.
    ---@param err? string Native parse error.
    ---@param trees? TSTree[] Parsed root-language trees.
    ---@return nil
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
      local state = report(buf, lang, "treesitter")
      state.parse_ms = (vim.uv.hrtime() - started) / 1e6
      if not err and trees and trees[1] then
        queries[lang] = query
        local result = previous
          or { rows = {}, directories = {}, errors = {}, references = {}, seen = {}, frontier = 0 }
        result.tick, result.lang, result.tree, result.query = tick, lang, trees[1], query
        result.options, result.policy = options, policy
        entries[buf] = result
      else
        entries[buf] = { tick = tick, lang = lang, failed = true }
        report(buf, lang, "lexer", "parse_error", tostring(err or "No syntax tree"))
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
  ---@cast entry ImageToolsReadySyntaxEntry
  if entry.frontier < row then
    local first, started = entry.frontier, vim.uv.hrtime()
    local ok, err = pcall(index, buf, entry, row)
    local state = diagnostics[buf]
    state.index_ms = (vim.uv.hrtime() - started) / 1e6
    totals.indexed_rows = totals.indexed_rows + row - first
    if not ok then
      report(buf, lang, "lexer", "index_error", tostring(err))
      entry.failed = true
      return
    end
  else
    totals.hits = totals.hits + 1
  end
  report(buf, lang, "treesitter")
  local candidates = entry.rows[row] or {}
  for _, err in ipairs(entry.errors) do
    -- Error recovery can expose calls inside unfinished raw/environment blocks.
    -- When preceding context is unreliable, let the existing lexer handle it.
    if err.row < row or err.row == row and candidates[1] and err.col < candidates[1].start_col then
      report(buf, lang, "lexer", "error_context", "Syntax error at line " .. err.row)
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

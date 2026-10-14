local M = {}
local function escaped(line, pos)
  local count = 0
  while pos > 1 and line:sub(pos - 1, pos - 1) == "\\" do
    count, pos = count + 1, pos - 1
  end
  return count % 2 == 1
end
local function group(line, pos, opening, ending)
  if line:sub(pos, pos) ~= opening then
    return
  end
  local depth, braces = 1, 0
  for i = pos + 1, #line do
    local char = line:sub(i, i)
    if not escaped(line, i) then
      if opening == "[" and char == "{" then
        braces = braces + 1
      elseif opening == "[" and char == "}" then
        braces = math.max(0, braces - 1)
      elseif char == opening and braces == 0 then
        depth = depth + 1
      elseif char == ending and braces == 0 then
        depth = depth - 1
        if depth == 0 then
          return i
        end
      end
    end
  end
end
local function space(line, pos)
  while line:sub(pos, pos):match("%s") do
    pos = pos + 1
  end
  return pos
end
local function clean(line)
  local pos = 1
  while pos <= #line do
    if not escaped(line, pos) and line:sub(pos, pos) == "%" then
      return line:sub(1, pos - 1)
    end
    if not escaped(line, pos) and line:sub(pos, pos + 4) == "\\verb" and not line:sub(pos + 5, pos + 5):match("%a") then
      local delimiter = pos + 5
      if line:sub(delimiter, delimiter) == "*" then
        delimiter = delimiter + 1
      end
      local finish = line:find(line:sub(delimiter, delimiter), delimiter + 1, true)
      if not finish then
        return line:sub(1, pos - 1)
      end
      line = line:sub(1, pos - 1) .. string.rep(" ", finish - pos + 1) .. line:sub(finish + 1)
      pos = finish + 1
    else
      pos = pos + 1
    end
  end
  return line
end
local function literal(src)
  src = vim.trim(src)
  local first = src:find("\\detokenize", 1, true)
  if first == 1 then
    local start = space(src, 12)
    local finish = group(src, start, "{", "}")
    if finish and vim.trim(src:sub(finish + 1)) == "" then
      return src:sub(start + 1, finish - 1)
    end
    return nil
  end
  src = src:gsub("\\([#$%%&_{} ])", "%1")
  if src:find("\\", 1, true) then
    return nil
  end -- Macros are not expanded.
  return src
end
M.clean, M.group, M.space, M.literal, M.escaped = clean, group, space, literal, escaped

function M.limits(opts)
  local config = opts and opts.latex or {}
  return config.max_reference_lines or 64, config.max_reference_bytes or 16384
end
local function position(text, offset, first)
  local row, start = first, 1
  for ending in text:gmatch("()\n") do
    if ending >= offset then
      break
    end
    row, start = row + 1, ending + 1
  end
  return row, offset - start
end
-- Keep offsets intact when excluding comments and inline verbatim text.
local function sanitize(text)
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    local cleaned = clean(line)
    lines[i] = cleaned .. string.rep(" ", #line - #cleaned)
  end
  return table.concat(lines, "\n")
end
function M.parse(text, first, opts)
  first = first or 1
  text = sanitize(text)
  local max_lines, max_bytes = M.limits(opts)
  local results, pos, error_message = {}, 1, nil
  while pos <= #text do
    local start = text:find("\\includegraphics", pos, true)
    if not start then
      break
    end
    pos = start + 16
    if not escaped(text, start) and not text:sub(pos, pos):match("%a") then
      if text:sub(pos, pos) == "*" then
        pos = pos + 1
      end
      pos = space(text, pos)
      if text:sub(pos, pos) == "[" then
        local finish = group(text, pos, "[", "]")
        pos = finish and space(text, finish + 1) or #text + 1
      end
      local finish = group(text, pos, "{", "}")
      if finish then
        local start_row, start_col = position(text, start, first)
        local end_row, end_col = position(text, finish + 1, first)
        if end_row - start_row + 1 > max_lines or finish - start + 1 > max_bytes then
          error_message = "LaTeX image reference exceeds configured limits"
        elseif text:sub(pos + 1, finish - 1):find("\n", 1, true) then
          error_message = "Multiline image filenames are not supported"
        else
          local src = literal(text:sub(pos + 1, finish - 1))
          if src and src ~= "" then
            results[#results + 1] = {
              src = src,
              start_row = start_row,
              start_col = start_col,
              end_row = end_row,
              end_col = end_col,
            }
          end
        end
        pos = finish + 1
      end
    end
  end
  return results, error_message
end
function M.contains(reference, row, col)
  return row >= reference.start_row
    and row <= reference.end_row
    and (
      col == nil
      or (row > reference.start_row or col >= reference.start_col)
        and (row < reference.end_row or col < reference.end_col)
    )
end
-- Decode an anchored command without relying on a grammar's argument extent.
-- Generic starred commands and nested detokenize paths can have partial nodes.
function M.at(buf, row, col, opts)
  local max_lines, max_bytes = M.limits(opts)
  local start_byte = vim.api.nvim_buf_get_offset(buf, row) + col
  local last = math.min(vim.api.nvim_buf_line_count(buf) - 1, row + max_lines - 1, (opts.max_scan_lines or 10000) - 1)
  if last < row then
    return {}
  end
  while last > row and vim.api.nvim_buf_get_offset(buf, last) >= start_byte + max_bytes do
    last = last - 1
  end
  local length = vim.api.nvim_buf_get_offset(buf, last + 1) - vim.api.nvim_buf_get_offset(buf, last) - 1
  local finish = math.min(length, start_byte + max_bytes - vim.api.nvim_buf_get_offset(buf, last))
  local text = table.concat(vim.api.nvim_buf_get_text(buf, row, col, last, finish, {}), "\n")
  local references = M.parse(text, row + 1, opts)
  for _, reference in ipairs(references) do
    if reference.start_row == row + 1 and reference.start_col == 0 then
      reference.start_col = col
      if reference.end_row == row + 1 then
        reference.end_col = reference.end_col + col
      end
      return { reference }
    end
  end
  return {}
end

-- Look only within a bounded neighborhood for a possible command. Context
-- (comments/environments/graphicspath) is supplied by the existing checkpoint lexer.
function M.nearby(buf, row, opts)
  local max_lines, max_bytes = M.limits(opts)
  local first = math.max(0, row - max_lines)
  -- Bound bytes before fetching text; very long lines are never copied whole.
  local ending = vim.api.nvim_buf_get_offset(buf, row)
  while first < row and ending - vim.api.nvim_buf_get_offset(buf, first) > max_bytes do
    first = first + 1
  end
  if first == row then
    return {}, "LaTeX image reference exceeds configured limits"
  end
  local before = vim.api.nvim_buf_get_lines(buf, first, row, false)
  local text = table.concat(before, "\n")
  if not text:find("\\includegraphics", 1, true) then
    return {}
  end
  local last = math.min(vim.api.nvim_buf_line_count(buf), opts.max_scan_lines, row + max_lines - 1)
  while last > row and vim.api.nvim_buf_get_offset(buf, last) - vim.api.nvim_buf_get_offset(buf, row) > max_bytes do
    last = last - 1
  end
  if last > row then
    text = text .. "\n" .. table.concat(vim.api.nvim_buf_get_lines(buf, row, last, false), "\n")
  end
  local all, err = M.parse(text, first + 1, opts)
  return vim.tbl_filter(function(reference)
    return M.contains(reference, row)
  end, all), err
end
return M

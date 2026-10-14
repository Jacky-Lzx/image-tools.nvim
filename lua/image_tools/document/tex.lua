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
  local depth = 1
  for i = pos + 1, #line do
    local char = line:sub(i, i)
    if not escaped(line, i) then
      if char == opening then
        depth = depth + 1
      elseif char == ending then
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
function M.parse(line)
  line = clean(line)
  local result, pos = {}, 1
  while pos <= #line do
    local start = line:find("\\includegraphics", pos, true)
    if not start then
      break
    end
    pos = start + 16
    if not escaped(line, start) and not line:sub(pos, pos):match("%a") then
      if line:sub(pos, pos) == "*" then
        pos = pos + 1
      end
      pos = space(line, pos)
      if line:sub(pos, pos) == "[" then
        local finish = group(line, pos, "[", "]")
        pos = finish and space(line, finish + 1) or #line + 1
      end
      local finish = group(line, pos, "{", "}")
      if finish then
        local src = literal(line:sub(pos + 1, finish - 1))
        if src and src ~= "" then
          result[#result + 1] = { src = src, start_col = start - 1, end_col = finish }
        end
        pos = finish + 1
      end
    end
  end
  return result
end

local excluded = { verbatim = true, ["verbatim*"] = true, lstlisting = true, minted = true, comment = true }
-- Shared literal argument handling for the lexer and Tree-sitter nodes.
function M.graphicspath(original, start)
  local line = clean(original)
  start = start or line:find("\\graphicspath", 1, true)
  if not start or line:sub(start, start + 12) ~= "\\graphicspath" or escaped(line, start) then
    return
  end
  local first = space(line, start + 13)
  local last = group(line, first, "{", "}")
  if not last then
    return
  end
  local directories, p = {}, space(line, first + 1)
  while p < last do
    local finish = group(line, p, "{", "}")
    if not finish then
      break
    end
    local directory = literal(line:sub(p + 1, finish - 1))
    if directory then
      directories[#directories + 1] = directory
    end
    p = space(line, finish + 1)
  end
  return directories
end
local function scan(lines, previous)
  local environment, directories = previous.environment, previous.directories or {}
  local blocked = false
  for i, original in ipairs(lines) do
    local line = clean(original)
    if environment then
      if line:find("\\end{" .. environment .. "}", 1, true) then
        environment = nil
      end
      if i == #lines then
        blocked = true
      end
    else
      local opening = line:match("\\begin{([^}]+)}")
      if excluded[opening] then
        if not line:find("\\end{" .. opening .. "}", 1, true) then
          environment = opening
        end
        if i == #lines then
          blocked = true
        end
      else
        directories = M.graphicspath(line) or directories
      end
    end
  end
  return {
    candidates = not blocked and M.parse(lines[#lines] or "") or {},
    directories = directories,
    blocked = blocked,
  }, { environment = environment, directories = directories }
end
function M.find(buf, row, col, opts)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  if not line:find("\\includegraphics", 1, true) then
    return nil, "No supported image reference on the current line"
  end
  local syntax = opts.treesitter ~= false
      and require("image_tools.document.treesitter").query(buf, row, "latex", opts._treesitter_ready)
    or nil
  if syntax and syntax.pending then
    return nil, "Tree-sitter parsing is pending", "pending"
  end
  syntax = syntax or require("image_tools.document.syntax_cache").query(buf, row, "tex", {}, scan)
  if syntax.blocked then
    return nil, "Cursor is inside a verbatim/comment environment"
  end
  local document = vim.api.nvim_buf_get_name(buf)
  local resolve_opts = vim.tbl_extend(
    "force",
    opts,
    { literal = true, root = require("image_tools.document.paths").base(document, opts, buf) }
  )
  for _, candidate in ipairs(syntax.candidates) do
    if col == nil or col >= candidate.start_col and col < candidate.end_col then
      local path, err = require("image_tools.document.paths").resolve(candidate.src, document, resolve_opts)
      if not path then
        return nil, err
      end
      local paths = { path }
      if candidate.src:sub(1, 1) ~= "/" then
        for _, directory in ipairs(syntax.directories) do
          local resolved =
            require("image_tools.document.paths").resolve(directory .. "/" .. candidate.src, document, resolve_opts)
          if resolved then
            paths[#paths + 1] = resolved
          end
        end
      end
      for _, target in ipairs(paths) do
        local stat = vim.uv.fs_stat(target)
        if stat and stat.type == "file" then
          return target
        end
        for _, extension in ipairs({ "pdf", "png", "jpg", "jpeg" }) do
          local extended = target .. "." .. extension
          stat = vim.uv.fs_stat(extended)
          if stat and stat.type == "file" then
            return extended
          end
        end
      end
      return nil, "Image not found in document root or graphicspath: " .. candidate.src
    end
  end
  return nil, "No supported image reference on the current line"
end
return M

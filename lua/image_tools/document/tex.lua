local M = {}
local reference = require("image_tools.document.tex.reference")
local clean, group, space, literal, escaped =
  reference.clean, reference.group, reference.space, reference.literal, reference.escaped
function M.parse(line)
  local results = reference.parse(line)
  for _, candidate in ipairs(results) do
    candidate.start_row, candidate.end_row = nil, nil
  end
  return results
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
  local nearby, nearby_error = reference.nearby(buf, row, opts)
  if #nearby == 0 then
    return nil, nearby_error or "No supported image reference on the current line"
  end
  local syntax = opts.treesitter ~= false
      and require("image_tools.document.treesitter").query(buf, row, "latex", opts._treesitter_ready, opts)
    or nil
  if syntax and syntax.pending then
    return nil, "Tree-sitter parsing is pending", "pending", nearby[1]
  end
  if not syntax then
    syntax = { candidates = {} }
    for _, candidate in ipairs(nearby) do
      local context = require("image_tools.document.syntax_cache").query(buf, candidate.start_row, "tex", {}, scan)
      if not context.blocked then
        candidate.directories = context.directories
        syntax.candidates[#syntax.candidates + 1] = candidate
      end
    end
  end
  local document = vim.api.nvim_buf_get_name(buf)
  local resolve_opts = vim.tbl_extend(
    "force",
    opts,
    { literal = true, root = require("image_tools.document.paths").base(document, opts, buf) }
  )
  for _, candidate in ipairs(syntax.candidates) do
    if reference.contains(vim.tbl_extend("keep", candidate, { start_row = row, end_row = row }), row, col) then
      local path, err = require("image_tools.document.paths").resolve(candidate.src, document, resolve_opts)
      if not path then
        return nil, err
      end
      local paths = { path }
      if candidate.src:sub(1, 1) ~= "/" then
        for _, directory in ipairs(candidate.directories or syntax.directories or {}) do
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
          return target, nil, nil, candidate
        end
        for _, extension in ipairs({ "pdf", "png", "jpg", "jpeg" }) do
          local extended = target .. "." .. extension
          stat = vim.uv.fs_stat(extended)
          if stat and stat.type == "file" then
            return extended, nil, nil, candidate
          end
        end
      end
      return nil, "Image not found in document root or graphicspath: " .. candidate.src
    end
  end
  return nil, "No supported image reference on the current line"
end
return M

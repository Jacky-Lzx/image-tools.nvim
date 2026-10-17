-- Module: image_tools.document.tex
--
-- Purpose:
--   Recognize literal LaTeX image references and define LaTeX insertion rules.
--
-- Architecture:
--   Combine tex/reference decoding with Tree-sitter or cached Lua environment
--   context. Resolve document/project roots, graphicspath directories and
--   omitted extensions; emit graphicx markup.
--
-- Ownership:
--   Store syntax context in the shared backends, not this adapter. References
--   carry multiline ranges; dynamic macros are not expanded and file
--   preparation remains outside document lookup.

local M = {}
local GRAPHICSPATH_COMMAND = "\\graphicspath"
local reference = require("image_tools.document.tex.reference")
local clean, group, space, literal, escaped =
  reference.clean, reference.group, reference.space, reference.literal, reference.escaped
-- Retain same-line reference compatibility by dropping row coordinates from decoded candidates.
---@param line string One source line.
---@return ImageToolsReference[] references
function M.parse(line)
  local results = reference.parse(line)
  for _, candidate in ipairs(results) do
    candidate.start_row, candidate.end_row = nil, nil
  end
  return results
end

local excluded = { verbatim = true, ["verbatim*"] = true, lstlisting = true, minted = true, comment = true }
-- Shared literal argument handling for the lexer and Tree-sitter nodes.
-- Decode a single-line literal graphicspath declaration after comment/inline-verbatim cleanup.
---@param original string Source line.
---@param start? integer One-based command position; otherwise search the line.
---@return string[]? directories Nil when the declaration is absent/invalid.
function M.graphicspath(original, start)
  local line = clean(original)
  start = start or line:find(GRAPHICSPATH_COMMAND, 1, true)
  if
    not start
    or line:sub(start, start + #GRAPHICSPATH_COMMAND - 1) ~= GRAPHICSPATH_COMMAND
    or escaped(line, start)
  then
    return
  end
  local first = space(line, start + #GRAPHICSPATH_COMMAND)
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

-- Advance excluded-environment and graphicspath context for the Lua checkpoint scanner.
---@param lines string[] Contiguous prefix/source lines.
---@param previous table Captured environment/directories before this segment.
---@return table result Candidate/block/path context for the segment last line.
---@return table state Updated prefix environment/directories.
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

-- Find a complete covering range, choose syntax authority and resolve literal paths/extensions in
-- project context.
---@param buf integer Buffer id.
---@param row integer One-based buffer row.
---@param col? integer Zero-based byte column; nil requests the first covering reference.
---@param opts ImageToolsOptions Lookup/scan/root settings.
---@return string? path Resolved image source.
---@return string? error Lookup/resolution message on failure.
---@return ImageToolsLookupStatus? status Only miss permits cursor-to-line fallback; pending must wait.
---@return ImageToolsReference? reference Selected range when resolved, or pending LaTeX coverage.
function M.find(buf, row, col, opts)
  local nearby, nearby_error = reference.nearby(buf, row, opts)
  if #nearby == 0 then
    return nil, nearby_error or "No supported image reference on the current line"
  end
  local syntax = opts.treesitter ~= false
      and require("image_tools.document.treesitter").query(buf, row, "latex", opts._treesitter_ready, opts)
    or nil
  if syntax and syntax.pending then
    local selected = nearby[1]
    for _, candidate in ipairs(nearby) do
      if reference.contains(candidate, row, col) then
        selected = candidate
        break
      end
    end
    return nil, "Tree-sitter parsing is pending", "pending", selected
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
  local document = opts._document_path or vim.api.nvim_buf_get_name(buf)
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
  return nil, "No supported image reference on the current line", "miss"
end

local image_formats = { "png", "jpg", "jpeg", "pdf" }
-- Emit each multiline command once, on its opening row; use the cached Lua backend.
function M.references(buf, row, opts)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  if not line:find("\\includegraphics", 1, true) then
    return {}
  end
  local results = {}
  for _, candidate in ipairs(reference.nearby(buf, row, opts)) do
    if candidate.start_row == row then
      local context = require("image_tools.document.syntax_cache").query(buf, row, "tex", {}, scan)
      if not context.blocked then
        local path, err, _, ref =
          M.find(buf, row, candidate.start_col, vim.tbl_extend("force", opts, { treesitter = false }))
        results[#results + 1] = { path = path, error = err, reference = ref or candidate }
      end
    end
  end
  return results
end

-- Return independently allocated insertion/picker formats accepted by the LaTeX adapter.
---@return string[] extensions
function M.image_formats()
  return vim.deepcopy(image_formats)
end

-- Check compiler-compatible imported/reference extensions without converting them.
---@param path string Source filename.
---@return boolean supported
function M.supports_image(path)
  return require("image_tools.media.formats").supports(path, image_formats)
end
M.insertion_base = require("image_tools.document.paths").base
-- Replace TeX-special/control filename characters while preserving spaces and underscores.
---@param name string Single imported basename.
---@return string sanitized
---@return integer replacements Number of characters replaced by gsub.
function M.sanitize_filename(name)
  return name:gsub("[%%#&$^~{}\\%c]", "_")
end

-- Match image-insert.nvim's default figure template and label naming, with the
-- editing offset inside the empty caption. Reject unsafe reference characters.
---@param path string Relative resource path.
---@param alt? string Unused by LaTeX markup.
---@return string markup Unsafe paths raise an error for transaction rollback.
---@return integer edit_offset Zero-based byte offset inside the caption, including preceding newlines.
function M.markup(path, alt)
  assert(
    not path:find("[%%#&$^~{}\\%c]"),
    "LaTeX image paths cannot contain TeX special characters or control characters; rename the file/directory"
  )
  local label = vim.fn.fnamemodify(vim.fs.basename(path), ":r"):lower():gsub("%s+", "-")
  local prefix = "\\begin{figure}[ht]\n  \\centering\n  \\includegraphics[width=0.8\\linewidth]{"
    .. path
    .. "}\n  \\caption{"
  return prefix .. "}\n  \\label{fig:" .. label .. "}\n\\end{figure}", #prefix
end

return M

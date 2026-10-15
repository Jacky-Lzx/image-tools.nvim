-- Module: image_tools.document.markdown
--
-- Purpose:
--   Recognize same-line Markdown images and define Markdown insertion rules.
--
-- Architecture:
--   Parse literal destinations, exclude code contexts using syntax_cache, and
--   resolve paths through document/paths. Derive insertion formats from
--   media/formats and emit escaped image markup.
--
-- Ownership:
--   Delegate persistent prefix context to syntax_cache. This adapter owns no
--   preview windows, converters or terminal resources.

local M = {}

-- Determine whether syntax at a one-based byte position follows an odd backslash run.
---@param text string Source text.
---@param pos integer One-based byte position.
---@return boolean escaped
local function escaped(text, pos)
  local count = 0
  while pos > 1 and text:sub(pos - 1, pos - 1) == "\\" do
    count, pos = count + 1, pos - 1
  end
  return count % 2 == 1
end

-- Find a balanced delimiter while honoring escapes, angle destinations and quoted titles.
---@param text string Source line.
---@param start integer One-based opening delimiter position.
---@param opening string Opening delimiter.
---@param ending string Closing delimiter.
---@return integer? finish One-based closing delimiter, or nil when incomplete.
local function closing(text, start, opening, ending)
  local depth, angle, quote = 1, false, nil
  for pos = start + 1, #text do
    local char = text:sub(pos, pos)
    if not escaped(text, pos) then
      if opening == "(" and angle then
        angle = char ~= ">"
      elseif opening == "(" and quote then
        if char == quote then
          quote = nil
        end
      elseif opening == "(" and char == "<" and depth == 1 then
        angle = true
      elseif opening == "(" and (char == '"' or char == "'") and text:sub(pos - 1, pos - 1):match("%s") then
        quote = char
      elseif char == opening then
        depth = depth + 1
      elseif char == ending then
        depth = depth - 1
        if depth == 0 then
          return pos
        end
      end
    end
  end
end

-- Extract a literal destination only when the remaining suffix is empty or a supported quoted
-- title.
---@param content string Text inside image destination parentheses.
---@return string? source
local function destination(content)
  content = vim.trim(content)
  if content:sub(1, 1) == "<" then
    for i = 2, #content do
      if content:sub(i, i) == ">" and not escaped(content, i) then
        local suffix = vim.trim(content:sub(i + 1))
        if suffix == "" or suffix:match('^".*"$') or suffix:match("^'.*'$") then
          return content:sub(2, i - 1)
        end
        return nil
      end
    end
    return nil
  end
  local depth, stop = 0, #content + 1
  for i = 1, #content do
    local char = content:sub(i, i)
    if not escaped(content, i) then
      if char == "(" then
        depth = depth + 1
      elseif char == ")" then
        depth = depth - 1
      elseif char:match("%s") and depth == 0 then
        stop = i
        break
      end
    end
  end
  local suffix = vim.trim(content:sub(stop))
  if suffix ~= "" and not suffix:match('^".*"$') and not suffix:match("^'.*'$") then
    return nil
  end
  return content:sub(1, stop - 1)
end

-- Deliberately bounded to complete, same-line Markdown inline images.
-- Ignore escaped syntax and code spans; unsupported forms are not guessed.
-- Collect complete same-line image candidates, skipping escaped syntax and inline code.
---@param line string One source line.
---@return ImageToolsReference[] references Byte-column ranges, without row coordinates.
function M.parse(line, references)
  local result, pos = {}, 1
  while pos <= #line do
    local char = line:sub(pos, pos)
    if char == "`" and not escaped(line, pos) then
      local ticks = line:match("^`+", pos)
      local finish = line:find(ticks, pos + #ticks, true)
      pos = finish and finish + #ticks or #line + 1
    elseif references and line:sub(pos, pos + 2) == "![[" and not escaped(line, pos) then
      local finish = line:find("]]", pos + 3, true)
      if finish then
        local src = line:sub(pos + 3, finish - 1):match("^[^|]+")
        if src and require("image_tools.media.formats").supported(src) then
          result[#result + 1] = { src = src, literal = true, start_col = pos - 1, end_col = finish + 1 }
        end
      end
      pos = finish and finish + 2 or #line + 1
    elseif line:sub(pos, pos + 1) == "![" and not escaped(line, pos) then
      local alt_end = closing(line, pos + 1, "[", "]")
      local finish = alt_end and line:sub(alt_end + 1, alt_end + 1) == "(" and closing(line, alt_end + 1, "(", ")")
        or nil
      if finish then
        local src = destination(line:sub(alt_end + 2, finish - 1))
        if src and src ~= "" then
          result[#result + 1] = { src = src, start_col = pos - 1, end_col = finish }
        end
        pos = finish + 1
      elseif references and alt_end and line:sub(alt_end + 1, alt_end + 1) ~= "(" then
        local label_end = line:sub(alt_end + 1, alt_end + 1) == "[" and closing(line, alt_end + 1, "[", "]") or nil
        local label = label_end and line:sub(alt_end + 2, label_end - 1) or ""
        if label == "" then
          label = line:sub(pos + 2, alt_end - 1)
        end
        result[#result + 1] = { label = label, start_col = pos - 1, end_col = label_end or alt_end }
        pos = (label_end or alt_end) + 1
      else
        pos = pos + 2
      end
    else
      pos = pos + 1
    end
  end
  return result
end

-- Reuse the same exclusion rules for preview candidates and reference definitions.
local scan_context = function(lines, state)
  local fence, length = state.fence, state.length
  local blocked
  for i, line in ipairs(lines) do
    local run = line:match("^ ? ? ?(```+)") or line:match("^ ? ? ?(~~~+)")
    if run then
      if not fence then
        fence, length = run:sub(1, 1), #run
      elseif run:sub(1, 1) == fence and #run >= length and line:match("^%s*[`~]+%s*$") then
        fence = nil
      end
      if i == #lines then
        blocked = "Cursor is inside a fenced code block"
      end
    elseif i == #lines and (fence or line:match("^    ") or line:match("^\t")) then
      blocked = "Cursor is inside a code block"
    end
  end
  return { blocked = blocked }, { fence = fence, length = length }
end

local indexes, attached = {}, {}
local function label_key(label)
  return vim.fn.tolower((vim.trim(label:gsub("\\([%p ])", "%1")):gsub("%s+", " ")))
end

-- Index bounded, same-line definitions, including forward references. First definition wins.
local function definitions(buf, limit)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local cached = indexes[buf]
  if cached and cached.tick == tick and cached.limit == limit then
    return cached.labels
  end
  if not attached[buf] then
    attached[buf] = vim.api.nvim_buf_attach(buf, false, {
      on_detach = function()
        indexes[buf], attached[buf] = nil, nil
      end,
    })
  end
  local labels, state = {}, {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, math.min(limit, vim.api.nvim_buf_line_count(buf)), false)) do
    local context
    context, state = scan_context({ line }, state)
    if not context.blocked then
      local label, content = line:match("^ ? ? ?%[([^%]]+)%]:%s*(.+)$")
      local src = content and destination(content)
      if src and not labels[label_key(label)] then
        labels[label_key(label)] = src
      end
    end
  end
  indexes[buf] = { tick = tick, limit = limit, labels = labels }
  return labels
end

-- Reject fenced/indented code before selecting a candidate and resolving its decoded local
-- destination.
---@param buf integer Buffer id.
---@param row integer One-based buffer row.
---@param col? integer Zero-based byte column; nil requests the first covering reference.
---@param opts ImageToolsOptions Lookup/scan/root settings.
---@return string? path Resolved image source.
---@return string? error Lookup/resolution message on failure.
---@return ImageToolsLookupStatus? status Only miss permits cursor-to-line fallback; pending must wait.
---@return ImageToolsReference? reference Selected range when resolved, or pending LaTeX coverage.
function M.find(buf, row, col, opts)
  local candidates = M.parse(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or "", true)
  if #candidates == 0 then
    return nil, "No supported image reference on the current line"
  end
  local syntax = require("image_tools.document.syntax_cache").query(buf, row, "markdown", {}, scan_context)
  if syntax.blocked then
    return nil, syntax.blocked
  end
  for _, image in ipairs(candidates) do
    if col == nil or (col >= image.start_col and col < image.end_col) then
      local src = image.src or definitions(buf, opts.max_scan_lines)[label_key(image.label)]
      if not src then
        return nil, "Undefined image reference: " .. image.label
      end
      image.src = src
      local path, err = require("image_tools.document.paths").resolve(
        src,
        opts._document_path or vim.api.nvim_buf_get_name(buf),
        image.literal and vim.tbl_extend("force", opts, { literal = true }) or opts
      )
      return path, err, nil, vim.tbl_extend("force", image, { start_row = row, end_row = row })
    end
  end
  return nil, "No supported image reference under the cursor", "miss"
end

-- Enumerate resolved references using the same lexer/exclusions as cursor lookup.
function M.references(buf, row, opts)
  local candidates = M.parse(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or "", true)
  if
    #candidates == 0
    or require("image_tools.document.syntax_cache").query(buf, row, "markdown", {}, scan_context).blocked
  then
    return {}
  end
  local results = {}
  for _, candidate in ipairs(candidates) do
    local path, err, _, ref = M.find(buf, row, candidate.start_col, opts)
    results[#results + 1] = {
      path = path,
      error = err,
      reference = ref or vim.tbl_extend("force", candidate, { start_row = row, end_row = row }),
    }
  end
  return results
end

-- Return a fresh list of all preview formats allowed for Markdown insertion/picker filtering.
---@return string[] extensions
function M.image_formats()
  return require("image_tools.media.formats").extensions()
end
M.supports_image = require("image_tools.media.formats").supported
M.insertion_base = require("image_tools.document.paths").base
-- Emit an angle-bracket image destination with byte-wise escaping and sanitized alt text.
---@param path string Relative resource path.
---@param alt? string Optional image description.
---@return string markup
function M.markup(path, alt)
  local encoded = path:gsub("[%%<>%s\\%z]", function(c)
    return string.format("%%%02X", c:byte())
  end)
  alt = (alt or ""):gsub("[\r\n]", " "):gsub("([\\%[%]])", "\\%1")
  return "![" .. alt .. "](<" .. encoded .. ">)"
end

return M

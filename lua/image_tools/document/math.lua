-- Module: image_tools.document.math
--
-- Purpose:
--   Recognize bounded TeX formulas in LaTeX and Markdown buffers.
--
-- Architecture:
--   Cache prefix context independently of image scanners. Look ahead only to
--   finish a formula covering the queried row; preserve original byte ranges.
--
-- Ownership:
--   Own no processes or paths. References carry standalone TeX source and a
--   content identity; asset enumeration continues to use image adapters only.

local M = {}
local defaults = require("image_tools.defaults")
local tex = require("image_tools.document.tex.reference")
local environments = {}
for _, name in ipairs({
  "math",
  "displaymath",
  "equation",
  "align",
  "alignat",
  "gather",
  "multline",
  "flalign",
  "eqnarray",
}) do
  environments[name], environments[name .. "*"] = true, true
end
local excluded = { verbatim = true, ["verbatim*"] = true, lstlisting = true, minted = true, comment = true }

-- Match a command at the current byte without consuming surrounding source.
local function environment(line, pos, command)
  return line:sub(pos):match("^\\" .. command .. "%s*{([%a*]+)}()")
end

-- An unmatched backtick run is literal Markdown text. Confirm a closing run
-- before entering code, including multiline spans within the scan ceiling.
-- Blank lines and fences end the paragraph in which a code span can occur.
local function code_end(buf, row, pos, ticks, ceiling)
  while row <= ceiling do
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
    if not line then
      return nil, nil, row
    end
    if pos == 1 and (line:match("^%s*$") or line:match("^ ? ? ?```") or line:match("^ ? ? ?~~~")) then
      return nil, nil, row
    end
    while pos <= #line do
      local first, last = line:find("`+", pos)
      if not first then
        break
      end
      if last - first + 1 == ticks then
        return row, last, row
      end
      pos = last + 1
    end
    row, pos = row + 1, 1
  end
  return nil, nil, ceiling
end

local function scanner(markdown, limits, buf, ceiling)
  return function(lines, state)
    local refs = {}
    for _, original in ipairs(lines) do
      refs = {}
      state.row = (state.row or 0) + 1
      local row, line = state.row, markdown and original or tex.clean(original)
      local active = state.active
      if active and row - active.start_row >= limits.max_lines then
        state.active, active = nil, nil
      end
      local fence = markdown and (line:match("^ ? ? ?(```+)") or line:match("^ ? ? ?(~~~+)"))
      local blocked = false
      local code_context = state.html_code or state.html or state.code_row
      if fence and not active and not code_context then
        if not state.fence then
          state.fence, state.fence_length = fence:sub(1, 1), #fence
        elseif fence:sub(1, 1) == state.fence and #fence >= state.fence_length and line:match("^%s*[`~]+%s*$") then
          state.fence = nil
        end
        blocked = true
      elseif
        state.fence
        or markdown and not active and not code_context and (line:match("^    ") or line:match("^ ? ? ?\t"))
      then
        blocked = true
      end
      local pos, segment = 1, 1
      while not blocked and pos <= #line do
        local char = line:sub(pos, pos)
        if state.excluded then
          local ending = "\\end{" .. state.excluded .. "}"
          local first, last = line:find(ending, pos, true)
          if not first then
            break
          end
          state.excluded, pos = nil, last + 1
        elseif state.html then
          local _, last = line:find("-->", pos, true)
          if not last then
            break
          end
          state.html, pos = nil, last + 1
        elseif state.code_row then
          if row == state.code_row then
            pos, state.code_row = state.code_col + 1, nil
          else
            break
          end
        elseif state.html_code then
          local _, last = line:lower():find("</" .. state.html_code .. "%s*>", pos)
          if not last then
            break
          end
          state.html_code, pos = nil, last + 1
        elseif not active and markdown and line:sub(pos, pos + 3) == "<!--" then
          state.html, pos = true, pos + 4
        elseif not active and markdown and char == "<" then
          local tag = line:sub(pos):lower():match("^<([%a]+)[%s>]")
          if tag == "code" or tag == "pre" then
            state.html_code = tag
          end
          pos = pos + 1
        elseif not active and markdown and char == "`" and not tex.escaped(line, pos) then
          local run = line:match("^`+", pos)
          local through
          state.code_row, state.code_col, through = code_end(buf, row, pos + #run, #run, ceiling)
          state.code_through = math.max(state.code_through or 0, through)
          pos = pos + #run
        elseif not active and not markdown and char == "\\" and not tex.escaped(line, pos) then
          local name, after = environment(line, pos, "begin")
          if excluded[name] then
            state.excluded, pos = name, pos + after - 1
          else
            -- Leave math commands for the common delimiter decoder below.
            local ending, length
            if environments[name] then
              ending, length = "\\end{" .. name .. "}", after - 1
            elseif line:sub(pos, pos + 1) == "\\(" then
              ending, length = "\\)", 2
            elseif line:sub(pos, pos + 1) == "\\[" then
              ending, length = "\\]", 2
            end
            if ending then
              active = { start_row = row, start_col = pos - 1, ending = ending, source = "" }
              state.active, segment = active, pos
              pos = pos + length
            else
              pos = pos + 1
            end
          end
        elseif active then
          if markdown and char == "%" and not tex.escaped(line, pos) then
            -- Preserve the original comment in the source, but ignore its
            -- delimiters. TeX consumes it through the newline when compiling.
            break
          end
          local ending = active.ending
          local closes = line:sub(pos, pos + #ending - 1) == ending and not tex.escaped(line, pos)
          if ending == "$" and line:sub(pos, pos + 1) == "$$" then
            closes = false
          end
          if
            markdown
            and ending == "$"
            and (not line:sub(pos - 1, pos - 1):match("%S") or line:sub(pos + 1, pos + 1):match("%d"))
          then
            closes = false
          end
          if closes then
            active.source = active.source .. original:sub(segment, pos + #ending - 1)
            if #active.source <= limits.max_bytes then
              refs[#refs + 1] = {
                kind = "math",
                src = active.source,
                formula = active.source,
                start_row = active.start_row,
                start_col = active.start_col,
                end_row = row,
                end_col = pos + #ending - 1,
              }
            end
            pos, active, state.active, segment = pos + #ending, nil, nil, 1
          else
            pos = pos + 1
          end
        else
          local ending, length
          if not tex.escaped(line, pos) then
            if char == "$" then
              local display = line:sub(pos, pos + 1) == "$$"
              -- Markdown single dollars follow common whitespace/currency rules.
              if display or not markdown or line:sub(pos + 1, pos + 1):match("%S") then
                ending, length = display and "$$" or "$", display and 2 or 1
              end
            elseif markdown and char == "\\" then
              local pair = line:sub(pos, pos + 1)
              local name, after = environment(line, pos, "begin")
              if pair == "\\(" or pair == "\\[" then
                ending, length = pair == "\\(" and "\\)" or "\\]", 2
              elseif environments[name] then
                ending, length = "\\end{" .. name .. "}", after - 1
              end
            end
          end
          if ending then
            active = { start_row = row, start_col = pos - 1, ending = ending, source = "" }
            state.active, segment = active, pos
            pos = pos + length
          else
            pos = pos + 1
          end
        end
      end
      if active then
        active.source = active.source .. original:sub(segment) .. "\n"
        if #active.source > limits.max_bytes then
          state.active = nil
        end
      end
    end
    return { references = refs, state = state }, state
  end
end

-- Select by row/byte column. No compilation or filesystem access occurs here.
---@return ImageToolsReference? reference
function M.find(buf, row, col, opts)
  local kind = require("image_tools.document.formats").kind(vim.bo[buf].filetype)
  local limits = opts.math or defaults.math
  -- LaTeX document formulas are owned by tex-tools. Markdown keeps its existing
  -- scanner/compiler and does not acquire a dependency on that plugin.
  if limits.enabled == false or kind ~= "markdown" then
    return
  end
  -- Ordinary text needs only a bounded local read, not a cold prefix scan.
  local nearby = table.concat(vim.api.nvim_buf_get_lines(buf, math.max(0, row - limits.max_lines), row, false), "\n")
  if
    not nearby:find("$", 1, true)
    and not nearby:find("\\(", 1, true)
    and not nearby:find("\\[", 1, true)
    and not nearby:find("\\begin", 1, true)
  then
    return
  end
  local scan = scanner(kind == "markdown", limits, buf, opts.max_scan_lines)
  local key = table.concat({ kind, limits.max_lines, limits.max_bytes, opts.max_scan_lines }, ":")
  -- Editing a future closer can change an earlier literal backtick. Report
  -- that dependency while preserving snapshots before unaffected edits.
  local result = require("image_tools.document.syntax_cache").query(buf, row, key, {}, scan, "math", function(state)
    return state.code_through
  end)
  local refs = vim.deepcopy(result.references)
  local state = vim.deepcopy(result.state)
  if state.active then
    local last =
      math.min(opts.max_scan_lines, vim.api.nvim_buf_line_count(buf), state.active.start_row + limits.max_lines - 1)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, row, last, false)) do
      local forward = scan({ line }, state)
      vim.list_extend(refs, forward.references)
      if not state.active then
        break
      end
    end
  end
  for _, ref in ipairs(refs) do
    if
      row >= ref.start_row
      and row <= ref.end_row
      and (col == nil or (row > ref.start_row or col >= ref.start_col) and (row < ref.end_row or col < ref.end_col))
    then
      ref.path = "image-tools-math:" .. vim.fn.sha256(ref.formula)
      return ref
    end
  end
end

return M

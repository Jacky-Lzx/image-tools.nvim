local M = {}

local function escaped(text, pos)
  local count = 0
  while pos > 1 and text:sub(pos - 1, pos - 1) == "\\" do
    count, pos = count + 1, pos - 1
  end
  return count % 2 == 1
end

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
function M.parse(line)
  local result, pos = {}, 1
  while pos <= #line do
    local char = line:sub(pos, pos)
    if char == "`" and not escaped(line, pos) then
      local ticks = line:match("^`+", pos)
      local finish = line:find(ticks, pos + #ticks, true)
      pos = finish and finish + #ticks or #line + 1
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
      else
        pos = pos + 2
      end
    else
      pos = pos + 1
    end
  end
  return result
end

function M.find(buf, row, col, opts)
  local candidates = M.parse(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or "")
  if #candidates == 0 then
    return nil, "No supported image reference on the current line"
  end
  local syntax = require("image_tools.document.syntax_cache").query(buf, row, "markdown", {}, function(lines, state)
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
  end)
  if syntax.blocked then
    return nil, syntax.blocked
  end
  for _, image in ipairs(candidates) do
    if col == nil or (col >= image.start_col and col < image.end_col) then
      local path, err = require("image_tools.document.paths").resolve(image.src, vim.api.nvim_buf_get_name(buf), opts)
      return path, err
    end
  end
  return nil, "No supported image reference under the cursor"
end

function M.image_formats()
  return require("image_tools.media.formats").extensions()
end
M.supports_image = require("image_tools.media.formats").supported
M.insertion_base = require("image_tools.document.paths").base
function M.markup(path, alt)
  local encoded = path:gsub("[%%<>%s\\%z]", function(c)
    return string.format("%%%02X", c:byte())
  end)
  alt = (alt or ""):gsub("[\r\n]", " "):gsub("([\\%[%]])", "\\%1")
  return "![" .. alt .. "](<" .. encoded .. ">)"
end

return M

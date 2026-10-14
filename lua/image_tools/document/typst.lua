local M = {}
local function escaped(text, pos)
  local n = 0
  while pos > 1 and text:sub(pos - 1, pos - 1) == "\\" do
    n, pos = n + 1, pos - 1
  end
  return n % 2 == 1
end
local function quoted(line, start)
  if line:sub(start, start) ~= '"' then
    return
  end
  local result, pos = {}, start + 1
  while pos <= #line do
    local char = line:sub(pos, pos)
    if char == '"' then
      return table.concat(result), pos
    end
    if char == "\\" then
      local next_char = line:sub(pos + 1, pos + 1)
      local simple = { ['"'] = '"', ["\\"] = "\\", n = "\n", r = "\r", t = "\t" }
      if simple[next_char] then
        result[#result + 1] = simple[next_char]
        pos = pos + 2
      elseif next_char == "u" then
        local hex = line:match("^u{(%x+)}", pos + 1)
        local codepoint = hex and tonumber(hex, 16)
        if not codepoint or codepoint > 0x10FFFF or codepoint >= 0xD800 and codepoint <= 0xDFFF then
          return
        end
        result[#result + 1] = vim.fn.nr2char(codepoint)
        pos = pos + #hex + 4
      else
        return
      end
    else
      result[#result + 1] = char
      pos = pos + 1
    end
  end
end
M.quoted = quoted
local function string_end(line, start)
  for pos = start + 1, #line do
    if line:sub(pos, pos) == '"' and not escaped(line, pos) then
      return pos
    end
  end
end

local function finish_call(line, start)
  local depth, pos = 1, start + 1
  while pos <= #line do
    local char = line:sub(pos, pos)
    if char == '"' then
      local _, finish = quoted(line, pos)
      if not finish then
        return
      end
      pos = finish + 1
    elseif line:sub(pos, pos + 1) == "//" or line:sub(pos, pos + 1) == "/*" then
      return
    elseif char == "(" then
      depth, pos = depth + 1, pos + 1
    elseif char == ")" then
      depth = depth - 1
      if depth == 0 then
        return pos
      end
      pos = pos + 1
    else
      pos = pos + 1
    end
  end
end

-- Bounded lexer: literal same-line image calls, including calls in a multiline
-- #figure/code expression. Skip strings, raw text and nested block comments.
function M.scan(lines, previous)
  previous = previous or {}
  local result, stack, mode, raw, block, transient, statement =
    {},
    previous.stack or {},
    previous.mode or "markup",
    previous.raw,
    previous.block or 0,
    previous.transient or false,
    previous.statement or false
  local in_string = previous.in_string or false
  for row, line in ipairs(lines) do
    local pos = 1
    while pos <= #line do
      local char, pair = line:sub(pos, pos), line:sub(pos, pos + 1)
      if raw then
        local ticks = line:match("^`+", pos)
        if ticks and #ticks == raw then
          raw = nil
        end
        pos = pos + (ticks and #ticks or 1)
      elseif in_string then
        local finish = string_end(line, pos - 1)
        in_string, pos = not finish, finish and finish + 1 or #line + 1
      elseif block > 0 then
        if pair == "/*" then
          block, pos = block + 1, pos + 2
        elseif pair == "*/" then
          block, pos = block - 1, pos + 2
        else
          pos = pos + 1
        end
      elseif escaped(line, pos) and mode == "markup" then
        pos = pos + 1
      elseif pair == "//" then
        break
      elseif pair == "/*" then
        block, pos = 1, pos + 2
      elseif char == "`" then
        local ticks = line:match("^`+", pos)
        raw, pos = #ticks, pos + #ticks
      elseif char == '"' and mode == "code" then
        local finish = string_end(line, pos)
        in_string, pos = not finish, finish and finish + 1 or #line + 1
      elseif char == "#" then
        if mode == "markup" then
          mode, transient = "code", true
        end
        local identifier = line:match("^([%a_]+)", pos + 1)
        if
          vim.tbl_contains({ "let", "set", "show", "if", "for", "while", "context", "import", "include" }, identifier)
        then
          statement, transient = true, false
        end
        pos = pos + 1
      elseif
        mode == "code"
        and line:sub(pos, pos + 4) == "image"
        and not line:sub(pos - 1, pos - 1):match("[%w_.-]")
        and not line:sub(pos + 5, pos + 5):match("[%w_]")
      then
        local open = pos + 5
        while line:sub(open, open):match("%s") do
          open = open + 1
        end
        local first = open + 1
        while line:sub(first, first):match("%s") do
          first = first + 1
        end
        local src, last = quoted(line, first)
        local finish = line:sub(open, open) == "(" and finish_call(line, open)
        local following = last and line:sub(last + 1):match("^%s*(.)")
        if src and last and finish and (following == "," or following == ")") and row == #lines then
          result[#result + 1] =
            { src = src, start_col = pos - (line:sub(pos - 1, pos - 1) == "#" and 2 or 1), end_col = finish }
        end
        pos = pos + 5
      elseif char == "[" then
        stack[#stack + 1] = { ending = "]", mode = mode }
        mode, transient, pos = "markup", false, pos + 1
      elseif mode == "code" and (char == "(" or char == "{") then
        stack[#stack + 1] =
          { ending = char == "(" and ")" or "}", mode = transient and not statement and "markup" or "code" }
        transient, pos = false, pos + 1
      elseif #stack > 0 and char == stack[#stack].ending then
        mode = table.remove(stack).mode
        transient, pos = false, pos + 1
      elseif char == ";" and #stack == 0 then
        mode, statement, transient, pos = "markup", false, false, pos + 1
      elseif char:match("%s") and transient then
        local next_pos = pos
        while line:sub(next_pos, next_pos):match("%s") do
          next_pos = next_pos + 1
        end
        if line:sub(next_pos, next_pos) ~= "(" then
          mode, transient = "markup", false
        end
        pos = next_pos
      else
        pos = pos + 1
      end
    end
    if #stack == 0 then
      mode, transient, statement = "markup", false, false
    end
  end
  return result,
    {
      stack = stack,
      mode = mode,
      raw = raw,
      block = block,
      transient = transient,
      statement = statement,
      in_string = in_string,
    }
end
function M.find(buf, row, col, opts)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  if not line:find("image%s*%(") then
    return nil, "No supported image reference on the current line"
  end
  local syntax = opts.treesitter ~= false
      and require("image_tools.document.treesitter").query(buf, row, "typst", opts._treesitter_ready)
    or nil
  if syntax and syntax.pending then
    return nil, "Tree-sitter parsing is pending", "pending"
  end
  local candidates = syntax and syntax.candidates
    or require("image_tools.document.syntax_cache").query(buf, row, "typst", {}, M.scan)
  local document = vim.api.nvim_buf_get_name(buf)
  for _, image in ipairs(candidates) do
    if col == nil or col >= image.start_col and col < image.end_col then
      if image.src:find("%c") then
        return nil, "Invalid Typst image path"
      end
      local root = image.src:sub(1, 1) == "/" and require("image_tools.document.paths").base(document, opts, buf)
        or vim.fs.dirname(document)
      if document == "" then
        return nil, "Save the document before previewing an image reference"
      end
      local src = image.src:sub(1, 1) == "/" and image.src:gsub("^/+", "") or image.src
      return require("image_tools.document.paths").resolve(
        src,
        document,
        vim.tbl_extend("force", opts, { root = root, literal = true })
      )
    end
  end
  return nil, "No supported image reference on the current line"
end

local image_formats = { "png", "jpg", "jpeg", "gif", "webp", "svg", "pdf" }
function M.image_formats()
  return vim.deepcopy(image_formats)
end
function M.supports_image(path)
  return require("image_tools.media.formats").supports(path, image_formats)
end
function M.insertion_base(document)
  return vim.fs.dirname(document)
end
function M.validate_reference(path, document, opts, buf)
  local paths = require("image_tools.document.paths")
  local project = paths.base(document, opts, buf)
  assert(
    not paths.relative(path, project):match("^%.%./"),
    "Typst image is outside the project root; copy it or configure root to match typst compile --root"
  )
end
function M.markup(path, alt)
  assert(not path:find("%c"), "Typst image paths cannot contain control characters")
  local function quoted(text)
    return '"' .. text:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
  end
  local description = alt and alt ~= "" and ", alt: " .. quoted(alt:gsub("[\r\n]", " ")) or ""
  return "#image(" .. quoted(path) .. ", width: 100%" .. description .. ")"
end

return M

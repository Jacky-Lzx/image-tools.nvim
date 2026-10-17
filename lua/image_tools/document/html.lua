-- Literal same-line <img src=...> lookup, with cached comment/raw-element context.
-- This is not a DOM evaluator: dynamic sources, srcset and multiline tags are
-- outside this adapter's scope.
local M = {}
local paths = require("image_tools.document.paths")
local formats = { "png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "svg" }
local raw = { script = true, style = true, pre = true, code = true }
local MAX_TAG_BYTES = 16 * 1024

local function entities(text)
  local named = { amp = "&", quot = '"', apos = "'", lt = "<", gt = ">" }
  return (
    text:gsub("&(#?[%w]+);", function(entity)
      if named[entity] then
        return named[entity]
      end
      local value = entity:match("^#[xX](%x+)$")
      value = value and tonumber(value, 16) or tonumber(entity:match("^#(%d+)$"))
      if value and value > 0 and value <= 0x10FFFF and not (value >= 0xD800 and value <= 0xDFFF) then
        return vim.fn.nr2char(value)
      end
      return "&" .. entity .. ";"
    end)
  )
end

local function tag_end(line, start)
  local quote
  for i = start, math.min(#line, start + MAX_TAG_BYTES) do
    local char = line:sub(i, i)
    if quote then
      if char == quote then
        quote = nil
      end
    elseif char == '"' or char == "'" then
      quote = char
    elseif char == ">" then
      return i
    end
  end
end

local function source(tag)
  local pos = tag:find("%s") or #tag
  local src
  while pos < #tag do
    local first, last, name = tag:find("^%s*([%w_:%-]+)", pos)
    if not first then
      break
    end
    pos = last + 1
    local equals_end = tag:match("^%s*=%s*()", pos)
    if equals_end then
      pos = equals_end
      local quote, value = tag:sub(pos, pos)
      if quote == '"' or quote == "'" then
        local close = tag:find(quote, pos + 1, true)
        if not close then
          return
        end
        value, pos = tag:sub(pos + 1, close - 1), close + 1
      else
        local finish = tag:find("[%s>]", pos) or #tag + 1
        value, pos = tag:sub(pos, finish - 1), finish
      end
      if name:lower() == "src" and src == nil then
        src = entities(value)
      end
    end
  end
  if src and (src:find("{{", 1, true) or src:find("<%", 1, true) or src:find("${", 1, true)) then
    return nil
  end
  return src
end

function M.scan(lines, state)
  local references = {}
  for _, line in ipairs(lines) do
    references = {}
    local pos, lower = 1, line:lower()
    while pos <= #line do
      if state.comment then
        local close = line:find("-->", pos, true)
        if not close then
          break
        end
        state.comment, pos = false, close + 3
      elseif state.raw then
        local _, finish = lower:find("</%s*" .. state.raw .. "%s*>", pos)
        if not finish then
          break
        end
        state.raw, pos = nil, finish + 1
      else
        local first = line:find("<", pos, true)
        if not first then
          break
        end
        if line:sub(first, first + 3) == "<!--" then
          state.comment, pos = true, first + 4
        else
          local closing, name = lower:match("^<%s*(/?)%s*([%w%-]+)", first)
          local finish = tag_end(line, first + 1)
          if not closing or closing == "" then
            if raw[name] then
              state.raw = name
            elseif name == "img" and finish then
              local src = source(line:sub(first, finish))
              if src then
                references[#references + 1] = { src = src, start_col = first - 1, end_col = finish }
              end
            end
          end
          pos = finish and finish + 1 or #line + 1
        end
      end
    end
  end
  return references, state
end

local function candidates(buf, row)
  return require("image_tools.document.syntax_cache").query(buf, row, "html", {}, M.scan)
end

function M.find(buf, row, col, opts)
  for _, ref in ipairs(candidates(buf, row)) do
    if col == nil or col >= ref.start_col and col < ref.end_col then
      local path, err = paths.resolve(ref.src, opts._document_path or vim.api.nvim_buf_get_name(buf), opts)
      return path, err, nil, vim.tbl_extend("force", ref, { start_row = row, end_row = row })
    end
  end
  return nil, "No literal HTML image reference at this position", "miss"
end

function M.references(buf, row, opts)
  local result = {}
  for _, ref in ipairs(candidates(buf, row)) do
    local path, err, _, reference = M.find(buf, row, ref.start_col, opts)
    result[#result + 1] = { path = path, error = err, reference = reference }
  end
  return result
end

function M.image_formats()
  return vim.deepcopy(formats)
end
function M.supports_image(path)
  return require("image_tools.media.formats").supports(path, formats)
end
M.insertion_base = paths.base

function M.markup(path, alt)
  assert(not path:find("%c"), "HTML image paths cannot contain control characters")
  local encoded = path:gsub("[^%w%-%._~/]", function(char)
    return string.format("%%%02X", char:byte())
  end)
  local escaped = (alt or ""):gsub("[\r\n]", " "):gsub("[&<>\"']", function(char)
    return ({ ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" })[char]
  end)
  local prefix = '<img src="' .. encoded .. '" alt="'
  return prefix .. escaped .. '" />', #prefix
end

return M

-- Expand user templates without treating replacement values as Lua patterns or
-- template source. Each operation gets its own immutable rendering context.
local M = {}

local marker = "\0image-tools-cursor\0"

function M.validate(template)
  if template == nil or template == false then
    return
  end
  if type(template) == "table" then
    for ft, value in pairs(template) do
      assert(type(ft) == "string" and ft ~= "", "template keys must be filetypes or default")
      assert(type(value) == "string" or type(value) == "function", "template entries must be strings or functions")
    end
  else
    assert(
      type(template) == "string" or type(template) == "function",
      "template must be a string, function or filetype table"
    )
  end
end

-- Trim the padding commonly introduced by Lua long strings while retaining the
-- relative indentation of a multiline figure/template.
local function normalize(text)
  local lines = vim.split(text:gsub("\r\n", "\n"), "\n", { plain = true })
  while #lines > 0 and lines[1]:match("^%s*$") do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  local indent = (lines[1] or ""):match("^%s*")
  for i, line in ipairs(lines) do
    if line:sub(1, #indent) == indent then
      lines[i] = line:sub(#indent + 1)
    end
  end
  return table.concat(lines, "\n")
end

function M.render(template, context, fallback, fallback_offset)
  M.validate(template)
  if type(template) == "table" then
    local kind = require("image_tools.document.formats").kind(context.filetype)
    template = template[context.filetype] or template[kind] or template.default
  end
  if not template then
    return fallback, fallback_offset
  end
  context = vim.tbl_extend("force", context, { cursor = marker })
  local text
  if type(template) == "function" then
    text = template(context)
  else
    local values = {
      FILE_PATH = context.file_path,
      FILE_NAME = context.file_name,
      FILE_NAME_NO_EXT = context.file_name_no_ext,
      LABEL = context.label,
      ALT = context.alt,
      CURSOR = marker,
    }
    text = template:gsub("%$([A-Z_]+)", function(key)
      return values[key] or "$" .. key
    end)
  end
  assert(type(text) == "string", "template must return a string")
  text = normalize(text)
  local first, last = text:find(marker, 1, true)
  if first then
    assert(not text:find(marker, last + 1, true), "template must contain at most one cursor placeholder")
    text = text:sub(1, first - 1) .. text:sub(last + 1)
  end
  assert(text ~= "" and not text:find("%z"), "template must produce nonempty text without NUL bytes")
  return text, first and first - 1 or #text
end

return M

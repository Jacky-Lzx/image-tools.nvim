local M = {}
local paths = require("image_tools.document.paths")
local formats = { markdown = "markdown", tex = "tex", latex = "tex", plaintex = "tex", typst = "typst" }

-- Preserve the existing document helpers while format modules use paths directly.
M.base, M.resolve = paths.base, paths.resolve
function M.parse(line)
  return require("image_tools.document.markdown").parse(line)
end
function M.supported(filetype)
  return formats[filetype] ~= nil
end
local function find(buf, row, col, opts)
  local filetype = vim.bo[buf].filetype
  local format = formats[filetype]
  if not format then
    return nil, "Image references support Markdown, LaTeX and Typst"
  end
  if row > opts.max_scan_lines then
    return nil, "Document exceeds max_scan_lines; use :ImagePreview with a file path"
  end
  return require("image_tools.document." .. format).find(buf, row, col, opts)
end
function M.at_cursor(buf, row, col, opts)
  return find(buf, row, col, opts)
end
-- A line with multiple references consistently previews its first image.
function M.at_line(buf, row, opts)
  return find(buf, row, nil, opts)
end
return M

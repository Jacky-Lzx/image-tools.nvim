-- Module: image_tools.document
--
-- Purpose:
--   Dispatch document reference lookup through the canonical format adapters.
--
-- Architecture:
--   Use document/formats for filetype selection and enforce the scan ceiling
--   before lookup. Retain path helpers and the Markdown-line parse
--   compatibility API without making adapters import this dispatcher.
--
-- Ownership:
--   Own no syntax cache. at_cursor selects by byte column; at_line requests the
--   first covering reference, with parsing and resolution delegated to the
--   adapter.

local M = {}

local paths = require("image_tools.document.paths")
local formats = require("image_tools.document.formats")
M.adapter = formats.get

-- Preserve the existing document helpers while format modules use paths directly.
M.base, M.resolve = paths.base, paths.resolve

function M.parse(line)
  return require("image_tools.document.markdown").parse(line)
end

function M.supported(filetype)
  return formats.supported(filetype)
end

local function find(buf, row, col, opts)
  local filetype = vim.bo[buf].filetype
  local format = formats.get(filetype)
  if not format then
    return nil, "Image references support Markdown, LaTeX and Typst"
  end
  if row > opts.max_scan_lines then
    return nil, "Document exceeds max_scan_lines; use :ImagePreview with a file path"
  end
  return format.find(buf, row, col, opts)
end

function M.at_cursor(buf, row, col, opts)
  return find(buf, row, col, opts)
end

-- A line with multiple references consistently previews its first image.
function M.at_line(buf, row, opts)
  return find(buf, row, nil, opts)
end

return M

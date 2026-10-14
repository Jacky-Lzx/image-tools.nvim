-- Module: image_tools.media.formats
--
-- Purpose:
--   Define preview format capabilities and normalize filename extensions.
--
-- Architecture:
--   Used by the media entry point, converters, document insertion rules and
--   file-buffer validation. Treat PNG as the native path and expose the other
--   supported formats for conversion.
--
-- Ownership:
--   Keep a static format registry and allocate result lists on demand; perform
--   no file reads or conversions.

local M = {}
M.formats = {
  jpg = true,
  jpeg = true,
  webp = true,
  avif = true,
  heic = true,
  gif = true,
  bmp = true,
  tiff = true,
  tif = true,
  pdf = true,
  svg = true,
}

-- Read and lowercase the last filename extension without accessing the filesystem.
---@param path string Filename or path.
---@return string? extension No extension yields nil.
function M.extension(path)
  local extension = path:match("%.([^./]+)$")
  return extension and extension:lower()
end

-- Accept native PNG or a format supported by conversion.
---@param path string Filename or path.
---@return boolean supported
function M.supported(path)
  local extension = M.extension(path)
  return extension == "png" or M.formats[extension] == true
end

-- Check a filename against a document adapter-specific extension list.
---@param path string Filename or path.
---@param extensions string[] Allowed lowercase extensions.
---@return boolean supported
function M.supports(path, extensions)
  return vim.tbl_contains(extensions, M.extension(path))
end

-- Return an independently allocated, sorted preview extension list including PNG.
---@return string[] extensions
function M.extensions()
  local result = vim.tbl_keys(M.formats)
  result[#result + 1] = "png"
  table.sort(result)
  return result
end

return M

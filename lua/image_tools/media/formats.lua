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

function M.extension(path)
  local extension = path:match("%.([^./]+)$")
  return extension and extension:lower()
end
function M.supported(path)
  local extension = M.extension(path)
  return extension == "png" or M.formats[extension] == true
end
function M.supports(path, extensions)
  return vim.tbl_contains(extensions, M.extension(path))
end
function M.extensions()
  local result = vim.tbl_keys(M.formats)
  result[#result + 1] = "png"
  table.sort(result)
  return result
end

return M

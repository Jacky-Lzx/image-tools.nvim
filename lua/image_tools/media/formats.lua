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

function M.supported(path)
  local extension = path:match("%.([^./]+)$")
  extension = extension and extension:lower()
  return extension == "png" or M.formats[extension] == true
end

return M

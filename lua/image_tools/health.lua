local M = {}

function M.check()
  vim.health.start("image-tools")
  local supported, reason = require("image_tools.terminal").supports({})
  if supported then
    vim.health.ok("Kitty terminal detected (Unicode placeholders require Kitty 0.28+)")
  else
    vim.health.warn(reason)
  end
  if vim.fn.executable("magick") == 1 then
    vim.health.ok("ImageMagick found: non-PNG previews available")
  else
    vim.health.warn("ImageMagick missing: PNG previews only")
  end
  local cell = require("image_tools.terminal").cell_size({ width = 10, height = 20 })
  vim.health.info(string.format("Cell geometry: %.2f x %.2f pixels", cell.width, cell.height))
end

return M

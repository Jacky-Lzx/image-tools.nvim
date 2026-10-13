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
  if vim.fn.has("mac") == 1 then
    if vim.fn.executable("pngpaste") == 1 then
      vim.health.ok("pngpaste found: macOS clipboard paste available")
    else
      vim.health.warn("Install pngpaste for clipboard images: brew install pngpaste")
    end
  end
  if vim.fn.executable("rsvg-convert") == 1 then
    vim.health.ok("rsvg-convert found: SVG preview renderer")
  else
    vim.health.info("SVG preview falls back to ImageMagick internal MSVG renderer")
  end
  if vim.fn.executable("gs") ~= 1 then
    vim.health.info("Ghostscript delegate is needed for ImageMagick PDF preview")
  end
  local cell = require("image_tools.terminal").cell_size({ width = 10, height = 20 })
  vim.health.info(string.format("Cell geometry: %.2f x %.2f pixels", cell.width, cell.height))
  local state = require("image_tools").status()
  vim.health.info("Transport: " .. state.transport .. " (auto tries local files and falls back to direct data)")
  if state.terminal_cache then
    vim.health.info(
      string.format(
        "Terminal cache: %d image(s), %d estimated decoded bytes; %d hit(s), %d upload attempt(s)",
        state.terminal_cache.images,
        state.terminal_cache.bytes,
        state.terminal_cache.hits,
        state.terminal_cache.uploads
      )
    )
    if state.terminal_cache.last_error then
      vim.health.warn(state.terminal_cache.last_error)
    end
  end
end

return M

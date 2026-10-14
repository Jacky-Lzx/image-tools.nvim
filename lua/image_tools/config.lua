-- Module: image_tools.config
--
-- Purpose:
--   Define defaults and resolve independent, validated option tables.
--
-- Architecture:
--   Used by the public facade and internal services. Consult the media entry point
--   for supported buffer formats; leave handler registration and resource
--   allocation to runtime.
--
-- Ownership:
--   Keep private defaults and deep-copy caller options. Resolving configuration
--   does not change an active Runtime.

---@class ImageToolsOptions
---@field auto_preview boolean Enable automatic reference previews.
---@field treesitter boolean Prefer native parsers; unavailable/failed parsing falls back to Lua.
---@field latex {max_reference_lines: integer, max_reference_bytes: integer} Budgets for one LaTeX reference.
---@field buffer {enabled: boolean, formats: string[]} Automatic file-buffer interception settings.
---@field pdfinfo string PDF metadata executable.
---@field pdf_density integer Rasterization DPI, included in PDF conversion keys.
---@field insert ImageToolsInsertOptions Defaults merged into individual import operations.
---@field position "cursor"|"bottom_right" Floating preview anchor policy.
---@field transport "auto"|"file"|"direct" Upload transport policy.
---@field terminal_timeout integer Milliseconds allowed for each upload/placement acknowledgement.
---@field terminal_cache {max_images: integer, max_bytes: integer} Retention limits; bytes estimate decoded RGBA.
---@field disk_cache {enabled: boolean, max_bytes: integer, max_files: integer} Unused converted-file eviction limits.
---@field max_width integer Floating preview width limit in terminal cells.
---@field max_height integer Floating preview height limit in terminal cells.
---@field border string|string[] Neovim floating window border configuration.
---@field force boolean Bypass terminal-name detection only.
---@field cell_size ImageToolsCellSize Fallback geometry when ioctl cannot provide pixel dimensions.
---@field max_bytes integer Maximum source/prepared PNG file size.
---@field max_dimension integer Maximum validated PNG dimension per axis.
---@field max_pixels integer Maximum validated PNG pixel count.
---@field max_scan_lines integer Highest document row eligible for reference lookup.
---@field convert_timeout integer Converter/PDF metadata process timeout in milliseconds.
---@field convert_concurrency integer Process-wide FIFO conversion budget.
---@field magick string ImageMagick executable.
---@field rsvg string Preferred SVG renderer executable.
---@field cache? string Converted PNG directory; resolve fills the default when absent.
---@field root? string|fun(document: string): string? Reference/project base override.
---@field resolve? fun(document: string, source: string): string? Optional local path resolver.
---@field _treesitter_ready? fun() Internal continuation for an authoritative pending parse.

---@class ImageToolsConfig
local M = {}
local defaults = {
  auto_preview = true,
  treesitter = true,
  latex = { max_reference_lines = 64, max_reference_bytes = 16 * 1024 },
  buffer = {
    enabled = true,
    formats = { "png", "jpg", "jpeg", "webp", "avif", "heic", "gif", "bmp", "tif", "tiff", "pdf" },
  },
  pdfinfo = "pdfinfo",
  pdf_density = 144,
  insert = { directory = "Figures", mode = "copy", insert_strategy = "insert_line_after", prompt_for_file_name = false },
  position = "cursor", -- "cursor" or "bottom_right"
  transport = "auto", -- "auto", "file" or "direct"
  terminal_timeout = 1500,
  terminal_cache = { max_images = 32, max_bytes = 64 * 1024 * 1024 },
  disk_cache = { enabled = true, max_bytes = 512 * 1024 * 1024, max_files = 256 },
  max_width = 60,
  max_height = 30,
  border = "rounded",
  force = false,
  cell_size = { width = 10, height = 20 },
  max_bytes = 32 * 1024 * 1024,
  max_dimension = 16384,
  max_pixels = 64 * 1024 * 1024,
  max_scan_lines = 10000,
  convert_timeout = 10000,
  convert_concurrency = 2,
  magick = "magick",
  rsvg = "rsvg-convert",
}

-- Deep-copy defaults/caller options, fill the cache path and reject invalid limits before Runtime
-- replacement.
---@param opts? table Partial overrides; caller-owned tables are not mutated.
---@return ImageToolsOptions options Independent resolved configuration; invalid values raise an error.
function M.resolve(opts)
  local options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), vim.deepcopy(opts or {}))
  options.cache = options.cache or (vim.fn.stdpath("cache") .. "/image-tools")
  assert(options.position == "cursor" or options.position == "bottom_right", "position must be cursor or bottom_right")
  assert(type(options.treesitter) == "boolean", "treesitter must be boolean")
  assert(vim.tbl_contains({ "auto", "file", "direct" }, options.transport), "transport must be auto, file or direct")
  assert(type(options.disk_cache.enabled) == "boolean", "disk_cache.enabled must be boolean")
  for _, name in ipairs({ "max_files", "max_bytes" }) do
    assert(
      type(options.disk_cache[name]) == "number" and options.disk_cache[name] >= 0 and options.disk_cache[name] % 1 == 0,
      "disk_cache." .. name .. " must be a non-negative integer"
    )
  end
  for _, name in ipairs({ "max_images", "max_bytes" }) do
    assert(
      type(options.terminal_cache[name]) == "number"
        and options.terminal_cache[name] >= 0
        and options.terminal_cache[name] % 1 == 0,
      "terminal_cache." .. name .. " must be a non-negative integer"
    )
  end
  for _, name in ipairs({
    "max_width",
    "max_height",
    "max_bytes",
    "max_dimension",
    "max_pixels",
    "max_scan_lines",
    "convert_timeout",
    "convert_concurrency",
    "terminal_timeout",
    "pdf_density",
  }) do
    assert(
      type(options[name]) == "number" and options[name] >= 1 and options[name] % 1 == 0,
      name .. " must be a positive integer"
    )
  end
  for _, name in ipairs({ "max_reference_lines", "max_reference_bytes" }) do
    assert(
      type(options.latex[name]) == "number" and options.latex[name] >= 1 and options.latex[name] % 1 == 0,
      "latex." .. name .. " must be a positive integer"
    )
  end
  assert(options.cell_size.width > 0 and options.cell_size.height > 0, "cell_size must be positive")
  assert(type(options.buffer.enabled) == "boolean", "buffer.enabled must be boolean")
  for _, extension in ipairs(options.buffer.formats) do
    assert(
      type(extension) == "string"
        and extension:match("^%a+$")
        and require("image_tools.media").supported("file." .. extension),
      "Unsupported buffer format"
    )
  end
  return options
end

return M

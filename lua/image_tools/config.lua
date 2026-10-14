-- Module: image_tools.config
--
-- Purpose:
--   Define defaults and resolve independent, validated option tables.
--
-- Architecture:
--   Used by the public facade and internal services. Consult the image facade
--   for supported buffer formats; leave handler registration and resource
--   allocation to runtime.
--
-- Ownership:
--   Keep private defaults and deep-copy caller options. Resolving configuration
--   does not change an active Runtime.

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
        and require("image_tools.image").supported("file." .. extension),
      "Unsupported buffer format"
    )
  end
  return options
end

return M

-- Module: image_tools.defaults
--
-- Purpose:
--   Define shared option defaults for configuration and partial internal callers.
--
-- Architecture:
--   Keep this data-only module independent of runtime and media services.
--   config.resolve deep-copies it; service fallbacks read the same values.
--
-- Ownership:
--   Treat the returned table as read-only. Copy nested values before exposing
--   them through resolved options or mutable service state.

return {
  auto_preview = true,
  auto_preview_delay = 100, -- milliseconds before preparing a newly selected automatic preview
  preview_loading_delay = 300, -- milliseconds; zero disables the loading hint
  treesitter = true,
  inline = { enabled = false, max_width = 60, max_height = 20, max_images = 16, debounce = 50 },
  remote = { enabled = false, curl = "curl", timeout = 10000, ttl = 3600, max_redirects = 5 },
  latex = { max_reference_lines = 64, max_reference_bytes = 16 * 1024 },
  math = {
    enabled = true,
    latex = "latex",
    dvipng = "dvipng",
    density = 360, -- raster detail; formula display size stays at the 180-DPI baseline
    foreground = "auto", -- Normal foreground, or #RRGGBB
    preamble = "\\usepackage{amsmath,amssymb}",
    max_lines = 64,
    max_bytes = 16 * 1024,
  },
  buffer = {
    enabled = true,
    keymaps = {
      reload = "r",
      info = "i",
      zoom_in = "+",
      zoom_out = "-",
      fit = "0",
      native = "1",
      pan_left = "<Left>",
      pan_right = "<Right>",
      pan_up = "<Up>",
      pan_down = "<Down>",
      next_page = "]p",
      previous_page = "[p",
    },
    formats = { "png", "jpg", "jpeg", "webp", "avif", "heic", "gif", "bmp", "tif", "tiff", "pdf" },
  },
  pdfinfo = "pdfinfo",
  pdf_density = 144,
  insert = {
    directory = "Figures",
    mode = "copy",
    deduplicate = false,
    insert_strategy = "insert_line_after",
    prompt_for_file_name = false,
  },
  assets = {
    max_entries = 10000,
    max_document_bytes = 2 * 1024 * 1024,
    exclude_dirs = { ".git", ".hg", ".svn", "node_modules", ".venv", "vendor", "build", ".cache" },
  },
  position = "cursor", -- "cursor" or "bottom_right"
  right_padding = 0, -- minimum right-side space in terminal columns; includes automatic scrollbar space
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

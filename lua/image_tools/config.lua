-- Module: image_tools.config
--
-- Purpose:
--   Resolve independent, validated option tables from shared defaults.
--
-- Architecture:
--   Used by the public facade and internal services. Copy image_tools.defaults
--   and consult the media entry point for supported buffer formats; leave
--   handler registration and resource allocation to runtime.
--
-- Ownership:
--   Deep-copy shared defaults and caller options. Resolving configuration
--   does not change an active Runtime.

---@class ImageToolsOptions
---@field auto_preview boolean Enable automatic reference previews.
---@field preview_loading_delay integer Milliseconds before a loading hint; zero disables it.
---@field treesitter boolean Prefer native parsers; unavailable/failed parsing falls back to Lua.
---@field latex {max_reference_lines: integer, max_reference_bytes: integer} Budgets for one LaTeX reference.
---@field buffer {enabled: boolean, formats: string[], keymaps: table<string, string|boolean>|boolean} Automatic file-buffer interception settings.
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
---@field convert_concurrency integer Process-wide FIFO conversion/hash budget.
---@field magick string ImageMagick executable.
---@field rsvg string Preferred SVG renderer executable.
---@field cache? string Converted PNG directory; resolve fills the default when absent.
---@field root? string|fun(document: string): string? Reference/project base override.
---@field resolve? fun(document: string, source: string): string? Optional local path resolver.
---@field render_scale? number Internal converted-raster detail multiplier, capped at eight.
---@field _treesitter_ready? fun() Internal continuation for an authoritative pending parse.

---@class ImageToolsConfig
local M = {}
local defaults = require("image_tools.defaults")

-- Deep-copy defaults/caller options, fill the cache path and reject invalid limits before Runtime
-- replacement.
---@param opts? table Partial overrides; caller-owned tables are not mutated.
---@return ImageToolsOptions options Independent resolved configuration; invalid values raise an error.
function M.resolve(opts)
  local options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), vim.deepcopy(opts or {}))
  options.cache = options.cache or (vim.fn.stdpath("cache") .. "/image-tools")
  assert(options.position == "cursor" or options.position == "bottom_right", "position must be cursor or bottom_right")
  assert(type(options.treesitter) == "boolean", "treesitter must be boolean")
  assert(
    type(options.preview_loading_delay) == "number"
      and options.preview_loading_delay >= 0
      and options.preview_loading_delay % 1 == 0,
    "preview_loading_delay must be a non-negative integer"
  )
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
  assert(type(options.insert.deduplicate) == "boolean", "insert.deduplicate must be boolean")
  assert(type(options.buffer.enabled) == "boolean", "buffer.enabled must be boolean")
  assert(
    options.buffer.keymaps == false or type(options.buffer.keymaps) == "table",
    "buffer.keymaps must be a table or false"
  )
  if options.buffer.keymaps then
    local used = {}
    for action, key in pairs(options.buffer.keymaps) do
      assert(defaults.buffer.keymaps[action], "Unknown viewer keymap action: " .. tostring(action))
      assert(key == false or type(key) == "string" and key ~= "", "Viewer keys must be nonempty strings or false")
      if key then
        local normalized = vim.api.nvim_replace_termcodes(key, true, true, true)
        assert(not used[normalized], "Duplicate viewer key: " .. key)
        used[normalized] = action
      end
    end
  end
  for _, tool in ipairs({ "magick", "rsvg", "pdfinfo" }) do
    assert(type(options[tool]) == "string" and options[tool] ~= "", tool .. " must be an executable name or path")
  end
  assert(
    options.insert.pngpaste == nil or type(options.insert.pngpaste) == "string" and options.insert.pngpaste ~= "",
    "insert.pngpaste must be an executable name or path"
  )
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

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
---@field path_preview boolean Preview literal local paths in filetypes without an adapter.
---@field auto_preview_delay integer Delay before preparing a newly selected automatic reference; zero is immediate.
---@field preview_loading_delay integer Milliseconds before a loading hint; zero disables it.
---@field treesitter boolean Prefer native parsers; unavailable/failed parsing falls back to Lua.
---@field inline table Optional Markdown virtual-line images/block math, cell limits, image budget and debounce.
---@field remote table HTTPS opt-in, curl path, timeout, TTL and redirect budget.
---@field latex {max_reference_lines: integer, max_reference_bytes: integer} Budgets for one LaTeX reference.
---@field math table Formula enablement, latex/dvipng executables, DPI, color, preamble and scan budgets.
---@field _formula? string Internal selected formula source, including delimiters.
---@field buffer {enabled: boolean, formats: string[], keymaps: table<string, string|boolean>|boolean} Automatic file-buffer interception settings.
---@field pdfinfo string PDF metadata executable.
---@field pdf_density integer Rasterization DPI, included in PDF conversion keys.
---@field insert ImageToolsInsertOptions Defaults merged into individual import operations.
---@field assets table Project inspection entry/size budgets and excluded directory names.
---@field position "cursor"|"bottom_right" Floating preview anchor policy.
---@field right_padding integer Minimum right-side space in terminal columns, including automatic scrollbar space.
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
---@field convert_concurrency integer Process-wide conversion/hash budget with interactive priority and background fairness.
---@field magick string ImageMagick executable.
---@field rsvg string Preferred SVG renderer executable.
---@field cache? string Converted PNG directory; resolve fills the default when absent.
---@field root? string|fun(document: string): string? Reference/project base override.
---@field resolve? fun(document: string, source: string): string? Optional local path resolver.
---@field render_scale? number Internal converted-raster detail multiplier, capped at eight.
---@field _raster_size? ImageToolsImageSize Internal PDF pixel target, bounded before conversion.
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
  assert(type(options.path_preview) == "boolean", "path_preview must be boolean")
  assert(type(options.inline.enabled) == "boolean", "inline.enabled must be boolean")
  for _, name in ipairs({ "max_width", "max_height", "max_images", "debounce" }) do
    assert(
      type(options.inline[name]) == "number"
        and options.inline[name] % 1 == 0
        and options.inline[name] >= (name == "debounce" and 0 or 1),
      "Invalid inline." .. name
    )
  end
  assert(type(options.remote.enabled) == "boolean", "remote.enabled must be boolean")
  assert(type(options.remote.curl) == "string" and options.remote.curl ~= "", "remote.curl must be an executable")
  for _, name in ipairs({ "timeout", "ttl", "max_redirects" }) do
    assert(
      type(options.remote[name]) == "number"
        and options.remote[name] % 1 == 0
        and options.remote[name] >= (name == "timeout" and 1 or 0),
      "Invalid remote." .. name
    )
  end
  assert(type(options.math.enabled) == "boolean", "math.enabled must be boolean")
  for _, name in ipairs({ "latex", "dvipng" }) do
    assert(
      type(options.math[name]) == "string" and options.math[name] ~= "",
      "math." .. name .. " must be an executable name or path"
    )
  end
  for _, name in ipairs({ "density", "max_lines", "max_bytes" }) do
    assert(
      type(options.math[name]) == "number" and options.math[name] >= 1 and options.math[name] % 1 == 0,
      "math." .. name .. " must be a positive integer"
    )
  end
  assert(type(options.math.preamble) == "string", "math.preamble must be a string")
  assert(
    options.math.foreground == "auto"
      or type(options.math.foreground) == "string" and options.math.foreground:match("^#%x%x%x%x%x%x$"),
    "math.foreground must be auto or #RRGGBB"
  )
  for _, name in ipairs({ "auto_preview_delay", "preview_loading_delay", "right_padding" }) do
    assert(
      type(options[name]) == "number" and options[name] >= 0 and options[name] % 1 == 0,
      name .. " must be a non-negative integer"
    )
  end
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
  if options.insert.template ~= nil then
    require("image_tools.workflow.template").validate(options.insert.template)
  end
  if options.insert.process ~= nil then
    require("image_tools.workflow.process").validate(options.insert.process)
  end
  if options.insert.file_name ~= nil then
    require("image_tools.workflow.naming").validate(options.insert.file_name)
  end
  require("image_tools.workflow.clipboard_backend").validate(options.insert)
  for _, name in ipairs({ "max_entries", "max_document_bytes" }) do
    assert(
      type(options.assets[name]) == "number" and options.assets[name] >= 1 and options.assets[name] % 1 == 0,
      "assets." .. name .. " must be a positive integer"
    )
  end
  assert(type(options.assets.exclude_dirs) == "table", "assets.exclude_dirs must be a list")
  for _, name in ipairs(options.assets.exclude_dirs) do
    assert(
      type(name) == "string" and name ~= "" and not name:find("[/\\]"),
      "assets.exclude_dirs must contain directory names"
    )
  end
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
        and require("image_tools.media.formats").supported("file." .. extension),
      "Unsupported buffer format"
    )
  end
  return options
end

return M

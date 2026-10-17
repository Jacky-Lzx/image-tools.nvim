-- Module: image_tools.health
--
-- Purpose:
--   Provide Neovim checkhealth diagnostics for terminal, tools and plugin
--   resources.
--
-- Architecture:
--   Read terminal capabilities, the public status snapshot and media/disk_cache
--   inspection. Tool detection uses configured executable names; diagnostics do
--   not start a parser or initialize the Runtime.
--
-- Ownership:
--   Own only the current inspection callback and its bounded wait. Disk
--   inspection is read-only and does not create or evict cache files.

local M = {}
local defaults = require("image_tools.defaults")
local BINARY_UNIT_BASE = 1024
local DISK_INSPECTION_TIMEOUT_MS = 3000
local DISK_INSPECTION_POLL_MS = 10

-- Format a byte estimate in binary units for readable health output.
---@param bytes number Nonnegative bytes.
---@return string display
local function size(bytes)
  local units, index = { "B", "KiB", "MiB", "GiB", "TiB" }, 1
  while bytes >= BINARY_UNIT_BASE and index < #units do
    bytes, index = bytes / BINARY_UNIT_BASE, index + 1
  end
  return string.format(index == 1 and "%.0f %s" or "%.2f %s", bytes, units[index])
end

-- Inspect managed disk usage with a bounded wait and report missing/unreadable directories without
-- eviction.
---@param state ImageToolsRuntimeStatus Existing status snapshot or unconfigured defaults.
---@return nil
local function disk_health(state)
  vim.health.start("image-tools: disk cache")

  local opts
  if state.disk_cache then
    opts = { cache = state.disk_cache.path, disk_cache = state.disk_cache }
  else
    opts = require("image_tools.config").resolve()
    vim.health.info("Plugin is not configured; showing default disk-cache settings")
  end

  local report
  local cancel = require("image_tools.media.disk_cache").inspect(opts, function(snapshot)
    report = snapshot
  end)

  if not vim.wait(DISK_INSPECTION_TIMEOUT_MS, function()
    return report ~= nil
  end, DISK_INSPECTION_POLL_MS) then
    cancel()
    vim.health.info("Directory: " .. opts.cache)
    vim.health.warn("Disk-cache inspection timed out; current usage is unavailable")
    return
  end
  vim.health.info("Directory: " .. report.path)
  vim.health.info("Automatic eviction: " .. (report.enabled and "enabled" or "disabled"))
  vim.health.info(string.format("Limits: %d file(s) / %s", report.max_files, size(report.max_bytes)))
  if report.error then
    vim.health.warn("Cannot inspect disk cache: " .. report.error)
    return
  end
  vim.health.info(
    string.format("Current usage: %d file(s) / %s (%d bytes)", report.files, size(report.bytes), report.bytes)
  )
  vim.health.info(
    string.format("Protected files in use: %d file(s) / %s", report.protected, size(report.protected_bytes))
  )
  if not report.exists then
    vim.health.info("Cache directory has not been created yet")
  end
  vim.health.info("Cleanup: " .. (report.cleanup_running and "running or queued" or "idle"))
  if report.enabled and (report.files > report.max_files or report.bytes > report.max_bytes) then
    if report.cleanup_running then
      vim.health.info("Cache currently exceeds limits; cleanup is in progress")
    elseif report.protected > 0 then
      vim.health.info("Cache currently exceeds limits; files in use are retained until previews close")
    else
      vim.health.warn("Cache exceeds configured limits; automatic cleanup may be pending")
    end
  end
  vim.health.info("Run :ImageCacheClear to remove unused converted images from disk")
end

-- Report terminal/tool support and service/cache diagnostics without initializing the plugin.
---@return nil
function M.check()
  local state = require("image_tools").status()
  local tools = state.tools
    or { magick = defaults.magick, rsvg = defaults.rsvg, pdfinfo = defaults.pdfinfo, pngpaste = "pngpaste" }
  vim.health.start("image-tools")
  local supported, reason = require("image_tools.terminal").supports({})
  if supported then
    vim.health.ok("Kitty terminal detected (Unicode placeholders require Kitty 0.28+)")
  else
    vim.health.warn(reason)
  end

  if vim.fn.executable(tools.magick) == 1 then
    vim.health.ok("ImageMagick found: non-PNG previews available (" .. tools.magick .. ")")
  else
    vim.health.warn(
      "ImageMagick missing: " .. tools.magick .. "; native PNG remains available; SVG may use rsvg-convert"
    )
  end

  local clipboard = state.clipboard
  if not clipboard then
    local backend, err = require("image_tools.workflow.clipboard_backend").detect({})
    clipboard = backend and { backend = backend.name, executable = backend.executable } or { error = err }
  end
  if clipboard.backend then
    vim.health.ok("Clipboard backend: " .. clipboard.backend .. " (" .. clipboard.executable .. ")")
  else
    vim.health.warn(clipboard.error)
  end

  if vim.fn.executable(tools.rsvg) == 1 then
    vim.health.ok("rsvg-convert found: SVG preview renderer (" .. tools.rsvg .. ")")
  else
    vim.health.info("SVG executable missing: " .. tools.rsvg .. "; falls back to ImageMagick internal MSVG renderer")
  end

  if vim.fn.executable("gs") ~= 1 then
    vim.health.info("Ghostscript delegate is needed for ImageMagick PDF preview")
  end

  if vim.fn.executable(tools.pdfinfo) == 1 then
    vim.health.ok("pdfinfo found: PDF buffer page counts available (" .. tools.pdfinfo .. ")")
  else
    vim.health.warn("PDF metadata executable missing: " .. tools.pdfinfo .. " (brew install poppler)")
  end

  for _, name in ipairs({ "latex", "dvipng" }) do
    local tool = tools["math_" .. name] or defaults.math[name]
    if vim.fn.executable(tool) == 1 then
      vim.health.ok("Formula renderer found: " .. tool .. " (math." .. name .. ")")
    else
      vim.health.info(
        "Formula renderer missing: " .. tool .. "; install TeX Live with latex, amsmath, amssymb and dvipng"
      )
    end
  end

  local cell = require("image_tools.terminal").cell_size(vim.deepcopy(state.cell_size or defaults.cell_size))
  vim.health.info(string.format("Cell geometry: %.2f x %.2f pixels", cell.width, cell.height))

  vim.health.info("Transport: " .. state.transport .. " (auto tries local files and falls back to direct data)")

  if state.terminal_cache then
    vim.health.info(
      string.format(
        "Terminal cache: %d image(s), %d estimated decoded bytes; %d hit(s), %d upload attempt(s), %d placement(s)",
        state.terminal_cache.images,
        state.terminal_cache.bytes,
        state.terminal_cache.hits,
        state.terminal_cache.uploads,
        state.terminal_cache.placements or 0
      )
    )
    if state.terminal_cache.last_error then
      vim.health.warn(state.terminal_cache.last_error)
    end
  end
  if state.conversion_queue then
    vim.health.info(
      string.format("Converters: %d active, %d queued", state.conversion_queue.active, state.conversion_queue.queued)
    )
  end
  if state.treesitter then
    local syntax = state.treesitter
    ---@cast syntax ImageToolsSyntaxStatus
    vim.health.start("image-tools: reference syntax")
    vim.health.info("Tree-sitter: " .. (syntax.enabled and "enabled" or "disabled; using Lua scanner"))
    vim.health.info(
      string.format("%d parse(s), %d index hit(s), %d indexed row(s)", syntax.parses, syntax.hits, syntax.indexed_rows)
    )
    for _, reason in ipairs(vim.tbl_keys(syntax.fallbacks)) do
      vim.health.info(string.format("Fallback %s: %d event(s)", reason, syntax.fallbacks[reason]))
    end
    if syntax.current then
      local current = syntax.current
      ---@cast current ImageToolsSyntaxDiagnostic
      vim.health.info("Current buffer backend: " .. current.backend .. " (" .. current.lang .. ")")
      if current.reason then
        vim.health.info("Reason: " .. current.reason .. ": " .. (current.detail or ""))
      end
      vim.health.info(
        string.format("Last parse: %.2f ms; last index: %.2f ms", current.parse_ms or 0, current.index_ms or 0)
      )
    end
  end
  disk_health(state)
end

return M

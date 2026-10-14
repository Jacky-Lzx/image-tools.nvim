local M = {}

local function size(bytes)
  local units, index = { "B", "KiB", "MiB", "GiB", "TiB" }, 1
  while bytes >= 1024 and index < #units do
    bytes, index = bytes / 1024, index + 1
  end
  return string.format(index == 1 and "%.0f %s" or "%.2f %s", bytes, units[index])
end
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
  local cancel = require("image_tools.disk_cache").inspect(opts, function(snapshot)
    report = snapshot
  end)
  if not vim.wait(3000, function()
    return report ~= nil
  end, 10) then
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

  if vim.fn.executable("pdfinfo") == 1 then
    vim.health.ok("pdfinfo found: PDF buffer page counts available")
  else
    vim.health.warn("Install poppler for PDF buffers: brew install poppler")
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
  if state.treesitter then
    local syntax = state.treesitter
    vim.health.start("image-tools: reference syntax")
    vim.health.info("Tree-sitter: " .. (syntax.enabled and "enabled" or "disabled; using Lua scanner"))
    vim.health.info(
      string.format("%d parse(s), %d index hit(s), %d indexed row(s)", syntax.parses, syntax.hits, syntax.indexed_rows)
    )
    for _, reason in ipairs(vim.tbl_keys(syntax.fallbacks)) do
      vim.health.info(string.format("Fallback %s: %d request(s)", reason, syntax.fallbacks[reason]))
    end
    if syntax.current then
      local current = syntax.current
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

-- Module: image_tools
--
-- Purpose:
--   Expose the supported plugin API and manage the single active Runtime.
--
-- Architecture:
--   Validate options through config before constructing runtime. Delegate
--   preview, file-buffer and import operations to that instance; module loading
--   itself installs no handlers.
--
-- Ownership:
--   Own the module-local Runtime reference. Reconfiguration destroys the
--   previous instance; status and close remain safe before setup.

---@class ImageToolsApi
local M = {}
local instance

local function refresh_adapter(filetype)
  if instance and vim.bo.filetype == filetype then
    instance:close()
    instance:schedule_refresh()
  end
end

-- Registration is independent of setup; returned cleanup is safe after a later
-- registration replaces this adapter, and built-ins remain protected.
function M.register_adapter(filetype, definition)
  local unregister = require("image_tools.document.formats").register(filetype, definition)
  refresh_adapter(filetype)
  return function()
    local removed = unregister()
    if removed then
      refresh_adapter(filetype)
    end
    return removed
  end
end

function M.unregister_adapter(filetype)
  local removed = require("image_tools.document.formats").unregister(filetype)
  if removed then
    refresh_adapter(filetype)
  end
  return removed
end

-- Lazily configure the single active Runtime for operations that require services.
---@return ImageToolsRuntime instance
local function runtime()
  if not instance then
    M.setup(require("image_tools.bootstrap").options())
  end
  return instance
end

M._runtime = runtime

-- Validate and construct before replacing the active Runtime; clean up a partially failed start.
---@param opts? table Configuration overrides copied by config.resolve.
---@return nil
function M.setup(opts)
  assert(opts == nil or type(opts) == "table", "image-tools.nvim: setup expects a table")
  opts = vim.deepcopy(opts or {})
  local options = require("image_tools.config").resolve(opts)
  local replacement = require("image_tools.runtime").new(options)
  if instance then
    instance:destroy()
  end
  instance = replacement
  local ok, err = pcall(replacement.start, replacement)
  if not ok then
    replacement:destroy()
    instance = nil
    error(err, 0)
  end
  local bootstrap = package.loaded["image_tools.bootstrap"]
  if bootstrap then
    bootstrap.configured()
  end
  vim.api.nvim_exec_autocmds("User", { pattern = "ImageToolsReady", modeline = false })
end

-- Release the runtime and cold bootstrap without implicitly starting services.
function M.dispose()
  if instance then
    instance:destroy()
    instance = nil
  end
  local bootstrap = package.loaded["image_tools.bootstrap"]
  if bootstrap then
    bootstrap.dispose()
  end
end

-- Close only the floating preview; safe before setup and when already closed.
---@return nil
function M.close()
  if instance then
    instance:close()
  end
end

-- Release plugin-owned terminal pixels and views without deleting disk conversions.
---@return nil
function M.clear_cache()
  if instance then
    instance:clear_cache()
  end
end

-- Initialize services if needed and schedule removal of unused disk conversions.
---@param callback? fun(status: ImageToolsDiskCleanupStatus) Receives a cleanup snapshot.
---@return nil
function M.clear_disk_cache(callback)
  return runtime():clear_disk_cache(callback)
end

-- Read current configuration/resource snapshots without implicitly setting up the plugin.
---@return ImageToolsRuntimeStatus status Unconfigured snapshots omit service statistics.
function M.status()
  return instance and instance:status() or { configured = false, auto_preview = false, transport = "auto" }
end

-- Inspect supported extensions without configuring services or loading renderers.
function M.supports(path)
  return type(path) == "string" and require("image_tools.media.formats").supported(path) or false
end

-- Render into a caller-owned nofile buffer/window; no windows are created.
-- The returned view has idempotent close() and geometry-aware resize().
---@param request ImageToolsEmbeddedRequest
---@return ImageToolsEmbeddedView? view
---@return string? error
function M.render(request)
  return runtime():render(request)
end

-- Display a producer-owned local image in an independently managed float.
-- Returns a close()/resize() handle; on_close releases the producer's file lease.
function M.float(request)
  return runtime():float(request)
end

-- Start a floating preview of an explicit path resolved relative to cwd.
---@param path string Image path.
---@param opts? ImageToolsPreviewOptions Notification/reference authority options.
---@return boolean accepted Request accepted; successful display is asynchronous.
---@return string? error
function M.preview(path, opts)
  return runtime():open_preview(path, opts)
end

-- Import/reference one file or a batch at a captured document position; nil paths prompt for a
-- file.
---@param paths? string|string[] Source paths.
---@param opts? ImageToolsInsertOptions Per-operation insertion overrides.
---@param callback? ImageToolsInsertCallback Reports completion or cancellation.
---@return ImageToolsCancel cancel
function M.insert(paths, opts, callback)
  return runtime():insert(paths, opts, callback)
end

-- Start a clipboard import using a captured document context.
---@param opts? ImageToolsInsertOptions Insertion and clipboard options.
---@param callback? ImageToolsInsertCallback Reports completion or cancellation.
---@return ImageToolsCancel cancel
function M.paste(opts, callback)
  return runtime():paste(opts, callback)
end

-- Open the optional selection-tools picker and import at the original extmark.
---@param opts? table insert and picker override tables.
---@param callback? ImageToolsInsertCallback Reports import results or unconfirmed cancellation.
---@return table? picker Nil when picker construction fails.
function M.pick(opts, callback)
  return runtime():pick(opts, callback)
end

-- Open an explicit read-only image/PDF file buffer; errors during rendering appear in the buffer.
---@param path string Source file path.
---@return boolean accepted
---@return string? error
function M.open(path)
  return runtime():open(path)
end

-- Select an absolute PDF page in the current file-viewer buffer.
---@param page integer? One-based page; out-of-range values are rejected.
---@return boolean accepted
---@return string? error
function M.page(page)
  return runtime():page(page)
end

-- Move within the current PDF, clamping at the first and last pages.
---@param delta? integer Signed page offset; defaults to one.
---@return boolean accepted
---@return string? error
function M.next_page(delta)
  return runtime():next_page(delta)
end

-- Force source/metadata refresh in the current image/PDF viewer.
---@return boolean accepted
---@return string? error
function M.reload()
  return runtime():reload()
end

-- Select the cursor reference, falling back to the first covering reference only on a selection
-- miss.
---@param opts? ImageToolsPreviewOptions silent suppresses notifications.
---@return boolean accepted False for errors or an authoritative pending syntax parse.
---@return string? error
function M.hover(opts)
  return runtime():hover(opts)
end

-- Toggle automatic reference preview, close current work and refresh when newly enabled.
---@return boolean enabled
function M.toggle()
  return runtime():toggle()
end

function M.toggle_inline()
  return runtime():toggle_inline()
end

-- Adjust the current file-viewer window independently of other splits.
function M.zoom(value)
  return runtime():zoom(value)
end

function M.pan(x, y)
  return runtime():pan(x, y)
end

function M.check_assets(opts, callback)
  return runtime():check_assets(opts, callback or function(err, report)
    vim.notify(
      err
        or string.format("%d missing reference(s), %d possibly unused image(s)", #report.missing, #report.unreferenced),
      err and vim.log.levels.ERROR or vim.log.levels.INFO
    )
  end)
end

-- Review and apply an image move across recognized project references.
function M.move(source, target, opts, callback)
  return runtime():move(source, target, opts, callback)
end

function M.localize(opts, callback)
  return runtime():localize(opts, callback)
end

-- Metadata inspection does not implicitly configure an unused plugin.
function M.info()
  if not instance then
    return nil, "No active image preview"
  end
  return instance:info()
end

return M

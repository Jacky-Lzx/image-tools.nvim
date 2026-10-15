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

-- Lazily configure the single active Runtime for operations that require services.
---@return ImageToolsRuntime instance
local function runtime()
  if not instance then
    M.setup()
  end
  return instance
end

-- Validate and construct before replacing the active Runtime; clean up a partially failed start.
---@param opts? table Configuration overrides copied by config.resolve.
---@return nil
function M.setup(opts)
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
  elseif package.loaded["image_tools.workflow.picker"] then
    require("image_tools.workflow.picker").clear_all()
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

-- Provide the custom Snacks preview callback, with ordinary file preview fallback.
---@param ctx table Snacks preview context.
---@return nil
function M.snacks_preview(ctx)
  return runtime():snacks_preview(ctx)
end

-- Open the optional Snacks picker and import confirmed selections at the original extmark.
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

-- Adjust the current file-viewer window independently of other splits.
function M.zoom(value)
  return runtime():zoom(value)
end

function M.pan(x, y)
  return runtime():pan(x, y)
end

return M

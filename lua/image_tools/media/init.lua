-- Module: image_tools.media
--
-- Purpose:
--   Provide the unified entry point for image formats, reads and preparation.
--
-- Architecture:
--   Forward format checks, PNG inspection/reads and file-version keys to media
--   helpers. Adapt media/prepare request handles into a cancellation function that
--   also releases the preparation lease.
--
-- Ownership:
--   Own no cache or worker state. The returned preparation cancel function
--   performs close, cancelling delivery and releasing any file lease.

---@alias ImageToolsCancel fun()
---@class ImageToolsImageSize
---@field width integer Width in pixels.
---@field height integer Height in pixels.
---@class ImageToolsImage: ImageToolsImageSize
---@field path string Native or converted PNG path.
---@field key string PNG file revision used for terminal caching.
---@field size? integer Compressed PNG size when supplied by the reader.
---@field data? string Complete PNG bytes; absent for metadata-only preparation.
---@field source? string Original convertible source path.
---@field cache_source? string Logical source identity; PDF pages include a page suffix.
---@alias ImageToolsImageCallback fun(err: string?, image: ImageToolsImage?)

---@class ImageToolsMedia
local M = {}

-- Check a filename extension against the shared native/conversion format registry.
---@param path string Filename; no existence check is performed.
---@return boolean supported
function M.supported(path)
  return require("image_tools.media.formats").supported(path)
end

-- Validate a complete PNG byte string and return its pixel dimensions.
---@param data string PNG bytes (or combined header/tail metadata bytes).
---@param opts table PNG dimension/pixel validation limits.
---@return ImageToolsImageSize? info
---@return string? error
function M.info(data, opts)
  return require("image_tools.media.png").info(data, opts)
end

-- Compute a file revision key from caller-supplied metadata.
---@param path string File path included in the key.
---@param stat table Filesystem stat snapshot, including inode, size and nanosecond timestamps.
---@return string key
function M.key(path, stat)
  return require("image_tools.media.file_version").key(path, stat)
end

-- Start a cancellable PNG read; callbacks are scheduled rather than delivered during the call.
---@param path string PNG file path.
---@param opts table File-size and PNG validation limits.
---@param callback ImageToolsImageCallback Receives dimensions/revision and optional bytes.
---@param metadata_only? boolean Read header/tail only and omit image.data when true.
---@return ImageToolsCancel cancel Suppress pending delivery; in-flight reads finish descriptor cleanup.
function M.read(path, opts, callback, metadata_only)
  return require("image_tools.media.png").read(path, opts, callback, metadata_only)
end

-- Prepare native/converted pixels and expose one cleanup function for both cancellation and lease
-- release.
---@param path string Native image or convertible source.
---@param opts table Preparation, converter, cache and validation settings.
---@param callback ImageToolsImageCallback Receives prepared PNG metadata on success.
---@return ImageToolsCancel close Cancels pending delivery and releases the delivered file lease.
function M.prepare(path, opts, callback)
  local request = require("image_tools.media.prepare").request(path, opts, callback)
  -- Closing the preparation handle cancels delivery and releases resources.
  return request.close
end

return M

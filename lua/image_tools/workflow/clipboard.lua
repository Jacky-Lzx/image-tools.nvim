-- Module: image_tools.workflow.clipboard
--
-- Purpose:
--   Read a macOS clipboard image, optionally convert its format and import it.
--
-- Architecture:
--   Capture insertion context, run pngpaste, validate PNG data and submit
--   optional conversion to the shared queue. Delegate final text/file
--   publication to workflow/insert, always in copy mode.
--
-- Ownership:
--   Each paste owns subprocess/read cancellation, a temporary directory and
--   import context. Completion or cancellation cleans temporary resources
--   without changing clipboard contents.

---@class ImageToolsClipboardState
---@field done? boolean Completion/cancellation guard.
---@field directory? string Owned temporary directory, removed on finish/cancel.
---@field job? table Pending pngpaste process with kill support.
---@field cancel_read? ImageToolsCancel Pending PNG validation read.
---@field cancel_conversion? ImageToolsCancel Shared-queue converter operation.
---@field cancel_import? ImageToolsCancel Pending file/text publication transaction.

---@class ImageToolsClipboard
local M = {}
local uv = vim.uv
local defaults = require("image_tools.defaults")
local limits = require("image_tools.media.conversion_limits")
local SIGTERM = 15
local DEFAULT_QUALITY = 75
local DEFAULT_CLIPBOARD_TIMEOUT_MS = 5000
local formats = { png = true, jpg = true, webp = true, avif = true }

-- pngpaste uses AppKit's pasteboard conversion. It reads the clipboard without
-- altering it and writes PNG data regardless of its original representation.
-- Capture the document, read/validate the clipboard, optionally convert format and always import a
-- copied resource.
---@param opts? ImageToolsInsertOptions Clipboard and insertion options.
---@param callback? ImageToolsInsertCallback Defaults to error notifications.
---@param dependencies? table macos=true enables controlled platform tests.
---@return ImageToolsCancel cancel Stops owned read/process/import work and cleans temporary resources.
function M.paste(opts, callback, dependencies)
  opts, dependencies = opts or {}, dependencies or {}
  callback = callback
    or function(err)
      if err and err ~= "Cancelled" then
        vim.notify(err, vim.log.levels.ERROR, { title = "image-tools" })
      end
    end

  local I = require("image_tools.workflow.insert")
  local context = opts.context or I.capture(opts)
  opts = vim.tbl_extend("force", opts, { context = context })
  ---@type ImageToolsClipboardState
  local state = {}

  -- Remove the operation temporary directory; repeated cleanup is harmless.
  ---@return nil
  local function cleanup()
    if state.directory then
      vim.fn.delete(state.directory, "rf")
    end
  end

  -- Deliver one paste result after temporary cleanup and context release.
  ---@param err? string Read/validation/conversion/import error.
  ---@param paths? string[] Successfully published resource paths.
  ---@return nil
  local function finish(err, paths)
    if state.done then
      cleanup()
      return
    end
    state.done = true
    cleanup()
    I.release(context)
    callback(err, paths)
  end

  -- Suppress further stages, stop owned work, remove temporaries and report cancellation once.
  ---@return nil
  local function cancel()
    if state.done then
      return
    end
    state.done = true
    if state.job then
      state.job:kill(SIGTERM)
    end
    if state.cancel_conversion then
      state.cancel_conversion()
    end
    if state.cancel_import then
      state.cancel_import()
    end
    cleanup()
    I.release(context)
    callback("Cancelled")
  end

  if not (dependencies.macos == true or vim.fn.has("mac") == 1) then
    finish("Clipboard image paste currently supports macOS only")
    return cancel
  end

  local format = opts.format or "png"
  if not formats[format] then
    finish("Clipboard format must be png, jpg, webp or avif")
    return cancel
  end

  if not I.supported(context.filetype, "clipboard." .. format) then
    finish("Unsupported clipboard format for " .. context.filetype .. "; use PNG or JPG")
    return cancel
  end

  local executable = opts.pngpaste or "pngpaste"
  if vim.fn.executable(executable) ~= 1 then
    finish("pngpaste is required for clipboard images (brew install pngpaste)")
    return cancel
  end

  state.directory = uv.fs_mkdtemp(vim.fn.tempname() .. "-image-tools-XXXXXX")
  if not state.directory then
    finish("Cannot create a clipboard temporary directory")
    return cancel
  end

  local png = state.directory .. "/clipboard.png"

  -- Validate output existence/size and delegate final publication in mandatory copy mode.
  ---@param path string Temporary PNG or converted clipboard output.
  ---@return nil
  local function imported(path)
    if state.done then
      cleanup()
      return
    end
    local stat = uv.fs_stat(path)
    if not stat or stat.size == 0 then
      finish("Clipboard did not contain an image")
      return
    end
    if stat.size > (opts.max_bytes or defaults.max_bytes) then
      finish("Clipboard image exceeds max_bytes")
      return
    end
    local insertion = vim.tbl_extend("force", opts, {
      mode = "copy", -- Clipboard temporary resources must never be referenced.
      filename = opts.filename or os.date("image-%Y%m%d-%H%M%S") .. "." .. format,
    })
    state.cancel_import = I.files({ path }, insertion, finish)
  end

  -- Bypass conversion for PNG; other formats share the configured process queue and timeout.
  ---@return nil
  local function convert()
    if format == "png" then
      imported(png)
      return
    end

    local magick = opts.magick or "magick"
    if vim.fn.executable(magick) ~= 1 then
      finish("ImageMagick is required for clipboard conversion")
      return
    end
    local output = state.directory .. "/clipboard." .. format
    state.cancel_conversion = require("image_tools.media.conversion_queue").run(
      {
        magick,
        "-limit",
        "memory",
        limits.MAGICK_MEMORY,
        "-limit",
        "map",
        limits.MAGICK_MAP,
        "-limit",
        "disk",
        limits.MAGICK_DISK,
        png,
        "-auto-orient",
        "-quality",
        tostring(opts.quality or DEFAULT_QUALITY),
        output,
      },
      { timeout = opts.convert_timeout or defaults.convert_timeout },
      vim.schedule_wrap(function(result)
        state.cancel_conversion = nil
        if state.done then
          cleanup()
          return
        end
        if result.code ~= 0 then
          finish("Clipboard conversion failed: " .. vim.trim(result.stderr or ""))
          return
        end
        imported(output)
      end)
    )
  end

  state.job = vim.system(
    { executable, png },
    { timeout = opts.clipboard_timeout or DEFAULT_CLIPBOARD_TIMEOUT_MS },
    vim.schedule_wrap(function(result)
      state.job = nil
      if state.done then
        cleanup()
        return
      end
      if result.code ~= 0 then
        finish("Cannot read a clipboard image: " .. vim.trim(result.stderr or ""))
        return
      end
      local stat = uv.fs_stat(png)
      if not stat or stat.size > (opts.max_bytes or defaults.max_bytes) then
        finish("Clipboard image missing or exceeds max_bytes")
        return
      end

      -- Validate PNG before copying it into the user's document resources.
      state.cancel_read = require("image_tools.media").read(png, {
        max_bytes = opts.max_bytes or defaults.max_bytes,
        max_dimension = opts.max_dimension or defaults.max_dimension,
        max_pixels = opts.max_pixels or defaults.max_pixels,
      }, function(err)
        if state.done then
          cleanup()
          return
        end
        if err then
          finish(err)
          return
        end
        convert()
      end, true)
    end)
  )

  return function()
    if state.cancel_read then
      state.cancel_read()
    end
    cancel()
  end
end

return M

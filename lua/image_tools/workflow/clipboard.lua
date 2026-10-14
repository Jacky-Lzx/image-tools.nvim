local M = {}
local uv = vim.uv
local formats = { png = true, jpg = true, webp = true, avif = true }

-- pngpaste uses AppKit's pasteboard conversion. It reads the clipboard without
-- altering it and writes PNG data regardless of its original representation.
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
  local state = {}

  local function cleanup()
    if state.directory then
      vim.fn.delete(state.directory, "rf")
    end
  end
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
  local function cancel()
    if state.done then
      return
    end
    state.done = true
    if state.job then
      state.job:kill(15)
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
    if stat.size > (opts.max_bytes or 32 * 1024 * 1024) then
      finish("Clipboard image exceeds max_bytes")
      return
    end
    local insertion = vim.tbl_extend("force", opts, {
      mode = "copy", -- Clipboard temporary resources must never be referenced.
      filename = opts.filename or os.date("image-%Y%m%d-%H%M%S") .. "." .. format,
    })
    state.cancel_import = I.files({ path }, insertion, finish)
  end

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
        "128MiB",
        "-limit",
        "map",
        "256MiB",
        "-limit",
        "disk",
        "256MiB",
        png,
        "-auto-orient",
        "-quality",
        tostring(opts.quality or 75),
        output,
      },
      { timeout = opts.convert_timeout or 10000 },
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
    { timeout = opts.clipboard_timeout or 5000 },
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
      if not stat or stat.size > (opts.max_bytes or 32 * 1024 * 1024) then
        finish("Clipboard image missing or exceeds max_bytes")
        return
      end

      -- Validate PNG before copying it into the user's document resources.
      state.cancel_read = require("image_tools.image").read(png, {
        max_bytes = opts.max_bytes or 32 * 1024 * 1024,
        max_dimension = opts.max_dimension or 16384,
        max_pixels = opts.max_pixels or 64 * 1024 * 1024,
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

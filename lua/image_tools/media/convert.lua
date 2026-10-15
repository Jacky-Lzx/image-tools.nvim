-- Module: image_tools.media.convert
--
-- Purpose:
--   Prepare validated cached PNGs from convertible image formats and PDF pages.
--
-- Architecture:
--   Select rsvg-convert or ImageMagick, derive a versioned disk output, and
--   submit processes through conversion_queue. Validate temporary output with
--   png before atomic publication and disk-cache bookkeeping.
--
-- Ownership:
--   Each operation owns its queued/running process, temporary output and disk
--   lease. Cancellation suppresses delivery; source changes prevent publication
--   and originals are never overwritten.

local M = {}
local uv = vim.uv
local png = require("image_tools.media.png")
local version = require("image_tools.media.file_version")
local convertible = require("image_tools.media.formats").formats
local defaults = require("image_tools.defaults")
local limits = require("image_tools.media.conversion_limits")

-- Choose a renderer, reuse or publish a validated cache PNG, and retain a temporary disk lease
-- during work.
---@param path string Convertible source path.
---@param opts table Converter, page/density, cache and validation options.
---@param callback ImageToolsImageCallback Receives the prepared PNG or conversion error.
---@param metadata_only? boolean Request metadata without full PNG bytes.
---@return ImageToolsCancel cancel Cancel queued/running work and suppress delivery; cleanup may finish asynchronously.
function M.prepare(path, opts, callback, metadata_only)
  local extension = path:match("%.([^./]+)$")
  extension = extension and extension:lower()
  local page = opts.page == nil and 1 or opts.page
  if extension == "pdf" and (type(page) ~= "number" or page < 1 or page % 1 ~= 0) then
    local cancelled = false
    vim.schedule(function()
      if not cancelled then
        callback("PDF page must be a positive integer")
      end
    end)
    return function()
      cancelled = true
    end
  end
  local scale = math.max(
    1,
    math.min(
      8,
      opts.render_scale or 1,
      opts.max_dimension / limits.MAX_WIDTH,
      opts.max_dimension / limits.MAX_HEIGHT,
      math.sqrt(opts.max_pixels / (limits.MAX_WIDTH * limits.MAX_HEIGHT))
    )
  )
  local output_width, output_height = math.floor(limits.MAX_WIDTH * scale), math.floor(limits.MAX_HEIGHT * scale)
  local density = math.max(1, math.floor((opts.pdf_density or defaults.pdf_density) * scale))
  local cancelled, process, cache_release = false, nil, nil
  -- Deliver a result if active and release the worker disk lease after the callback.
  ---@param err? string Conversion/read error.
  ---@param image? ImageToolsImage Validated PNG with original source identity.
  ---@return nil
  local function done(err, image)
    if not cancelled then
      if image then
        image.source = path
        if extension == "pdf" then
          image.cache_source = path .. "#page=" .. page
        end
      end
      callback(err, image)
    end
    if cache_release then
      cache_release()
      cache_release = nil
    end
  end
  vim.schedule(function()
    if cancelled then
      return
    end
    if not convertible[extension] then
      done("Unsupported image format: " .. tostring(extension))
      return
    end
    local svg_renderer = opts.rsvg or "rsvg-convert"
    local use_rsvg = extension == "svg" and vim.fn.executable(svg_renderer) == 1
    if not use_rsvg and vim.fn.executable(opts.magick) ~= 1 then
      done("ImageMagick is required to preview " .. extension)
      return
    end
    local stat = uv.fs_stat(path)
    if not stat or stat.type ~= "file" then
      done("Image file is missing or not a regular file: " .. path)
      return
    end
    if stat.size > opts.max_bytes then
      done("Image file exceeds max_bytes")
      return
    end
    local key = vim.fn.sha256(
      version.key(path, stat)
        .. ":"
        .. (use_rsvg and svg_renderer or opts.magick)
        .. ":viewport-v3:"
        .. output_width
        .. "x"
        .. output_height
        .. ":"
        .. (extension == "pdf" and (page .. ":" .. density) or "")
    )
    local output = opts.cache .. "/" .. key .. ".png"
    -- Read an existing pinned cache result or run a converter into an unpublished temporary PNG.
    ---@return nil
    local function load()
      if uv.fs_stat(output) then
        png.read(output, opts, done, metadata_only)
        return
      end
      vim.fn.mkdir(opts.cache, "p")
      local temporary = output .. "." .. tostring(uv.hrtime()) .. ".tmp.png"
      local command
      if use_rsvg then
        command = {
          svg_renderer,
          "--format=png",
          "--width=" .. output_width,
          "--height=" .. output_height,
          "--keep-aspect-ratio",
          "--output",
          temporary,
          path,
        }
      else
        command = {
          opts.magick,
          "-limit",
          "memory",
          limits.MAGICK_MEMORY,
          "-limit",
          "map",
          limits.MAGICK_MAP,
          "-limit",
          "disk",
          limits.MAGICK_DISK,
        }
        if extension == "pdf" then
          vim.list_extend(command, { "-density", tostring(density) })
        end
        vim.list_extend(command, {
          (extension == "svg" and "MSVG:" or "") .. path .. "[" .. (extension == "pdf" and page - 1 or 0) .. "]",
          "-auto-orient",
          "-resize",
          output_width .. "x" .. output_height .. ">",
          "png:" .. temporary,
        })
      end

      process = require("image_tools.media.conversion_queue").run(
        command,
        { text = true, timeout = opts.convert_timeout },
        function(result)
          vim.schedule(function()
            process = nil
            if cancelled or result.code ~= 0 then
              uv.fs_unlink(temporary)
              if not cancelled then
                done("Image conversion failed: " .. vim.trim(result.stderr or ""))
              end
              return
            end
            png.read(temporary, opts, function(err, image)
              if cancelled then
                uv.fs_unlink(temporary)
                return
              end
              local after = uv.fs_stat(path)
              if not err and (not after or version.key(path, after) ~= version.key(path, stat)) then
                err = "Image source changed during conversion; retry the preview"
              end
              if not err then
                local renamed, rename_err = uv.fs_rename(temporary, output)
                if not renamed then
                  err = rename_err
                else
                  image.path = output
                  require("image_tools.media.disk_cache").published(opts, output)
                  local final_stat = uv.fs_stat(output)
                  if final_stat then
                    image.key = version.key(output, final_stat)
                  else
                    err = "Converted image disappeared before caching"
                  end
                end
              end
              uv.fs_unlink(temporary)
              done(err, image)
            end, metadata_only)
          end)
        end
      )
    end
    cache_release = require("image_tools.media.disk_cache").acquire(opts, output, function()
      if not cancelled then
        load()
      end
    end)
  end)
  return function()
    cancelled = true
    if process then
      process()
    end
    if cache_release then
      cache_release()
      cache_release = nil
    end

    -- Let any in-flight read complete to clean its temporary file. done()
    -- suppresses its callback after cancellation.
  end
end

return M

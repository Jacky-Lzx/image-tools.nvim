local M = {}
local uv = vim.uv
local png = require("image_tools.media.png")
local version = require("image_tools.media.file_version")
local convertible = require("image_tools.media.formats").formats

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
  local cancelled, process, cache_release = false, nil, nil
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
        .. ":svg-v2:"
        .. (extension == "pdf" and (page .. ":" .. (opts.pdf_density or 144)) or "")
    )
    local output = opts.cache .. "/" .. key .. ".png"
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
          "--width=1920",
          "--height=1080",
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
          "128MiB",
          "-limit",
          "map",
          "256MiB",
          "-limit",
          "disk",
          "256MiB",
        }
        if extension == "pdf" then
          vim.list_extend(command, { "-density", tostring(opts.pdf_density or 144) })
        end
        vim.list_extend(command, {
          (extension == "svg" and "MSVG:" or "") .. path .. "[" .. (extension == "pdf" and page - 1 or 0) .. "]",
          "-auto-orient",
          "-resize",
          "1920x1080>",
          "png:" .. temporary,
        })
      end

      process = require("image_tools.conversion_queue").run(
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
                  require("image_tools.disk_cache").published(opts, output)
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
    cache_release = require("image_tools.disk_cache").acquire(opts, output, function()
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

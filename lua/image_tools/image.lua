local M = {}
local uv = vim.uv
local signature = "\137PNG\13\10\26\10"
local convertible = {
  jpg = true,
  jpeg = true,
  webp = true,
  avif = true,
  heic = true,
  gif = true,
  bmp = true,
  tiff = true,
  tif = true,
  pdf = true,
  svg = true,
}

function M.supported(path)
  local extension = path:match("%.([^./]+)$")
  extension = extension and extension:lower()
  return extension == "png" or convertible[extension] == true
end

local function integer(data, offset)
  local a, b, c, d = data:byte(offset, offset + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

function M.info(data, opts)
  if
    #data < 45
    or data:sub(1, 8) ~= signature
    or data:sub(13, 16) ~= "IHDR"
    or integer(data, 9) ~= 13
    or data:sub(-8, -5) ~= "IEND"
  then
    return nil, "Not a complete PNG image"
  end
  local width, height = integer(data, 17), integer(data, 21)
  if
    width < 1
    or height < 1
    or width > opts.max_dimension
    or height > opts.max_dimension
    or width * height > opts.max_pixels
  then
    return nil, "Image dimensions exceed configured limits"
  end
  return { width = width, height = height }
end

function M.key(path, stat)
  return table.concat(
    { path, stat.size, stat.ino, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec },
    ":"
  )
end

function M.read(path, opts, callback, metadata_only)
  local cancelled, fd = false, nil

  local function done(err, image)
    vim.schedule(function()
      if not cancelled then
        callback(err, image)
      end
    end)
  end

  uv.fs_stat(path, function(err, stat)
    if cancelled then
      return
    end
    if err or not stat or stat.type ~= "file" then
      done("Image file is missing or not a regular file: " .. path)
      return
    end
    if stat.size > opts.max_bytes then
      done("Image file exceeds max_bytes")
      return
    end
    if stat.size < 45 then
      done("Not a complete PNG image")
      return
    end

    uv.fs_open(path, "r", 0, function(open_err, handle)
      if open_err then
        done(open_err)
        return
      end
      fd = handle
      if cancelled then
        uv.fs_close(fd)
        fd = nil
        return
      end

      local function finish(read_err, data)
        uv.fs_close(fd)
        fd = nil
        if cancelled then
          return
        end
        if read_err or not data then
          done(read_err or "Could not read image")
          return
        end

        local info, info_err = M.info(data, opts)
        if not info then
          done(info_err)
          return
        end

        uv.fs_stat(path, function(stat_err, after)
          if stat_err or not after or M.key(path, after) ~= M.key(path, stat) then
            done("Image file changed while reading; retry the preview")
            return
          end
          done(nil, {
            data = not metadata_only and data or nil,
            width = info.width,
            height = info.height,
            path = path,
            size = stat.size,
            key = M.key(path, stat),
          })
        end)
      end

      uv.fs_read(fd, metadata_only and 33 or stat.size, 0, function(read_err, data)
        if read_err or not data or cancelled or not metadata_only then
          finish(read_err, data)
          return
        end
        uv.fs_read(fd, 12, stat.size - 12, function(tail_err, tail)
          finish(tail_err, tail and data .. tail or nil)
        end)
      end)
    end)
  end)

  return function()
    cancelled = true
  end
end

local function prepare(path, opts, callback)
  local extension = path:match("%.([^./]+)$")
  extension = extension and extension:lower()
  -- All configured transports prepare only metadata. Direct uploads read the
  -- full PNG lazily on a cache miss, so cache hits avoid both IO and Base64.
  local metadata_only = opts.transport ~= nil
  if extension == "png" then
    return M.read(path, opts, callback, metadata_only)
  end
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
      M.key(path, stat)
        .. ":"
        .. (use_rsvg and svg_renderer or opts.magick)
        .. ":svg-v2:"
        .. (extension == "pdf" and (page .. ":" .. (opts.pdf_density or 144)) or "")
    )
    local output = opts.cache .. "/" .. key .. ".png"
    local function load()
      if uv.fs_stat(output) then
        M.read(output, opts, done, metadata_only)
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

      process = vim.system(command, { text = true, timeout = opts.convert_timeout }, function(result)
        vim.schedule(function()
          process = nil
          if cancelled or result.code ~= 0 then
            uv.fs_unlink(temporary)
            if not cancelled then
              done("Image conversion failed: " .. vim.trim(result.stderr or ""))
            end
            return
          end
          M.read(temporary, opts, function(err, image)
            if cancelled then
              uv.fs_unlink(temporary)
              return
            end
            local after = uv.fs_stat(path)
            if not err and (not after or M.key(path, after) ~= M.key(path, stat)) then
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
                  image.key = M.key(output, final_stat)
                else
                  err = "Converted image disappeared before caching"
                end
              end
            end
            uv.fs_unlink(temporary)
            done(err, image)
          end, metadata_only)
        end)
      end)
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
      process:kill(15)
    end
    if cache_release then
      cache_release()
      cache_release = nil
    end
    -- Let any in-flight read complete to clean its temporary file. done()
    -- suppresses its callback after cancellation.
  end
end

-- Share conversion work across renderers. Subscribers keep independent
-- cancellation; source version, page, renderer and validation limits form identity.
local pending = {}
function M.prepare(path, opts, callback)
  local extension = path:match("%.([^./]+)$")
  extension = extension and extension:lower()
  local disk = require("image_tools.disk_cache")
  if extension == "png" and disk.owns(opts, path) then
    local cancel_read
    local release = disk.acquire(opts, path, function()
      cancel_read = prepare(path, opts, callback)
    end)
    return function()
      if cancel_read then
        cancel_read()
      end
      release()
    end
  end
  local stat = convertible[extension] and uv.fs_stat(path)
  if
    not stat
    or stat.type ~= "file"
    or extension == "pdf"
      and (opts.page ~= nil and (type(opts.page) ~= "number" or opts.page < 1 or opts.page % 1 ~= 0))
  then
    return prepare(path, opts, callback)
  end
  local key = table.concat({
    M.key(path, stat),
    opts.cache or "",
    opts.magick or "",
    opts.rsvg or "rsvg-convert",
    tostring(opts.page or 1),
    tostring(opts.pdf_density or 144),
    tostring(opts.transport ~= nil),
    tostring(opts.max_bytes),
    tostring(opts.max_dimension),
    tostring(opts.max_pixels),
    tostring(opts.convert_timeout),
  }, "\0")
  local job = pending[key]
  local fresh = not job
  if fresh then
    job = { subscribers = {} }
    pending[key] = job
  end
  local subscriber = { active = true }
  job.subscribers[subscriber] = callback
  if fresh then
    job.cancel = prepare(path, opts, function(err, image)
      if job.done then
        return
      end
      job.done = true
      if pending[key] == job then
        pending[key] = nil
      end
      local subscribers = job.subscribers
      job.subscribers = {}
      for consumer, receive in pairs(subscribers) do
        if image and consumer.active then
          consumer.release = disk.acquire(opts, image.path, function() end)
        end
        -- One callback cannot prevent other subscribers from completing.
        vim.schedule(function()
          if consumer.active then
            consumer.active = false
            receive(err, image and vim.deepcopy(image) or nil)
          end
        end)
      end
    end)
  end
  return function()
    if subscriber.release then
      subscriber.release()
      subscriber.release = nil
    end
    if not subscriber.active then
      return
    end
    subscriber.active = false
    job.subscribers[subscriber] = nil
    if not job.done and not next(job.subscribers) then
      job.done = true
      if pending[key] == job then
        pending[key] = nil
      end
      if job.cancel then
        job.cancel()
      end
    end
  end
end

return M

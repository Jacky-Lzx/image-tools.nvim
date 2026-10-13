local M = {}
local uv = vim.uv
local signature = "\137PNG\13\10\26\10"
local convertible =
  { jpg = true, jpeg = true, webp = true, avif = true, heic = true, gif = true, bmp = true, tiff = true, tif = true }

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

function M.prepare(path, opts, callback)
  local extension = path:match("%.([^./]+)$")
  extension = extension and extension:lower()
  -- All configured transports prepare only metadata. Direct uploads read the
  -- full PNG lazily on a cache miss, so cache hits avoid both IO and Base64.
  local metadata_only = opts.transport ~= nil
  if extension == "png" then
    return M.read(path, opts, callback, metadata_only)
  end
  local cancelled, process = false, nil
  local function done(err, image)
    if not cancelled then
      if image then
        image.source = path
      end
      callback(err, image)
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
    if vim.fn.executable(opts.magick) ~= 1 then
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
    local key = vim.fn.sha256(M.key(path, stat) .. ":" .. opts.magick)
    local output = opts.cache .. "/" .. key .. ".png"
    if uv.fs_stat(output) then
      M.read(output, opts, done, metadata_only)
      return
    end
    vim.fn.mkdir(opts.cache, "p")
    local temporary = output .. "." .. tostring(uv.hrtime()) .. ".tmp.png"
    process = vim.system({
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
      path .. "[0]",
      "-auto-orient",
      "-resize",
      "1920x1080>",
      "png:" .. temporary,
    }, { text = true, timeout = opts.convert_timeout }, function(result)
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
          if not err then
            local renamed, rename_err = uv.fs_rename(temporary, output)
            if not renamed then
              err = rename_err
            else
              image.path = output
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
  end)
  return function()
    cancelled = true
    if process then
      process:kill(15)
    end
    -- Let any in-flight read complete to clean its temporary file. done()
    -- suppresses its callback after cancellation.
  end
end

return M

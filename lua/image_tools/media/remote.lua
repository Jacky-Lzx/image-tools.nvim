-- HTTPS downloads share the interactive process queue and disk-cache leases.
-- Retain original bytes for localization; previews use the ordinary media pipeline.
local M = {}
local uv = vim.uv
local disk = require("image_tools.media.disk_cache")
local formats = require("image_tools.media.formats")
local pending = {}
local counters = { downloads = 0, hits = 0 }

function M.validate(url, opts)
  if not (opts.remote and opts.remote.enabled) then
    return nil, "Enable remote.enabled to load HTTPS images"
  end
  if type(url) ~= "string" or not url:match("^https://[^/]+") or url:find("[%c%s]") then
    return nil, "Remote images require an absolute HTTPS URL without spaces/control bytes"
  end
  return true
end

local function sniff(path)
  local fd = assert(uv.fs_open(path, "r", 384))
  local data = uv.fs_read(fd, 4096, 0) or ""
  uv.fs_close(fd)
  if data:sub(1, 8) == "\137PNG\r\n\26\n" then
    return "png"
  end
  if data:sub(1, 3) == "\255\216\255" then
    return "jpg"
  end
  if data:match("^GIF8[79]a") then
    return "gif"
  end
  if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
    return "webp"
  end
  if data:sub(1, 2) == "BM" then
    return "bmp"
  end
  if data:sub(1, 4) == "II*\0" or data:sub(1, 4) == "MM\0*" then
    return "tiff"
  end
  if data:match("^%%PDF%-") then
    return "pdf"
  end
  if data:sub(5, 8) == "ftyp" then
    local brands = data:sub(9, 64)
    if brands:find("avif", 1, true) or brands:find("avis", 1, true) then
      return "avif"
    end
    if brands:find("heic", 1, true) or brands:find("heix", 1, true) or brands:find("mif1", 1, true) then
      return "heic"
    end
  end
  if not data:find("%z") and data:match("<svg[%s>]") then
    return "svg"
  end
  return nil, "Downloaded content is not a supported image (HTML/error pages are rejected)"
end

local function worker(url, opts, callback)
  local settings = opts.remote
  local active, temp, fd, cancel_process, validation, release = true, nil, nil, nil, nil, nil
  local function cleanup()
    if fd then
      uv.fs_close(fd)
      fd = nil
    end
    if validation then
      validation.close()
      validation = nil
    end
    if release then
      release()
      release = nil
    end
    if temp then
      vim.fn.delete(temp, "rf")
    end
  end
  local function finish(err, path)
    if not active then
      cleanup()
      return
    end
    active = false
    callback(err, path)
    cleanup()
  end
  local rawkey = vim.fn.sha256("image-tools-https-v1\0" .. url .. "\0" .. settings.curl)
  local function validate(path, complete)
    validation = require("image_tools.media.prepare").request(path, opts, function(err)
      complete(err)
    end)
  end
  vim.schedule(function()
    if not active then
      return
    end
    local valid, err = M.validate(url, opts)
    if not valid then
      finish(err)
      return
    end
    if not opts._remote_refresh and settings.ttl > 0 then
      for _, ext in ipairs(formats.extensions()) do
        local path = opts.cache .. "/" .. rawkey .. "." .. ext
        local stat = uv.fs_lstat(path)
        if stat and stat.type == "file" and os.time() - stat.mtime.sec < settings.ttl then
          release = disk.acquire(opts, path, function()
            validate(path, function(cache_err)
              if not cache_err then
                counters.hits = counters.hits + 1
              end
              finish(cache_err, not cache_err and path or nil)
            end)
          end)
          return
        end
      end
    end
    if vim.fn.executable(settings.curl) ~= 1 then
      finish("HTTPS downloader not found: " .. settings.curl)
      return
    end
    temp, err = uv.fs_mkdtemp(vim.fn.tempname() .. "-image-tools-https-XXXXXX")
    if not temp then
      finish(tostring(err))
      return
    end
    local download = temp .. "/download"
    fd, err = uv.fs_open(download, "wx", 384)
    if not fd then
      finish(tostring(err))
      return
    end
    local bytes, stream_error = 0, nil
    local seconds = tostring(settings.timeout / 1000)
    local command = {
      settings.curl,
      "-q",
      "--globoff",
      "--silent",
      "--show-error",
      "--fail",
      "--location",
      "--proto",
      "=https",
      "--proto-redir",
      "=https",
      "--max-redirs",
      tostring(settings.max_redirects),
      "--max-time",
      seconds,
      "--connect-timeout",
      seconds,
      "--url",
      url,
    }
    counters.downloads = counters.downloads + 1
    cancel_process = require("image_tools.media.conversion_queue").run(command, {
      timeout = settings.timeout,
      stdout = function(read_err, data)
        if not active or stream_error then
          return
        end
        if read_err then
          stream_error = "HTTPS stream failed: " .. tostring(read_err)
        elseif data then
          if bytes + #data > opts.max_bytes then
            stream_error = "Remote image exceeds max_bytes"
          else
            local offset = 0
            while offset < #data do
              local written, write_err = uv.fs_write(fd, data:sub(offset + 1), bytes + offset)
              if not written or written == 0 then
                stream_error = "HTTPS write failed: " .. tostring(write_err)
                break
              end
              offset = offset + written
            end
            bytes = bytes + offset
          end
        end
        if stream_error then
          vim.schedule(function()
            if active and cancel_process then
              cancel_process()
            end
          end)
        end
      end,
    }, function(result)
      cancel_process = nil
      if fd then
        uv.fs_close(fd)
        fd = nil
      end
      if not active then
        cleanup()
        return
      end
      if stream_error or result.code ~= 0 then
        finish(stream_error or ("HTTPS download failed: " .. vim.trim(result.stderr or "")))
        return
      end
      if bytes == 0 then
        finish("Downloaded image is empty")
        return
      end
      local extension, sniff_err = sniff(download)
      if not extension then
        finish(sniff_err)
        return
      end
      local source = temp .. "/image." .. extension
      local renamed, rename_err = uv.fs_rename(download, source)
      if not renamed then
        finish(tostring(rename_err))
        return
      end
      validate(source, function(validation_err)
        if not active then
          cleanup()
          return
        end
        if validation_err then
          finish(validation_err)
          return
        end
        local output = opts.cache .. "/" .. rawkey .. "." .. extension
        -- Keep the destination pinned while publishing and delivering subscribers.
        release = disk.acquire(opts, output, function()
          local made, mkdir_err = pcall(vim.fn.mkdir, opts.cache, "p")
          if not made then
            finish(tostring(mkdir_err))
            return
          end
          local staged = opts.cache .. "/." .. rawkey .. "." .. uv.hrtime() .. ".download"
          local copied, copy_err = uv.fs_copyfile(source, staged, 1)
          if not copied then
            finish(tostring(copy_err))
            return
          end
          local published, publish_err = uv.fs_rename(staged, output)
          if not published then
            uv.fs_unlink(staged)
            finish(tostring(publish_err))
            return
          end
          disk.published(opts, output)
          finish(nil, output)
        end)
        -- acquire may synchronously publish and finish before returning its lease.
        if not active and release then
          release()
          release = nil
        end
      end)
    end)
  end)
  return function()
    if active then
      active = false
      if cancel_process then
        cancel_process()
      end
      cleanup()
    end
  end
end

-- Each subscriber holds its own raw-file pin; only the final cancellation stops
-- a shared pending download. Callback delivery remains asynchronous.
function M.fetch(url, opts, callback)
  local id = table.concat({
    url,
    opts.cache,
    vim.inspect(opts.remote),
    tostring(opts.max_bytes),
    tostring(opts.max_dimension),
    tostring(opts.max_pixels),
    tostring(opts.convert_timeout),
    tostring(opts.magick),
    tostring(opts.rsvg),
    tostring(opts._remote_refresh),
  }, "\0")
  local job = pending[id]
  local fresh = not job
  if fresh then
    job = { subscribers = {} }
    pending[id] = job
  end
  local subscriber = { active = true }
  job.subscribers[subscriber] = callback
  if fresh then
    job.cancel = worker(url, opts, function(err, path)
      job.done = true
      if pending[id] == job then
        pending[id] = nil
      end
      local subscribers = job.subscribers
      job.subscribers = {}
      for consumer, receive in pairs(subscribers) do
        if consumer.active and path then
          consumer.release = disk.acquire(opts, path, function() end)
        end
        vim.schedule(function()
          if consumer.active then
            consumer.delivered = true
            receive(err, path)
          end
        end)
      end
    end)
  end
  return function()
    if not subscriber.active then
      return
    end
    subscriber.active = false
    if subscriber.release then
      subscriber.release()
    end
    job.subscribers[subscriber] = nil
    if not job.done and not next(job.subscribers) then
      if pending[id] == job then
        pending[id] = nil
      end
      job.cancel()
    end
  end
end

function M.prepare(url, opts, callback)
  local active, prepared = true, nil
  local close_fetch = M.fetch(url, opts, function(err, path)
    if not active then
      return
    end
    if err then
      callback(err)
      return
    end
    prepared = require("image_tools.media.prepare").request(path, opts, function(prepare_err, image, timing)
      if active then
        if image then
          image.source, image.source_format, image.source_bytes = url, formats.extension(path), uv.fs_stat(path).size
        end
        callback(prepare_err, image, timing)
      end
    end)
  end)
  local function close()
    if not active then
      return
    end
    active = false
    if prepared then
      prepared.close()
    end
    close_fetch()
  end
  return { cancel = close, release = close, close = close }
end

function M.status()
  return vim.tbl_extend("force", counters, { pending = vim.tbl_count(pending) })
end

return M

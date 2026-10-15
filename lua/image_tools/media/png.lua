-- Module: image_tools.media.png
--
-- Purpose:
--   Read PNG bytes or lightweight metadata and enforce image resource limits.
--
-- Architecture:
--   Serve native PNG preparation, converter output validation and direct
--   terminal transmission. Check signature, IHDR/IEND, dimensions and source
--   version; terminal acknowledgement handles decoding validation.
--
-- Ownership:
--   Each read owns its file descriptor and cancellation flag. Schedule
--   delivery, close descriptors after reads and suppress callbacks after
--   cancellation; no shared PNG cache is kept here.

local M = {}
local uv = vim.uv
local PNG_SIGNATURE = "\137PNG\13\10\26\10"
local BYTE_RADIX = 256
local UINT32_BYTES = 4
local CHUNK_TYPE_BYTES = #"IHDR"
local CHUNK_OVERHEAD_BYTES = UINT32_BYTES + CHUNK_TYPE_BYTES + UINT32_BYTES -- Length, type and CRC.
local IHDR_DATA_BYTES = 13
local IHDR_LENGTH_OFFSET = #PNG_SIGNATURE + 1
local IHDR_TYPE_OFFSET = IHDR_LENGTH_OFFSET + UINT32_BYTES
local WIDTH_OFFSET = IHDR_TYPE_OFFSET + CHUNK_TYPE_BYTES
local HEIGHT_OFFSET = WIDTH_OFFSET + UINT32_BYTES
local HEADER_BYTES = #PNG_SIGNATURE + CHUNK_OVERHEAD_BYTES + IHDR_DATA_BYTES
local IEND_BYTES = CHUNK_OVERHEAD_BYTES -- The final chunk has no data payload.
local MIN_PNG_BYTES = HEADER_BYTES + IEND_BYTES
M.key = require("image_tools.media.file_version").key

-- Decode one big-endian unsigned 32-bit PNG field.
---@param data string Raw PNG bytes.
---@param offset integer One-based byte offset.
---@return integer value
local function integer(data, offset)
  local a, b, c, d = data:byte(offset, offset + UINT32_BYTES - 1)
  return ((a * BYTE_RADIX + b) * BYTE_RADIX + c) * BYTE_RADIX + d
end

-- Check signature/IHDR/IEND and configured dimensions; this is basic validation, not full PNG
-- decoding.
---@param data string Complete bytes or the concatenated 33-byte header and 12-byte tail.
---@param opts table max_dimension and max_pixels limits.
---@return ImageToolsImageSize? info
---@return string? error
function M.info(data, opts)
  if
    #data < MIN_PNG_BYTES
    or data:sub(1, #PNG_SIGNATURE) ~= PNG_SIGNATURE
    or data:sub(IHDR_TYPE_OFFSET, IHDR_TYPE_OFFSET + CHUNK_TYPE_BYTES - 1) ~= "IHDR"
    or integer(data, IHDR_LENGTH_OFFSET) ~= IHDR_DATA_BYTES
    or data:sub(-(CHUNK_TYPE_BYTES + UINT32_BYTES), -(UINT32_BYTES + 1)) ~= "IEND"
  then
    return nil, "Not a complete PNG image"
  end
  local width, height = integer(data, WIDTH_OFFSET), integer(data, HEIGHT_OFFSET)
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

-- Read PNG metadata or full bytes, then verify that the source revision remained stable.
---@param path string PNG file path.
---@param opts table max_bytes, max_dimension and max_pixels limits.
---@param callback ImageToolsImageCallback Scheduled once on success/error unless cancelled.
---@param metadata_only? boolean Omit image.data and read only the header/end chunk.
---@return ImageToolsCancel cancel Suppresses callback delivery; descriptor cleanup still completes.
function M.read(path, opts, callback, metadata_only)
  local cancelled, fd = false, nil

  -- Schedule completion outside libuv callbacks and discard delivery after cancellation.
  ---@param err? string Read/validation error.
  ---@param image? ImageToolsImage Validated PNG result.
  ---@return nil
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
    if stat.size < MIN_PNG_BYTES then
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

      -- Close the file descriptor before validation and verify the source revision before
      -- scheduled delivery.
      ---@param read_err? string Read error.
      ---@param data? string Full PNG bytes or combined header/tail bytes.
      ---@return nil
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

      uv.fs_read(fd, metadata_only and HEADER_BYTES or stat.size, 0, function(read_err, data)
        if read_err or not data or cancelled or not metadata_only then
          finish(read_err, data)
          return
        end
        uv.fs_read(fd, IEND_BYTES, stat.size - IEND_BYTES, function(tail_err, tail)
          finish(tail_err, tail and data .. tail or nil)
        end)
      end)
    end)
  end)

  return function()
    cancelled = true
  end
end

return M

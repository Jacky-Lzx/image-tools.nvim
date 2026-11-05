-- Module: image_tools.media.pdf
--
-- Purpose:
--   Read source-versioned PDF page counts and selected-page geometry.
--
-- Architecture:
--   Run pdfinfo asynchronously with the configured timeout and validate the
--   source version before returning metadata. Page rasterization is handled
--   separately by media/convert.
--
-- Ownership:
--   Each request owns one process and cancellation flag. Consumers own page
--   state; the bounded geometry cache retains metadata by source version/page.
--   Metadata reads bypass the
--   converter queue.

---@class ImageToolsPdfInfo
---@field pages integer Positive PDF page count.
---@field key string Source revision validated after pdfinfo exits.
---@field width? number Selected-page width in points, including rotation.
---@field height? number Selected-page height in points, including rotation.

---@class ImageToolsPdf
local M = {}
local SIGTERM = 15
local size_cache, size_keys = {}, {}

-- Run pdfinfo and report page count only if the source revision is still current.
---@param path string PDF path.
---@param opts table pdfinfo, convert_timeout and max_bytes settings.
---@param callback fun(err: string?, info: ImageToolsPdfInfo?) Receives metadata or an error.
---@return ImageToolsCancel cancel Stop the subprocess and suppress delivery.
local function info(path, opts, callback, page)
  local cancelled, job = false, nil
  -- Deliver the metadata result only while this request remains uncancelled.
  ---@param err? string Metadata process/source error.
  ---@param info? ImageToolsPdfInfo Validated result.
  ---@return nil
  local function done(err, info)
    if not cancelled then
      callback(err, info)
    end
  end
  vim.schedule(function()
    if cancelled then
      return
    end
    local image = require("image_tools.media")
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.type ~= "file" then
      done("PDF is missing or not a regular file")
      return
    end
    if stat.size > opts.max_bytes then
      done("PDF exceeds max_bytes")
      return
    end
    local executable = opts.pdfinfo or "pdfinfo"
    if vim.fn.executable(executable) ~= 1 then
      done(
        page and "pdfinfo is required for pixel-fit PDF previews (brew install poppler)"
          or "pdfinfo is required for PDF buffer previews (brew install poppler)"
      )
      return
    end
    local key = image.key(path, stat)
    local command = page and { executable, "-f", tostring(page), "-l", tostring(page), "-box", path }
      or { executable, path }
    job = vim.system(
      command,
      { text = true, timeout = opts.convert_timeout, env = { LC_ALL = "C" } },
      vim.schedule_wrap(function(result)
        job = nil
        if cancelled then
          return
        end
        if result.code ~= 0 then
          done("Cannot read PDF: " .. vim.trim(result.stderr or ""))
          return
        end
        local after = vim.uv.fs_stat(path)
        if not after or image.key(path, after) ~= key then
          done("PDF changed while reading metadata; reload the preview")
          return
        end
        local pages = tonumber((result.stdout or ""):match("Pages:%s+(%d+)"))
        if not pages or pages < 1 then
          done("Cannot determine PDF page count")
          return
        end
        local result_info = { pages = pages, key = key }
        if page then
          local width, height = (result.stdout or ""):match("Page%s+%d+%s+size:%s+([%d.]+)%s+x%s+([%d.]+)%s+pts")
          if not width then
            width, height = (result.stdout or ""):match("Page size:%s+([%d.]+)%s+x%s+([%d.]+)%s+pts")
          end
          width, height = tonumber(width), tonumber(height)
          -- ImageMagick reads the MediaBox; pdfinfo's Page size may use a smaller CropBox.
          local x1, y1, x2, y2 = (result.stdout or ""):match(
            "MediaBox:%s+([%d.-]+)%s+([%d.-]+)%s+([%d.-]+)%s+([%d.-]+)"
          )
          if x1 then
            width, height = math.abs(tonumber(x2) - tonumber(x1)), math.abs(tonumber(y2) - tonumber(y1))
          end
          if not width or not height or width <= 0 or height <= 0 or width >= math.huge or height >= math.huge then
            done("Cannot determine PDF page dimensions")
            return
          end
          local rotation = tonumber(
            (result.stdout or ""):match("Page%s+%d+%s+rot:%s+(-?%d+)")
              or (result.stdout or ""):match("Page rot:%s+(-?%d+)")
          ) or 0
          if rotation % 180 ~= 0 then
            width, height = height, width
          end
          result_info.width, result_info.height = width, height
        end
        done(nil, result_info)
      end)
    )
  end)
  return function()
    cancelled = true
    if job then
      job:kill(SIGTERM)
    end
  end
end
function M.info(path, opts, callback)
  return info(path, opts, callback)
end

-- Cache only source-versioned page dimensions, never a caller's cancellation state.
function M.page_size(path, opts, callback)
  local stat = vim.uv.fs_stat(path)
  local key = stat
    and table.concat(
      { opts.pdfinfo or "pdfinfo", require("image_tools.media.file_version").key(path, stat), opts.page or 1 },
      ":"
    )
  if key and stat.size <= opts.max_bytes and size_cache[key] then
    local cancelled = false
    vim.schedule(function()
      if not cancelled then
        callback(nil, vim.deepcopy(size_cache[key]))
      end
    end)
    return function()
      cancelled = true
    end
  end
  return info(path, opts, function(err, size)
    if not err and key then
      if not size_cache[key] then
        size_keys[#size_keys + 1] = key
        if #size_keys > 128 then
          size_cache[table.remove(size_keys, 1)] = nil
        end
      end
      size_cache[key] = vim.deepcopy(size)
    end
    callback(err, size)
  end, opts.page or 1)
end
return M

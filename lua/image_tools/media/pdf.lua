-- Module: image_tools.media.pdf
--
-- Purpose:
--   Read PDF page counts and source revision metadata for file-buffer viewing.
--
-- Architecture:
--   Run pdfinfo asynchronously with the configured timeout and validate the
--   source version before returning metadata. Page rasterization is handled
--   separately by media/convert.
--
-- Ownership:
--   Each request owns one process and cancellation flag. The file-buffer
--   controller owns the resulting page state; metadata reads bypass the
--   converter queue.

local M = {}

function M.info(path, opts, callback)
  local cancelled, job = false, nil
  local function done(err, info)
    if not cancelled then
      callback(err, info)
    end
  end
  vim.schedule(function()
    if cancelled then
      return
    end
    local image = require("image_tools.image")
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
      done("pdfinfo is required for PDF buffer previews (brew install poppler)")
      return
    end
    local key = image.key(path, stat)
    job = vim.system(
      { executable, path },
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
        done(nil, { pages = pages, key = key })
      end)
    )
  end)
  return function()
    cancelled = true
    if job then
      job:kill(15)
    end
  end
end
return M

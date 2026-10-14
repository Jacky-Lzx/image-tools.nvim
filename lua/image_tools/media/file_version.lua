-- Module: image_tools.media.file_version
--
-- Purpose:
--   Build revision keys for source files and prepared PNGs.
--
-- Architecture:
--   Combine the supplied path, inode, size and nanosecond mtime/ctime. Media
--   readers, converters, imports and terminal caches use the key to detect
--   changes and distinguish revisions.
--
-- Ownership:
--   Keep no filesystem cache and perform no stat calls; the caller supplies the
--   file metadata snapshot.

local M = {}

-- Combine file identity and high-resolution timestamps so changed files cannot reuse old pixels.
---@param path string Path or logical file identity.
---@param stat table Stat snapshot with size, ino, mtime and ctime.
---@return string key
function M.key(path, stat)
  return table.concat(
    { path, stat.size, stat.ino, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec },
    ":"
  )
end

return M

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

function M.key(path, stat)
  return table.concat(
    { path, stat.size, stat.ino, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec },
    ":"
  )
end

return M

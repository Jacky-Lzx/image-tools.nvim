local M = {}

function M.key(path, stat)
  return table.concat(
    { path, stat.size, stat.ino, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec },
    ":"
  )
end

return M

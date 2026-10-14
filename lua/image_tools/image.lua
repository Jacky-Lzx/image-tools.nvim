local M = {}

function M.supported(path)
  return require("image_tools.media.formats").supported(path)
end
function M.info(data, opts)
  return require("image_tools.media.png").info(data, opts)
end
function M.key(path, stat)
  return require("image_tools.media.file_version").key(path, stat)
end
function M.read(path, opts, callback, metadata_only)
  return require("image_tools.media.png").read(path, opts, callback, metadata_only)
end
function M.prepare(path, opts, callback)
  local request = require("image_tools.media.prepare").request(path, opts, callback)
  -- Preserve the existing cancellation function, which also releases resources.
  return request.close
end

return M

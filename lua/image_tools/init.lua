local M = {}
local instance

local function runtime()
  if not instance then
    M.setup()
  end
  return instance
end

function M.setup(opts)
  local options = require("image_tools.config").resolve(opts)
  local replacement = require("image_tools.runtime").new(options)
  if instance then
    instance:destroy()
  end
  instance = replacement
  local ok, err = pcall(replacement.start, replacement)
  if not ok then
    replacement:destroy()
    instance = nil
    error(err, 0)
  end
end

function M.close()
  if instance then
    instance:close()
  end
end
function M.clear_cache()
  if instance then
    instance:clear_cache()
  elseif package.loaded["image_tools.picker"] then
    require("image_tools.picker").clear_all()
  end
end
function M.clear_disk_cache(callback)
  return runtime():clear_disk_cache(callback)
end

function M.status()
  return instance and instance:status() or { configured = false, auto_preview = false, transport = "auto" }
end

function M.preview(path, opts)
  return runtime():open_preview(path, opts)
end

function M.insert(paths, opts, callback)
  return runtime():insert(paths, opts, callback)
end

function M.paste(opts, callback)
  return runtime():paste(opts, callback)
end

function M.snacks_preview(ctx)
  return runtime():snacks_preview(ctx)
end

function M.pick(opts, callback)
  return runtime():pick(opts, callback)
end

function M.open(path)
  return runtime():open(path)
end

function M.page(page)
  return runtime():page(page)
end

function M.next_page(delta)
  return runtime():next_page(delta)
end

function M.reload()
  return runtime():reload()
end

function M.hover(opts)
  return runtime():hover(opts)
end

function M.toggle()
  return runtime():toggle()
end

return M

local M = {}
local uv, managers = vim.uv, {}
local defaults = { enabled = true, max_bytes = 512 * 1024 * 1024, max_files = 256 }
local function canonical(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local current, suffix = path, {}
  while true do
    local resolved = uv.fs_realpath(current)
    if resolved then
      return vim.fs.normalize(resolved .. "/" .. table.concat(suffix, "/"))
    end
    local parent = vim.fs.dirname(current)
    if not parent or parent == current then
      return path
    end
    table.insert(suffix, 1, vim.fs.basename(current))
    current = parent
  end
end
local function managed(name)
  return #name == 68 and name:match("^%x+%.png$") ~= nil
end
local function get(opts)
  local root = canonical(opts.cache)
  local manager = managers[root]
  if not manager then
    manager = { root = root, pins = {}, used = {}, deleting = {}, waiting = {}, callbacks = {} }
    managers[root] = manager
  end
  manager.limits = vim.tbl_extend("force", defaults, opts.disk_cache or {})
  return manager
end
local schedule, run
local function finish(manager, status, callbacks)
  manager.running = false
  manager.scanned = true
  manager.deferred = status.files > manager.limits.max_files or status.bytes > manager.limits.max_bytes
  for _, callback in ipairs(callbacks) do
    vim.schedule(function()
      callback(status)
    end)
  end
  if manager.requested then
    schedule(manager)
  end
end
run = function(manager)
  manager.running, manager.requested = true, false
  local force, callbacks = manager.force, manager.callbacks
  manager.force, manager.callbacks = nil, {}
  local files, status = {}, { files = 0, bytes = 0, removed = 0, removed_bytes = 0, protected = 0 }
  local function evict()
    table.sort(files, function(a, b)
      return a.used < b.used or a.used == b.used and a.path < b.path
    end)
    local index = 0
    local function next_file()
      index = index + 1
      local file = files[index]
      if not file then
        finish(manager, status, callbacks)
        return
      end
      if manager.pins[file.path] then
        status.protected = status.protected + 1
        vim.schedule(next_file)
        return
      end
      if
        not force
        and (
          not manager.limits.enabled
          or status.files <= manager.limits.max_files and status.bytes <= manager.limits.max_bytes
        )
      then
        vim.schedule(next_file)
        return
      end
      manager.deleting[file.path] = true
      uv.fs_unlink(
        file.path,
        vim.schedule_wrap(function(err)
          manager.deleting[file.path] = nil
          if not err then
            status.files, status.bytes = status.files - 1, status.bytes - file.size
            status.removed, status.removed_bytes = status.removed + 1, status.removed_bytes + file.size
            manager.used[file.path] = nil
          else
            status.error = tostring(err)
          end
          local waiting = manager.waiting[file.path] or {}
          manager.waiting[file.path] = nil
          for _, ready in ipairs(waiting) do
            ready()
          end
          next_file()
        end)
      )
    end
    next_file()
  end
  uv.fs_scandir(
    manager.root,
    vim.schedule_wrap(function(err, directory)
      if err then
        if not tostring(err):find("ENOENT", 1, true) then
          status.error = tostring(err)
        end
        finish(manager, status, callbacks)
        return
      end
      local function batch()
        local pending, ended = 0, false
        local function proceed()
          if ended then
            evict()
          else
            vim.schedule(batch)
          end
        end
        for _ = 1, 64 do
          local name, kind = uv.fs_scandir_next(directory)
          if not name then
            ended = true
            break
          end
          if managed(name) and (not kind or kind == "file") then
            pending = pending + 1
            local path = manager.root .. "/" .. name
            uv.fs_lstat(path, function(_, stat)
              if stat and stat.type == "file" then
                files[#files + 1] = { path = path, size = stat.size, used = manager.used[path] or stat.mtime.sec }
                status.files, status.bytes = status.files + 1, status.bytes + stat.size
              end
              pending = pending - 1
              if pending == 0 then
                vim.schedule(proceed)
              end
            end)
          end
        end
        if pending == 0 then
          proceed()
        end
      end
      batch()
    end)
  )
end
schedule = function(manager, force, callback)
  if force then
    manager.force = true
  end
  if callback then
    manager.callbacks[#manager.callbacks + 1] = callback
  end
  manager.requested = true
  if manager.running or manager.scheduled then
    return
  end
  manager.scheduled = true
  vim.schedule(function()
    manager.scheduled = false
    run(manager)
  end)
end
function M.owns(opts, path)
  return opts.cache and managed(vim.fs.basename(path)) and canonical(vim.fs.dirname(path)) == canonical(opts.cache)
end
function M.acquire(opts, path, ready)
  local manager = get(opts)
  path = manager.root .. "/" .. vim.fs.basename(path)
  manager.pins[path] = (manager.pins[path] or 0) + 1
  local sec, usec = uv.gettimeofday()
  manager.used[path] = sec + usec / 1e6
  local active = true
  local function deliver()
    if active then
      ready()
    end
  end
  if manager.deleting[path] then
    manager.waiting[path] = manager.waiting[path] or {}
    table.insert(manager.waiting[path], deliver)
  else
    deliver()
  end
  if manager.limits.enabled and not manager.scanned then
    schedule(manager)
  end
  return function()
    if not active then
      return
    end
    active = false
    manager.pins[path] = manager.pins[path] - 1
    if manager.pins[path] == 0 then
      manager.pins[path] = nil
      uv.fs_lstat(path, function(_, stat)
        if not stat and not manager.pins[path] then
          manager.used[path] = nil
        end
      end)
    end
    if manager.limits.enabled and manager.deferred then
      schedule(manager)
    end
  end
end
function M.published(opts, path)
  local manager = get(opts)
  local sec, usec = uv.gettimeofday()
  manager.used[manager.root .. "/" .. vim.fs.basename(path)] = sec + usec / 1e6
  if manager.limits.enabled then
    schedule(manager)
  end
end
function M.prune(opts, callback)
  schedule(get(opts), false, callback)
end
function M.clear(opts, callback)
  schedule(get(opts), true, callback)
end
return M

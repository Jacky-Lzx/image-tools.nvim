-- Module: image_tools.media.disk_cache
--
-- Purpose:
--   Manage converted-file leases, bounded eviction and read-only usage
--   inspection.
--
-- Architecture:
--   Share managers by canonical cache directory. Scan managed hash-named PNGs
--   asynchronously, evict unused files in access order and coordinate readers
--   with in-flight deletions.
--
-- Ownership:
--   Own process-scoped pins, access records and cleanup state. Active leases
--   protect files; clear removes unused outputs, while inspect leaves directory
--   contents and access order unchanged.

---@class ImageToolsDiskCleanupStatus
---@field files integer Managed file count remaining after this sweep.
---@field bytes integer Compressed bytes remaining after successful removals.
---@field removed integer Files removed by this sweep.
---@field removed_bytes integer Compressed bytes removed by this sweep.
---@field ["protected"] integer Managed files skipped because a lease still pins them.
---@field error? string Last scan/deletion error; missing cache directories are not errors.
---@class ImageToolsDiskInspection
---@field path string Canonical cache directory.
---@field enabled boolean Configured automatic eviction policy.
---@field max_files integer Configured retained-file limit.
---@field max_bytes integer Configured compressed-byte limit.
---@field files integer Managed regular files currently found.
---@field bytes integer Their compressed bytes.
---@field ["protected"] integer Existing managed files currently pinned.
---@field protected_bytes integer Compressed bytes of pinned files.
---@field exists boolean False for a missing cache directory.
---@field cleanup_running boolean Whether this directory has a running or scheduled sweep.
---@field error? string Inspection error; usage may be partial when present.
---@class ImageToolsDiskManager
---@field root string Canonical cache directory shared by all matching callers.
---@field limits table Current effective enabled/max_files/max_bytes settings.
---@field pins table<string, integer> Reference-counted protection by canonical output path.
---@field used table<string, number> In-memory access timestamps; filesystem mtime supplies cold ordering.
---@field deleting table<string, boolean> Files whose asynchronous unlink is in flight.
---@field waiting table<string, function[]> Readers deferred until unlink completion.
---@field callbacks function[] Completion callbacks queued for a sweep; each receives cleanup status.
---@field running? boolean Sweep currently active.
---@field scheduled? boolean Sweep queued on the main event loop.
---@field requested? boolean Another cleanup was requested during the current sweep.
---@field scanned? boolean At least one cleanup scan completed.
---@field deferred? boolean Remaining files exceed limits, often because they are pinned.
---@field force? boolean Next sweep removes every unused output instead of only excess files.

---@class ImageToolsDiskCache
local M = {}
local uv, managers = vim.uv, {}
local defaults = { enabled = true, max_bytes = 512 * 1024 * 1024, max_files = 256 }
-- Resolve existing ancestors and append missing suffixes so aliases share one cache manager.
---@param path string Cache directory or containing path.
---@return string canonical Normalized absolute identity without creating directories.
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

-- Accept only the plugin hash-PNG basename shape; content and ownership are checked elsewhere.
---@param name string Directory entry basename.
---@return boolean managed
local function managed(name)
  return #name == 68 and name:match("^%x+%.png$") ~= nil
end

-- Read-only batched traversal shared by eviction and health diagnostics.
-- Read managed regular-file metadata in 64-entry asynchronous batches, excluding symbolic links.
---@param root string Directory to inspect.
---@param receive fun(path: string, stat: table) Called for each eligible regular file.
---@param callback fun(err: string?) Called after batches finish, unless cancelled.
---@return ImageToolsCancel cancel Suppress further receive/completion delivery.
local function scan(root, receive, callback)
  local cancelled = false
  uv.fs_scandir(
    root,
    vim.schedule_wrap(function(err, directory)
      if cancelled then
        return
      end
      if err then
        callback(err)
        return
      end
      local stat_error
      -- Launch at most 64 entry-stat requests per event-loop batch so directory inspection does
      -- not monopolize the UI.
      ---@return nil
      local function batch()
        if cancelled then
          return
        end
        local pending, ended = 0, false
        -- Advance directory scanning only after all stat callbacks in the current batch complete.
        ---@return nil
        local function proceed()
          if cancelled then
            return
          end
          if ended then
            callback(stat_error)
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
            local path = root .. "/" .. name
            uv.fs_lstat(path, function(read_err, stat)
              if cancelled then
                return
              end
              if read_err and not tostring(read_err):find("ENOENT", 1, true) then
                stat_error = read_err
              end
              if stat and stat.type == "file" then
                receive(path, stat)
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
  return function()
    cancelled = true
  end
end

-- Find/create a directory manager and refresh its effective eviction policy.
---@param opts table cache directory and optional disk_cache overrides.
---@return ImageToolsDiskManager manager
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
-- Publish cleanup status, remember over-budget state and schedule any newly requested sweep.
---@param manager ImageToolsDiskManager Directory state.
---@param status ImageToolsDiskCleanupStatus Completed sweep snapshot.
---@param callbacks function[] Consumers captured for this sweep.
---@return nil
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

-- Run one directory sweep; capture pending force/callback state before asynchronous traversal.
---@param manager ImageToolsDiskManager
---@return nil
run = function(manager)
  manager.running, manager.requested = true, false
  local force, callbacks = manager.force, manager.callbacks
  manager.force, manager.callbacks = nil, {}
  local files, status = {}, { files = 0, bytes = 0, removed = 0, removed_bytes = 0, protected = 0 }
  -- Remove unused outputs in access order while preserving pins and accounting only successful
  -- deletions.
  ---@return nil
  local function evict()
    table.sort(files, function(a, b)
      return a.used < b.used or a.used == b.used and a.path < b.path
    end)
    local index = 0
    -- Skip protected outputs and unlink eligible files sequentially; wake readers after deletion
    -- completes.
    ---@return nil
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
  scan(manager.root, function(path, stat)
    files[#files + 1] = { path = path, size = stat.size, used = manager.used[path] or stat.mtime.sec }
    status.files, status.bytes = status.files + 1, status.bytes + stat.size
  end, function(err)
    if err then
      if not tostring(err):find("ENOENT", 1, true) then
        status.error = tostring(err)
      end
      finish(manager, status, callbacks)
    else
      evict()
    end
  end)
end

-- Coalesce cleanup requests while retaining forced clearing and all completion consumers.
---@param manager ImageToolsDiskManager
---@param force? boolean Remove all unused files on the next sweep.
---@param callback? fun(status: ImageToolsDiskCleanupStatus)
---@return nil
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

-- Check managed filename shape and canonical containing directory without reading image content.
---@param opts table Configured cache path.
---@param path string Candidate PNG path.
---@return boolean? owned Nil when opts.cache is absent.
function M.owns(opts, path)
  return opts.cache and managed(vim.fs.basename(path)) and canonical(vim.fs.dirname(path)) == canonical(opts.cache)
end

-- Pin an output and deliver readiness immediately unless a deletion is already in flight.
---@param opts table Cache directory and eviction policy.
---@param path string Managed output path; basename is joined to canonical cache root.
---@param ready fun() Start the reader/worker once deletion coordination permits.
---@return ImageToolsCancel release Idempotently remove this pin and resume deferred cleanup when eligible.
function M.acquire(opts, path, ready)
  local manager = get(opts)
  path = manager.root .. "/" .. vim.fs.basename(path)
  manager.pins[path] = (manager.pins[path] or 0) + 1
  local sec, usec = uv.gettimeofday()
  manager.used[path] = sec + usec / 1e6
  local active = true
  -- Run the ready callback only while this reader lease remains active.
  ---@return nil
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

-- Record newly published output access and request automatic cleanup when enabled.
---@param opts table Cache directory/settings.
---@param path string Validated published PNG path.
---@return nil
function M.published(opts, path)
  local manager = get(opts)
  local sec, usec = uv.gettimeofday()
  manager.used[manager.root .. "/" .. vim.fs.basename(path)] = sec + usec / 1e6
  if manager.limits.enabled then
    schedule(manager)
  end
end

-- Schedule policy-driven unused-file eviction, coalescing with existing directory cleanup.
---@param opts table Cache directory/settings.
---@param callback? fun(status: ImageToolsDiskCleanupStatus) Receives the completed sweep.
---@return nil
function M.prune(opts, callback)
  schedule(get(opts), false, callback)
end

-- Schedule removal of every unused managed output, even when automatic eviction is disabled.
---@param opts table Cache directory/settings.
---@param callback? fun(status: ImageToolsDiskCleanupStatus) Reports removals and protected files.
---@return nil
function M.clear(opts, callback)
  schedule(get(opts), true, callback)
end

-- Inspection never creates a manager, changes access order or triggers eviction.
-- Report usage/pins without creating a manager, changing access order or deleting files.
---@param opts table Cache directory/settings.
---@param callback fun(status: ImageToolsDiskInspection) Includes missing-directory and scan-error diagnostics.
---@return ImageToolsCancel cancel Suppress unfinished inspection callbacks.
function M.inspect(opts, callback)
  local root = canonical(opts.cache)
  local limits = vim.tbl_extend("force", defaults, opts.disk_cache or {})
  local manager = managers[root]
  local status = {
    path = root,
    enabled = limits.enabled,
    max_files = limits.max_files,
    max_bytes = limits.max_bytes,
    files = 0,
    bytes = 0,
    protected = 0,
    protected_bytes = 0,
    exists = true,
  }
  return scan(root, function(path, stat)
    status.files, status.bytes = status.files + 1, status.bytes + stat.size
    if manager and manager.pins[path] then
      status.protected, status.protected_bytes = status.protected + 1, status.protected_bytes + stat.size
    end
  end, function(err)
    if err then
      if tostring(err):find("ENOENT", 1, true) then
        status.exists = false
      else
        status.error = tostring(err)
      end
    end
    status.cleanup_running = manager and (manager.running or manager.scheduled) or false
    callback(status)
  end)
end
return M

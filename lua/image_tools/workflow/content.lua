-- Module: image_tools.workflow.content
--
-- Purpose:
--   Find byte-identical imports without hashing image bytes on the editor thread.
-- Architecture:
--   Share revision-keyed background hash workers through the process queue and
--   retain a bounded LRU of digests. Filter candidates by extension and size.
-- Ownership:
--   Subscribers cancel independently; the last cancellation stops queued/running
--   work. Workers own all file bytes; callbacks recheck revisions before delivery.
local M = {}
local uv = vim.uv
local version = require("image_tools.media.file_version")

-- Keep only digest metadata. Cache hits still validate the live file revision.
local cache, pending, clock, hits, workers = {}, {}, 0, 0, 0
local CACHE_LIMIT = 128
local worker = vim.fn.fnamemodify(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/hash_worker.lua", ":p")
local queue = require("image_tools.media.conversion_queue")

local function remember(path, key, hash)
  clock = clock + 1
  cache[path] = { key = key, hash = hash, used = clock }
  local count, oldest = 0, nil
  for name, entry in pairs(cache) do
    count = count + 1
    if not oldest or entry.used < cache[oldest].used then
      oldest = name
    end
  end
  if count > CACHE_LIMIT then
    cache[oldest] = nil
  end
end

-- Hash in an isolated Neovim process, with no user configuration or extra tools.
-- Requests for one revision share a worker and retain independent cancellation.
---@param path string Source path.
---@param max_bytes integer Maximum source size, also enforced for cache hits.
---@param callback fun(err: string?, digest: string?, stat: table?) Always delivered asynchronously unless cancelled.
---@return ImageToolsCancel cancel Cancels only this subscriber; the last owner stops the worker.
function M.digest(path, max_bytes, callback)
  local subscriber, request = { active = true, callback = callback }, nil
  uv.fs_stat(
    path,
    vim.schedule_wrap(function(err, stat)
      if not subscriber.active then
        return
      end
      if err or stat.type ~= "file" or stat.size > max_bytes then
        subscriber.active = false
        callback(err or "File is not regular or exceeds max_bytes")
        return
      end
      local key = version.key(path, stat)
      local cached = cache[path]
      if cached and cached.key == key then
        hits, clock = hits + 1, clock + 1
        cached.used = clock
        subscriber.active = false
        callback(nil, cached.hash, stat)
        return
      end
      request = pending[key]
      if request then
        request.subscribers[#request.subscribers + 1] = subscriber
        return
      end
      request = { key = key, subscribers = { subscriber } }
      pending[key] = request
      workers = workers + 1
      request.cancel = queue.run({
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "--noplugin",
        "-l",
        worker,
        path,
        tostring(max_bytes),
      }, { text = true, timeout = 10000 }, function(result)
        uv.fs_stat(
          path,
          vim.schedule_wrap(function(after_err, after)
            if pending[key] ~= request then
              return
            end
            pending[key] = nil
            local hash = vim.trim(result.stdout or "")
            local message
            if result.code ~= 0 then
              message = "Cannot hash image: " .. vim.trim(result.stderr or "worker failed")
            elseif after_err or version.key(path, after) ~= key then
              message = "File changed while hashing"
            elseif #hash ~= 64 or not hash:match("^%x+$") then
              message = "Invalid image hash worker response"
            else
              remember(path, key, hash)
            end
            for _, listener in ipairs(request.subscribers) do
              if listener.active then
                listener.active = false
                local ok, delivery_err =
                  pcall(listener.callback, message, not message and hash or nil, not message and after or nil)
                if not ok then
                  vim.schedule(function()
                    error(delivery_err)
                  end)
                end
              end
            end
          end)
        )
      end)
    end)
  )
  return function()
    if not subscriber.active then
      return
    end
    subscriber.active = false
    if request then
      for _, listener in ipairs(request.subscribers) do
        if listener.active then
          return
        end
      end
      if pending[request.key] == request then
        pending[request.key] = nil
      end
      request.cancel()
    end
  end
end

-- Internal counters for benchmarks and lifecycle tests; no pixels/file bytes retained.
function M.status()
  return { entries = vim.tbl_count(cache), pending = vim.tbl_count(pending), hits = hits, workers = workers }
end

function M.find(source, directory, extension, max_bytes, callback)
  local active, cancel_read = true, nil
  local function done(err, path)
    if active then
      callback(err, path)
    end
  end
  cancel_read = M.digest(source, max_bytes, function(err, hash, source_stat)
    if err then
      done(err)
      return
    end
    uv.fs_scandir(directory, function(scan_err, scan)
      vim.schedule(function()
        if not active then
          return
        end
        if scan_err then
          done(scan_err)
          return
        end
        local next_file
        next_file = function()
          if not active then
            return
          end
          local name = uv.fs_scandir_next(scan)
          if not name then
            done(nil)
            return
          end
          local path = directory .. "/" .. name
          if require("image_tools.media.formats").extension(path) ~= extension:lower() then
            vim.schedule(next_file)
            return
          end
          uv.fs_lstat(path, function(stat_err, stat)
            vim.schedule(function()
              if not active then
                return
              end
              if stat_err or stat.type ~= "file" or stat.size ~= source_stat.size then
                next_file()
                return
              end
              cancel_read = M.digest(path, max_bytes, function(_, candidate_hash)
                if candidate_hash == hash then
                  done(nil, path)
                else
                  next_file()
                end
              end)
            end)
          end)
        end
        next_file()
      end)
    end)
  end)
  return function()
    active = false
    if cancel_read then
      cancel_read()
    end
  end
end
return M

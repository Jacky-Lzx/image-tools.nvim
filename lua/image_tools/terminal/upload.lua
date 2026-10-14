-- Module: image_tools.terminal.upload
--
-- Purpose:
--   Upload versioned pixels and retain inactive terminal images in an LRU
--   cache.
--
-- Architecture:
--   Use terminal I/O and protocol encoding for file/direct transmission with
--   acknowledgement and auto fallback. Expose readiness to pixel_pool; do not
--   create or hide placements.
--
-- Ownership:
--   Each uploader owns pixel entries, pin state and counters; image ids come
--   from a process-scoped allocator. Cancellation releases uploads/reads, and
--   cache limits evict only inactive retained entries.

-- Logical dependency keys remain stable across module directory changes.
local dependency_modules = {
  protocol = "image_tools.terminal.protocol",
}

local M = {}
M.__index = M
local next_id = math.floor(vim.uv.hrtime() % 0xEFFFFF) + 0x100000

local function allocate_id()
  next_id = (next_id % 0xFFFFFF) + 1
  return next_id
end

function M.new(opts, dependencies)
  return setmetatable(
    { opts = opts, dependencies = dependencies or {}, entries = {}, clock = 0, hits = 0, uploads = 0, last_error = nil },
    M
  )
end

function M:dependency(name)
  return self.dependencies[name] or require(dependency_modules[name] or ("image_tools." .. name))
end

function M:discard(entry)
  if self.entries[entry.key] == entry then
    self.entries[entry.key] = nil
  end
  self:dependency("terminal").write(self:dependency("protocol").delete(entry.id))
end

function M:trim()
  local count, bytes = 0, 0
  for _, entry in pairs(self.entries) do
    if entry.cacheable then
      count, bytes = count + 1, bytes + entry.bytes
    end
  end

  local limits = self.opts.terminal_cache or { max_images = 32, max_bytes = 64 * 1024 * 1024 }
  while count > limits.max_images or bytes > limits.max_bytes do
    local oldest
    for _, entry in pairs(self.entries) do
      if entry.cacheable and not entry.pinned and (not oldest or entry.used < oldest.used) then
        oldest = entry
      end
    end
    if not oldest then
      break
    end
    count, bytes = count - 1, bytes - oldest.bytes
    self:discard(oldest)
  end
end

function M:clear()
  for _, entry in pairs(vim.tbl_extend("force", {}, self.entries)) do
    if entry.cancel then
      entry.cancel()
    end
    if self.entries[entry.key] == entry then
      self:discard(entry)
    end
  end
end

function M:status()
  local images, bytes = 0, 0
  for _, entry in pairs(self.entries) do
    if entry.uploaded then
      images, bytes = images + 1, bytes + entry.bytes
    end
  end

  return {
    images = images,
    bytes = bytes,
    hits = self.hits,
    uploads = self.uploads,
    last_transport = self.last_transport,
    last_error = self.last_error,
  }
end

-- Inspect cache readiness without exposing entry storage to placement owners.
function M:cached(key)
  return self.entries[key] ~= nil and self.entries[key].uploaded == true
end

function M:acquire(image, callback)
  local terminal, protocol = self:dependency("terminal"), self:dependency("protocol")
  local key = image.key or vim.fn.sha256((image.path or "") .. (image.data or ""))
  local source = image.cache_source or image.source or image.path
  -- Drop obsolete versions of the same file, rather than filling the cache
  -- with every edit. The active image is released before the next acquire.
  for _, old in pairs(vim.tbl_extend("force", {}, self.entries)) do
    if source and old.source == source and old.key ~= key and not old.pinned then
      self:discard(old)
    end
  end
  local entry = self.entries[key]
  local cached = entry and entry.uploaded
  if not entry then
    local limits = self.opts.terminal_cache or { max_images = 32, max_bytes = 64 * 1024 * 1024 }
    local bytes = image.width * image.height * 4 -- conservative decoded RGBA estimate
    entry = {
      key = key,
      id = allocate_id(),
      path = image.path,
      source = source,
      bytes = bytes,
      cacheable = limits.max_images > 0 and bytes <= limits.max_bytes,
    }
    self.entries[key] = entry
  end
  self.clock = self.clock + 1
  entry.used, entry.pinned = self.clock, true
  self:trim()
  local active, completed, cancel_request, cancel_read = true, false, nil, nil
  local function cancel()
    if not active then
      return
    end
    active = false
    if cancel_request then
      cancel_request()
    end
    if cancel_read then
      cancel_read()
    end
    entry.cancel, entry.pinned = nil, false
    if completed and entry.uploaded and entry.cacheable then
      self:trim()
    else
      self:discard(entry)
    end
  end
  entry.cancel = cancel
  local function fail(err)
    self.last_error = err
    cancel()
    callback(err)
  end
  local function request(command, continuation)
    local done = false
    local cancellation = terminal.request(entry.id, command, self.opts.terminal_timeout or 1500, function(err)
      done = true
      cancel_request = nil
      if active then
        continuation(err)
      end
    end)
    if not done then
      cancel_request = cancellation
    end
  end
  local upload
  local function ready()
    completed = true
    self.last_error = nil
    callback(nil, entry)
  end
  upload = function(force_direct)
    local mode = self.opts.transport or "auto"
    local remote = (vim.env.SSH_CONNECTION or "") ~= "" or (vim.env.SSH_TTY or "") ~= ""
    local use_file = image.path
      and not force_direct
      and mode ~= "direct"
      and (mode == "file" or not remote)
      and not (mode == "auto" and entry.transport == "direct")
    local function send(data)
      if not active then
        return
      end
      self.uploads = self.uploads + 1
      local command = use_file and protocol.upload_file(entry.id, image.path) or protocol.upload(entry.id, data, 0)
      request(command, function(err)
        if err then
          if use_file and mode == "auto" then
            terminal.write(protocol.delete(entry.id))
            entry.id = allocate_id()
            upload(true)
          else
            fail(err)
          end
          return
        end
        entry.uploaded = true
        self.last_transport = use_file and "file" or "direct"
        entry.transport = self.last_transport
        ready()
      end)
    end
    if use_file then
      send()
    elseif image.data then
      send(image.data)
    else
      cancel_read = self:dependency("image").read(image.path, self.opts, function(err, loaded)
        cancel_read = nil
        if not active then
          return
        end
        if err then
          fail(err)
        elseif loaded.key ~= image.key then
          fail("Image file changed before direct transmission; retry the preview")
        else
          send(loaded.data)
        end
      end)
    end
  end
  if cached then
    ready()
  else
    upload()
  end
  return cancel
end

return M

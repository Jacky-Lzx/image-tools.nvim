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
  image = "image_tools.media",
  protocol = "image_tools.terminal.protocol",
}

---@alias ImageToolsUploadCancel fun()

---@class ImageToolsUploadImage
---@field width integer Prepared PNG width in pixels.
---@field height integer Prepared PNG height in pixels.
---@field key? string Prepared PNG revision key; acquire derives a fallback when absent.
---@field path? string Prepared PNG file; either path or data must be available for a new upload.
---@field data? string Complete PNG bytes for direct transmission; metadata-only preparation omits them.
---@field source? string Original image file path, before conversion.
---@field cache_source? string Logical source override, such as a PDF path with a page suffix.

---@class ImageToolsUploadEntry
---@field key string Prepared PNG revision key, or a hash of image path/data when image.key is absent.
---@field id integer Kitty image id; a failed file upload may replace it before a direct retry.
---@field path? string Prepared PNG path for file transfer or a deferred read; absent for in-memory images.
---@field source? string Logical source identity for old-version eviction; PDF pages use path#page=N.
---@field bytes integer Estimated decoded RGBA size (width * height * 4), not compressed file size or measured GPU usage.
---@field cacheable boolean Whether a successful upload may be retained after release under terminal_cache limits.
---@field used? integer Last acquisition's increasing LRU sequence number; lower values are older.
---@field pinned? boolean Whether an upload/use lease protects this entry from ordinary LRU eviction; not a view count.
---@field uploaded? boolean True after a successful upload acknowledgement; absent before acknowledgement.
---@field transport? "file"|"direct" Transport used by the successful upload; absent until it succeeds.
---@field cancel? ImageToolsUploadCancel Current lease cleanup: cancel pending I/O, unpin, and retain or discard the entry.

---@alias ImageToolsUploadCallback fun(err: string?, entry: ImageToolsUploadEntry?)

---@class ImageToolsUploadStatus
---@field images integer Number of tracked entries with acknowledged uploads.
---@field bytes integer Total estimated decoded RGBA bytes of those uploaded entries.
---@field hits integer Legacy uploader reuse counter; pixel_pool adds its own hits separately.
---@field uploads integer Upload attempts since construction, including failures and fallbacks.
---@field last_transport? "file"|"direct" Most recent successful upload transport.
---@field last_error? string Most recent reported upload/read error, if not cleared by readiness.

-- Entries cover pending uploads, active leases and inactive cached images.
-- pixel_pool shares one upload lease across views and releases it after the last
-- consumer leaves. A released, successfully uploaded, cacheable entry stays in
-- entries until eviction/clearing; the table stores metadata, not PNG bytes.
---@class ImageToolsUploader
---@field opts table Configuration for transport, terminal cache, response timeout and PNG validation.
---@field dependencies table<string, table> Injected module overrides, addressed by logical dependency names.
---@field entries table<string, ImageToolsUploadEntry> Managed images indexed by their prepared-image revision key.
---@field clock integer Increasing acquisition sequence used by entry.used for LRU ordering; starts at zero.
---@field hits integer Legacy uploader hit counter; currently stays zero because pixel_pool counts reuse.
---@field uploads integer Upload attempts since construction, including failed attempts and direct fallbacks.
---@field last_transport? "file"|"direct" Most recent successful upload transport; absent before the first success.
---@field last_error? string Most recent reported upload/read error; cleared when acquire delivers a ready entry.
local M = {}
M.__index = M
local next_id = math.floor(vim.uv.hrtime() % 0xEFFFFF) + 0x100000

-- Allocate the next process-scoped, nonzero 24-bit Kitty image id.
---@return integer id
local function allocate_id()
  next_id = (next_id % 0xFFFFFF) + 1
  return next_id
end

-- Construct an uploader without starting uploads or registering terminal requests.
---@param opts table
---@param dependencies? table<string, table>
---@return ImageToolsUploader
function M.new(opts, dependencies)
  return setmetatable(
    { opts = opts, dependencies = dependencies or {}, entries = {}, clock = 0, hits = 0, uploads = 0, last_error = nil },
    M
  )
end

-- Resolve an injected module first, then load its default implementation.
---@param name string Logical dependency name, such as terminal, protocol or image.
---@return table module
function M:dependency(name)
  return self.dependencies[name] or require(dependency_modules[name] or ("image_tools." .. name))
end

-- Remove the local entry and send terminal deletion without waiting for a reply.
---@param entry ImageToolsUploadEntry
---@return nil
function M:discard(entry)
  if self.entries[entry.key] == entry then
    self.entries[entry.key] = nil
  end
  self:dependency("terminal").write(self:dependency("protocol").delete(entry.id))
end

-- Evict inactive LRU entries until cache limits are met or only pinned entries remain.
---@return nil
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

-- Cancel active leases and discard the remaining tracked terminal images.
---@return nil
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

-- Snapshot acknowledged image usage and uploader counters without changing state.
---@return ImageToolsUploadStatus status
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
---@param key string Prepared-image revision key.
---@return boolean uploaded Whether this uploader has acknowledged pixels for the key.
function M:cached(key)
  return self.entries[key] ~= nil and self.entries[key].uploaded == true
end

-- Acquire/pin pixels and deliver readiness, synchronously on an acknowledged cache hit.
---@param image ImageToolsUploadImage
---@param callback ImageToolsUploadCallback Receives nil/entry on success or an error without an entry on failure.
---@return ImageToolsUploadCancel cancel Release the lease; pending delivery is suppressed and cacheable pixels may remain.
function M:acquire(image, callback)
  local terminal, protocol = self:dependency("terminal"), self:dependency("protocol")
  local key = image.key or vim.fn.sha256((image.path or "") .. (image.data or ""))
  local source = image.cache_source or image.source or image.path

  -- Drop obsolete versions of the same file, rather than filling the cache
  -- with every edit. The active image is released before the next acquire.
  if source then
    for _, old in pairs(vim.tbl_extend("force", {}, self.entries)) do
      if old.source == source and old.key ~= key and not old.pinned then
        self:discard(old)
      end
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
  -- Release this lease once, cancelling pending terminal requests and PNG reads.
  ---@return nil
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

  -- Record failure, release the lease and report it to the acquire callback.
  ---@param err string
  ---@return nil
  local function fail(err)
    self.last_error = err
    cancel()
    callback(err)
  end

  -- Track one bounded terminal acknowledgement wait for the current image id.
  ---@param command string Encoded Kitty graphics command.
  ---@param continuation fun(err: string?) Receives nil for OK, or a terminal/write/timeout error.
  ---@return nil
  local function request(command, continuation)
    local done = false
    local cancellation = terminal.request(
      entry.id,
      command,
      self.opts.terminal_timeout or 1500,
      ---@param err string?
      ---@return nil
      function(err)
        done = true
        cancel_request = nil
        if active then
          continuation(err)
        end
      end
    )

    if not done then
      cancel_request = cancellation
    end
  end

  ---@type fun(force_direct?: boolean)
  local upload
  -- Deliver the acknowledged entry and clear the previous uploader error.
  ---@return nil
  local function ready()
    completed = true
    self.last_error = nil
    callback(nil, entry)
  end

  -- Choose a transport, reading PNG bytes only if direct transmission needs them.
  ---@param force_direct? boolean Bypass file transfer when retrying an automatic fallback.
  ---@return nil
  upload = function(force_direct)
    local mode = self.opts.transport or "auto"
    local remote = (vim.env.SSH_CONNECTION or "") ~= "" or (vim.env.SSH_TTY or "") ~= ""
    local use_file = image.path
      and not force_direct
      and mode ~= "direct"
      and (mode == "file" or not remote)
      and not (mode == "auto" and entry.transport == "direct")

    -- Send one upload attempt and handle acknowledgement or automatic fallback.
    ---@param data? string PNG bytes for direct transfer; file transfer passes no data.
    ---@return nil
    local function send(data)
      if not active then
        return
      end
      self.uploads = self.uploads + 1

      local command = use_file and protocol.upload_file(entry.id, image.path) or protocol.upload(entry.id, data, 0)
      request(
        command,
        ---@param err string?
        ---@return nil
        function(err)
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
        end
      )
    end

    if use_file then
      send()
    elseif image.data then
      send(image.data)
    else
      cancel_read = self:dependency("image").read(
        image.path,
        self.opts,
        ---@param err string?
        ---@param loaded ImageToolsUploadImage? Complete PNG data on success; absent on a read error.
        ---@return nil
        function(err, loaded)
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
        end
      )
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

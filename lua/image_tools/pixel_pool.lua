local Pool, Handle = {}, {}
Pool.__index, Handle.__index = Pool, Handle
local placement = 0
local function next_placement()
  placement = placement % 0xFFFFFF + 1
  return placement
end
function Pool.new(options, dependencies)
  dependencies = vim.tbl_extend("force", {}, dependencies or {})
  dependencies.pixel_pool = nil
  local master = require("image_tools.transfer").new(options, dependencies)
  master.pixels_only = true
  return setmetatable({ master = master, states = {}, hits = 0 }, Pool)
end
function Pool:manager()
  return setmetatable({ pool = self, leases = {} }, Handle)
end
function Pool:status()
  local status = self.master:status()
  status.hits = status.hits + self.hits
  status.last_error = self.last_error or status.last_error
  status.placements = 0
  for _, state in pairs(self.states) do
    for consumer in pairs(state.consumers) do
      if consumer.placed then
        status.placements = status.placements + 1
      end
    end
  end
  return status
end
function Pool:clear()
  for _, state in pairs(vim.tbl_extend("force", {}, self.states)) do
    for consumer in pairs(vim.tbl_extend("force", {}, state.consumers)) do
      consumer.cancel()
    end
  end
  self.master:clear()
end
function Handle:status()
  return self.pool:status()
end
function Handle:clear()
  for consumer in pairs(vim.tbl_extend("force", {}, self.leases)) do
    consumer.cancel()
  end
end
function Handle:acquire(image, width, height, callback, retried)
  local pool, master = self.pool, self.pool.master
  local terminal, protocol = master:dependency("terminal"), master:dependency("protocol")
  local key = image.key or vim.fn.sha256((image.path or "") .. (image.data or ""))
  local state = pool.states[key]
  local fresh = not state
  if fresh then
    state = { consumers = {}, reused = master.entries[key] and master.entries[key].uploaded }
    pool.states[key] = state
  end
  local consumer = { active = true, placement = next_placement(), shared = not fresh }
  state.consumers[consumer], self.leases[consumer] = true, true
  local replacement
  local function cancel()
    if replacement then
      replacement()
      replacement = nil
    end
    if not consumer.active then
      return
    end
    consumer.active = false
    if consumer.request then
      consumer.request()
      consumer.request = nil
    end
    if consumer.sent and state.pixel then
      terminal.write(protocol.hide(state.pixel.id, consumer.placement))
    end
    state.consumers[consumer], self.leases[consumer] = nil, nil
    if not next(state.consumers) then
      if pool.states[key] == state then
        pool.states[key] = nil
      end
      if state.cancel_upload then
        state.cancel_upload()
      end
    end
  end
  consumer.cancel = cancel
  local function fail(err)
    pool.last_error = err
    cancel()
    callback(err)
  end
  function consumer.ready(err)
    if not consumer.active then
      return
    end
    if err then
      fail(err)
      return
    end
    consumer.sent = true
    local done = false
    local cancellation = terminal.request(
      state.pixel.id,
      protocol.place(state.pixel.id, width, height, 0, consumer.placement),
      master.opts.terminal_timeout or 1500,
      function(place_err)
        done = true
        consumer.request = nil
        if not consumer.active then
          return
        end
        if place_err then
          -- Re-upload only when this consumer is the sole owner. An upload
          -- replaces every placement, so it must never disrupt another view.
          if
            not retried
            and (place_err:match("^ENOENT") or place_err:match("^ETIMEDOUT"))
            and next(state.consumers, consumer) == nil
            and next(state.consumers) == consumer
          then
            cancel()
            master:discard(state.pixel)
            replacement = self:acquire(image, width, height, callback, true)
          else
            fail(place_err)
          end
          return
        end
        consumer.placed = true
        pool.last_error = nil
        if state.reused or consumer.shared then
          pool.hits = pool.hits + 1
        end
        callback(nil, { id = state.pixel.id, placement_id = consumer.placement, cancel = cancel })
      end,
      consumer.placement
    )
    if not done then
      consumer.request = cancellation
    end
  end
  if fresh then
    local cancellation = master:acquire(image, 1, 1, function(err, entry)
      state.pixel = entry
      for waiting in pairs(vim.tbl_extend("force", {}, state.consumers)) do
        waiting.ready(err)
      end
    end)
    state.cancel_upload = cancellation
    if not next(state.consumers) then
      cancellation()
    end
  elseif state.pixel then
    consumer.ready()
  end
  return cancel
end
return Pool

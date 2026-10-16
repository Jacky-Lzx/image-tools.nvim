-- Module: image_tools.render.session
--
-- Purpose:
--   Own the common asynchronous preparation-to-placement lifecycle for one
--   view.
--
-- Architecture:
--   Bridge the media entry point and a transfer manager. Controllers supply
--   authority checks, size, drawing and error callbacks, keeping window policy
--   outside the shared lifecycle.
--
-- Ownership:
--   Track preparation/placement stages and cancellation handles. Close releases
--   handles in reverse order, including handles returned after synchronous
--   closure; stale results cannot draw.

-- One preparation handle and one placement lease, bounded by view authority.
---@class ImageToolsRenderView
---@field current fun(): boolean Caller authority check for owner/source/generation.
---@field stale fun() Caller cleanup when authority is lost.
---@field error fun(err: string) Caller presentation after session resources are released.
---@field size fun(image: ImageToolsImage): integer, integer, table? Placement columns, rows and optional source crop.
---@field draw fun(entry: ImageToolsPlacement, width: integer, height: integer) Called only after acknowledgement.
---@class ImageToolsRenderSession
---@field image table Media dependency providing prepare.
---@field transfer ImageToolsTransfer Placement service.
---@field active boolean False after close; late-returned handles are released immediately.
---@field releases ImageToolsCancel[] Owned cleanup handles, released in reverse acquisition order.
---@field stage? "preparing"|"placing"|"ready" Duplicate-delivery guard; absent before start.
---@field error? string Last failure, retained after releasing resources.
---@field error_stage? string Stage which failed.
---@field measurements table Completed subphase milliseconds, with no per-view timer.
---@field started? number Render-session start in monotonic nanoseconds.
---@field prepared? number Preparation completion in nanoseconds.
---@field transfer_started? number Transfer request start in nanoseconds.
---@field transferred? number Transfer completion in nanoseconds.
---@field finished? number Frozen completion/close timestamp.
local M = {}
M.__index = M
local function elapsed(first, last)
  return math.max(0, last - first) / 1e6
end

-- Create one active prepare/place lifecycle without starting work.
---@param image table Media dependency with prepare.
---@param transfer ImageToolsTransfer View-scoped placement service.
---@param timing? table Optional lookup/automatic-delay milliseconds from reference selection.
---@return ImageToolsRenderSession session
function M.new(image, transfer, timing)
  return setmetatable(
    { image = image, transfer = transfer, active = true, releases = {}, measurements = vim.deepcopy(timing or {}) },
    M
  )
end

-- Snapshot milliseconds without retaining timers. Preparation includes queue,
-- conversion and validation; transfer includes upload waits and placement replies.
---@return table timings Independent snapshot; nested phase totals overlap.
function M:timings()
  local result = vim.deepcopy(self.measurements)
  if not self.started then
    return result
  end
  local now = self.finished or vim.uv.hrtime()
  result.preparation_ms = elapsed(self.started, self.prepared or now)
  if self.transfer_started then
    result.transfer_ms = elapsed(self.transfer_started, self.transferred or now)
  end
  result.total_ms = elapsed(self.started, now) + (result.lookup_ms or 0) + (result.automatic_delay_ms or 0)
  return result
end

-- Retain a cleanup handle, or execute it immediately if synchronous completion already closed the
-- session.
---@param release ImageToolsCancel Resource cleanup function.
---@return nil
function M:keep(release)
  if self.active then
    self.releases[#self.releases + 1] = release
  else
    release()
  end
end

-- Mark inactive before releasing handles in reverse order; repeated close is harmless.
---@return nil
function M:close()
  if not self.active then
    return
  end
  self.active = false
  self.finished = self.finished or vim.uv.hrtime()
  local releases = self.releases
  self.releases = {}
  for i = #releases, 1, -1 do
    releases[i]()
  end
end

-- Prepare pixels, choose placement size and draw only while the caller authority remains current.
---@param path string Source image/PDF path.
---@param opts table Preparation settings, including optional PDF page.
---@param view ImageToolsRenderView Window/source-specific policies and callbacks.
---@return nil
function M:start(path, opts, view)
  self.started = vim.uv.hrtime()
  -- Recheck view authority before continuing and release an already-delivered stale placement.
  ---@param entry? ImageToolsPlacement Acknowledged lease to release on staleness.
  ---@return boolean valid
  local function current(entry)
    if not self.active or not view.current() then
      if entry and entry.cancel then
        entry.cancel()
      end
      if self.active then
        self:close()
        view.stale()
      end
      return false
    end
    return true
  end

  -- Release session resources before asking the controller to present failure.
  ---@param err string Preparation, placement or drawing error.
  ---@return nil
  local function fail(err)
    self.error, self.error_stage = tostring(err), self.stage
    self:close()
    view.error(err)
  end
  self.stage = "preparing"
  self:keep(self.image.prepare(path, opts, function(err, image, timing)
    if self.stage ~= "preparing" or not current() then
      return
    end
    self.prepared = vim.uv.hrtime()
    if timing then
      -- Shared workers may predate this subscriber. Count only overlapping time.
      self.measurements.queue_ms =
        elapsed(math.max(self.started, timing.queued), math.max(self.started, timing.started))
      self.measurements.conversion_ms =
        elapsed(math.max(self.started, timing.started), math.max(self.started, timing.finished))
    else
      self.measurements.queue_ms, self.measurements.conversion_ms = 0, 0
    end
    if err then
      fail(err)
      return
    end
    local width, height, crop = view.size(image)
    self.transfer_started = vim.uv.hrtime()
    self.stage = "placing"
    self:keep(self.transfer:acquire(image, width, height, function(transfer_err, entry, transfer_timing)
      if not current(entry) then
        return
      end
      if self.stage ~= "placing" then
        return
      end
      self.transferred = vim.uv.hrtime()
      if transfer_timing then
        self.measurements.upload_ms, self.measurements.placement_ms =
          transfer_timing.upload_ms, transfer_timing.placement_ms
      end
      if transfer_err then
        fail(transfer_err)
        return
      end
      local draw_started = vim.uv.hrtime()
      local ok, draw_err = pcall(view.draw, entry, width, height)
      self.measurements.draw_ms = elapsed(draw_started, vim.uv.hrtime())
      if not ok then
        fail(draw_err)
      else
        self.stage = "ready"
        self.finished = vim.uv.hrtime()
      end
    end, crop))
  end))
end

return M

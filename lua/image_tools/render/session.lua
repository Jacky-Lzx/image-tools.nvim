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
---@field size fun(image: ImageToolsImage): integer, integer Placement columns and rows.
---@field draw fun(entry: ImageToolsPlacement, width: integer, height: integer) Called only after acknowledgement.
---@class ImageToolsRenderSession
---@field image table Media dependency providing prepare.
---@field transfer ImageToolsTransfer Placement service.
---@field active boolean False after close; late-returned handles are released immediately.
---@field releases ImageToolsCancel[] Owned cleanup handles, released in reverse acquisition order.
---@field stage? "preparing"|"placing"|"ready" Duplicate-delivery guard; absent before start.
local M = {}
M.__index = M

-- Create one active prepare/place lifecycle without starting work.
---@param image table Media dependency with prepare.
---@param transfer ImageToolsTransfer View-scoped placement service.
---@return ImageToolsRenderSession session
function M.new(image, transfer)
  return setmetatable({ image = image, transfer = transfer, active = true, releases = {} }, M)
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
    self:close()
    view.error(err)
  end
  self.stage = "preparing"
  self:keep(self.image.prepare(path, opts, function(err, image)
    if self.stage ~= "preparing" or not current() then
      return
    end
    self.stage = "placing"
    if err then
      fail(err)
      return
    end
    local width, height = view.size(image)
    self:keep(self.transfer:acquire(image, width, height, function(transfer_err, entry)
      if not current(entry) then
        return
      end
      if self.stage ~= "placing" then
        return
      end
      self.stage = "ready"
      if transfer_err then
        fail(transfer_err)
        return
      end
      local ok, draw_err = pcall(view.draw, entry, width, height)
      if not ok then
        fail(draw_err)
      end
    end))
  end))
end

return M

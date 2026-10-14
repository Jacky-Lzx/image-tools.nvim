-- Module: image_tools.render.session
--
-- Purpose:
--   Own the common asynchronous preparation-to-placement lifecycle for one
--   view.
--
-- Architecture:
--   Bridge the image facade and a transfer manager. Controllers supply
--   authority checks, size, drawing and error callbacks, keeping window policy
--   outside the shared lifecycle.
--
-- Ownership:
--   Track preparation/placement stages and cancellation handles. Close releases
--   handles in reverse order, including handles returned after synchronous
--   closure; stale results cannot draw.

-- One preparation handle and one placement lease, bounded by view authority.
local M = {}
M.__index = M

function M.new(image, transfer)
  return setmetatable({ image = image, transfer = transfer, active = true, releases = {} }, M)
end

function M:keep(release)
  if self.active then
    self.releases[#self.releases + 1] = release
  else
    release()
  end
end

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

function M:start(path, opts, view)
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

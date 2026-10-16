vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local Session = require("image_tools.render.session")
local count = 0
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local function harness(sync, draw_error)
  local callbacks, prepared, placed, drawn, stale, errors = {}, 0, 0, 0, 0, 0
  local authority = true
  local session = Session.new({
    prepare = function(_, _, callback)
      callbacks.prepare = callback
      if sync then
        callback(nil, {})
      end
      return function()
        prepared = prepared + 1
      end
    end,
  }, {
    acquire = function(_, _, _, _, callback)
      callbacks.place = callback
      if sync then
        callback(nil, { id = 1 })
      end
      return function()
        placed = placed + 1
      end
    end,
  })
  session:start("fixture.png", {}, {
    current = function()
      return authority
    end,
    size = function()
      return 16, 5
    end,
    draw = function()
      drawn = drawn + 1
      if draw_error then
        error("drawing failed")
      end
    end,
    stale = function()
      stale = stale + 1
    end,
    error = function()
      errors = errors + 1
    end,
  })
  return session,
    callbacks,
    function()
      authority = false
    end,
    function()
      return { prepared, placed, drawn, stale, errors }
    end
end
local session, callbacks, invalidate, counts = harness(false)
callbacks.prepare(nil, {})
invalidate()
callbacks.place(nil, { id = 1 })
check(vim.deep_equal(counts(), { 1, 1, 0, 1, 0 }), "Authority loss releases preparation and placement without drawing")
session:close()
callbacks.prepare(nil, {})
check(vim.deep_equal(counts(), { 1, 1, 0, 1, 0 }), "Closed session ignores late preparation and closes once")
local late_release = 0
callbacks.place(nil, {
  cancel = function()
    late_release = late_release + 1
  end,
})
check(late_release == 1, "Late placement lease is returned immediately")
session, callbacks, invalidate, counts = harness(true, true)
check(vim.deep_equal(counts(), { 1, 1, 1, 0, 1 }), "Synchronous drawing failure releases handles returned after close")
session, callbacks, invalidate, counts = harness(true)
callbacks.prepare(nil, {})
callbacks.place(nil, { id = 1 })
check(vim.deep_equal(counts(), { 0, 0, 1, 0, 0 }), "Duplicate completions cannot redraw the view")
session:close()
session:close()
check(vim.deep_equal(counts(), { 1, 1, 1, 0, 0 }), "Visible session retains preparation lease until idempotent close")
-- Deterministic clock checks distinguish nested stage times, clip shared work
-- to this subscriber, and keep completed/failing totals fixed after delivery.
local hrtime, clock = vim.uv.hrtime, 100 * 1e6
vim.uv.hrtime = function()
  return clock
end
local prepared, transferred
session = Session.new({
  prepare = function(_, _, callback)
    prepared = callback
    return function() end
  end,
}, {
  acquire = function(_, _, _, _, callback)
    transferred = callback
    return function() end
  end,
}, { lookup_ms = 2, automatic_delay_ms = 100 })
local function view()
  return {
    current = function()
      return true
    end,
    stale = function() end,
    error = function() end,
    size = function()
      return 10, 10
    end,
    draw = function()
      clock = clock + 2 * 1e6
    end,
  }
end
session:start("timed.jpg", {}, view())
clock = 120 * 1e6
prepared(nil, {}, { queued = 90 * 1e6, started = 110 * 1e6, finished = 120 * 1e6 })
clock = 150 * 1e6
transferred(nil, {}, { upload_ms = 20, placement_ms = 10 })
local times = session:timings()
check(
  times.queue_ms == 10 and times.conversion_ms == 10 and times.preparation_ms == 20,
  "Shared worker times clip to subscriber start"
)
check(
  times.upload_ms == 20 and times.placement_ms == 10 and times.transfer_ms == 30,
  "Transfer phases remain independently visible"
)
check(times.draw_ms == 2 and times.total_ms == 154, "Total includes lookup, automatic delay and pipeline once")
times.total_ms = 0
clock = 200 * 1e6
check(session:timings().total_ms == 154, "Completed timing snapshots are independent and frozen")
session:close()
session = Session.new({
  prepare = function(_, _, callback)
    prepared = callback
    return function() end
  end,
}, {})
session:start("failed.jpg", {}, view())
clock = 210 * 1e6
prepared("failed", nil, { queued = 190 * 1e6, started = 205 * 1e6, finished = 209 * 1e6 })
clock = 1000 * 1e6
times = session:timings()
check(
  times.total_ms == 10 and times.queue_ms == 5 and times.conversion_ms == 4 and not times.transfer_ms,
  "Failures retain elapsed stages without inventing transfer work"
)
prepared(nil, {})
check(session:timings().total_ms == 10, "Late completions cannot rewrite failed timings")
vim.uv.hrtime = hrtime
print("render session: " .. count .. " assertions passed")

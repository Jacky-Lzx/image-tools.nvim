vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local Session = require("image_tools.render_session")
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
print("render session: " .. count .. " assertions passed")

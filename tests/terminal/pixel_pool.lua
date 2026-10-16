vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local Pool, config = require("image_tools.terminal.pixel_pool"), require("image_tools.config")
local count = 0
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local function fields(command)
  local result = {}
  for key, value in command:match("\27_G([^;\27]+)"):gmatch("([^,=]+)=([^,]+)") do
    result[key] = value
  end
  return result
end
local function harness(settings)
  local commands, pending, cancelled, held, rejected = {}, {}, 0, false, false
  local terminal = {
    write = function(command)
      commands[#commands + 1] = fields(command)
    end,
  }
  terminal.request = function(_, command, _, callback, placement)
    local f = fields(command)
    commands[#commands + 1] = f
    check(tonumber(f.p) == placement, "Request identity includes placement")
    if held then
      pending[#pending + 1] = callback
    else
      local err = rejected and f.a == "p" and "ENOENT: evicted" or nil
      if err then
        rejected = false
      end
      callback(err)
    end
    return function()
      cancelled = cancelled + 1
    end
  end
  local pool = Pool.new(config.resolve(settings or {}), { terminal = terminal })
  return pool,
    commands,
    pending,
    function(value)
      held = value
    end,
    function()
      rejected = true
    end,
    function()
      return cancelled
    end
end
local image =
  { key = "one", path = "/tmp/one.png", width = 160, height = 100, data = "payload", source = "/tmp/source.jpg" }
local function acquire(handle, width, height)
  local entry
  local release = handle:acquire(image, width or 16, height or 5, function(err, result)
    assert(not err, err)
    entry = result
  end)
  return entry, release
end
local pool, commands = harness()
local a, b = pool:manager(), pool:manager()
local first, release_a = acquire(a)
local second, release_b = acquire(b, 32, 10)
check(first.id == second.id and first.placement_id ~= second.placement_id, "Same pixels, independent placements")
check(pool:status().uploads == 1 and pool:status().placements == 2, "Two owners share one upload")
check(commands[2].c == "16" and commands[3].c == "32", "Each view retains independent dimensions")
a:clear()
check(commands[4].d == "i" and tonumber(commands[4].p) == first.placement_id, "Closing first only hides its placement")
check(pool:status().images == 1 and pool:status().placements == 1, "Other view remains pinned")
local third, release_c = acquire(a)
check(third.id == second.id and pool:status().uploads == 1, "Returning view reuses active pixels")
release_c()
release_b()
release_a()
check(pool:status().placements == 0 and pool:status().images == 1, "Last close retains bounded inactive cache")
local warm, release_warm = acquire(a)
check(warm.id == first.id and pool:status().uploads == 1, "Warm reopening needs only a placement request")
release_warm()
pool:clear()
check(pool:status().images == 0 and commands[#commands].d == "I", "Runtime clear frees shared pixels")
-- Coalesced pending uploads retain independent cancellation.
local pending, hold, reject, cancelled
pool, commands, pending, hold, reject, cancelled = harness()
a, b = pool:manager(), pool:manager()
hold(true)
local invoked_a, invoked_b = 0, 0
release_a = a:acquire(image, 16, 5, function()
  invoked_a = invoked_a + 1
end)
release_b = b:acquire(image, 32, 10, function(err)
  assert(not err, err)
  invoked_b = invoked_b + 1
end)
check(#commands == 1, "Cold simultaneous views coalesce upload")
release_a()
check(cancelled() == 0, "One cancellation preserves shared upload")
hold(false)
pending[1](nil)
check(invoked_a == 0 and invoked_b == 1, "Only surviving subscriber gets a placement")
check(pool:status().uploads == 1 and pool:status().placements == 1, "Pending fan-out uploads once")
release_b()
pool:clear()
-- Late upload completion after every owner leaves cannot create placements.
pool, commands, pending, hold, reject, cancelled = harness()
hold(true)
release_a = pool:manager():acquire(image, 16, 5, function()
  error("Cancelled upload callback")
end)
release_a()
pending[1](nil)
check(cancelled() == 1 and pool:status().images == 0, "Last cancellation releases partial upload")
check(commands[#commands].d == "I" and #commands == 2, "Late acknowledgement cannot place cancelled pixels")
-- Cached eviction retries once with a fresh image id and cancel routes to retry.
pool, commands, pending, hold, reject = harness()
a = pool:manager()
first, release_a = acquire(a)
release_a()
reject()
second, release_b = acquire(a)
check(second.id ~= first.id and pool:status().uploads == 2, "Evicted cache retransmits under fresh identity")
release_b()
check(pool:status().placements == 0, "Retry cancellation releases replacement lease")
pool:clear()
-- A missing placement cannot trigger an upload that overwrites another view.
pool, commands, pending, hold, reject = harness()
a, b = pool:manager(), pool:manager()
first, release_a = acquire(a)
reject()
local failure
b:acquire(image, 32, 10, function(err)
  failure = err
end)
check(
  failure and failure:match("ENOENT") and pool:status().uploads == 1,
  "Failure with another owner cannot retransmit its pixels"
)
check(pool:status().placements == 1 and pool:status().images == 1, "Placement failure only releases failing consumer")
release_a()
pool:clear()
-- Active pixels may exceed cache budget; another view must not evict them.
pool, commands = harness({ terminal_cache = { max_images = 1 } })
a, b = pool:manager(), pool:manager()
first, release_a = acquire(a)
local newer = vim.tbl_extend("force", image, { key = "two" })
local release_new = b:acquire(newer, 16, 5, function(err)
  assert(not err, err)
end)
check(pool:status().images == 2, "Two pinned versions survive a one-image budget")
release_a()
check(pool:status().images == 1 and pool:status().placements == 1, "Only unpinned old version is evicted")
release_new()
pool:clear()
-- Transfer construction has one interface, and shared managers release only
-- their own placements rather than clearing another view's cached pixels.
pool, commands = harness()
local Transfer = require("image_tools.terminal.transfer")
a = Transfer.new(config.resolve(), { pixel_pool = pool })
b = Transfer.new(config.resolve(), { pixel_pool = pool })
check(getmetatable(a) == Transfer and getmetatable(b) == Transfer, "Transfer constructors always return a manager")
first, release_a = acquire(a)
second, release_b = acquire(b)
a:clear()
check(pool:status().placements == 1 and pool:status().images == 1, "Shared transfer clear preserves other owners")
b:clear()
pool:clear()
-- Each consumer measures its own shared-upload wait; cached pixels need no
-- upload wait, and duplicate placement replies cannot add time or redeliver.
local hrtime, clock = vim.uv.hrtime, 100 * 1e6
vim.uv.hrtime = function()
  return clock
end
pool, commands, pending, hold = harness()
hold(true)
local first_time, second_time, deliveries = nil, nil, 0
a, b = pool:manager(), pool:manager()
release_a = a:acquire(image, 16, 5, function(err, _, timing)
  assert(not err, err)
  first_time, deliveries = timing, deliveries + 1
end)
clock = 110 * 1e6
release_b = b:acquire(image, 16, 5, function(err, _, timing)
  assert(not err, err)
  second_time, deliveries = timing, deliveries + 1
end)
clock = 120 * 1e6
pending[1](nil)
clock = 130 * 1e6
pending[2](nil)
pending[3](nil)
check(first_time.upload_ms == 20 and second_time.upload_ms == 10, "Shared consumers count only their own upload wait")
check(first_time.placement_ms == 10 and second_time.placement_ms == 10, "Placement replies have their own timing")
pending[2](nil)
check(deliveries == 2 and first_time.placement_ms == 10, "Duplicate reply cannot redeliver or inflate timing")
release_a()
release_b()
hold(false)
local warm_time
release_a = a:acquire(image, 16, 5, function(err, _, timing)
  assert(not err, err)
  warm_time = timing
end)
check(warm_time.upload_ms == 0, "Warm pixels record zero upload wait")
release_a()
pool:clear()
vim.uv.hrtime = hrtime
print("shared pixel pool: " .. count .. " assertions passed")

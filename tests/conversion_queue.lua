vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local Q, config = require("image_tools.conversion_queue"), require("image_tools.config")
local jobs, kills, received, count = {}, 0, 0, 0
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local original = vim.system
vim.system = function(command, _, callback)
  if command[1] == "throw" then
    error("spawn failed")
  end
  jobs[#jobs + 1] = { command = command[1], finish = callback }
  return {
    kill = function()
      kills = kills + 1
    end,
  }
end
local function enqueue(name)
  return Q.run({ name }, {}, function()
    received = received + 1
  end)
end
local a = enqueue("a")
enqueue("b")
local c = enqueue("c")
enqueue("d")
check(#jobs == 2 and Q.status().queued == 2, "Different inputs obey concurrency cap")
c()
c()
check(#jobs == 2 and Q.status().queued == 1, "Cancelled queued job never spawns")
a()
a()
check(kills == 1 and Q.status().active == 2, "Killed worker retains slot until exit")
jobs[1].finish({ code = 143 })
vim.wait(10)
check(#jobs == 3 and jobs[3].command == "d", "Next live job launches in FIFO order after exit")
jobs[2].finish({ code = 0 })
jobs[3].finish({ code = 0 })
vim.wait(10)
check(Q.status().active == 0 and received == 3, "Success and cancelled exits release slots")
Q.configure(1)
enqueue("throw")
enqueue("retry")
vim.wait(10)
check(jobs[4].command == "retry" and Q.status().active == 1, "Spawn exception releases slot")
jobs[4].finish({ code = 0 })
jobs[4].finish({ code = 0 })
vim.wait(10)
check(Q.status().active == 0 and received == 5, "Duplicate process callback cannot release twice")
check(config.resolve({}).convert_concurrency == 2, "Default converter budget")
check(not pcall(config.resolve, { convert_concurrency = 0 }), "Zero budget fails validation")
check(not pcall(config.resolve, { convert_concurrency = 1.5 }), "Fractional budget fails validation")
-- A single budget applies to existing queued work across reconfiguration.
Q.configure(2)
enqueue("old-a")
enqueue("old-b")
enqueue("waiting-a")
enqueue("waiting-b")
local started = #jobs
Q.configure(1)
check(Q.status().active == 2 and #jobs == started, "Reducing budget retains already running workers")
jobs[started - 1].finish({ code = 0 })
vim.wait(10)
check(#jobs == started and Q.status().active == 1, "Old queued work waits for the new lower budget")
jobs[started].finish({ code = 0 })
vim.wait(10)
check(#jobs == started + 1 and jobs[#jobs].command == "waiting-a", "Lower budget starts one FIFO successor")
Q.configure(2)
check(#jobs == started + 2 and jobs[#jobs].command == "waiting-b", "Increasing budget admits waiting work immediately")
jobs[started + 1].finish({ code = 0 })
jobs[started + 2].finish({ code = 0 })
vim.wait(10)
check(Q.status().active == 0 and Q.status().limit == 2, "Reconfigured queue drains without abandoning callbacks")
vim.system = original
print("conversion queue: " .. count .. " assertions passed")

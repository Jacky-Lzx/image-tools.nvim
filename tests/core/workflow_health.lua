vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local reports = {}
for _, kind in ipairs({ "start", "ok", "warn", "info", "error" }) do
  vim.health[kind] = function(message)
    reports[#reports + 1] = { kind = kind, message = message }
  end
end
local function contains(kind, message)
  return vim.iter(reports):any(function(row)
    return row.kind == kind and row.message:find(message, 1, true)
  end)
end
local health = require("image_tools.health")
health.check()
assert(contains("warn", "selection-tools unavailable"))
assert(contains("info", "plain diff fallback"))
local fixture = vim.fn.tempname()
for _, module in ipairs({ "selection_tools", "git_tools/diff" }) do
  vim.fn.mkdir(fixture .. "/lua/" .. module, "p")
  vim.fn.writefile({ 'error("Health must not execute this provider")' }, fixture .. "/lua/" .. module .. "/init.lua")
end
vim.opt.rtp:append(fixture)
reports = {}
health.check()
assert(contains("ok", "selection-tools available"))
assert(contains("ok", "git-tools shared native diff available"))
assert(not package.loaded.selection_tools and not package.loaded["git_tools.diff"])
assert(not package.loaded["image_tools.runtime"])
vim.opt.rtp:remove(fixture)
vim.fn.delete(fixture, "rf")
print("Image workflow health: fallback/provider reports without initialization passed")
